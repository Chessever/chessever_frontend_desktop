/// Resilience, diagnostics and wording for local chess SQLite opens.
///
/// resqlite's open path is all-or-nothing: `Database.open` either returns a
/// handle or throws
/// `ResqliteConnectionException('Failed to open database at "<path>"')`.
/// That message is produced by resqlite 0.7.0
/// (`lib/src/native/open_database.dart`, thrown when the native `resqlite_open`
/// returns NULL). The native side returns NULL from exactly two places
/// (`native/resqlite.c` → `open_connection`):
///
/// 1. `sqlite3_open_v2(READWRITE|CREATE)` failed. On Windows `winOpen` maps a
///    failing `CreateFileW` to `SQLITE_CANTOPEN` (missing parent directory,
///    access denied, sharing violation that outlives SQLite's own retry loop).
/// 2. `PRAGMA journal_mode = WAL` failed **or did not report `wal`**. Switching
///    into WAL needs a write transaction on the file header, and SQLite leaves
///    the mode unchanged when the pager cannot change journal modes at all.
///
/// `busy_timeout` is applied *after* both steps, so an open that meets a
/// transient lock, an antivirus scan, or a file that is being replaced or
/// deleted right now fails **immediately, with no retry budget**, and the raw
/// native string used to reach the UI as the whole error message.
///
/// This file owns:
///
/// - the bounded retry/backoff for those transient open failures;
/// - the structured diagnostics that make the next occurrence explainable;
/// - the user-grade wording for the failures that survive the retries.
///
/// It deliberately does **not** retry a path that has gone missing: a vanished
/// file is a different, honest state, and the callers' fallbacks (reuse the
/// already-open app cache connection, or re-index the source) own that case.
/// Real errors that are not open failures are rethrown untouched.
library;

import 'dart:io';

import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_diagnostics.dart';

/// What the caller was doing with the database file, for diagnostics and
/// wording. Today every open goes through [LocalChessDatabaseOperation.open];
/// read/write exist so the log line names the actual phase once a query-level
/// failure is routed through here.
enum LocalChessDatabaseOperation { open, read, write }

/// What to do when the file is provably gone (or never existed).
enum LocalChessDatabaseAbsentPolicy {
  /// Return `null` so the caller can fall back to the connection it already
  /// has open (or re-index the source). Correct for regenerable sidecars such
  /// as `<db>.pgn.cetg`.
  fallBackToExistingConnection,

  /// Throw [LocalChessDatabaseUnavailableException]. Correct when the caller
  /// cannot continue without this exact file (the app-wide cache database).
  fail,
}

/// Bounded backoff for a transient local-database open failure.
///
/// Three retries cover the known transient windows — a source rebuild
/// publishing a new sidecar, a short-lived lock from another writer, and a
/// first-touch virus scan — without hiding a persistent failure: the caller
/// still surfaces an actionable error after ~2.3s of total backoff.
const List<Duration> localChessDatabaseOpenRetryDelays = <Duration>[
  Duration(milliseconds: 200),
  Duration(milliseconds: 600),
  Duration(milliseconds: 1500),
];

/// The open call, injectable so regression sources can drive failures without
/// touching the filesystem.
typedef LocalChessDatabaseOpenCall =
    Future<resqlite.Database> Function(String path);

/// A local chess database file that exists but cannot be opened.
///
/// The message is user-facing wording: it never contains the raw native
/// string, it names the database the user recognises, and it says what to do.
/// Also used by `toString()` so no surface can print the native text instead.
class LocalChessDatabaseUnavailableException implements Exception {
  const LocalChessDatabaseUnavailableException({
    required this.path,
    required this.operation,
    required this.attempts,
    this.purpose = '',
    this.label = '',
    this.retryable = true,
    this.cause,
  });

  /// Resolved path of the file that could not be opened. Diagnostics only.
  final String path;
  final LocalChessDatabaseOperation operation;

  /// How many open attempts were made (1 + the retries that ran).
  final int attempts;

  /// Short phase description, e.g. `opening-tree game index`.
  final String purpose;

  /// Optional user-facing name for the database, supplied by the caller when it
  /// knows the user's own file (e.g. `X.pgn` rather than `X.pgn.cetg`).
  final String label;

  /// True when re-running the same request can plausibly succeed.
  final bool retryable;

  /// The underlying failure, kept for logs. Never rendered to the user.
  final Object? cause;

  /// The user's own file name, with generated sidecar suffixes stripped so the
  /// wording names the database the user recognises.
  String get fileName {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    var name = (index < 0 ? normalized : normalized.substring(index + 1)).trim();
    if (name.isEmpty) return 'the local database';
    for (final suffix in const <String>[
      '.cetg',
      '.ceti',
      '.previous',
      '-wal',
      '-shm',
    ]) {
      if (name.toLowerCase().endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
      }
    }
    final staged = RegExp(r'\.build-\d+$');
    name = name.replaceFirst(staged, '');
    return name.trim().isEmpty ? 'the local database' : name;
  }

  String get displayName {
    final clean = label.trim();
    return clean.isEmpty ? fileName : clean;
  }

  String get message => switch (operation) {
    LocalChessDatabaseOperation.open =>
      'Could not open $displayName after $attempts '
          '${attempts == 1 ? 'attempt' : 'attempts'}. It may be rebuilding or '
          'in use by another program. Retry — and if it keeps failing, reopen '
          'the database from the Library.',
    LocalChessDatabaseOperation.read =>
      'Could not read $displayName. It may be rebuilding or in use by '
          'another program. Retry — and if it keeps failing, reopen the '
          'database from the Library.',
    LocalChessDatabaseOperation.write =>
      'Could not write to $displayName. It may be in use by another '
          'program. Retry — and if it keeps failing, reopen the database from '
          'the Library.',
  };

  @override
  String toString() => message;

  /// A copy carrying the caller's user-facing name for the database.
  LocalChessDatabaseUnavailableException withLabel(String label) {
    return LocalChessDatabaseUnavailableException(
      path: path,
      operation: operation,
      attempts: attempts,
      purpose: purpose,
      label: label,
      retryable: retryable,
      cause: cause,
    );
  }
}

/// True when re-running the same request can plausibly succeed: a database that
/// is being rebuilt, replaced or written by another connection.
bool isRetryableLocalChessDatabaseFailure(Object error) {
  if (error is LocalChessDatabaseUnavailableException) return error.retryable;
  if (isLocalChessDatabaseOpenFailure(error)) return true;
  final text = error.toString().toLowerCase();
  return text.contains('database is locked') ||
      text.contains('database is busy') ||
      text.contains('sqlite_busy') ||
      text.contains('sqlite code: 5');
}

/// Wording for any failure surfaced next to a local database read.
///
/// A raw resqlite open failure must never reach the user: it names an internal
/// sidecar path and class, and the widget-level string surgery used to turn
/// `ResqliteConnectionException: Failed to open database at "..."` into
/// `ResqliteConnectionFailed to open database at "..."` (the text users
/// actually saw) damaged it further. Everything else keeps its own message with
/// a leading `SomeException: ` type prefix removed, since that prefix is Dart
/// framing rather than a user-facing explanation.
String localChessDatabaseUserMessage(Object error) {
  if (error is LocalChessDatabaseUnavailableException) return error.message;
  if (isLocalChessDatabaseOpenFailure(error)) {
    return 'Could not open a local database. It may be rebuilding or in use by '
        'another program. Retry — and if it keeps failing, reopen the database '
        'from the Library.';
  }
  final raw = error.toString().trim();
  final withoutType = raw.replaceFirst(_leadingExceptionType, '').trim();
  return withoutType.isEmpty ? raw : withoutType;
}

final RegExp _leadingExceptionType = RegExp(
  r'^(?:[A-Za-z_][A-Za-z0-9_]*\.)*[A-Za-z_][A-Za-z0-9_]*(?:Exception|Error)\s*:\s*',
);

/// True when [error] is SQLite/resqlite refusing to *open* a database file.
///
/// Distinct from `database is locked` / `database is busy`, which the
/// repository already retries at the query level. Matching on the message keeps
/// this usable from sources that cannot import resqlite's exception type.
bool isLocalChessDatabaseOpenFailure(Object error) {
  if (error is resqlite.ResqliteConnectionException) {
    // resqlite also uses this type for "Database is closed." — only the open
    // failure carries the path-qualified wording.
    return error.message.contains('Failed to open database at') ||
        error.message.contains('unable to open database file');
  }
  final text = error.toString();
  return text.contains('Failed to open database at') ||
      text.contains('unable to open database file') ||
      text.contains('SQLITE_CANTOPEN') ||
      text.contains('sqlite code: 14');
}

/// The native error code, when the underlying failure carries one.
///
/// resqlite discards `sqlite3_open_v2`'s result code before throwing, so an
/// open failure usually has no code at all; a `dart:io` probe failure does
/// (Win32 `ERROR_SHARING_VIOLATION` = 32, `ERROR_ACCESS_DENIED` = 5,
/// `ERROR_PATH_NOT_FOUND` = 3), and a query failure carries `sqlite code: N`.
Object? localChessDatabaseErrorCode(Object? error) {
  if (error is FileSystemException) return error.osError?.errorCode;
  final text = error?.toString() ?? '';
  final match = RegExp(r'sqlite code: (\d+)').firstMatch(text);
  return match?.group(1);
}

/// Opens [path] with a bounded retry for transient open failures, structured
/// diagnostics, and user-grade wording when it still cannot be opened.
///
/// Returns `null` when the file is gone by the time the failure is classified
/// and [absentPolicy] is [LocalChessDatabaseAbsentPolicy.fallBackToExistingConnection]:
/// the caller keeps whatever connection it already has instead of dead-ending.
///
/// Throws [LocalChessDatabaseUnavailableException] once the retries are spent
/// on a file that is present but unopenable, and rethrows any error that is not
/// an open failure (a corrupt file, a bad query, a programming error) so real
/// faults are never swallowed.
Future<resqlite.Database?> openLocalChessDatabaseHandle({
  required String path,
  required LocalChessDatabaseOperation operation,
  String purpose = '',
  String label = '',
  LocalChessDatabaseAbsentPolicy absentPolicy =
      LocalChessDatabaseAbsentPolicy.fallBackToExistingConnection,
  LocalChessDatabaseOpenCall? open,
  List<Duration> retryDelays = localChessDatabaseOpenRetryDelays,
  Future<bool> Function(String path)? pathExists,
}) {
  return openLocalChessResourceWithRetry<resqlite.Database>(
    path: path,
    operation: operation,
    purpose: purpose,
    label: label,
    absentPolicy: absentPolicy,
    open: open ?? (String target) => resqlite.Database.open(target),
    retryDelays: retryDelays,
    pathExists: pathExists,
  );
}

/// The retry/diagnostic core of [openLocalChessDatabaseHandle], generic over the
/// handle type so regression sources can drive the transient-failure paths
/// without a real sqlite file.
Future<T?> openLocalChessResourceWithRetry<T>({
  required String path,
  required LocalChessDatabaseOperation operation,
  required Future<T> Function(String path) open,
  String purpose = '',
  String label = '',
  LocalChessDatabaseAbsentPolicy absentPolicy =
      LocalChessDatabaseAbsentPolicy.fallBackToExistingConnection,
  List<Duration> retryDelays = localChessDatabaseOpenRetryDelays,
  Future<bool> Function(String path)? pathExists,
}) async {
  final clean = path.trim();
  final exists = pathExists ?? _fileExists;
  final delays = retryDelays.isEmpty ? const <Duration>[] : retryDelays;
  final maxAttempts = delays.length + 1;

  if (clean.isEmpty) {
    throw LocalChessDatabaseUnavailableException(
      path: path,
      operation: operation,
      attempts: 0,
      purpose: purpose,
      label: label,
    );
  }

  for (var attempt = 1; ; attempt++) {
    try {
      return await open(clean);
    } catch (error, stackTrace) {
      if (!isLocalChessDatabaseOpenFailure(error)) rethrow;

      final stillThere = await _safePathExists(exists, clean);
      if (!stillThere &&
          absentPolicy ==
              LocalChessDatabaseAbsentPolicy.fallBackToExistingConnection) {
        _logOpen(
          'Local chess database open skipped: file is gone',
          level: _OpenLogLevel.warning,
          path: clean,
          operation: operation,
          purpose: purpose,
          attempt: attempt,
          maxAttempts: maxAttempts,
          retrying: false,
          error: error,
          stackTrace: stackTrace,
          probe: const <String, Object?>{'exists': false},
        );
        return null;
      }

      final exhausted = attempt >= maxAttempts;
      final probe = await localChessDatabasePathProbe(clean);
      _logOpen(
        exhausted
            ? 'Local chess database open failed'
            : 'Local chess database open failed; retrying',
        level: exhausted ? _OpenLogLevel.error : _OpenLogLevel.warning,
        path: clean,
        operation: operation,
        purpose: purpose,
        attempt: attempt,
        maxAttempts: maxAttempts,
        retrying: !exhausted,
        error: error,
        stackTrace: stackTrace,
        probe: probe,
      );

      if (!exhausted) {
        await Future<void>.delayed(delays[attempt - 1]);
        continue;
      }

      throw LocalChessDatabaseUnavailableException(
        path: clean,
        operation: operation,
        attempts: attempt,
        purpose: purpose,
        label: label,
        cause: error,
      );
    }
  }
}

/// Best-effort, read-only snapshot of the file state used to explain an open
/// failure. Never throws and never writes: it only reports what the OS says at
/// the moment of the failure.
Future<Map<String, Object?>> localChessDatabasePathProbe(String path) async {
  final probe = <String, Object?>{};
  final clean = path.trim();
  if (clean.isEmpty) return probe;
  final file = File(clean);
  try {
    final exists = await file.exists();
    probe['exists'] = exists;
    if (exists) {
      final stat = await file.stat();
      probe['sizeBytes'] = stat.size;
      probe['modifiedAgeMs'] =
          DateTime.now().millisecondsSinceEpoch -
          stat.modified.millisecondsSinceEpoch;
    }
    probe['parentExists'] = await file.parent.exists();
  } on Object catch (error) {
    probe['statError'] = error.toString();
    probe['statErrorCode'] = localChessDatabaseErrorCode(error);
  }
  if (probe['exists'] == true) {
    probe.addAll(await _journalVersionProbe(file));
  }
  if (probe['exists'] == true) {
    try {
      final handle = file.openSync();
      handle.closeSync();
      probe['osReadable'] = true;
    } on FileSystemException catch (error) {
      probe['osReadable'] = false;
      probe['probeErrorCode'] = error.osError?.errorCode;
      probe['probeError'] = error.osError?.message ?? error.message;
    } on Object catch (error) {
      probe['osReadable'] = false;
      probe['probeError'] = error.toString();
    }
  }
  return probe;
}

/// Bytes 18/19 of a SQLite file hold the file-format write/read version; `2/2`
/// means the file is in WAL mode. resqlite *requires* WAL — `open_connection`
/// fails the whole open when `PRAGMA journal_mode=WAL` does not report `wal` —
/// so this value at the moment of a failure is the single most useful piece of
/// evidence for the next occurrence: `walMode: false` points at the
/// rollback→WAL transition being refused, `walMode: true` points at the
/// underlying file open/handle itself. Read-only: it never modifies the file.
Future<Map<String, Object?>> _journalVersionProbe(File file) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open(mode: FileMode.read);
    await handle.setPosition(18);
    final bytes = await handle.read(2);
    if (bytes.length < 2) {
      return const <String, Object?>{'journalProbe': 'short-header'};
    }
    return <String, Object?>{
      'journalWriteVersion': bytes[0],
      'journalReadVersion': bytes[1],
      'walMode': bytes[0] == 2 && bytes[1] == 2,
    };
  } on Object catch (error) {
    return <String, Object?>{
      'journalProbeError': error.toString(),
      'journalProbeErrorCode': localChessDatabaseErrorCode(error),
    };
  } finally {
    try {
      await handle?.close();
    } on Object {
      // Best effort.
    }
  }
}

Future<bool> _fileExists(String path) async {
  try {
    return await File(path).exists();
  } on Object {
    return false;
  }
}

Future<bool> _safePathExists(
  Future<bool> Function(String path) exists,
  String path,
) async {
  try {
    return await exists(path);
  } on Object {
    return true;
  }
}

enum _OpenLogLevel { warning, error }

/// Diagnostics must never be able to break an open attempt, and a worker
/// isolate may not have the same reporter bindings as the UI isolate.
void _logOpen(
  String message, {
  required _OpenLogLevel level,
  required String path,
  required LocalChessDatabaseOperation operation,
  required String purpose,
  required int attempt,
  required int maxAttempts,
  required bool retrying,
  required Object error,
  required StackTrace stackTrace,
  required Map<String, Object?> probe,
}) {
  try {
    final context = <String, Object?>{
      'operation': operation.name,
      'purpose': purpose.isEmpty ? null : purpose,
      'path': path,
      'attempt': attempt,
      'attemptsAllowed': maxAttempts,
      'retrying': retrying,
      'errorType': error.runtimeType.toString(),
      'errorCode': localChessDatabaseErrorCode(error),
      ...probe,
    };
    if (level == _OpenLogLevel.error) {
      localChessLog.error(
        message,
        error,
        stackTrace,
        context: context,
        tag: 'local-chess.open',
      );
      return;
    }
    localChessLog.warning(
      message,
      context: context,
      error: error,
      stackTrace: stackTrace,
      tag: 'local-chess.open',
    );
  } on Object {
    // Diagnostics are best effort by contract.
  }
}
