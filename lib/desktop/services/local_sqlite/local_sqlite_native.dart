/// Native local SQLite driver: `package:sqlite3` over FFI, run off the
/// calling isolate.
///
/// One [Database] handle is one file:
///
/// - **Writes and transactions** run on the handle's own writer isolate, on a
///   single read-write connection. `transaction` holds that connection with
///   `BEGIN IMMEDIATE` for its whole body; its statements see the
///   transaction's own uncommitted writes.
/// - **Reads outside a transaction** run on a small process-wide pool of
///   reader isolates. Each reader keeps one read-only connection per handle
///   it has served, so a read sees committed data only and never waits
///   behind a write transaction (WAL snapshot isolation). Opening a
///   read-only handle spawns nothing: it opens one connection on a pooled
///   reader.
/// - `onCurrentIsolate: true` runs the connection on the calling isolate
///   instead, for code that already runs on a worker isolate (the opening
///   tree build). Never use it on the UI isolate.
///
/// Every connection is configured for parity with the files the previous
/// driver (resqlite) wrote: WAL, `synchronous=NORMAL`, `foreign_keys=ON`
/// (the schema's ON DELETE CASCADE / SET NULL depend on it), a busy timeout,
/// and `temp_store=MEMORY`. Each connection caches up to
/// [_statementCacheSize] prepared statements.
///
/// SQLite runs in `package:sqlite3`'s non-leaf FFI calls, so a long statement
/// on a worker isolate never holds up garbage collection on the UI isolate.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:chessever/desktop/services/local_sqlite/local_sqlite_types.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart' as sqlite;

export 'package:chessever/desktop/services/local_sqlite/local_sqlite_types.dart';

// ---------------------------------------------------------------------------
// Connection settings.
// ---------------------------------------------------------------------------

const int _writerBusyTimeoutMs = 20000;
const int _readerBusyTimeoutMs = 10000;
const int _statementCacheSize = 64;

/// Applied after `busy_timeout` and `journal_mode=WAL` on every read-write
/// connection.
const List<String> _writerPragmas = <String>[
  // package:sqlite3's prebuilt library defaults WAL to FULL; resqlite
  // compiled with SQLITE_DEFAULT_WAL_SYNCHRONOUS=1. NORMAL keeps committed
  // data safe across app crashes; only an OS crash can lose the last commits.
  'PRAGMA synchronous = NORMAL',
  'PRAGMA foreign_keys = ON',
  'PRAGMA temp_store = MEMORY',
  'PRAGMA mmap_size = 268435456',
  'PRAGMA cache_size = -65536',
  // Bound the WAL: checkpoint (PASSIVE, on this writer) every ~1000 pages
  // and truncate a reset WAL back to 64 MB.
  'PRAGMA wal_autocheckpoint = 1000',
  'PRAGMA journal_size_limit = 67108864',
];

const List<String> _readerPragmas = <String>[
  'PRAGMA foreign_keys = ON',
  'PRAGMA temp_store = MEMORY',
  'PRAGMA mmap_size = 268435456',
  // resqlite's per-reader value. Reads mostly come through the 256 MB mmap
  // window, and up to four readers keep a connection to the app cache.
  'PRAGMA cache_size = -8192',
  'PRAGMA wal_autocheckpoint = 0',
];

// ---------------------------------------------------------------------------
// Worker protocol. Every message is a List whose first two entries are the
// operation and the handle id; every reply is a List whose first entry is a
// reply tag.
// ---------------------------------------------------------------------------

const int _opOpenWriter = 0; // [op, id, path]
const int _opOpenReader = 1; // [op, id, path]
const int _opExecute = 2; // [op, id, sql, params]
const int _opSelect = 3; // [op, id, sql, params, path]
const int _opBatch = 4; // [op, id, sql, paramSets, atomic]
const int _opControl = 5; // [op, id, kind, savepointName]
const int _opCloseHandle =
    6; // [op, id] (reader: drop that handle's connection)
const int _opClose = 7; // [op, id] (writer/inline: close and stop)

const int _controlBegin = 0;
const int _controlCommit = 1;
const int _controlRollback = 2;
const int _controlSavepoint = 3;
const int _controlRelease = 4;
const int _controlRollbackTo = 5;

const List<String> _controlNames = <String>[
  'begin',
  'commit',
  'rollback',
  'savepoint',
  'release',
  'rollback_to',
];

const int _replyOk = 0; // [tag, value]
const int _replySqliteError = 1; // [tag, message, explanation, code, extended]
const int _replyOpenError = 2; // [tag, path, reason, code?, extended?]
const int _replyArgumentError = 3; // [tag, message]
const int _replyStateError = 4; // [tag, message]
const int _replyInternalError = 5; // [tag, error, stackTrace]

const int _roleWriter = 0;
const int _roleReader = 1;
const int _roleInline = 2;

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// A handle to one SQLite database file. See the library documentation for
/// how work is split between isolates.
final class Database {
  Database._({
    required this.path,
    required this.readOnly,
    required int id,
    required _Channel? connection,
    required bool inline,
  }) : _id = id,
       _connection = connection,
       _inline = inline;

  static int _nextId = 0;

  /// Opens [path], creating it when missing (unless [readOnly]).
  ///
  /// A writable handle is put in WAL mode and fails to open when WAL cannot
  /// be enabled. [readOnly] handles cannot write. [onCurrentIsolate] runs
  /// every statement synchronously on the calling isolate; use it only from a
  /// worker isolate.
  ///
  /// Throws [LocalSqliteConnectionException] whose message starts with
  /// `Failed to open database at "<path>"` when the file cannot be opened.
  static Future<Database> open(
    String path, {
    bool readOnly = false,
    bool onCurrentIsolate = false,
  }) async {
    final id = ++_nextId;
    final openMessage = <Object?>[
      readOnly ? _opOpenReader : _opOpenWriter,
      id,
      path,
    ];
    if (onCurrentIsolate) {
      final channel = _InlineChannel(_WorkerState(_roleInline));
      final reply = await channel.request(openMessage);
      _unwrap(reply, openPath: path);
      return Database._(
        path: path,
        readOnly: readOnly,
        id: id,
        connection: channel,
        inline: true,
      );
    }
    if (readOnly) {
      final pool = _ReaderPool.shared;
      try {
        _unwrap(await pool.submit(id, openMessage), openPath: path);
      } catch (_) {
        await pool.release(id);
        rethrow;
      }
      return Database._(
        path: path,
        readOnly: true,
        id: id,
        connection: null,
        inline: false,
      );
    }
    final _IsolateChannel channel;
    try {
      channel = await _IsolateChannel.spawn(
        _roleWriter,
        'local_sqlite.writer#$id',
      );
    } on LocalSqliteException {
      rethrow;
    } on Object catch (error) {
      throw LocalSqliteConnectionException.openFailed(
        path,
        'could not start the SQLite worker ($error)',
      );
    }
    try {
      _unwrap(await channel.request(openMessage), openPath: path);
    } catch (_) {
      // shutdown() stops the worker too; without that the idle isolate would
      // outlive every failed open (the open guard retries up to 4 times).
      await channel.shutdown();
      rethrow;
    }
    return Database._(
      path: path,
      readOnly: false,
      id: id,
      connection: channel,
      inline: false,
    );
  }

  /// The path this handle was opened with.
  final String path;

  /// Whether this handle rejects writes.
  final bool readOnly;

  final int _id;

  /// Writer isolate (writable handles), the inline connection
  /// ([onCurrentIsolate] handles), or null (pooled read-only handles).
  final _Channel? _connection;
  final bool _inline;

  final _Mutex _writeLock = _Mutex();
  final Object _zoneKey = Object();
  final Set<Future<void>> _inFlight = <Future<void>>{};
  bool _closeRequested = false;
  Future<void>? _closing;

  /// Whether [close] was called.
  bool get isClosed => _closeRequested;

  /// Runs [sql] and returns its rows.
  ///
  /// Outside a transaction this reads the last committed state on a pooled
  /// read-only connection; inside one of this handle's transactions it reads
  /// on the transaction's connection and sees its uncommitted writes.
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    final transaction = _activeTransaction;
    if (transaction != null) return transaction.select(sql, parameters);
    return _track(() async {
      _ensureOpen();
      final message = <Object?>[_opSelect, _id, sql, parameters, path];
      final connection = _connection;
      final reply =
          _inline && connection != null
              ? await connection.request(message)
              : await _ReaderPool.shared.submit(_id, message);
      return _rows(reply, sql);
    });
  }

  /// Runs one write statement (or several, when [parameters] is empty) in
  /// its own autocommit transaction.
  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    final transaction = _activeTransaction;
    if (transaction != null) return transaction.execute(sql, parameters);
    return _track(() async {
      _ensureOpen();
      final connection = _writableConnection(sql);
      final reply = await _sendLocked(connection, <Object?>[
        _opExecute,
        _id,
        sql,
        parameters,
      ]);
      return _writeResult(reply, sql);
    });
  }

  /// Runs [sql] once per entry of [paramSets] with one prepared statement,
  /// atomically: all rows apply or none do.
  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) {
    final transaction = _activeTransaction;
    if (transaction != null) return transaction.executeBatch(sql, paramSets);
    return _track(() async {
      _ensureOpen();
      checkUniformLocalSqliteParamSets(sql, paramSets);
      if (paramSets.isEmpty) return;
      final connection = _writableConnection(sql);
      final reply = await _sendLocked(connection, <Object?>[
        _opBatch,
        _id,
        sql,
        paramSets,
        true,
      ]);
      _unwrap(reply, sql: sql);
    });
  }

  /// Runs [body] in one `BEGIN IMMEDIATE` transaction on this handle's
  /// writer connection.
  ///
  /// Other writes on this handle wait until it ends. When [body] throws, the
  /// transaction rolls back and the same error is rethrown. Calls made on this
  /// handle from inside [body]'s zone join the transaction; a nested
  /// `transaction` becomes a savepoint.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) {
    final current = _activeTransaction;
    if (current != null) return current.transaction(body);
    return _track(() async {
      _ensureOpen();
      final connection = _writableConnection('BEGIN IMMEDIATE');
      await _writeLock.lock();
      try {
        await _control(connection, _controlBegin);
        final transaction = Transaction._(this, connection, 0);
        final T result;
        try {
          result = await runZoned(
            () => body(transaction),
            zoneValues: <Object, Object?>{_zoneKey: transaction},
          );
        } catch (error, stackTrace) {
          transaction._active = false;
          try {
            await _control(connection, _controlRollback);
          } on Object {
            // The body's error is the one the caller needs.
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
        transaction._active = false;
        await _control(connection, _controlCommit);
        return result;
      } finally {
        _writeLock.unlock();
      }
    });
  }

  /// Waits for running work, then closes every connection of this handle.
  ///
  /// Safe to call more than once. When this handle holds the last connection
  /// to its file, SQLite checkpoints the WAL into the database file and
  /// deletes the `-wal` / `-shm` sidecars, so the file can be renamed or
  /// copied on its own afterwards.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closeRequested = true;
    while (_inFlight.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_inFlight));
    }
    await _writeLock.lock();
    final connection = _connection;
    if (!_inline) {
      final released = _ReaderPool.shared.release(_id);
      if (connection == null) {
        // A pooled read-only handle: its connections close in each reader's
        // queue order. Normally that is immediate, but a reader may already be
        // running another handle's long read, so a query that opens and closes
        // a handle must not wait behind it. Its id is already detached from
        // every reader, so nothing new can reach those connections.
        await released.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () {},
        );
        return;
      }
      await released;
    }
    // Closes the connection (checkpointing the WAL when it is the file's last
    // one) and stops its worker.
    await connection?.shutdown();
  }

  Transaction? get _activeTransaction {
    final value = Zone.current[_zoneKey];
    if (value is Transaction && value._active) return value;
    return null;
  }

  void _ensureOpen() {
    if (_closeRequested) throw LocalSqliteConnectionException.databaseClosed();
  }

  _Channel _writableConnection(String sql) {
    final connection = _connection;
    if (readOnly || connection == null) {
      throw LocalSqliteQueryException(
        'attempt to write a readonly database (opened read-only)',
        sql: sql,
        sqliteCode: 8,
        extendedCode: 8,
      );
    }
    return connection;
  }

  /// Sends one standalone write while holding the write lock, so it can never
  /// interleave with a transaction. The lock is released once the request is
  /// queued: the worker runs its queue in order.
  Future<List<Object?>> _sendLocked(
    _Channel connection,
    List<Object?> message,
  ) async {
    await _writeLock.lock();
    final Future<List<Object?>> reply;
    try {
      reply = connection.request(message);
    } finally {
      _writeLock.unlock();
    }
    return reply;
  }

  Future<void> _control(
    _Channel connection,
    int kind, [
    String? savepoint,
  ]) async {
    final reply = await connection.request(<Object?>[
      _opControl,
      _id,
      kind,
      savepoint,
    ]);
    _unwrap(reply, controlOperation: _controlNames[kind]);
  }

  Future<T> _track<T>(Future<T> Function() operation) {
    final future = operation();
    final done = future.then<void>((_) {}, onError: (Object _) {});
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
    return future;
  }
}

/// The transaction passed to [Database.transaction]'s body. Valid only until
/// the body returns.
final class Transaction {
  Transaction._(this._database, this._connection, this._depth);

  final Database _database;
  final _Channel _connection;
  final int _depth;
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
    List<Object?> parameters = const <Object?>[],
  ]) async {
    _ensureActive();
    final reply = await _connection.request(<Object?>[
      _opExecute,
      _database._id,
      sql,
      parameters,
    ]);
    return _writeResult(reply, sql);
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) async {
    _ensureActive();
    final reply = await _connection.request(<Object?>[
      _opSelect,
      _database._id,
      sql,
      parameters,
      _database.path,
    ]);
    return _rows(reply, sql);
  }

  /// Like [Database.executeBatch], but part of this transaction: it adds no
  /// transaction of its own, so a failing row leaves the earlier rows applied
  /// until the transaction rolls back.
  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) async {
    _ensureActive();
    checkUniformLocalSqliteParamSets(sql, paramSets);
    if (paramSets.isEmpty) return;
    final reply = await _connection.request(<Object?>[
      _opBatch,
      _database._id,
      sql,
      paramSets,
      false,
    ]);
    _unwrap(reply, sql: sql);
  }

  /// Runs [body] in a savepoint nested in this transaction.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) async {
    _ensureActive();
    final savepoint = 's${_depth + 1}';
    await _database._control(_connection, _controlSavepoint, savepoint);
    final nested = Transaction._(_database, _connection, _depth + 1);
    final T result;
    try {
      result = await runZoned(
        () => body(nested),
        zoneValues: <Object, Object?>{_database._zoneKey: nested},
      );
    } catch (error, stackTrace) {
      nested._active = false;
      try {
        await _database._control(_connection, _controlRollbackTo, savepoint);
      } on Object {
        // The body's error is the one the caller needs.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    nested._active = false;
    await _database._control(_connection, _controlRelease, savepoint);
    return result;
  }
}

// ---------------------------------------------------------------------------
// Reply decoding (caller side).
// ---------------------------------------------------------------------------

LocalSqliteRows _rows(List<Object?> reply, String sql) {
  final value = _unwrap(reply, sql: sql) as List<Object?>;
  return LocalSqliteRows(
    value[0] as List<String>,
    value[1] as List<List<Object?>>,
  );
}

WriteResult _writeResult(List<Object?> reply, String sql) {
  final value = _unwrap(reply, sql: sql) as List<int>;
  return WriteResult(value[0], value[1]);
}

/// Returns the value of an OK reply, or throws the error a failed reply
/// carries, typed by what was being done.
Object? _unwrap(
  List<Object?> reply, {
  String? sql,
  String? controlOperation,
  String? openPath,
}) {
  switch (reply[0] as int) {
    case _replyOk:
      return reply[1];
    case _replySqliteError:
      final message = reply[1] as String;
      final explanation = reply[2] as String?;
      final code = reply[3] as int;
      final extended = reply[4] as int;
      final text =
          explanation == null || explanation == message
              ? message
              : '$message, $explanation';
      if (openPath != null) {
        throw LocalSqliteConnectionException.openFailed(
          openPath,
          text,
          sqliteCode: code,
          extendedCode: extended,
        );
      }
      if (controlOperation != null) {
        throw LocalSqliteTransactionException(
          text,
          operation: controlOperation,
          sqliteCode: code,
          extendedCode: extended,
        );
      }
      throw LocalSqliteQueryException(
        text,
        sql: sql,
        sqliteCode: code,
        extendedCode: extended,
      );
    case _replyOpenError:
      throw LocalSqliteConnectionException.openFailed(
        reply[1] as String,
        reply[2] as String,
        sqliteCode: reply[3] as int?,
        extendedCode: reply[4] as int?,
      );
    case _replyArgumentError:
      throw _WorkerArgumentError(reply[1] as String);
    case _replyStateError:
      throw LocalSqliteConnectionException(reply[1] as String);
    default:
      throw LocalSqliteException(
        'SQLite worker failed: ${reply[1]}\n${reply.length > 2 ? reply[2] : ''}',
      );
  }
}

/// An [ArgumentError] raised on the worker (for example a parameter of a
/// type SQLite cannot bind), re-thrown with its original text.
final class _WorkerArgumentError extends ArgumentError {
  _WorkerArgumentError(this._text);

  final String _text;

  @override
  String toString() => _text;
}

// ---------------------------------------------------------------------------
// Channels: how a handle reaches its connection.
// ---------------------------------------------------------------------------

abstract interface class _Channel {
  /// Sends [message]; completes with the reply. Requests are answered in the
  /// order they were sent.
  Future<List<Object?>> request(List<Object?> message);

  /// Closes the connection after every request already sent, and stops the
  /// worker. Idempotent; never throws.
  Future<void> shutdown();
}

/// A connection on the calling isolate. Requests run synchronously.
final class _InlineChannel implements _Channel {
  _InlineChannel(this._state);

  final _WorkerState _state;

  @override
  Future<List<Object?>> request(List<Object?> message) =>
      Future<List<Object?>>.value(_state.handle(message));

  @override
  Future<void> shutdown() async {
    _state.handle(<Object?>[_opClose, 0]);
  }
}

/// A worker isolate answering requests in FIFO order on one reply port.
/// Worker isolates of this isolate whose ports are still open: writer
/// isolates of open writable handles plus the spawned pool readers.
@visibleForTesting
int get debugLiveLocalSqliteWorkers => _IsolateChannel._live;

final class _IsolateChannel implements _Channel {
  _IsolateChannel._(this._replies, this._lifecycle) {
    _live++;
  }

  static int _live = 0;
  bool _portsClosed = false;

  final RawReceivePort _replies;
  final RawReceivePort _lifecycle;
  final ListQueue<Completer<List<Object?>>> _pending =
      ListQueue<Completer<List<Object?>>>();
  final Completer<void> _ready = Completer<void>();
  SendPort? _requests;
  Object? _failure;
  bool _stopping = false;
  bool _exited = false;

  bool get isDead => _failure != null;

  static Future<_IsolateChannel> spawn(int role, String debugName) async {
    final channel = _IsolateChannel._(
      RawReceivePort(null, '$debugName.replies'),
      RawReceivePort(null, '$debugName.lifecycle'),
    );
    channel._replies.handler = channel._onReply;
    channel._lifecycle.handler = channel._onLifecycle;
    try {
      await Isolate.spawn<List<Object?>>(
        _workerMain,
        <Object?>[channel._replies.sendPort, role],
        debugName: debugName,
        errorsAreFatal: true,
        onExit: channel._lifecycle.sendPort,
        onError: channel._lifecycle.sendPort,
      );
      await channel._ready.future;
    } catch (_) {
      channel._closePorts();
      rethrow;
    }
    return channel;
  }

  void _onReply(Object? message) {
    if (message is SendPort) {
      _requests = message;
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (_pending.isEmpty) return;
    _pending.removeFirst().complete(message! as List<Object?>);
    if (_exited && _pending.isEmpty) _closePorts();
  }

  void _onLifecycle(Object? message) {
    if (_stopping) {
      // A clean stop. The exit notice can overtake the last replies (they
      // travel on another port); they were sent before the worker exited, so
      // keep the reply port open until they arrive.
      _exited = true;
      if (_pending.isEmpty) _closePorts();
      return;
    }
    final detail =
        message is List && message.isNotEmpty
            ? message.first
            : 'the isolate exited';
    _fail(
      LocalSqliteConnectionException(
        'SQLite worker stopped unexpectedly: $detail',
      ),
    );
  }

  void _fail(Object error) {
    _failure ??= error;
    if (!_ready.isCompleted) _ready.completeError(error);
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(error);
    }
    _closePorts();
  }

  void _closePorts() {
    if (_portsClosed) return;
    _portsClosed = true;
    _live--;
    _replies.close();
    _lifecycle.close();
  }

  @override
  Future<List<Object?>> request(List<Object?> message) {
    final failure = _failure;
    if (failure != null) return Future<List<Object?>>.error(failure);
    final requests = _requests;
    if (requests == null || _stopping) {
      return Future<List<Object?>>.error(
        LocalSqliteConnectionException.databaseClosed(),
      );
    }
    // Send first: a value that cannot cross isolates throws here, before a
    // completer is queued, so the FIFO reply order stays intact.
    requests.send(message);
    final completer = Completer<List<Object?>>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> shutdown() async {
    if (_failure != null || _stopping) return;
    final requests = _requests;
    if (requests != null) {
      // Ask the worker to close and stop (a no-op close when its connection
      // is already closed or never opened). Requests already sent are
      // answered first; the ports close when the worker exits (see
      // _onLifecycle).
      final stopped = Completer<List<Object?>>();
      requests.send(<Object?>[_opClose, 0]);
      _pending.add(stopped);
      _stopping = true;
      await stopped.future.then<void>((_) {}, onError: (Object _) {});
    }
    _stopping = true;
  }
}

// ---------------------------------------------------------------------------
// Process-wide (per isolate) pool of reader isolates.
// ---------------------------------------------------------------------------

final class _ReaderPool {
  _ReaderPool._(this.capacity);

  static _ReaderPool? _instance;

  static _ReaderPool get shared =>
      _instance ??= _ReaderPool._(
        (Platform.numberOfProcessors - 1).clamp(2, 4),
      );

  final int capacity;
  final List<_ReaderSlot> _slots = <_ReaderSlot>[];
  final ListQueue<_ReadJob> _queue = ListQueue<_ReadJob>();
  int _spawned = 0;

  Future<List<Object?>> submit(int handleId, List<Object?> message) {
    final job = _ReadJob(handleId, message);
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  /// Closes [handleId]'s connections on every reader that opened one.
  Future<void> release(int handleId) async {
    final closing = <Future<void>>[];
    for (final slot in List<_ReaderSlot>.of(_slots)) {
      if (!slot.handles.remove(handleId)) continue;
      final channel = slot.channel;
      if (channel == null || channel.isDead) continue;
      closing.add(
        channel
            .request(<Object?>[_opCloseHandle, handleId])
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }
    await Future.wait(closing);
  }

  void _pump() {
    while (_queue.isNotEmpty) {
      final job = _queue.first;
      final slot = _idleSlotFor(job.handleId);
      if (slot == null) return;
      _queue.removeFirst();
      unawaited(_run(slot, job));
    }
  }

  /// Prefers an idle reader that already has a connection for [handleId]
  /// (its page cache is warm), then any idle reader, then a new reader while
  /// the pool is below [capacity].
  _ReaderSlot? _idleSlotFor(int handleId) {
    _ReaderSlot? idle;
    for (final slot in _slots) {
      if (slot.busy) continue;
      if (slot.handles.contains(handleId)) return slot;
      idle ??= slot;
    }
    if (idle != null) return idle;
    if (_slots.length < capacity) {
      final slot = _ReaderSlot(++_spawned);
      _slots.add(slot);
      return slot;
    }
    return null;
  }

  Future<void> _run(_ReaderSlot slot, _ReadJob job) async {
    slot.busy = true;
    try {
      final channel = await slot.ensureChannel();
      slot.handles.add(job.handleId);
      final reply = await channel.request(job.message);
      job.completer.complete(reply);
    } catch (error, stackTrace) {
      job.completer.completeError(error, stackTrace);
    } finally {
      slot.busy = false;
      final channel = slot.channel;
      if (slot.failedToSpawn || (channel != null && channel.isDead)) {
        _slots.remove(slot);
      }
      _pump();
    }
  }
}

final class _ReaderSlot {
  _ReaderSlot(this.number);

  final int number;
  final Set<int> handles = <int>{};
  bool busy = false;
  bool failedToSpawn = false;
  _IsolateChannel? channel;
  Future<_IsolateChannel>? _spawning;

  Future<_IsolateChannel> ensureChannel() {
    final ready = channel;
    if (ready != null) return Future<_IsolateChannel>.value(ready);
    return _spawning ??= _IsolateChannel.spawn(
      _roleReader,
      'local_sqlite.reader#$number',
    ).then(
      (spawned) => channel = spawned,
      onError: (Object error, StackTrace stackTrace) {
        failedToSpawn = true;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }
}

final class _ReadJob {
  _ReadJob(this.handleId, this.message);

  final int handleId;
  final List<Object?> message;
  final Completer<List<Object?>> completer = Completer<List<Object?>>();
}

// ---------------------------------------------------------------------------
// Async FIFO lock.
// ---------------------------------------------------------------------------

final class _Mutex {
  final ListQueue<Completer<void>> _waiters = ListQueue<Completer<void>>();
  bool _locked = false;

  Future<void> lock() {
    if (!_locked) {
      _locked = true;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void unlock() {
    if (_waiters.isEmpty) {
      _locked = false;
    } else {
      _waiters.removeFirst().complete();
    }
  }
}

// ---------------------------------------------------------------------------
// Worker side: runs on a writer/reader isolate, or inline.
// ---------------------------------------------------------------------------

void _workerMain(List<Object?> arguments) {
  final replies = arguments[0]! as SendPort;
  final state = _WorkerState(arguments[1]! as int);
  final requests = RawReceivePort();
  requests.handler = (Object? message) {
    final reply = state.handle(message! as List<Object?>);
    replies.send(reply);
    if (state.stopped) requests.close();
  };
  replies.send(requests.sendPort);
}

final class _WorkerState {
  _WorkerState(this.role);

  final int role;

  /// The writer's or inline handle's connection.
  _ConnectionHost? _primary;

  /// A reader isolate's connections, one per handle it has served.
  final Map<int, _ConnectionHost> _readers = <int, _ConnectionHost>{};

  bool stopped = false;

  /// Runs one request. Never throws: failures become error replies.
  List<Object?> handle(List<Object?> request) {
    try {
      return <Object?>[_replyOk, _dispatch(request)];
    } on sqlite.SqliteException catch (error) {
      return <Object?>[
        _replySqliteError,
        error.message,
        error.explanation,
        error.resultCode,
        error.extendedResultCode,
      ];
    } on _OpenFailure catch (failure) {
      return <Object?>[
        _replyOpenError,
        failure.path,
        failure.reason,
        failure.code,
        failure.extendedCode,
      ];
    } on ArgumentError catch (error) {
      return <Object?>[_replyArgumentError, error.toString()];
    } on StateError catch (error) {
      return <Object?>[_replyStateError, error.message];
    } catch (error, stackTrace) {
      return <Object?>[_replyInternalError, '$error', '$stackTrace'];
    }
  }

  Object? _dispatch(List<Object?> request) {
    final op = request[0]! as int;
    final id = request[1]! as int;
    switch (op) {
      case _opOpenWriter:
        _openPrimary(request[2]! as String, readOnly: false);
        return null;
      case _opOpenReader:
        final path = request[2]! as String;
        if (role == _roleReader) {
          _readerFor(id, path);
        } else {
          _openPrimary(path, readOnly: true);
        }
        return null;
      case _opExecute:
        return _requirePrimary().execute(
          request[2]! as String,
          request[3]! as List<Object?>,
        );
      case _opSelect:
        final host =
            role == _roleReader
                ? _readerFor(id, request[4]! as String)
                : _requirePrimary();
        return host.select(request[2]! as String, request[3]! as List<Object?>);
      case _opBatch:
        _requirePrimary().batch(
          request[2]! as String,
          request[3]! as List<List<Object?>>,
          atomic: request[4]! as bool,
        );
        return null;
      case _opControl:
        _requirePrimary().control(request[2]! as int, request[3] as String?);
        return null;
      case _opCloseHandle:
        _readers.remove(id)?.close();
        return null;
      case _opClose:
        _primary?.close();
        _primary = null;
        for (final host in _readers.values) {
          host.close();
        }
        _readers.clear();
        stopped = role != _roleInline;
        return null;
      default:
        throw StateError('Unknown SQLite worker operation $op');
    }
  }

  void _openPrimary(String path, {required bool readOnly}) {
    if (_primary != null) {
      throw StateError('This SQLite worker already has a connection.');
    }
    _primary = _ConnectionHost.open(path, readOnly: readOnly);
  }

  _ConnectionHost _readerFor(int id, String path) =>
      _readers[id] ??= _ConnectionHost.open(path, readOnly: true);

  _ConnectionHost _requirePrimary() {
    final primary = _primary;
    if (primary == null) throw StateError('Database is closed.');
    return primary;
  }
}

final class _OpenFailure implements Exception {
  _OpenFailure(this.path, this.reason, [this.code, this.extendedCode]);

  final String path;
  final String reason;
  final int? code;
  final int? extendedCode;
}

/// One SQLite connection plus its prepared-statement cache.
final class _ConnectionHost {
  _ConnectionHost._(this._db, this.readOnly);

  final sqlite.Database _db;
  final bool readOnly;
  final LinkedHashMap<String, sqlite.PreparedStatement> _statements =
      LinkedHashMap<String, sqlite.PreparedStatement>();
  bool _closed = false;

  /// Opens a connection. A reading connection ([readOnly]) is opened
  /// read-write with `query_only=ON`, as resqlite did, so that when it is the
  /// file's last connection its close removes the `-wal` / `-shm` files a WAL
  /// database needs; a `SQLITE_OPEN_READONLY` connection cannot, and would
  /// leave them next to the user's files. When the file or its directory is
  /// not writable it falls back to a true read-only connection.
  static _ConnectionHost open(String path, {required bool readOnly}) {
    if (!readOnly) return _open(path, mode: sqlite.OpenMode.readWriteCreate);
    try {
      return _open(path, mode: sqlite.OpenMode.readWrite);
    } on _OpenFailure catch (failure) {
      const permissionCodes = <int>{3, 8, 14}; // PERM, READONLY, CANTOPEN
      if (!permissionCodes.contains(failure.code)) rethrow;
      return _open(path, mode: sqlite.OpenMode.readOnly);
    }
  }

  static _ConnectionHost _open(String path, {required sqlite.OpenMode mode}) {
    final readOnly = mode != sqlite.OpenMode.readWriteCreate;
    final sqlite.Database db;
    try {
      db = sqlite.sqlite3.open(path, mode: mode);
    } on sqlite.SqliteException catch (error) {
      throw _OpenFailure(
        path,
        error.message,
        error.resultCode,
        error.extendedResultCode,
      );
    }
    try {
      // The busy timeout goes first, so a file that is being recovered or
      // checkpointed by another connection is waited for, not failed.
      db.execute(
        'PRAGMA busy_timeout = '
        '${readOnly ? _readerBusyTimeoutMs : _writerBusyTimeoutMs}',
      );
      if (readOnly) {
        // Writes through this connection fail even when SQLite opened it
        // read-write.
        db.execute('PRAGMA query_only = ON');
        // sqlite3_open_v2 is lazy; reading the schema cookie proves the file
        // is a readable database now rather than at the first query.
        db.select('PRAGMA schema_version');
      } else {
        final mode = db.select('PRAGMA journal_mode = WAL');
        final value = mode.isEmpty ? null : mode.first.columnAt(0);
        if (value is! String || value.toLowerCase() != 'wal') {
          throw _OpenFailure(
            path,
            'could not enable WAL journal mode (SQLite kept "$value")',
          );
        }
      }
      for (final pragma in readOnly ? _readerPragmas : _writerPragmas) {
        db.execute(pragma);
      }
    } on sqlite.SqliteException catch (error) {
      db.close();
      throw _OpenFailure(
        path,
        error.message,
        error.resultCode,
        error.extendedResultCode,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
    return _ConnectionHost._(db, readOnly);
  }

  sqlite.PreparedStatement _prepared(String sql) {
    final cached = _statements.remove(sql);
    if (cached != null) {
      _statements[sql] = cached;
      return cached;
    }
    final statement = _db.prepare(sql, persistent: true);
    _statements[sql] = statement;
    if (_statements.length > _statementCacheSize) {
      final oldest = _statements.keys.first;
      _statements.remove(oldest)!.close();
    }
    return statement;
  }

  List<int> execute(String sql, List<Object?> parameters) {
    if (localSqliteHasMultipleStatements(sql)) {
      if (parameters.isNotEmpty) {
        throw ArgumentError.value(
          sql,
          'sql',
          'Multiple statements cannot take parameters',
        );
      }
      _db.execute(sql);
    } else {
      _prepared(sql).execute(parameters);
    }
    return <int>[_db.updatedRows, _db.lastInsertRowId];
  }

  List<Object?> select(String sql, List<Object?> parameters) {
    final result = _prepared(sql).select(parameters);
    return <Object?>[result.columnNames, result.rows];
  }

  void batch(
    String sql,
    List<List<Object?>> paramSets, {
    required bool atomic,
  }) {
    if (paramSets.isEmpty) return;
    final statement = _prepared(sql);
    if (!atomic) {
      for (final parameters in paramSets) {
        statement.execute(parameters);
      }
      return;
    }
    control(_controlBegin, null);
    try {
      for (final parameters in paramSets) {
        statement.execute(parameters);
      }
    } catch (_) {
      _rollbackQuietly();
      rethrow;
    }
    control(_controlCommit, null);
  }

  void control(int kind, String? savepoint) {
    switch (kind) {
      case _controlBegin:
        _prepared('BEGIN IMMEDIATE').execute();
      case _controlCommit:
        try {
          _prepared('COMMIT').execute();
        } catch (_) {
          _rollbackQuietly();
          rethrow;
        }
      case _controlRollback:
        if (!_db.autocommit) _prepared('ROLLBACK').execute();
      case _controlSavepoint:
        _prepared('SAVEPOINT ${_savepointName(savepoint)}').execute();
      case _controlRelease:
        final name = _savepointName(savepoint);
        try {
          _prepared('RELEASE $name').execute();
        } catch (_) {
          _rollbackToQuietly(name);
          rethrow;
        }
      case _controlRollbackTo:
        final name = _savepointName(savepoint);
        if (!_db.autocommit) {
          _prepared('ROLLBACK TO $name').execute();
          _prepared('RELEASE $name').execute();
        }
      default:
        throw StateError('Unknown transaction control $kind');
    }
  }

  static String _savepointName(String? name) {
    if (name == null || !RegExp(r'^s[0-9]+$').hasMatch(name)) {
      throw ArgumentError.value(name, 'savepoint', 'Invalid savepoint name');
    }
    return name;
  }

  void _rollbackQuietly() {
    try {
      if (!_db.autocommit) _prepared('ROLLBACK').execute();
    } on Object {
      // Best effort: the original failure is what the caller sees.
    }
  }

  void _rollbackToQuietly(String name) {
    try {
      if (!_db.autocommit) {
        _prepared('ROLLBACK TO $name').execute();
        _prepared('RELEASE $name').execute();
      }
    } on Object {
      // Best effort: the original failure is what the caller sees.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final statement in _statements.values) {
      try {
        statement.close();
      } on Object {
        // Finalizing a statement cannot fail in a way worth surfacing.
      }
    }
    _statements.clear();
    if (!readOnly) _rollbackQuietly();
    // With every statement finalized, sqlite3_close_v2 closes now. If this
    // was the last connection to the file, SQLite checkpoints the WAL into
    // the database and deletes the -wal and -shm files.
    _db.close();
  }
}
