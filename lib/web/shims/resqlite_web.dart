import 'dart:async';

import 'dart:typed_data';

import 'package:sqlite3/wasm.dart' as sqlite;

import 'package:chessever/web/web_file_system.dart';

/// Web stand-in for `package:resqlite` (a native SQLite binding), with the
/// same surface the local library uses: [Database.open], `select`, `execute`,
/// `executeBatch`, `transaction` and [WriteResult].
///
/// It runs SQLite compiled to WebAssembly (`web/sqlite/`) on this thread.
/// Database files are ordinary files in the browser filesystem
/// (web_file_system.dart), so the code that renames, deletes or checks them
/// sees the same files SQLite writes. Writes are serialized, as
/// with resqlite's single writer; calls made inside a transaction body run
/// directly instead of waiting for the lock they already hold.
class ResqliteException implements Exception {
  ResqliteException(this.message);

  final String message;

  @override
  String toString() => 'ResqliteException: $message';
}

class ResqliteConnectionException extends ResqliteException {
  ResqliteConnectionException(super.message);

  ResqliteConnectionException.databaseClosed() : super('Database is closed.');
}

class ResqliteQueryException extends ResqliteException {
  ResqliteQueryException(super.message);
}

class ResqliteTransactionException extends ResqliteException {
  ResqliteTransactionException(super.message);
}

final class WriteResult {
  const WriteResult(this.affectedRows, this.lastInsertId);

  final int affectedRows;
  final int lastInsertId;
}

Future<sqlite.WasmSqlite3>? _engine;

Future<sqlite.WasmSqlite3> _loadEngine() {
  return _engine ??= () async {
    final engine = await sqlite.WasmSqlite3.loadFromUrl(
      Uri.parse('sqlite/sqlite3-3.3.3.wasm'),
    );
    engine.registerVirtualFileSystem(_WebFsVfs(), makeDefault: true);
    return engine;
  }();
}

T _guard<T>(T Function() body) {
  try {
    return body();
  } on sqlite.SqliteException catch (e) {
    throw ResqliteQueryException(e.toString());
  }
}

List<Map<String, Object?>> _rows(sqlite.ResultSet result) => [
  for (final row in result) Map<String, Object?>.of(row),
];

final Object _transactionKey = Object();

final class Database {
  Database._(this._db, this.path);

  final sqlite.CommonDatabase _db;
  final String path;
  bool _closed = false;
  Future<void> _writeTail = Future<void>.value();
  final StreamController<void> _changes = StreamController.broadcast();

  static Future<Database> open(
    String path, {
    String? encryptionKey,
    Iterable<Object> extensions = const [],
  }) async {
    try {
      final engine = await _loadEngine();
      return Database._(engine.open(path), path);
    } catch (e) {
      throw ResqliteConnectionException('Cannot open $path: $e');
    }
  }

  void _ensureOpen() {
    if (_closed) throw ResqliteConnectionException.databaseClosed();
  }

  bool get _insideTransaction =>
      identical(Zone.current[_transactionKey], this);

  /// Runs [write] after earlier writes, unless already inside one of this
  /// database's transactions.
  Future<T> _serialized<T>(FutureOr<T> Function() write) {
    if (_insideTransaction) return Future.sync(write);
    final result = _writeTail.then((_) => write());
    _writeTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    await _writeTail;
    _closed = true;
    _db.close();
    await _changes.close();
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _ensureOpen();
    return _guard(() => _rows(_db.select(sql, parameters)));
  }

  Stream<List<Map<String, Object?>>> stream(
    String sql, [
    List<Object?> parameters = const [],
  ]) async* {
    yield await select(sql, parameters);
    await for (final _ in _changes.stream) {
      yield await select(sql, parameters);
    }
  }

  WriteResult _executeNow(String sql, List<Object?> parameters) {
    _ensureOpen();
    return _guard(() {
      _db.execute(sql, parameters);
      return WriteResult(_db.updatedRows, _db.lastInsertRowId);
    });
  }

  void _batchNow(String sql, List<List<Object?>> paramSets) {
    _ensureOpen();
    _guard(() {
      final statement = _db.prepare(sql);
      try {
        for (final parameters in paramSets) {
          statement.execute(parameters);
        }
      } finally {
        statement.close();
      }
    });
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) => _serialized(() {
    final result = _executeNow(sql, parameters);
    _notify();
    return result;
  });

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      _serialized(() async {
        if (_insideTransaction) {
          _batchNow(sql, paramSets);
          return;
        }
        await _inTransaction((_) async => _batchNow(sql, paramSets));
      });

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      _serialized(() => _inTransaction(body));

  int _savepoints = 0;

  Future<T> _inTransaction<T>(Future<T> Function(Transaction tx) body) async {
    _ensureOpen();
    final nested = _insideTransaction;
    final savepoint = 'resqlite_web_${_savepoints++}';
    _guard(
      () => _db.execute(nested ? 'SAVEPOINT $savepoint' : 'BEGIN IMMEDIATE'),
    );
    final tx = Transaction._(this);
    try {
      final result = await runZoned(
        () => body(tx),
        zoneValues: {_transactionKey: this},
      );
      _guard(
        () => _db.execute(nested ? 'RELEASE $savepoint' : 'COMMIT'),
      );
      if (!nested) _notify();
      return result;
    } catch (_) {
      try {
        _db.execute(
          nested
              ? 'ROLLBACK TO $savepoint; RELEASE $savepoint'
              : 'ROLLBACK',
        );
      } catch (_) {}
      rethrow;
    } finally {
      tx._active = false;
      _savepoints--;
    }
  }
}

final class Transaction {
  Transaction._(this._database);

  final Database _database;
  bool _active = true;

  void _ensureActive() {
    if (!_active) {
      throw StateError('Transaction used after its body returned.');
    }
  }

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _ensureActive();
    return _database._executeNow(sql, parameters);
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _ensureActive();
    return _database.select(sql, parameters);
  }

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) async {
    _ensureActive();
    _database._batchNow(sql, paramSets);
  }

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) {
    _ensureActive();
    return runZoned(
      () => _database._inTransaction(body),
      zoneValues: {_transactionKey: _database},
    );
  }

  void close() => _active = false;
}

/// SQLite VFS over [WebFileSystem]: every database, journal and temp file
/// SQLite opens is a file there.
final class _WebFsVfs extends sqlite.BaseVirtualFileSystem {
  _WebFsVfs() : super(name: 'chessever-webfs');

  WebFileSystem get _fs => WebFileSystem.instance;

  @override
  int xAccess(String path, int flags) => _fs.fileExists(path) ? 1 : 0;

  @override
  void xDelete(String path, int syncDir) => _fs.deleteFile(path);

  @override
  String xFullPathName(String path) => WebFileSystem.normalize(path);

  @override
  sqlite.XOpenResult xOpen(sqlite.Sqlite3Filename path, int flags) {
    final name =
        path.path ?? '/tmp/sqlite-${DateTime.now().microsecondsSinceEpoch}';
    if (!_fs.fileExists(name)) {
      if (flags & sqlite.SqlFlag.SQLITE_OPEN_CREATE == 0) {
        throw sqlite.VfsException(sqlite.SqlError.SQLITE_CANTOPEN);
      }
      _fs.ensureFile(name);
    }
    final deleteOnClose = flags & sqlite.SqlFlag.SQLITE_OPEN_DELETEONCLOSE != 0;
    return (outFlags: 0, file: _WebFsVfsFile(name, deleteOnClose));
  }

  @override
  void xSleep(Duration duration) {}
}

final class _WebFsVfsFile extends sqlite.BaseVfsFile {
  _WebFsVfsFile(this.path, this.deleteOnClose);

  final String path;
  final bool deleteOnClose;
  int _lockMode = sqlite.SqlFileLockingLevels.SQLITE_LOCK_NONE;

  WebFileSystem get _fs => WebFileSystem.instance;

  @override
  int readInto(Uint8List buffer, int offset) =>
      _fs.readFileInto(path, buffer, offset);

  @override
  void xWrite(Uint8List buffer, int fileOffset) =>
      _fs.writeFileAt(path, buffer, fileOffset);

  @override
  int xFileSize() => _fs.fileSize(path);

  @override
  void xTruncate(int size) => _fs.truncateFile(path, size);

  @override
  void xSync(int flags) {}

  @override
  int xCheckReservedLock() =>
      _lockMode >= sqlite.SqlFileLockingLevels.SQLITE_LOCK_RESERVED ? 1 : 0;

  @override
  void xLock(int mode) => _lockMode = mode;

  @override
  void xUnlock(int mode) => _lockMode = mode;

  @override
  void xClose() {
    if (deleteOnClose) _fs.deleteFile(path);
  }
}
