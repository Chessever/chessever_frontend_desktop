import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  UciEngine._({required this.binaryPath, required Process process})
    : _process = process,
      _stdoutLines = StreamController<String>.broadcast() {
    _bindProcessStreams();
  }

  final String binaryPath;
  final Process _process;
  final StreamController<String> _stdoutLines;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _disposed = false;

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
  }) async {
    final process = await Process.start(
      binaryPath,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    return UciEngine._(binaryPath: binaryPath, process: process);
  }

  void _bindProcessStreams() {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _stdoutLines.add,
          onError: (Object e) {
            if (kDebugMode) debugPrint('UCI stdout error: $e');
          },
        );
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (kDebugMode) debugPrint('UCI stderr: $line');
        });
  }

  /// Sends a UCI command and a trailing newline. The caller is responsible
  /// for any handshake (`uci`, `isready`) before issuing analysis commands.
  void send(String command) {
    if (_disposed) return;
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
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      send('stop');
      send('quit');
    } catch (_) {}
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      _process.kill();
    } catch (_) {}
    await _stdoutLines.close();
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
  // 1. Bundled asset.
  final bundled = await _ensureBundledBinary();
  if (bundled != null) return bundled;

  // 2. Homebrew on macOS.
  if (Platform.isMacOS) {
    for (final candidate in const <String>[
      '/opt/homebrew/bin/stockfish',
      '/usr/local/bin/stockfish',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
  }
  // 3. PATH fallback.
  try {
    final lookupTool = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(lookupTool, const ['stockfish']);
    if (result.exitCode == 0) {
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) return out.split(RegExp(r'[\r\n]')).first;
    }
  } catch (_) {
    // Silently fall through — caller treats null as "no engine available".
  }
  return null;
}

/// Copies the bundled Stockfish binary out of the Flutter asset bundle into
/// the app support directory on first launch. Returns the on-disk path of
/// the executable copy, or `null` if the bundle does not contain a
/// platform-appropriate binary (e.g. an old build that predates bundling).
Future<String?> _ensureBundledBinary() async {
  final assetPath = _bundledAssetPathForPlatform();
  if (assetPath == null) return null;

  try {
    final supportDir = await getApplicationSupportDirectory();
    final engineDir = Directory(p.join(supportDir.path, 'engine'));
    if (!await engineDir.exists()) {
      await engineDir.create(recursive: true);
    }

    final binaryName = Platform.isWindows ? 'stockfish.exe' : 'stockfish';
    final destination = File(p.join(engineDir.path, binaryName));

    // If we've already extracted the binary on a previous launch, reuse it.
    // Skip the size check for now — Stockfish releases ship at ~80 MB, and
    // a corrupted partial copy from a prior crash is the only realistic
    // case that would slip past `exists()`. The driver will fail at
    // `Process.start` with a clear message in that case, so it's not a
    // silent failure.
    if (!await destination.exists()) {
      final bytes = await rootBundle.load(assetPath);
      await destination.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      if (!Platform.isWindows) {
        // chmod +x on POSIX so the OS will exec the file.
        await Process.run('chmod', ['+x', destination.path]);
      }
    }
    return destination.path;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('⚠️ _ensureBundledBinary failed: $e');
    }
    return null;
  }
}

String? _bundledAssetPathForPlatform() {
  if (Platform.isMacOS) return 'assets/engine/macos/stockfish';
  if (Platform.isWindows) return 'assets/engine/windows/stockfish.exe';
  if (Platform.isLinux) return 'assets/engine/linux/stockfish';
  return null;
}
