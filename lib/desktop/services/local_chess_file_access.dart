import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const int _stableReadChunkBytes = 1024 * 1024;
const int _contentFingerprintSampleBytes = 64 * 1024;

/// An immutable-by-ownership copy of an external file and the metadata that
/// was validated while that copy was taken.
final class LocalChessFileSnapshot {
  const LocalChessFileSnapshot({required this.bytes, required this.sourceStat});

  final Uint8List bytes;
  final FileStat sourceStat;
}

/// Metadata obtained without touching an external path on the UI isolate.
///
/// Network shares and removable drives can block even for a simple `stat` or
/// entity-type query. Keeping those probes in a killable worker lets callers
/// use cache fast paths without reintroducing an unbounded pre-import wait.
final class LocalChessPathProbe {
  const LocalChessPathProbe({
    required this.type,
    this.sizeBytes,
    this.modifiedAt,
    this.changedAt,
    this.contentFingerprint,
  });

  final FileSystemEntityType type;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final DateTime? changedAt;
  final String? contentFingerprint;

  bool get isFile => type == FileSystemEntityType.file;
  bool get isDirectory => type == FileSystemEntityType.directory;
}

/// A recovery-oriented classification for failures while reading a local chess
/// file.
///
/// Native error text is localized by the operating system, so callers should
/// make decisions from [FileSystemException.osError] instead of matching that
/// text whenever an error code is available.
enum LocalChessFileAccessIssue {
  inUse,
  permissionDenied,
  missing,
  unavailable,
  noSpace,
  changed,
  stalled,
  unknown,
}

/// The error-code family used when interpreting a native [OSError].
///
/// This is public primarily so tests and imported diagnostics can identify the
/// originating platform. Runtime callers normally leave it unset.
enum LocalChessFileAccessPlatform { windows, posix }

/// A normalized local-file failure with recovery copy suitable for the UI.
final class LocalChessFileAccessException implements Exception {
  const LocalChessFileAccessException({
    required this.issue,
    this.path,
    this.cause,
    this.osErrorCode,
  });

  /// Normalizes an exception or a persisted scanner error string.
  ///
  /// [path] takes precedence over a path embedded in [error]. Pass [platform]
  /// when classifying diagnostics produced on a different operating system.
  factory LocalChessFileAccessException.from(
    Object error, {
    String? path,
    LocalChessFileAccessPlatform? platform,
  }) {
    if (error is LocalChessFileAccessException) {
      if (path == null || path.trim().isEmpty || path == error.path) {
        return error;
      }
      return LocalChessFileAccessException(
        issue: error.issue,
        path: path,
        cause: error.cause,
        osErrorCode: error.osErrorCode,
      );
    }

    final rawMessage = error.toString();
    final nativeCode =
        _nativeErrorCode(error) ??
        _nativeErrorCodeFromPersistedMessage(rawMessage);
    final resolvedPath =
        _nonEmpty(path) ??
        _pathFromError(error) ??
        _pathFromPersistedMessage(rawMessage);
    final resolvedPlatform = platform ?? _currentPlatform;
    var issue = _issueForNativeCode(nativeCode, resolvedPlatform);
    if (issue == LocalChessFileAccessIssue.unknown) {
      issue = _issueForMessage(rawMessage);
    }

    return LocalChessFileAccessException(
      issue: issue,
      path: resolvedPath,
      cause: error,
      osErrorCode: nativeCode,
    );
  }

  const LocalChessFileAccessException.changed({this.path, this.cause})
    : issue = LocalChessFileAccessIssue.changed,
      osErrorCode = null;

  const LocalChessFileAccessException.stalled({this.path, this.cause})
    : issue = LocalChessFileAccessIssue.stalled,
      osErrorCode = null;

  final LocalChessFileAccessIssue issue;
  final String? path;
  final Object? cause;
  final int? osErrorCode;

  String get userMessage {
    final subject = _fileSubject(path);
    return switch (issue) {
      LocalChessFileAccessIssue.inUse =>
        'ChessEver couldn\'t read $subject because another app, such as '
            'ChessBase, may be using it. Close the PGN in that app, then try '
            'again.',
      LocalChessFileAccessIssue.permissionDenied =>
        'ChessEver doesn\'t have permission to read $subject. Check the file\'s '
            'permissions or copy it to a local folder, then try again.',
      LocalChessFileAccessIssue.missing =>
        'ChessEver couldn\'t find $subject. It may have been moved or deleted. '
            'Choose the file again.',
      LocalChessFileAccessIssue.unavailable =>
        '$subject is on a drive or network location that isn\'t available. '
            'Reconnect it or copy the PGN to a local folder, then try again.',
      LocalChessFileAccessIssue.noSpace =>
        'ChessEver ran out of disk space while preparing $subject. Free some '
            'space, then try again.',
      LocalChessFileAccessIssue.changed =>
        '$subject changed while ChessEver was reading it. Finish saving it in '
            'the other app, or close it, then try again.',
      LocalChessFileAccessIssue.stalled =>
        'ChessEver stopped receiving data while reading $subject. Check the '
            'drive or network connection, or copy the PGN to a local folder, '
            'then try again.',
      LocalChessFileAccessIssue.unknown =>
        'ChessEver couldn\'t read $subject. Close it in other apps, check its '
            'permissions, or copy it to a local folder, then try again.',
    };
  }

  @override
  String toString() => userMessage;
}

/// Reads one stable, app-owned byte snapshot from an external chess file.
///
/// The original is opened exactly once per attempt. Metadata and handle length
/// are checked around the copy so a PGN that is still being saved cannot turn
/// into a mixed old/new import. Windows sharing violations are normalized into
/// actionable guidance; macOS/Linux writers are detected by the stability
/// checks because their locks are usually advisory.
Future<Uint8List> readStableLocalChessFileBytes(
  String path, {
  int maxAttempts = 2,
  int? maxBytes,
  Duration retryDelay = const Duration(milliseconds: 120),
  void Function(double fraction)? onProgress,
}) async {
  final snapshot = await readStableLocalChessFileSnapshot(
    path,
    maxAttempts: maxAttempts,
    maxBytes: maxBytes,
    retryDelay: retryDelay,
    onProgress: onProgress,
  );
  return snapshot.bytes;
}

/// Reads a stable byte snapshot together with its validated source metadata.
Future<LocalChessFileSnapshot> readStableLocalChessFileSnapshot(
  String path, {
  int maxAttempts = 2,
  int? maxBytes,
  Duration retryDelay = const Duration(milliseconds: 120),
  void Function(double fraction)? onProgress,
}) async {
  if (maxAttempts <= 0) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be > 0');
  }
  if (maxBytes != null && maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be > 0');
  }

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await _readStableLocalChessFileBytesOnce(
        path,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    } on LocalChessFileAccessException catch (error) {
      if (error.issue != LocalChessFileAccessIssue.changed ||
          attempt == maxAttempts) {
        rethrow;
      }
      await Future<void>.delayed(retryDelay);
    }
  }

  throw StateError('Stable PGN read exhausted without returning a result.');
}

/// Reads external bytes in a killable worker so a blocked drive or network
/// handle cannot leave a UI-only import waiting forever.
Future<Uint8List> readStableLocalChessFileBytesInWorker(
  String path, {
  int maxAttempts = 2,
  int? maxBytes,
  Duration retryDelay = const Duration(milliseconds: 120),
  Duration inactivityTimeout = const Duration(seconds: 30),
  @visibleForTesting Duration? debugWorkerStartDelay,
}) async {
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }

  final receivePort = ReceivePort();
  final completer = Completer<Uint8List>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: path),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError('Local PGN read worker exited without a result.'),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    switch (message) {
      case _StableReadWorkerProgress():
        armWatchdog();
      case _StableReadWorkerSuccess(:final bytes):
        inactivityTimer?.cancel();
        completer.complete(bytes.materialize().asUint8List());
      case _StableReadWorkerFailure(
        :final issue,
        :final message,
        :final osErrorCode,
      ):
        completeWithError(
          issue == null
              ? ArgumentError(message)
              : LocalChessFileAccessException(
                issue: issue,
                path: path,
                osErrorCode: osErrorCode,
              ),
          StackTrace.current,
        );
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _stableReadWorker,
      _StableReadWorkerRequest(
        sendPort: receivePort.sendPort,
        path: path,
        maxAttempts: maxAttempts,
        maxBytes: maxBytes,
        retryDelay: retryDelay,
        debugWorkerStartDelay: debugWorkerStartDelay,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The worker has already received an immediate kill request.
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

/// Probes a path in a killable worker.
///
/// When [includeContentFingerprint] is true, the worker verifies metadata
/// before and after sampling so callers never accept a fingerprint from a file
/// that changed mid-probe.
Future<LocalChessPathProbe> probeLocalChessPathInWorker(
  String path, {
  bool includeContentFingerprint = false,
  Duration inactivityTimeout = const Duration(seconds: 30),
  @visibleForTesting Duration? debugWorkerStartDelay,
}) async {
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }

  final receivePort = ReceivePort();
  final completer = Completer<LocalChessPathProbe>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: path),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError('Local path probe worker exited without a result.'),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    armWatchdog();
    switch (message) {
      case _StableReadWorkerProgress():
        break;
      case _PathProbeWorkerSuccess(
        :final typeCode,
        :final sizeBytes,
        :final modifiedAtMs,
        :final changedAtMs,
        :final contentFingerprint,
      ):
        inactivityTimer?.cancel();
        completer.complete(
          LocalChessPathProbe(
            type: _fileSystemEntityTypeForCode(typeCode),
            sizeBytes: sizeBytes,
            modifiedAt:
                modifiedAtMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs),
            changedAt:
                changedAtMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(changedAtMs),
            contentFingerprint: contentFingerprint,
          ),
        );
      case _StableReadWorkerFailure(
        :final issue,
        :final message,
        :final osErrorCode,
      ):
        completeWithError(
          issue == null
              ? StateError(message)
              : LocalChessFileAccessException(
                issue: issue,
                path: path,
                osErrorCode: osErrorCode,
              ),
          StackTrace.current,
        );
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _pathProbeWorker,
      _PathProbeWorkerRequest(
        sendPort: receivePort.sendPort,
        path: path,
        includeContentFingerprint: includeContentFingerprint,
        debugWorkerStartDelay: debugWorkerStartDelay,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The worker has already received an immediate kill request.
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

/// Recursively lists PGN files in a killable worker.
///
/// Directory enumeration can block on disconnected network mounts just like a
/// file read. Each discovered entity acts as a heartbeat for the watchdog.
Future<List<String>> listLocalChessPgnFilesInWorker(
  String directoryPath, {
  List<String> allowedSuffixes = const <String>['.pgn'],
  Duration inactivityTimeout = const Duration(seconds: 30),
  @visibleForTesting Duration? debugWorkerStartDelay,
}) async {
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }

  final receivePort = ReceivePort();
  final completer = Completer<List<String>>();
  final workerExited = Completer<void>();
  final paths = <String>[];
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: directoryPath),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError('Local PGN directory worker exited without a result.'),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    armWatchdog();
    switch (message) {
      case _PgnDirectoryWorkerPath(:final path):
        paths.add(path);
      case _PgnDirectoryWorkerSuccess():
        inactivityTimer?.cancel();
        completer.complete(List<String>.unmodifiable(paths));
      case _StableReadWorkerFailure(
        :final issue,
        :final message,
        :final osErrorCode,
      ):
        completeWithError(
          issue == null
              ? ArgumentError(message)
              : LocalChessFileAccessException(
                issue: issue,
                path: directoryPath,
                osErrorCode: osErrorCode,
              ),
          StackTrace.current,
        );
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _pgnDirectoryWorker,
      _PgnDirectoryWorkerRequest(
        sendPort: receivePort.sendPort,
        directoryPath: directoryPath,
        allowedSuffixes: List<String>.unmodifiable(
          allowedSuffixes.map((suffix) => suffix.toLowerCase()),
        ),
        debugWorkerStartDelay: debugWorkerStartDelay,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The worker has already received an immediate kill request.
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

/// Copies a stable external file snapshot to an app-owned destination.
///
/// This is the bounded-memory path for very large raw PGNs. Parsing can reopen
/// [destinationPath] freely without racing the application that owns [path].
/// The destination is removed after failed attempts.
Future<FileStat> copyStableLocalChessFile(
  String path,
  String destinationPath, {
  int maxAttempts = 2,
  Duration retryDelay = const Duration(milliseconds: 120),
  void Function(double fraction)? onProgress,
}) async {
  if (maxAttempts <= 0) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be > 0');
  }

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await _copyStableLocalChessFileOnce(
        path,
        destinationPath,
        onProgress: onProgress,
      );
    } on LocalChessFileAccessException catch (error) {
      await _deleteSnapshotBestEffort(destinationPath);
      if (error.issue != LocalChessFileAccessIssue.changed ||
          attempt == maxAttempts) {
        rethrow;
      }
      await Future<void>.delayed(retryDelay);
    } catch (_) {
      await _deleteSnapshotBestEffort(destinationPath);
      rethrow;
    }
  }

  throw StateError('Stable PGN copy exhausted without returning a result.');
}

Future<LocalChessFileSnapshot> _readStableLocalChessFileBytesOnce(
  String path, {
  required int? maxBytes,
  required void Function(double fraction)? onProgress,
}) async {
  final file = File(path);
  RandomAccessFile? input;
  Object? pendingError;
  try {
    input = await file.open(mode: FileMode.read);
    final before = await file.stat();
    final handleLength = await input.length();
    if (before.type != FileSystemEntityType.file) {
      throw LocalChessFileAccessException(
        issue: LocalChessFileAccessIssue.missing,
        path: path,
      );
    }
    if (maxBytes != null && handleLength > maxBytes) {
      throw ArgumentError(
        '"${localChessFileNameFromPath(path)}" is too large to open here.',
      );
    }

    final bytes = BytesBuilder(copy: false);
    var copied = 0;
    onProgress?.call(handleLength == 0 ? 1 : 0);
    while (copied < handleLength) {
      final chunk = await input.read(
        math.min(_stableReadChunkBytes, handleLength - copied),
      );
      if (chunk.isEmpty) {
        throw LocalChessFileAccessException.changed(path: path);
      }
      bytes.add(chunk);
      copied += chunk.length;
      onProgress?.call(
        handleLength == 0
            ? 1
            : (copied / handleLength).clamp(0.0, 1.0).toDouble(),
      );
    }

    final finalHandleLength = await input.length();
    final after = await file.stat();
    if (copied != handleLength ||
        finalHandleLength != handleLength ||
        !_sameStableFileMetadata(before, after, handleLength)) {
      throw LocalChessFileAccessException.changed(path: path);
    }
    onProgress?.call(1);
    return LocalChessFileSnapshot(bytes: bytes.takeBytes(), sourceStat: after);
  } on FileSystemException catch (error) {
    pendingError = error;
    throw LocalChessFileAccessException.from(error, path: path);
  } catch (error) {
    pendingError = error;
    rethrow;
  } finally {
    if (input != null) {
      try {
        await input.close();
      } on FileSystemException catch (error) {
        if (pendingError == null) {
          throw LocalChessFileAccessException.from(error, path: path);
        }
      }
    }
  }
}

/// Verifies that an external file still matches a previously stable snapshot.
///
/// The content fingerprint is checked in addition to timestamps so same-size
/// rewrites cannot leave snapshot-derived rows pointing into different bytes.
Future<void> validateLocalChessFileSnapshotSource(
  String path, {
  required FileStat expectedStat,
  required String expectedContentFingerprint,
}) async {
  try {
    final before = await File(path).stat();
    if (!_sameStableFileMetadata(expectedStat, before, expectedStat.size)) {
      throw LocalChessFileAccessException.changed(path: path);
    }
    final fingerprint = await computeLocalChessFileContentFingerprint(
      path,
      stat: before,
    );
    final after = await File(path).stat();
    if (!_sameStableFileMetadata(expectedStat, after, expectedStat.size) ||
        fingerprint != expectedContentFingerprint) {
      throw LocalChessFileAccessException.changed(path: path);
    }
  } on FileSystemException catch (error) {
    throw LocalChessFileAccessException.from(error, path: path);
  }
}

/// Computes the cache-compatible content fingerprint from app-owned bytes.
String computeLocalChessBytesContentFingerprint(Uint8List contents) {
  final size = contents.length;
  final bytes = BytesBuilder(copy: false)
    ..add(utf8.encode('chessever-local-pgn-fingerprint-v1:$size;'));

  if (size <= _contentFingerprintSampleBytes * 4) {
    bytes.add(contents);
  } else {
    void addSample(int start) {
      final clampedStart = start.clamp(0, size).toInt();
      final remaining = size - clampedStart;
      if (remaining <= 0) return;
      final length = math.min(remaining, _contentFingerprintSampleBytes);
      bytes.add(utf8.encode('$clampedStart:$length;'));
      bytes.add(
        Uint8List.sublistView(contents, clampedStart, clampedStart + length),
      );
    }

    addSample(0);
    addSample((size ~/ 2) - (_contentFingerprintSampleBytes ~/ 2));
    addSample(size - _contentFingerprintSampleBytes);
  }

  return 'v1:$size:${sha256.convert(bytes.takeBytes())}';
}

/// Computes the cache-compatible fingerprint by sampling a file.
Future<String> computeLocalChessFileContentFingerprint(
  String path, {
  FileStat? stat,
}) async {
  final file = File(path);
  final resolvedStat = stat ?? await file.stat();
  final size = resolvedStat.size;
  final bytes = BytesBuilder(copy: false)
    ..add(utf8.encode('chessever-local-pgn-fingerprint-v1:$size;'));

  if (size <= _contentFingerprintSampleBytes * 4) {
    bytes.add(await file.readAsBytes());
  } else {
    final raf = await file.open();
    try {
      Future<void> addSample(int start) async {
        final clampedStart = start.clamp(0, size).toInt();
        final remaining = size - clampedStart;
        if (remaining <= 0) return;
        final length = math.min(remaining, _contentFingerprintSampleBytes);
        await raf.setPosition(clampedStart);
        bytes.add(utf8.encode('$clampedStart:$length;'));
        bytes.add(await raf.read(length));
      }

      await addSample(0);
      await addSample((size ~/ 2) - (_contentFingerprintSampleBytes ~/ 2));
      await addSample(size - _contentFingerprintSampleBytes);
    } finally {
      await raf.close();
    }
  }

  return 'v1:$size:${sha256.convert(bytes.takeBytes())}';
}

Future<FileStat> _copyStableLocalChessFileOnce(
  String path,
  String destinationPath, {
  required void Function(double fraction)? onProgress,
}) async {
  final source = File(path);
  final destination = File(destinationPath);
  RandomAccessFile? input;
  RandomAccessFile? output;
  Object? pendingError;
  try {
    input = await source.open(mode: FileMode.read);
    final before = await source.stat();
    final handleLength = await input.length();
    if (before.type != FileSystemEntityType.file) {
      throw LocalChessFileAccessException(
        issue: LocalChessFileAccessIssue.missing,
        path: path,
      );
    }

    output = await destination.open(mode: FileMode.write);
    var copied = 0;
    onProgress?.call(handleLength == 0 ? 1 : 0);
    while (copied < handleLength) {
      final chunk = await input.read(
        math.min(_stableReadChunkBytes, handleLength - copied),
      );
      if (chunk.isEmpty) {
        throw LocalChessFileAccessException.changed(path: path);
      }
      await output.writeFrom(chunk);
      copied += chunk.length;
      onProgress?.call(
        handleLength == 0
            ? 1
            : (copied / handleLength).clamp(0.0, 1.0).toDouble(),
      );
    }
    await output.flush();

    final finalHandleLength = await input.length();
    final after = await source.stat();
    final destinationLength = await output.length();
    if (copied != handleLength ||
        destinationLength != handleLength ||
        finalHandleLength != handleLength ||
        !_sameStableFileMetadata(before, after, handleLength)) {
      throw LocalChessFileAccessException.changed(path: path);
    }
    onProgress?.call(1);
    return after;
  } on FileSystemException catch (error) {
    pendingError = error;
    throw LocalChessFileAccessException.from(error, path: path);
  } catch (error) {
    pendingError = error;
    rethrow;
  } finally {
    LocalChessFileAccessException? closeFailure;
    for (final handle in <RandomAccessFile?>[output, input]) {
      if (handle == null) continue;
      try {
        await handle.close();
      } on FileSystemException catch (error) {
        closeFailure ??= LocalChessFileAccessException.from(error, path: path);
      }
    }
    if (pendingError == null && closeFailure != null) throw closeFailure;
  }
}

Future<void> _deleteSnapshotBestEffort(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The caller still receives the original read/copy failure.
  }
}

bool _sameStableFileMetadata(FileStat before, FileStat after, int length) {
  return after.type == FileSystemEntityType.file &&
      before.size == length &&
      after.size == length &&
      before.modified == after.modified &&
      before.changed == after.changed;
}

/// Returns the last component of either a POSIX or Windows path.
///
/// `dart:io` path behavior follows the host OS, so splitting both separators
/// explicitly is necessary when displaying persisted Windows diagnostics on
/// macOS or Linux.
String localChessFileNameFromPath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  final separator = normalized.lastIndexOf('/');
  final fileName =
      separator < 0 ? normalized : normalized.substring(separator + 1);
  return fileName.isEmpty ? path.trim() : fileName;
}

LocalChessFileAccessPlatform get _currentPlatform =>
    Platform.isWindows
        ? LocalChessFileAccessPlatform.windows
        : LocalChessFileAccessPlatform.posix;

int? _nativeErrorCode(Object error) {
  if (error is FileSystemException) return error.osError?.errorCode;
  if (error is OSError) return error.errorCode;
  return null;
}

String? _pathFromError(Object error) {
  if (error is! FileSystemException) return null;
  return _nonEmpty(error.path);
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int? _nativeErrorCodeFromPersistedMessage(String message) {
  final match = RegExp(
    r'(?:errno|error(?:\s+code)?|code)\s*[=:]?\s*(-?\d+)',
    caseSensitive: false,
  ).firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String? _pathFromPersistedMessage(String message) {
  final quoted = RegExp(
    r'''path\s*=\s*(['"])(.*?)\1''',
    caseSensitive: false,
  ).firstMatch(message);
  return _nonEmpty(quoted?.group(2));
}

LocalChessFileAccessIssue _issueForNativeCode(
  int? code,
  LocalChessFileAccessPlatform platform,
) {
  if (code == null) return LocalChessFileAccessIssue.unknown;

  if (platform == LocalChessFileAccessPlatform.windows) {
    if (const <int>{32, 33, 108}.contains(code)) {
      return LocalChessFileAccessIssue.inUse;
    }
    if (const <int>{5, 65}.contains(code)) {
      return LocalChessFileAccessIssue.permissionDenied;
    }
    if (const <int>{2, 3}.contains(code)) {
      return LocalChessFileAccessIssue.missing;
    }
    if (const <int>{39, 112}.contains(code)) {
      return LocalChessFileAccessIssue.noSpace;
    }
    if (const <int>{21, 53, 55, 59, 64, 67, 121}.contains(code)) {
      return LocalChessFileAccessIssue.unavailable;
    }
    return LocalChessFileAccessIssue.unknown;
  }

  // Common Darwin/Linux errno values. Platform-specific conflicts (for
  // example Windows 112 vs Linux EHOSTDOWN) are resolved by [platform].
  if (code == 16) return LocalChessFileAccessIssue.inUse;
  if (const <int>{1, 13, 30}.contains(code)) {
    return LocalChessFileAccessIssue.permissionDenied;
  }
  if (const <int>{2, 20}.contains(code)) {
    return LocalChessFileAccessIssue.missing;
  }
  if (const <int>{28, 69, 122}.contains(code)) {
    return LocalChessFileAccessIssue.noSpace;
  }
  if (const <int>{
    5,
    6,
    19,
    50,
    51,
    54,
    57,
    60,
    64,
    65,
    70,
    100,
    101,
    104,
    107,
    110,
    112,
    113,
    116,
  }.contains(code)) {
    return LocalChessFileAccessIssue.unavailable;
  }
  return LocalChessFileAccessIssue.unknown;
}

LocalChessFileAccessIssue _issueForMessage(String message) {
  final normalized = message.toLowerCase();
  if (_containsAny(normalized, const <String>[
    'sharing violation',
    'lock violation',
    'being used by another process',
    'used by another process',
    'another app may be using',
    'another app, such as chessbase',
    'file is locked',
  ])) {
    return LocalChessFileAccessIssue.inUse;
  }
  if (_containsAny(normalized, const <String>[
    'permission denied',
    'operation not permitted',
    'access is denied',
    'access denied',
    'doesn\'t have permission',
  ])) {
    return LocalChessFileAccessIssue.permissionDenied;
  }
  if (_containsAny(normalized, const <String>[
    'no such file',
    'does not exist',
    'cannot find the file',
    'system cannot find',
    'couldn\'t find',
  ])) {
    return LocalChessFileAccessIssue.missing;
  }
  if (_containsAny(normalized, const <String>[
    'disk is full',
    'not enough space',
    'no space left on device',
    'quota exceeded',
    'ran out of disk space',
  ])) {
    return LocalChessFileAccessIssue.noSpace;
  }
  if (_containsAny(normalized, const <String>[
    'changed while',
    'modified while',
    'replaced while',
  ])) {
    return LocalChessFileAccessIssue.changed;
  }
  if (_containsAny(normalized, const <String>[
    'stopped receiving data',
    'stalled while',
    'read timed out',
  ])) {
    return LocalChessFileAccessIssue.stalled;
  }
  if (_containsAny(normalized, const <String>[
    'network path was not found',
    'network name is no longer available',
    'isn\'t available',
    'device is not ready',
    'semaphore timeout',
    'input/output error',
    'stale file handle',
  ])) {
    return LocalChessFileAccessIssue.unavailable;
  }
  return LocalChessFileAccessIssue.unknown;
}

bool _containsAny(String value, Iterable<String> candidates) {
  return candidates.any(value.contains);
}

String _fileSubject(String? path) {
  final nonEmptyPath = _nonEmpty(path);
  if (nonEmptyPath == null) return 'this PGN file';
  final fileName = localChessFileNameFromPath(
    nonEmptyPath,
  ).replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll('"', "'");
  return '"$fileName"';
}

final class _StableReadWorkerRequest {
  const _StableReadWorkerRequest({
    required this.sendPort,
    required this.path,
    required this.maxAttempts,
    required this.maxBytes,
    required this.retryDelay,
    required this.debugWorkerStartDelay,
  });

  final SendPort sendPort;
  final String path;
  final int maxAttempts;
  final int? maxBytes;
  final Duration retryDelay;
  final Duration? debugWorkerStartDelay;
}

final class _StableReadWorkerProgress {
  const _StableReadWorkerProgress();
}

final class _StableReadWorkerSuccess {
  const _StableReadWorkerSuccess(this.bytes);

  final TransferableTypedData bytes;
}

final class _StableReadWorkerFailure {
  const _StableReadWorkerFailure({
    required this.issue,
    required this.message,
    required this.osErrorCode,
  });

  final LocalChessFileAccessIssue? issue;
  final String message;
  final int? osErrorCode;
}

final class _PgnDirectoryWorkerRequest {
  const _PgnDirectoryWorkerRequest({
    required this.sendPort,
    required this.directoryPath,
    required this.allowedSuffixes,
    required this.debugWorkerStartDelay,
  });

  final SendPort sendPort;
  final String directoryPath;
  final List<String> allowedSuffixes;
  final Duration? debugWorkerStartDelay;
}

final class _PathProbeWorkerRequest {
  const _PathProbeWorkerRequest({
    required this.sendPort,
    required this.path,
    required this.includeContentFingerprint,
    required this.debugWorkerStartDelay,
  });

  final SendPort sendPort;
  final String path;
  final bool includeContentFingerprint;
  final Duration? debugWorkerStartDelay;
}

final class _PathProbeWorkerSuccess {
  const _PathProbeWorkerSuccess({
    required this.typeCode,
    required this.sizeBytes,
    required this.modifiedAtMs,
    required this.changedAtMs,
    required this.contentFingerprint,
  });

  final int typeCode;
  final int? sizeBytes;
  final int? modifiedAtMs;
  final int? changedAtMs;
  final String? contentFingerprint;
}

final class _PgnDirectoryWorkerPath {
  const _PgnDirectoryWorkerPath(this.path);

  final String path;
}

final class _PgnDirectoryWorkerSuccess {
  const _PgnDirectoryWorkerSuccess();
}

Future<void> _stableReadWorker(_StableReadWorkerRequest request) async {
  try {
    final debugDelay = request.debugWorkerStartDelay;
    if (debugDelay != null) await Future<void>.delayed(debugDelay);
    final bytes = await readStableLocalChessFileBytes(
      request.path,
      maxAttempts: request.maxAttempts,
      maxBytes: request.maxBytes,
      retryDelay: request.retryDelay,
      onProgress:
          (_) => request.sendPort.send(const _StableReadWorkerProgress()),
    );
    request.sendPort.send(
      _StableReadWorkerSuccess(
        TransferableTypedData.fromList(<Uint8List>[bytes]),
      ),
    );
  } on LocalChessFileAccessException catch (error) {
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: error.issue,
        message: error.userMessage,
        osErrorCode: error.osErrorCode,
      ),
    );
  } catch (error) {
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: null,
        message: error.toString(),
        osErrorCode: null,
      ),
    );
  }
}

Future<void> _pathProbeWorker(_PathProbeWorkerRequest request) async {
  try {
    final debugDelay = request.debugWorkerStartDelay;
    if (debugDelay != null) await Future<void>.delayed(debugDelay);
    request.sendPort.send(const _StableReadWorkerProgress());
    final type = await FileSystemEntity.type(request.path, followLinks: true);
    if (type != FileSystemEntityType.file) {
      request.sendPort.send(
        _PathProbeWorkerSuccess(
          typeCode: _fileSystemEntityTypeCode(type),
          sizeBytes: null,
          modifiedAtMs: null,
          changedAtMs: null,
          contentFingerprint: null,
        ),
      );
      return;
    }

    final before = await File(request.path).stat();
    request.sendPort.send(const _StableReadWorkerProgress());
    String? fingerprint;
    if (request.includeContentFingerprint) {
      fingerprint = await computeLocalChessFileContentFingerprint(
        request.path,
        stat: before,
      );
      request.sendPort.send(const _StableReadWorkerProgress());
    }
    final after = await File(request.path).stat();
    if (!_sameStableFileMetadata(before, after, before.size)) {
      throw LocalChessFileAccessException.changed(path: request.path);
    }
    request.sendPort.send(
      _PathProbeWorkerSuccess(
        typeCode: _fileSystemEntityTypeCode(type),
        sizeBytes: after.size,
        modifiedAtMs: after.modified.millisecondsSinceEpoch,
        changedAtMs: after.changed.millisecondsSinceEpoch,
        contentFingerprint: fingerprint,
      ),
    );
  } on LocalChessFileAccessException catch (error) {
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: error.issue,
        message: error.userMessage,
        osErrorCode: error.osErrorCode,
      ),
    );
  } on FileSystemException catch (error) {
    final normalized = LocalChessFileAccessException.from(
      error,
      path: request.path,
    );
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: normalized.issue,
        message: normalized.userMessage,
        osErrorCode: normalized.osErrorCode,
      ),
    );
  } catch (error) {
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: null,
        message: error.toString(),
        osErrorCode: null,
      ),
    );
  }
}

Future<void> _pgnDirectoryWorker(_PgnDirectoryWorkerRequest request) async {
  try {
    final debugDelay = request.debugWorkerStartDelay;
    if (debugDelay != null) await Future<void>.delayed(debugDelay);
    final type = await FileSystemEntity.type(
      request.directoryPath,
      followLinks: true,
    );
    if (type == FileSystemEntityType.file) {
      request.sendPort.send(const _PgnDirectoryWorkerSuccess());
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'File or folder does not exist',
        request.directoryPath,
      );
    }
    final suffixes = request.allowedSuffixes;
    await for (final entity in Directory(
      request.directoryPath,
    ).list(recursive: true, followLinks: false)) {
      final lowerPath = entity.path.toLowerCase();
      if (entity is File && suffixes.any(lowerPath.endsWith)) {
        request.sendPort.send(_PgnDirectoryWorkerPath(entity.path));
      } else {
        request.sendPort.send(const _StableReadWorkerProgress());
      }
    }
    request.sendPort.send(const _PgnDirectoryWorkerSuccess());
  } on FileSystemException catch (error) {
    final normalized = LocalChessFileAccessException.from(
      error,
      path: request.directoryPath,
    );
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: normalized.issue,
        message: normalized.userMessage,
        osErrorCode: normalized.osErrorCode,
      ),
    );
  } catch (error) {
    request.sendPort.send(
      _StableReadWorkerFailure(
        issue: null,
        message: error.toString(),
        osErrorCode: null,
      ),
    );
  }
}

int _fileSystemEntityTypeCode(FileSystemEntityType type) {
  if (type == FileSystemEntityType.file) return 1;
  if (type == FileSystemEntityType.directory) return 2;
  if (type == FileSystemEntityType.link) return 3;
  if (type == FileSystemEntityType.pipe) return 4;
  if (type == FileSystemEntityType.unixDomainSock) return 5;
  return 0;
}

FileSystemEntityType _fileSystemEntityTypeForCode(int code) {
  return switch (code) {
    1 => FileSystemEntityType.file,
    2 => FileSystemEntityType.directory,
    3 => FileSystemEntityType.link,
    4 => FileSystemEntityType.pipe,
    5 => FileSystemEntityType.unixDomainSock,
    _ => FileSystemEntityType.notFound,
  };
}
