import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/engine/stockfish_version.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';
import 'package:chessever/utils/host_platform.dart';
import 'package:chessever/web/web_engine_process_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/web_engine_process.dart';

/// Minimal UCI engine driver that talks to a chess engine binary over
/// stdin/stdout. Used on desktop where the `stockfish` Flutter package
/// (Android/iOS only) cannot be loaded.
///
/// The driver is intentionally low-level — it manages the process lifecycle
/// and surfaces a stream of UCI lines. Higher-level glue (eval parsing,
/// hash/threads tuning, multi-pv) lives in the existing analysis code so
/// the same logic can be reused once we wire the desktop engine into the
/// shared `StockfishSingleton` façade.
class UciEngine {
  UciEngine._({
    required this.binaryPath,
    required Process process,
    Duration gracefulExitTimeout = _defaultGracefulExitTimeout,
  }) : _process = process,
       _gracefulExitTimeout = gracefulExitTimeout,
       _stdoutLines = StreamController<String>.broadcast() {
    _liveEngines.add(this);
    _bindProcessStreams();
  }

  @visibleForTesting
  UciEngine.fromProcessForTesting(
    Process process, {
    Duration gracefulExitTimeout = _defaultGracefulExitTimeout,
  }) : this._(
         binaryPath: 'test-engine',
         process: process,
         gracefulExitTimeout: gracefulExitTimeout,
       );

  static const Duration _defaultGracefulExitTimeout = Duration(seconds: 2);
  static final Set<UciEngine> _liveEngines = <UciEngine>{};
  static int _inFlightProcessOperationCount = 0;
  static Completer<void>? _processOperationDrainCompleter;
  static int _activeDrainCount = 0;
  static bool _spawnsSuspended = false;

  final String binaryPath;
  final Process _process;
  final Duration _gracefulExitTimeout;
  final StreamController<String> _stdoutLines;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Future<void>? _disposeFuture;
  bool _disposing = false;
  bool _disposed = false;

  /// Stops every subprocess still owned by a UCI driver.
  ///
  /// Desktop shutdown must await this before the Dart VM tears down dart:io.
  /// On Windows, allowing a child-process exit callback to outlive dart:io
  /// shutdown can race the SDK's process-list mutex cleanup.
  /// See https://github.com/dart-lang/sdk/issues/60499.
  static Future<void> disposeAll() async {
    // Set the gate before inspecting either collection. Every tracked child
    // process operation increments the in-flight count synchronously before
    // its first await, so neither Process.start nor PATH discovery can slip
    // between this gate and the drain wait.
    _activeDrainCount += 1;
    _spawnsSuspended = true;
    try {
      await _waitForProcessOperationsToDrain();
      while (_liveEngines.isNotEmpty) {
        final engines = List<UciEngine>.of(_liveEngines);
        await Future.wait(engines.map((engine) => engine.dispose()));
      }
    } finally {
      _activeDrainCount -= 1;
    }
  }

  /// Re-enables process creation after an aborted external-termination flow.
  ///
  /// Only call this after the corresponding [disposeAll] future has completed.
  static void resumeSpawns() {
    // A recovery path must never reopen process creation underneath another
    // terminal drain. The caller can retry after the drain it owns completes.
    if (_activeDrainCount != 0) return;
    _spawnsSuspended = false;
  }

  /// Synchronously prevents new engine-owned child processes from starting.
  ///
  /// The shutdown coordinator calls this before it queues asynchronous service
  /// cleanup, closing the scheduling window before [disposeAll] takes over the
  /// full drain.
  static void suspendSpawns() {
    _spawnsSuspended = true;
  }

  @visibleForTesting
  static int get liveEngineCountForTesting => _liveEngines.length;

  @visibleForTesting
  static int get inFlightSpawnCountForTesting => _inFlightProcessOperationCount;

  @visibleForTesting
  static bool get spawnsSuspendedForTesting => _spawnsSuspended;

  /// Stream of stdout lines from the engine (already trimmed of `\n`).
  Stream<String> get lines => _stdoutLines.stream;

  /// Spawns the UCI binary at [binaryPath] and returns a connected driver.
  ///
  /// The resolver in [findStockfishBinary] should be used to obtain a
  /// platform-specific path before calling this.
  static Future<UciEngine> spawn(
    String binaryPath, {
    List<String> arguments = const <String>[],
    String? workingDirectory,
  }) {
    // The browser build has no processes; its engines run in Web Workers.
    if (kIsWeb) {
      return _spawn(
        binaryPath,
        processStarter: () => startWebEngineProcess(binaryPath),
      );
    }
    return _spawn(
      binaryPath,
      processStarter:
          () => Process.start(
            binaryPath,
            arguments,
            workingDirectory: workingDirectory,
            mode: ProcessStartMode.normal,
            runInShell: false,
          ),
    );
  }

  @visibleForTesting
  static Future<UciEngine> spawnForTesting(
    Future<Process> Function() processStarter, {
    Duration gracefulExitTimeout = _defaultGracefulExitTimeout,
  }) {
    return _spawn(
      'test-engine',
      processStarter: processStarter,
      gracefulExitTimeout: gracefulExitTimeout,
    );
  }

  static Future<UciEngine> _spawn(
    String binaryPath, {
    required Future<Process> Function() processStarter,
    Duration gracefulExitTimeout = _defaultGracefulExitTimeout,
  }) async {
    _beginProcessOperation();
    try {
      final process = await processStarter();
      final engine = UciEngine._(
        binaryPath: binaryPath,
        process: process,
        gracefulExitTimeout: gracefulExitTimeout,
      );
      if (_spawnsSuspended) {
        await engine.dispose();
        throw StateError('UCI engine spawning is suspended during shutdown.');
      }
      return engine;
    } finally {
      _endProcessOperation();
    }
  }

  static void _beginProcessOperation() {
    if (_spawnsSuspended) {
      throw StateError(
        'UCI child process creation is suspended during shutdown.',
      );
    }
    _inFlightProcessOperationCount += 1;
  }

  static void _endProcessOperation() {
    _inFlightProcessOperationCount -= 1;
    if (_inFlightProcessOperationCount == 0) {
      _processOperationDrainCompleter?.complete();
      _processOperationDrainCompleter = null;
    }
  }

  static Future<void> _waitForProcessOperationsToDrain() {
    if (_inFlightProcessOperationCount == 0) return Future<void>.value();
    return (_processOperationDrainCompleter ??= Completer<void>()).future;
  }

  static Future<ProcessResult> _runTrackedProcess(
    String executable,
    List<String> arguments,
  ) {
    return _trackProcessOperation(() => Process.run(executable, arguments));
  }

  @visibleForTesting
  static Future<ProcessResult> runPathLookupForTesting(
    Future<ProcessResult> Function() processRunner,
  ) {
    return _trackProcessOperation(processRunner);
  }

  static Future<T> _trackProcessOperation<T>(
    Future<T> Function() operation,
  ) async {
    _beginProcessOperation();
    try {
      return await operation();
    } finally {
      _endProcessOperation();
    }
  }

  // Engines are third-party binaries: an author or option name in Latin-1
  // is not valid UTF-8, and the strict decoder threw "Missing extension
  // byte" into the zone from the stderr listener, which has no onError
  // (CHESSEVER-23M). Malformed bytes become U+FFFD instead.
  static const _engineOutputDecoder = Utf8Decoder(allowMalformed: true);

  void _bindProcessStreams() {
    _stdoutSub = _process.stdout
        .transform(_engineOutputDecoder)
        .transform(const LineSplitter())
        .listen(
          _stdoutLines.add,
          onError: (Object e) {
            if (kDebugMode) debugPrint('UCI stdout error: $e');
          },
        );
    _stderrSub = _process.stderr
        .transform(_engineOutputDecoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (kDebugMode) debugPrint('UCI stderr: $line');
        });
  }

  /// Sends a UCI command and a trailing newline. The caller is responsible
  /// for any handshake (`uci`, `isready`) before issuing analysis commands.
  void send(String command) {
    if (_disposing || _disposed) return;
    _process.stdin.writeln(command);
  }

  /// Waits for the engine's `uciok` response, sets a few sensible default
  /// options, then waits for `readyok`. Returns true on success, false if
  /// the engine never identifies as UCI.
  Future<bool> initialize({int? threads, int? hashMb, int multiPv = 3}) async {
    if (_disposed) return false;
    final ready = Completer<bool>();

    final sub = lines.listen((line) {
      if (line == 'uciok') {
        if (threads != null) send('setoption name Threads value $threads');
        if (hashMb != null) send('setoption name Hash value $hashMb');
        send('setoption name MultiPV value $multiPv');
        send('isready');
      } else if (line == 'readyok') {
        if (!ready.isCompleted) ready.complete(true);
      }
    });

    send('uci');
    final ok = await ready.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () => false,
    );
    await sub.cancel();
    return ok;
  }

  /// Stops any running search and releases the underlying process. Idempotent.
  Future<void> dispose() {
    final pending = _disposeFuture;
    if (pending != null) return pending;

    // Gate new public commands immediately. _disposeProcess writes the two
    // terminal UCI commands directly so they cannot be swallowed by this gate.
    _disposing = true;
    final future = _disposeProcess();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeProcess() async {
    try {
      // Queue graceful termination before waiting. The previous implementation
      // marked the engine disposed first, causing send() to drop both commands.
      try {
        _process.stdin.writeln('stop');
        _process.stdin.writeln('quit');
        await _process.stdin.flush().timeout(_gracefulExitTimeout);
      } catch (_) {
        // A closed stdin normally means the child has already exited. The
        // exitCode wait below remains the authoritative lifecycle signal.
      }

      final exitedGracefully = await _waitForExit(_gracefulExitTimeout);
      if (!exitedGracefully) {
        try {
          // Windows ignores the signal and terminates the child. POSIX needs
          // SIGKILL here because the graceful SIGTERM-equivalent was `quit`.
          _process.kill(
            hostIsWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
          );
        } catch (_) {}

        // This wait is intentionally unbounded. Future.timeout does not cancel
        // Process.exitCode; proceeding while that callback is still pending is
        // the exact dart:io shutdown race this barrier exists to prevent.
        await _process.exitCode;
      }
    } finally {
      // Keep the pipe readers alive until after process exit; otherwise a full
      // pipe can prevent the child from reaching its exit path.
      try {
        await _process.stdin.close().timeout(_gracefulExitTimeout);
      } catch (_) {}
      try {
        await _stdoutSub?.cancel();
      } catch (_) {}
      try {
        await _stderrSub?.cancel();
      } catch (_) {}
      try {
        await _stdoutLines.close();
      } catch (_) {}
      _disposed = true;
      _liveEngines.remove(this);
    }
  }

  Future<bool> _waitForExit(Duration timeout) async {
    try {
      await _process.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Looks for a Stockfish binary in the conventional locations.
///
/// Order:
/// 1. Bundled asset under `assets/engine/<os>/stockfish[.exe]`. Copied to
///    `getApplicationSupportDirectory()/engine/` on first launch and
///    `chmod +x`ed on macOS so the OS will execute it. Idempotent —
///    subsequent launches return the cached path immediately.
/// 2. Common Homebrew install paths on macOS.
/// 3. `stockfish` on PATH (resolved via `which` on POSIX, `where` on
///    Windows). Useful for developer machines that already have Stockfish
///    installed.
///
/// Returns `null` if nothing is found. The caller should degrade gracefully
/// (disable engine UI / show a "configure engine" prompt) rather than
/// crashing the app.
Future<String?> findStockfishBinary() async {
  if (isMacAppStore) {
    // Store helpers are sealed and signed in the app bundle. Never extract an
    // executable to Application Support or discover an engine outside it.
    final helper = File(
      p.join(
        File(Platform.resolvedExecutable).parent.parent.path,
        'Helpers',
        'stockfish',
      ),
    );
    return await helper.exists() ? helper.path : null;
  }
  // 1. Bundled asset.
  final bundled = await _ensureBundledBinary();
  if (bundled != null) return bundled;

  // 2. Source-tree asset for local desktop debug/dev runs. Linux release
  // packaging injects its asset entry during CI, but local debug builds keep
  // the large binary out of pubspec.yaml so macOS/Windows bundles do not
  // accidentally carry it too.
  final sourceTree = await _findSourceTreeBinary();
  if (sourceTree != null) return sourceTree;

  // 3. Homebrew on macOS.
  if (hostIsMacOS) {
    for (final candidate in const <String>[
      '/opt/homebrew/bin/stockfish',
      '/usr/local/bin/stockfish',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
  }
  // 4. PATH fallback.
  try {
    final lookupTool = hostIsWindows ? 'where' : 'which';
    final result = await UciEngine._runTrackedProcess(lookupTool, const [
      'stockfish',
    ]);
    if (result.exitCode == 0) {
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) return out.split(RegExp(r'[\r\n]')).first;
    }
  } catch (_) {
    // Silently fall through — caller treats null as "no engine available".
  }
  return null;
}

Future<String?> _findSourceTreeBinary() async {
  final assetPath = _bundledAssetPathForPlatform();
  if (assetPath == null) return null;

  final candidates = <String>[
    p.join(Directory.current.path, assetPath),
    p.normalize(p.join(p.dirname(Platform.resolvedExecutable), assetPath)),
  ];

  for (final candidate in candidates) {
    final file = File(candidate);
    if (!await file.exists()) continue;
    if (!hostIsWindows) {
      try {
        await UciEngine._runTrackedProcess('chmod', ['+x', file.path]);
      } catch (_) {}
    }
    return file.path;
  }
  return null;
}

/// File name of the extracted bundled engine for this release. Naming the copy
/// after [kBundledStockfishVersion] makes an app update that ships a new
/// engine write a fresh copy instead of reusing the previous release's binary.
String bundledStockfishFileName({required bool windows}) =>
    windows
        ? 'stockfish-$kBundledStockfishVersion.exe'
        : 'stockfish-$kBundledStockfishVersion';

Future<String?>? _bundledBinaryExtraction;

/// Copies the bundled Stockfish binary out of the Flutter asset bundle into
/// the app support directory once per engine release. Returns the on-disk
/// path of the executable copy, or `null` if the bundle does not contain a
/// platform-appropriate binary (e.g. an old build that predates bundling).
Future<String?> _ensureBundledBinary() {
  final pending = _bundledBinaryExtraction ??= _extractBundledBinary();
  // A failed extraction can be retried by the next caller.
  pending.then((path) {
    if (path == null && identical(_bundledBinaryExtraction, pending)) {
      _bundledBinaryExtraction = null;
    }
  });
  return pending;
}

Future<String?> _extractBundledBinary() async {
  final assetPath = _bundledAssetPathForPlatform();
  if (assetPath == null) return null;

  try {
    final supportDir = await getApplicationSupportDirectory();
    final engineDir = Directory(p.join(supportDir.path, 'engine'));
    if (!await engineDir.exists()) {
      await engineDir.create(recursive: true);
    }

    final binaryName = bundledStockfishFileName(windows: hostIsWindows);
    final destination = File(p.join(engineDir.path, binaryName));

    // Written to a temporary name and renamed, so a crash mid-copy never
    // leaves a truncated binary at the final path.
    if (!await destination.exists()) {
      final bytes = await rootBundle.load(assetPath);
      final partial = File(
        '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.partial',
      );
      await partial.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      if (!hostIsWindows) {
        // chmod +x on POSIX so the OS will exec the file.
        await UciEngine._runTrackedProcess('chmod', ['+x', partial.path]);
      }
      try {
        await partial.rename(destination.path);
      } on FileSystemException {
        if (!await destination.exists()) rethrow;
        await partial.delete().catchError((Object _) => partial);
      }
    }
    unawaited(_deleteStaleBundledBinaries(engineDir, keep: binaryName));
    return destination.path;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('⚠️ _ensureBundledBinary failed: $e');
    }
    return null;
  }
}

/// Removes engine copies left by earlier releases (`stockfish`,
/// `stockfish.exe`, `stockfish-17.1`, ...) and abandoned partial copies.
/// Best effort: a file still held by a running process is left for the next
/// launch.
Future<void> _deleteStaleBundledBinaries(
  Directory engineDir, {
  required String keep,
}) async {
  try {
    await for (final entity in engineDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == keep || !isStaleBundledStockfishName(name, keep: keep)) {
        continue;
      }
      try {
        await entity.delete();
      } catch (_) {}
    }
  } catch (_) {}
}

/// Whether [name] in the engine directory is a bundled Stockfish copy other
/// than [keep]. Only `stockfish`, `stockfish.exe`, `stockfish-<version>[.exe]`
/// and their `.partial` copies match, so nothing else there is touched.
@visibleForTesting
bool isStaleBundledStockfishName(String name, {required String keep}) {
  // Another window may still be writing this release's partial copy.
  if (name == keep || name.startsWith('$keep.')) return false;
  return RegExp(
    r'^stockfish(-[0-9][0-9A-Za-z._]*)?(\.exe)?(\.[0-9]+\.partial)?$',
  ).hasMatch(name);
}

String? _bundledAssetPathForPlatform() {
  if (hostIsMacOS) return 'assets/engine/macos/stockfish';
  if (hostIsWindows) return 'assets/engine/windows/stockfish.exe';
  if (hostIsLinux) return 'assets/engine/linux/stockfish';
  return null;
}
