import 'dart:async';

import 'dart:typed_data';

import 'package:sqlite3/wasm.dart' as sqlite;

import 'package:chessever/desktop/services/local_sqlite/local_sqlite_types.dart';
import 'package:chessever/web/web_file_system.dart';

export 'package:chessever/desktop/services/local_sqlite/local_sqlite_types.dart';

/// Browser implementation of the local SQLite driver, with the same surface
/// as the native one (`local_sqlite_native.dart`): [Database.open],
/// `select`, `execute`, `executeBatch`, `transaction` and `close`.
///
/// It runs SQLite compiled to WebAssembly (`web/sqlite/`) on this thread.
/// Database files are ordinary files in the browser filesystem
/// (web_file_system.dart), so the code that renames, deletes or checks them
/// sees the same files SQLite writes. Writes are serialized per handle; calls
/// made inside a transaction body run directly instead of waiting for the
/// lock they already hold.
///
/// The browser has one thread and one connection per handle, so unlike the
/// native driver a `select` made outside a running transaction on the same
/// handle can see that transaction's uncommitted rows.

/// Must match the `sqlite3` version locked in pubspec.lock: the module's
/// imports are generated with the Dart bindings of that exact release.
const String _wasmAsset = 'sqlite/sqlite3-3.8.0.wasm';

Future<sqlite.WasmSqlite3>? _engine;

Future<sqlite.WasmSqlite3> _loadEngine() {
  final pending =
      _engine ??= () async {
        final engine = await sqlite.WasmSqlite3.loadFromUrl(
          Uri.parse(_wasmAsset),
        );
        engine.registerVirtualFileSystem(_WebFsVfs(), makeDefault: true);
        return engine;
      }();
  // A failed load (offline, a deploy swapping assets) must not be cached:
  // the next open retries it instead of failing until the page reloads.
  pending.then<void>(
    (_) {},
    onError: (Object _) {
      if (identical(_engine, pending)) _engine = null;
    },
  );
  return pending;
}

T _guard<T>(T Function() body, {String? sql}) {
  try {
    return body();
  } on sqlite.SqliteException catch (e) {
    final explanation = e.explanation;
    throw LocalSqliteQueryException(
      explanation == null || explanation == e.message
          ? e.message
          : '${e.message}, $explanation',
      sql: sql,
      sqliteCode: e.resultCode,
      extendedCode: e.extendedResultCode,
    );
  }
}

void _control(sqlite.CommonDatabase db, String sql, String operation) {
  try {
    db.execute(sql);
  } on sqlite.SqliteException catch (e) {
    throw LocalSqliteTransactionException(
      e.message,
      operation: operation,
      sqliteCode: e.resultCode,
      extendedCode: e.extendedResultCode,
    );
  }
}

LocalSqliteRows _rows(sqlite.ResultSet result) =>
    LocalSqliteRows(result.columnNames, result.rows);

final Object _transactionKey = Object();

final class Database {
  Database._(this._db, this.path, this.readOnly);

  final sqlite.CommonDatabase _db;
  final String path;
  final bool readOnly;
  bool _closed = false;
  Future<void> _writeTail = Future<void>.value();
  int _savepoints = 0;

  /// [onCurrentIsolate] is accepted for parity with the native driver; the
  /// browser always runs on the calling thread.
  static Future<Database> open(
    String path, {
    bool readOnly = false,
    bool onCurrentIsolate = false,
  }) async {
    final sqlite.WasmSqlite3 engine;
    try {
      engine = await _loadEngine();
    } catch (e) {
      throw LocalSqliteConnectionException.openFailed(
        path,
        'could not load SQLite ($e)',
      );
    }
    try {
      final db = engine.open(
        path,
        mode:
            readOnly
                ? sqlite.OpenMode.readOnly
                : sqlite.OpenMode.readWriteCreate,
      );
      try {
        // Proves the file is a readable database now, not at first query.
        db.select('PRAGMA schema_version');
        if (!readOnly) db.execute('PRAGMA foreign_keys = ON');
      } catch (_) {
        db.close();
        rethrow;
      }
      return Database._(db, path, readOnly);
    } on sqlite.SqliteException catch (e) {
      throw LocalSqliteConnectionException.openFailed(
        path,
        e.message,
        sqliteCode: e.resultCode,
        extendedCode: e.extendedResultCode,
      );
    } catch (e) {
      throw LocalSqliteConnectionException.openFailed(path, '$e');
    }
  }

  bool get isClosed => _closed;

  void _ensureOpen() {
    if (_closed) throw LocalSqliteConnectionException.databaseClosed();
  }

  bool get _insideTransaction => identical(Zone.current[_transactionKey], this);

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
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _ensureOpen();
    return _guard(() => _rows(_db.select(sql, parameters)), sql: sql);
  }

  WriteResult _executeNow(String sql, List<Object?> parameters) {
    _ensureOpen();
    return _guard(() {
      if (parameters.isNotEmpty && localSqliteHasMultipleStatements(sql)) {
        throw ArgumentError.value(
          sql,
          'sql',
          'Multiple statements cannot take parameters',
        );
      }
      _db.execute(sql, parameters);
      return WriteResult(_db.updatedRows, _db.lastInsertRowId);
    }, sql: sql);
  }

  void _batchNow(String sql, List<List<Object?>> paramSets) {
    _ensureOpen();
    checkUniformLocalSqliteParamSets(sql, paramSets);
    if (paramSets.isEmpty) return;
    _guard(() {
      final statement = _db.prepare(sql);
      try {
        for (final parameters in paramSets) {
          statement.execute(parameters);
        }
      } finally {
        statement.close();
      }
    }, sql: sql);
  }

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) => _serialized(() => _executeNow(sql, parameters));

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      _serialized(() async {
        if (_insideTransaction) {
          _batchNow(sql, paramSets);
          return;
        }
        checkUniformLocalSqliteParamSets(sql, paramSets);
        if (paramSets.isEmpty) return;
        await _inTransaction((_) async => _batchNow(sql, paramSets));
      });

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      _serialized(() => _inTransaction(body));

  Future<T> _inTransaction<T>(Future<T> Function(Transaction tx) body) async {
    _ensureOpen();
    final nested = _insideTransaction;
    final savepoint = 's${++_savepoints}';
    _control(
      _db,
      nested ? 'SAVEPOINT $savepoint' : 'BEGIN IMMEDIATE',
      nested ? 'savepoint' : 'begin',
    );
    final tx = Transaction._(this);
    try {
      final result = await runZoned(
        () => body(tx),
        zoneValues: {_transactionKey: this},
      );
      tx._active = false;
      _control(
        _db,
        nested ? 'RELEASE $savepoint' : 'COMMIT',
        nested ? 'release' : 'commit',
      );
      return result;
    } catch (_) {
      tx._active = false;
      try {
        if (!_db.autocommit) {
          if (nested) {
            _db.execute('ROLLBACK TO $savepoint');
            _db.execute('RELEASE $savepoint');
          } else {
            _db.execute('ROLLBACK');
          }
        }
      } catch (_) {}
      rethrow;
    } finally {
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
      throw StateError(
        'Transaction is no longer active. Use the transaction object only '
        'inside its body.',
      );
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
