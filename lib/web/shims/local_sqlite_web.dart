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
/// sees the same files SQLite writes.
///
/// Every handle opened on the same file shares one SQLite connection. On
/// desktop a second handle is a second connection, kept apart from the first
/// by file locks and able to wait on them from its own thread. A page has one
/// thread and no file locks, so a second connection would start with a cold
/// page cache, could not wait for the first, and would take the first one's
/// rollback journal for a crashed writer's and roll it back. Sharing gives
/// the "workers" that open the cache by path (tree builds, purges, imports)
/// the warm cache and makes their writes queue behind each other.
///
/// Writes are serialized per file; calls made inside a transaction body run
/// directly instead of waiting for the lock they already hold. Unlike the
/// native driver, a `select` made outside a running transaction on the same
/// file can see that transaction's uncommitted rows.

/// Must match the `sqlite3` version locked in pubspec.lock: the module's
/// imports are generated with the Dart bindings of that exact release.
const String _wasmAsset = 'sqlite/sqlite3-3.8.0.wasm';

/// Tests that run in a browser load the module from their own server.
String? debugLocalSqliteWasmUrl;

Future<sqlite.WasmSqlite3>? _engine;

Future<sqlite.WasmSqlite3> _loadEngine() {
  final pending =
      _engine ??= () async {
        final engine = await sqlite.WasmSqlite3.loadFromUrl(
          Uri.parse(debugLocalSqliteWasmUrl ?? _wasmAsset),
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

/// The one SQLite connection behind every [Database] handle on a file.
final class _Connection {
  _Connection(this.db, this.key, this.identity);

  final sqlite.CommonDatabase db;
  final String key;

  /// The file the connection was opened on. A path that is deleted and
  /// created again is a different file and gets its own connection.
  final Object? identity;
  int handles = 0;
  Future<void> writeTail = Future<void>.value();
  int savepoints = 0;

  static final Map<String, _Connection> _byPath = {};

  bool get insideTransaction =>
      identical(Zone.current[_transactionKey], this);

  void release() {
    if (--handles > 0) return;
    if (identical(_byPath[key], this)) _byPath.remove(key);
    db.close();
  }
}

final class Database {
  Database._(this._connection, this.path, this.readOnly) {
    _connection.handles++;
  }

  final _Connection _connection;
  final String path;
  final bool readOnly;
  bool _closed = false;

  sqlite.CommonDatabase get _db => _connection.db;

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
    final fs = WebFileSystem.instance;
    final key = WebFileSystem.normalize(path);
    final shared = _Connection._byPath[key];
    if (shared != null && identical(shared.identity, fs.fileIdentity(key))) {
      return Database._(shared, path, readOnly);
    }
    if (readOnly && !fs.fileExists(key)) {
      throw LocalSqliteConnectionException.openFailed(
        path,
        'unable to open database file',
        sqliteCode: sqlite.SqlError.SQLITE_CANTOPEN,
        extendedCode: sqlite.SqlError.SQLITE_CANTOPEN,
      );
    }
    try {
      // Always writable, so later handles on the file can share it; a
      // read-only handle refuses writes itself.
      final db = engine.open(key, mode: sqlite.OpenMode.readWriteCreate);
      try {
        // Proves the file is a readable database now, not at first query.
        db.select('PRAGMA schema_version');
        db.execute('PRAGMA foreign_keys = ON');
        // The file is already in memory; a rollback journal kept there too
        // would only be copied to IndexedDB and deleted again each write.
        // web_file_system.dart saves no file while a transaction is open,
        // so a reload never finds a half-written database without it.
        db.execute('PRAGMA journal_mode = MEMORY');
        // This connection is the file's only one, and the filesystem has no
        // locks to share it with. Left in the default mode SQLite gives the
        // lock up after each transaction and, taking it again, threw away
        // its page cache: every BEGIN cost 150 to 300 ms on a database of a
        // few thousand games, most of an import's time.
        db.execute('PRAGMA locking_mode = EXCLUSIVE');
        db.execute('PRAGMA temp_store = MEMORY');
        db.execute('PRAGMA cache_size = -16384');
      } catch (_) {
        db.close();
        rethrow;
      }
      final connection = _Connection(db, key, fs.fileIdentity(key));
      _Connection._byPath[key] = connection;
      return Database._(connection, path, readOnly);
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

  void _ensureWritable(String sql) {
    if (!readOnly) return;
    throw LocalSqliteQueryException(
      'attempt to write a readonly database',
      sql: sql,
      sqliteCode: sqlite.SqlError.SQLITE_READONLY,
      extendedCode: sqlite.SqlError.SQLITE_READONLY,
    );
  }

  bool get _insideTransaction => _connection.insideTransaction;

  /// Runs [write] after earlier writes to this file, unless already inside
  /// one of its transactions.
  Future<T> _serialized<T>(FutureOr<T> Function() write) {
    if (_insideTransaction) return Future.sync(write);
    final result = _connection.writeTail.then((_) => write());
    _connection.writeTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    // Closing from inside a transaction on this file must not wait for it.
    if (!_insideTransaction) await _connection.writeTail;
    if (_closed) return;
    _closed = true;
    _connection.release();
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
      if (readOnly && !_isReadOnlyStatement(sql)) _ensureWritable(sql);
      if (_keepsJournalMode(sql)) return WriteResult(0, _db.lastInsertRowId);
      _db.execute(sql, parameters);
      return WriteResult(_db.updatedRows, _db.lastInsertRowId);
    }, sql: sql);
  }

  void _batchNow(String sql, List<List<Object?>> paramSets) {
    _ensureOpen();
    checkUniformLocalSqliteParamSets(sql, paramSets);
    if (paramSets.isEmpty) return;
    _ensureWritable(sql);
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
    _ensureWritable('BEGIN');
    final connection = _connection;
    final nested = _insideTransaction;
    final savepoint = 's${++connection.savepoints}';
    try {
      _control(
        _db,
        nested ? 'SAVEPOINT $savepoint' : 'BEGIN IMMEDIATE',
        nested ? 'savepoint' : 'begin',
      );
    } catch (_) {
      connection.savepoints--;
      rethrow;
    }
    if (!nested) WebFileSystem.instance.holdSaves();
    final tx = Transaction._(this);
    try {
      final result = await runZoned(
        () => body(tx),
        zoneValues: {_transactionKey: connection},
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
      connection.savepoints--;
      if (!nested) WebFileSystem.instance.releaseSaves();
    }
  }
}

final RegExp _readOnlyStatement = RegExp(
  r'^\s*(select|pragma|explain|with)\b',
  caseSensitive: false,
);

bool _isReadOnlyStatement(String sql) => _readOnlyStatement.hasMatch(sql);

final RegExp _journalModeChange = RegExp(
  r'^\s*pragma\s+(\w+\.)?journal_mode\s*=',
  caseSensitive: false,
);

/// The desktop code switches databases between WAL and rollback journals,
/// which exist for other processes and crashes. Neither applies to a file
/// that lives in this page's memory, and WAL needs shared memory the browser
/// filesystem does not have, so the mode chosen at open stays.
bool _keepsJournalMode(String sql) => _journalModeChange.hasMatch(sql);

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
      zoneValues: {_transactionKey: _database._connection},
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
  _WebFsVfsFile(this.path, this.deleteOnClose)
    : _file = WebFileSystem.instance.openFile(path);

  final String path;
  final bool deleteOnClose;
  final WebFileHandle _file;
  int _lockMode = sqlite.SqlFileLockingLevels.SQLITE_LOCK_NONE;

  @override
  int readInto(Uint8List buffer, int offset) => _file.readInto(buffer, offset);

  @override
  void xWrite(Uint8List buffer, int fileOffset) =>
      _file.writeAt(buffer, fileOffset);

  @override
  int xFileSize() => _file.length;

  @override
  void xTruncate(int size) => _file.truncate(size);

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
    if (deleteOnClose) WebFileSystem.instance.deleteFile(path);
  }
}
