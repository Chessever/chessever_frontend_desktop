import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'package:chessever/desktop/services/local_chess_diagnostics.dart';
import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/time_control_classifier.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/utils/eco_openings.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';

export 'package:chessever/repository/sqlite/local_chess_schema.dart'
    show createLocalChessDatabaseSchema;

class LocalChessResqliteDatabase {
  LocalChessResqliteDatabase._();

  static final LocalChessResqliteDatabase instance =
      LocalChessResqliteDatabase._();

  static const String _dbFileName = 'chessever_local_chess.db';

  resqlite.Database? _database;
  Completer<resqlite.Database>? _initCompleter;
  String? _cachedPath;
  bool _didApplyDevelopmentPurge = false;

  Future<resqlite.Database> get database async {
    return databaseWithProgress();
  }

  Future<resqlite.Database> databaseWithProgress({
    LocalChessScanProgressSink? onProgress,
  }) async {
    final opened = _database;
    if (opened != null) return opened;

    final pending = _initCompleter;
    if (pending != null) return pending.future;

    final completer = _initCompleter = Completer<resqlite.Database>();
    try {
      final db = await _open(onProgress: onProgress);
      _database = db;
      completer.complete(db);
      return db;
    } catch (error, stackTrace) {
      // Report unconditionally: a failure to open the local-chess resqlite
      // database is exactly the kind of Windows issue that otherwise gets
      // swallowed by a UI .when(error:) and never reaches Sentry.
      localChessLog.error(
        'Failed to open local chess resqlite database',
        error,
        stackTrace,
        tag: 'local-chess.open',
      );
      completer.completeError(error);
      completer.future.ignore();
      _initCompleter = null;
      rethrow;
    }
  }

  Future<resqlite.Database> openDedicatedConnection() async {
    final path = await _resolvePath();
    final db = await resqlite.Database.open(path);
    await LocalChessDatabaseRepository._runLocalCacheWriteQueued(
      () => _configure(db),
    );
    return db;
  }

  Future<String> get path async => _resolvePath();

  Future<resqlite.Database> _open({
    LocalChessScanProgressSink? onProgress,
  }) async {
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.02,
        message: 'Opening local database cache...',
      ),
    );
    final path = await _resolvePath();
    final purgedForDevelopment = await _maybePurgeDevelopmentCacheOnOpen(path);
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.04,
        message: 'Preparing local database cache...',
      ),
    );
    final db = await resqlite.Database.open(path);
    await LocalChessDatabaseRepository._runLocalCacheWriteQueued(() async {
      await _configure(db);
      await createLocalChessResqliteDatabaseSchema(db);
      if (purgedForDevelopment) {
        localChessLog.warning(
          'Skipping legacy sqflite local chess migration for development purge',
          context: <String, Object?>{'path': path},
        );
      } else {
        await migrateLegacyLocalChessSqfliteCache(
          db,
          legacyDatabase: _defaultLegacyLocalChessSqfliteDatabase,
          onProgress: onProgress,
        );
      }
    });
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.18,
        message: 'Local database cache ready.',
      ),
    );
    return db;
  }

  Future<String> _resolvePath() async {
    final cached = _cachedPath;
    if (cached != null) return cached;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(supportDir.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _cachedPath = p.join(dir.path, _dbFileName);
  }

  Future<void> _configure(resqlite.Database db) async {
    await _executePragmaSafe(db, 'PRAGMA foreign_keys=ON');
    await _executePragmaSafe(db, 'PRAGMA journal_mode=WAL');
    await _executePragmaSafe(db, 'PRAGMA synchronous=NORMAL');
    await _executePragmaSafe(db, 'PRAGMA temp_store=MEMORY');
    // Backstop for any writer not routed through the global write lock (and for
    // WAL checkpoint contention): block-and-retry the write lock for up to 20s
    // instead of throwing SQLITE_BUSY after 2s. The lock keeps writers from
    // overlapping in the first place; this only covers the rare uncovered case.
    await _executePragmaSafe(db, 'PRAGMA busy_timeout=20000');
    await _executePragmaSafe(db, 'PRAGMA cache_size=-65536');
  }

  Future<void> _executePragmaSafe(
    resqlite.Database db,
    String statement,
  ) async {
    try {
      await db.execute(statement);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Local chess resqlite pragma failed ($statement): $error');
      }
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db == null) return;
    await db.close();
    _database = null;
    _initCompleter = null;
  }

  Future<void> reset() async {
    await close();
    final dbPath = await _resolvePath();
    await deleteLocalChessResqliteCacheFilesAt(dbPath);
  }

  Future<bool> _maybePurgeDevelopmentCacheOnOpen(String dbPath) async {
    final flagFile = File(
      p.join(p.dirname(dbPath), localChessDevelopmentPurgeFlagFileName),
    );
    final dartDefineEnabled = const bool.fromEnvironment(
      _localChessDevelopmentPurgeEnv,
    );
    final environmentValue =
        Platform.environment[_localChessDevelopmentPurgeEnv];
    final flagFileExists = await flagFile.exists();
    final shouldPurge = shouldPurgeLocalChessResqliteCacheForDevelopment(
      isReleaseMode: kReleaseMode,
      dartDefineEnabled: dartDefineEnabled,
      environmentValue: environmentValue,
      flagFileExists: flagFileExists,
    );
    if (!shouldPurge) return false;
    if (_didApplyDevelopmentPurge) return true;

    _didApplyDevelopmentPurge = true;
    final deleted = await deleteLocalChessResqliteCacheFilesAt(dbPath);
    final consumedFlag =
        flagFileExists
            ? await consumeLocalChessDevelopmentPurgeFlagAt(flagFile.path)
            : false;
    localChessLog.warning(
      'Purged local chess resqlite cache for development startup',
      context: <String, Object?>{
        'deletedFiles': deleted,
        'path': dbPath,
        'flag': flagFile.path,
        'releaseMode': kReleaseMode,
        'dartDefine': dartDefineEnabled,
        'environment': _isTruthyDevelopmentFlag(environmentValue),
        'consumedFlag': consumedFlag,
      },
    );
    return true;
  }
}

const String _localChessDevelopmentPurgeEnv =
    'CHESSEVER_PURGE_LOCAL_CHESS_CACHE_ON_START';

@visibleForTesting
const String localChessDevelopmentPurgeFlagFileName =
    '.chessever_purge_local_chess_cache_on_start';

/// The file opt-in is a one-shot request. Leaving it in place silently purges
/// hundreds of megabytes on every session and forces the Players page to
/// re-index each source the first time it is opened.
@visibleForTesting
Future<bool> consumeLocalChessDevelopmentPurgeFlagAt(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}

@visibleForTesting
bool shouldPurgeLocalChessResqliteCacheForDevelopment({
  required bool isReleaseMode,
  required bool dartDefineEnabled,
  required String? environmentValue,
  required bool flagFileExists,
}) {
  // Opt-in only (flag file / env / dart-define). Allowed in release so local
  // `flutter run --release` can match debug when developers request a clean
  // local-chess cache. Production installs never set these opt-ins.
  //
  // [isReleaseMode] is kept for call-site compatibility and logging; it no
  // longer blocks an explicit opt-in.
  // ignore: avoid_unused_constructor_parameters
  final _ = isReleaseMode;
  return dartDefineEnabled ||
      flagFileExists ||
      _isTruthyDevelopmentFlag(environmentValue);
}

bool _isTruthyDevelopmentFlag(String? value) {
  switch (value?.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'y':
    case 'on':
      return true;
  }
  return false;
}

@visibleForTesting
Future<int> deleteLocalChessResqliteCacheFilesAt(String dbPath) async {
  var deleted = 0;
  for (final path in <String>[
    dbPath,
    '$dbPath-wal',
    '$dbPath-shm',
    '$dbPath-journal',
  ]) {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      deleted++;
    }
  }
  return deleted;
}

const int _kPositionRefInsertBatchSize = 4096;
const int _kSqlWriteBatchSize = 4096;
// SQLite on supported desktop builds accepts at least 32,766 bound variables.
// Keep a margin below that limit while still turning large tree saves into a
// few hundred SQL statements instead of one statement per row.
const int _kTreeMultiRowBindLimit = 24000;
const int _kCooperativePurgeBatchSize = 512;
const int _kMaximumAdaptivePurgeBatchSize = 4096;
const Duration _kSlowPurgeBatchThreshold = Duration(milliseconds: 100);
// Move parsing happens on the import worker, so the caller isolate only packs
// compact metadata and UCI strings. A moderate batch sharply reduces SQLite
// transaction overhead while remaining small enough for interactive use.
const int _kInteractiveImportBatchSize = 64;
const int _kEagerPositionRefLoadLimit = 250000;
const int _kEagerTreeMoveLoadLimit = 250000;
const int _kCachedFileNodeGamePreviewLimit = 1000;
const int _kTreeWorkerProgressGameInterval = 512;
const int _kCachedTreeRebuildPageSize = 2048;
const int _kCachedTreeBuildInputBatchSize = 96;
const int _kPersistedPositionGameRefLimit = 10000;
const int _kSingleWorkerTreeBuildBytes = 128 * 1024 * 1024;
const String _localTreePositionRefStageTable =
    'temp_local_chess_tree_position_refs';
const int _kLegacyMigrationGamePageSize = 256;
const int _kLegacyMigrationRowPageSize = 4096;
const String _legacySqfliteMigrationV1Name = 'legacy_sqflite_local_chess_v1';
const String _legacySqfliteMigrationName =
    'legacy_sqflite_local_chess_v2_desktop_path_scan';
const String _localChessMigrationsTable = 'local_chess_migrations';
const String _localChessCacheGenerationName =
    'local_chess_resqlite_cache_generation_20260628_safe_streaming_v1';
const String _localChessTreeDepthGenerationName =
    'local_chess_tree_depth_50_v1';
const String _localChessTreePositionIdentityGenerationName =
    'local_chess_tree_position_identity_fen4_v1';
const String _localChessOpeningNameBackfillName =
    'local_chess_opening_name_backfill_v1';
const String _localChessTimeControlBackfillName =
    'local_chess_source_time_control_backfill_v2';

bool _localChessTreeMetadataIsUsable({
  required int positionCount,
  required int? maxPly,
}) => positionCount > 0 && maxPly != null && maxPly > 0;

typedef LocalChessLegacySqfliteDatabaseFactory =
    Future<sqflite.Database> Function();
typedef LocalChessScanProgressSink =
    void Function(LocalChessScanProgress progress);
typedef LocalChessDatabaseWithProgress =
    Future<resqlite.Database> Function({
      LocalChessScanProgressSink? onProgress,
    });
typedef LocalChessDatabaseFilePathResolver = Future<String?> Function();

typedef LocalChessPurgeDiagnosticSink =
    void Function(LocalChessPurgeBatchDiagnostic diagnostic);

@immutable
class LocalChessPurgeBatchDiagnostic {
  const LocalChessPurgeBatchDiagnostic({
    required this.table,
    required this.batchSize,
    required this.affectedRows,
    required this.elapsedMilliseconds,
  });

  final String table;
  final int batchSize;
  final int affectedRows;
  final int elapsedMilliseconds;

  /// Deliberately excludes database ids, source paths, and player metadata.
  Map<String, Object> get sentryData => <String, Object>{
    'table': table,
    'batchSize': batchSize,
    'affectedRows': affectedRows,
    'elapsedMs': elapsedMilliseconds,
  };
}

class _LocalChessPurgeDiagnostics {
  final Set<String> _reportedTables = <String>{};
  int slowBatchCount = 0;
  int maxElapsedMilliseconds = 0;

  int get reportedTableCount => _reportedTables.length;

  bool record(LocalChessPurgeBatchDiagnostic diagnostic) {
    slowBatchCount += 1;
    if (diagnostic.elapsedMilliseconds > maxElapsedMilliseconds) {
      maxElapsedMilliseconds = diagnostic.elapsedMilliseconds;
    }
    return _reportedTables.add(diagnostic.table);
  }
}

class _LocalChessSingleFileImport {
  const _LocalChessSingleFileImport(this.future, this.cancellationToken);

  final Future<LocalChessSource?> future;
  final OperationCancellationToken? cancellationToken;

  bool get isCanceled => cancellationToken?.isCanceled == true;
}

Future<T> _cancelableLocalChessFuture<T>(
  Future<T> future,
  OperationCancellationToken? cancellationToken,
) {
  if (cancellationToken == null) return future;
  cancellationToken.throwIfCanceled();
  return Future.any<T>(<Future<T>>[
    future,
    cancellationToken.whenCanceled.then<T>((_) {
      throw const OperationCanceledException();
    }),
  ]);
}

/// Production legacy source for the sqflite→resqlite migration.
///
/// Reuses the already-open, WAL-mode [AppDatabase] connection instead of
/// opening a second `readOnly` connection to the same file. A read-only open
/// of a WAL database has to (re)create the `-wal`/`-shm` sidecars and collides
/// with AppDatabase's `singleInstance` write handle; on Windows that fails with
/// "unable to open database file", which previously aborted the migration
/// silently. Reading through the live connection sidesteps that entirely.
Future<sqflite.Database> _defaultLegacyLocalChessSqfliteDatabase() =>
    AppDatabase.instance.database;

Future<void> createLocalChessResqliteDatabaseSchema(resqlite.Database db) {
  return LocalChessDatabaseRepository._runLocalCacheWriteQueued(
    () => _createLocalChessResqliteDatabaseSchemaUnlocked(db),
  );
}

Future<void> _createLocalChessResqliteDatabaseSchemaUnlocked(
  resqlite.Database db,
) async {
  await db.transaction((tx) async {
    for (var i = 0; i < _localChessSchemaStatements.length; i++) {
      await tx.execute(_localChessSchemaStatements[i]);
    }
    // The UNIQUE(database_id, fen_key) constraint already supplies the exact
    // lookup index used by the explorer. Maintaining a second identical index
    // made every large tree build pay for the same FEN key twice. Move rows are
    // also read after a single-node lookup, so sorting that node's handful of
    // moves is cheaper than maintaining a global total index during ingestion.
    await tx.execute('DROP INDEX IF EXISTS idx_local_chess_tree_nodes_fen');
    await tx.execute('DROP INDEX IF EXISTS idx_local_chess_tree_moves_total');
    await _ensureColumn(
      tx,
      table: localChessGamesTable,
      column: 'pgn_hash',
      ddl: 'TEXT',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_pgn_hash ON '
      '$localChessGamesTable(database_id, pgn_hash)',
    );
    await _ensureColumn(
      tx,
      table: localChessGamesTable,
      column: 'source_byte_start',
      ddl: 'INTEGER',
    );
    await _ensureColumn(
      tx,
      table: localChessGamesTable,
      column: 'source_byte_end',
      ddl: 'INTEGER',
    );
    await _ensureColumn(
      tx,
      table: localChessGamesTable,
      column: 'time_control_category',
      ddl: 'TEXT',
    );
    await _ensureColumn(
      tx,
      table: localChessGamesTable,
      column: 'is_online',
      ddl: 'INTEGER',
    );
    await _backfillGameDerivedFilters(tx);
    await _backfillTimeControlCategories(tx);
    await _backfillGameOpeningNames(tx);
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_result ON '
      '$localChessGamesTable(database_id, result)',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_time_category ON '
      '$localChessGamesTable(database_id, time_control_category)',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_online ON '
      '$localChessGamesTable(database_id, is_online)',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_date ON '
      '$localChessGamesTable(database_id, date)',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_white_elo ON '
      '$localChessGamesTable(database_id, white_elo)',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_black_elo ON '
      '$localChessGamesTable(database_id, black_elo)',
    );
    await _ensureColumn(
      tx,
      table: localChessDatabasesTable,
      column: 'deleted_at_ms',
      ddl: 'INTEGER',
    );
    await _ensureColumn(
      tx,
      table: localChessDatabasesTable,
      column: 'tree_max_ply',
      ddl: 'INTEGER',
    );
    await _ensureColumn(
      tx,
      table: localChessDatabasesTable,
      column: 'player_enrichment_at_ms',
      ddl: 'INTEGER',
    );
    await _ensureColumn(
      tx,
      table: localChessDatabasesTable,
      column: 'content_fingerprint',
      ddl: 'TEXT',
    );
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_databases_deleted ON '
      '$localChessDatabasesTable(deleted_at_ms)',
    );
    await _backfillGamePgnHashes(tx);
    await _ensureColumn(
      tx,
      table: localChessPositionGamesTable,
      column: 'next_uci',
      ddl: 'TEXT',
    );
    await _backfillPositionGameNextUci(tx);
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_chess_position_games_next ON '
      '$localChessPositionGamesTable(database_id, fen_key, next_uci)',
    );
    await tx.execute(
      'INSERT OR IGNORE INTO $localChessPlayersTable(id, name, elo) '
      'VALUES (?, ?, ?)',
      const <Object?>[0, 'Unknown', null],
    );
    await tx.execute(
      'INSERT OR IGNORE INTO $localChessEventsTable(id, name) VALUES (?, ?)',
      const <Object?>[0, 'Unknown'],
    );
    await tx.execute(
      'INSERT OR IGNORE INTO $localChessSitesTable(id, name) VALUES (?, ?)',
      const <Object?>[0, 'Unknown'],
    );
    await _ensureLocalChessCacheGeneration(tx);
    await _ensureLocalChessTreePositionIdentityGeneration(tx);
    await _ensureLocalChessTreeDepthGeneration(tx);
  });
}

Future<void> _ensureColumn(
  resqlite.Transaction tx, {
  required String table,
  required String column,
  required String ddl,
}) async {
  final rows = await tx.select('PRAGMA table_info($table)', const <Object?>[]);
  final exists = rows.any(
    (row) => row['name']?.toString().toLowerCase() == column.toLowerCase(),
  );
  if (exists) return;
  await tx.execute('ALTER TABLE $table ADD COLUMN $column $ddl');
}

Future<void> _backfillGamePgnHashes(resqlite.Transaction tx) async {
  while (true) {
    final rows = await tx.select('''
      SELECT database_id, id, raw_pgn
      FROM $localChessGamesTable
      WHERE (pgn_hash IS NULL OR pgn_hash = '')
        AND raw_pgn IS NOT NULL
        AND TRIM(raw_pgn) <> ''
      LIMIT 500
    ''');
    if (rows.isEmpty) return;
    await tx.executeBatch(
      '''
      UPDATE $localChessGamesTable
      SET pgn_hash = ?
      WHERE database_id = ? AND id = ?
      ''',
      <List<Object?>>[
        for (final row in rows)
          <Object?>[
            localChessPgnFingerprint(row['raw_pgn']?.toString() ?? ''),
            row['database_id'],
            row['id'],
          ],
      ],
    );
    if (rows.length < 500) return;
  }
}

Future<void> _backfillGameDerivedFilters(resqlite.Transaction tx) async {
  // The v2 time-control migration is recorded only after this older derived
  // filter backfill has completed. Once that marker exists, every legacy row
  // has both derived fields and all current import paths populate them on
  // insert. Avoid re-running the unindexed OR query on every database open:
  // when no rows need repair SQLite otherwise scans the entire games table.
  final completedRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessTimeControlBackfillName],
  );
  if (completedRows.isNotEmpty) return;

  while (true) {
    final rows = await tx.select('''
      SELECT database_id, id, time_control, time_control_category, headers_json
      FROM $localChessGamesTable
      WHERE time_control_category IS NULL
        OR time_control_category = ''
        OR is_online IS NULL
      LIMIT 500
    ''');
    if (rows.isEmpty) return;
    await tx.executeBatch(
      '''
      UPDATE $localChessGamesTable
      SET time_control_category = ?,
          is_online = ?
      WHERE database_id = ? AND id = ?
      ''',
      <List<Object?>>[
        for (final row in rows)
          <Object?>[
            _localGameTimeControlCategory(
              timeControl: row['time_control'],
              headersJson: row['headers_json'],
              storedCategory: row['time_control_category'],
            ),
            _inferLocalGameIsOnline(
                  timeControl: row['time_control'],
                  headersJson: row['headers_json'],
                )
                ? 1
                : 0,
            row['database_id'],
            row['id'],
          ],
      ],
    );
    if (rows.length < 500) return;
  }
}

Future<void> _backfillTimeControlCategories(resqlite.Transaction tx) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessTimeControlBackfillName],
  );
  if (markerRows.isNotEmpty) return;

  var lastRowId = 0;
  while (true) {
    final rows = await tx.select(
      '''
      SELECT rowid AS game_rowid, time_control, time_control_category,
             headers_json
      FROM $localChessGamesTable
      WHERE rowid > ?
      ORDER BY rowid
      LIMIT 500
      ''',
      <Object?>[lastRowId],
    );
    if (rows.isEmpty) break;
    final updates = <List<Object?>>[];
    for (final row in rows) {
      final category = _localGameTimeControlCategory(
        timeControl: row['time_control'],
        headersJson: row['headers_json'],
        storedCategory: row['time_control_category'],
      );
      final storedCategory = row['time_control_category']?.toString();
      if (category != storedCategory) {
        updates.add(<Object?>[category, row['game_rowid']]);
      }
    }
    if (updates.isNotEmpty) {
      await tx.executeBatch('''
        UPDATE $localChessGamesTable
        SET time_control_category = ?
        WHERE rowid = ?
        ''', updates);
    }
    lastRowId = _readInt(rows.last['game_rowid']);
    await _yieldAfterSqlBatch();
  }
  await tx.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[
      _localChessTimeControlBackfillName,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

Future<void> _backfillGameOpeningNames(resqlite.Transaction tx) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessOpeningNameBackfillName],
  );
  if (markerRows.isNotEmpty) return;
  final knownCodes = EcoOpenings.codeToName.keys.toList(growable: false);
  for (final codes in _chunks(knownCodes, 300)) {
    final placeholders = List<String>.filled(codes.length, '?').join(', ');
    while (true) {
      final rows = await tx.select(
        '''
        SELECT database_id, id, eco, headers_json
        FROM $localChessGamesTable
        WHERE SUBSTR(UPPER(TRIM(COALESCE(eco, ''))), 1, 3)
            IN ($placeholders)
          AND LOWER(TRIM(COALESCE(
            json_extract(headers_json, '\$.Opening'), ''
          ))) IN ('', '?', '-', 'unknown', 'unknown opening')
        LIMIT 500
        ''',
        <Object?>[...codes],
      );
      if (rows.isEmpty) break;
      await tx.executeBatch(
        '''
        UPDATE $localChessGamesTable
        SET headers_json = ?
        WHERE database_id = ? AND id = ?
        ''',
        <List<Object?>>[
          for (final row in rows)
            <Object?>[
              jsonEncode(
                _metadataWithCanonicalOpening(
                  _jsonMap(row['headers_json']),
                  row['eco'],
                ),
              ),
              row['database_id'],
              row['id'],
            ],
        ],
      );
      if (rows.length < 500) break;
    }
  }
  await tx.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[
      _localChessOpeningNameBackfillName,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

Future<void> _backfillPositionGameNextUci(resqlite.Transaction tx) async {
  await tx.execute('''
    UPDATE $localChessPositionGamesTable
    SET next_uci = (
      SELECT LOWER(TRIM(CAST(json_extract(g.moves, '\$[' || $localChessPositionGamesTable.ply || ']') AS TEXT)))
      FROM $localChessGamesTable g
      WHERE g.database_id = $localChessPositionGamesTable.database_id
        AND g.id = $localChessPositionGamesTable.game_id
    )
    WHERE next_uci IS NULL OR next_uci = ''
  ''');
}

Future<void> _ensureLocalChessCacheGeneration(resqlite.Transaction tx) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessCacheGenerationName],
  );
  if (markerRows.isNotEmpty) return;

  final databaseRows = await tx.select(
    'SELECT COUNT(*) AS count FROM $localChessDatabasesTable',
  );
  final databaseCount = _readInt(databaseRows.single['count']);
  if (databaseCount > 0) {
    localChessLog.info(
      'Invalidating stale local chess resqlite cache',
      context: <String, Object?>{
        'databases': databaseCount,
        'generation': _localChessCacheGenerationName,
      },
    );
  }

  await tx.execute('DELETE FROM $localChessPositionGamesTable');
  await tx.execute('DELETE FROM $localChessTreeMovesTable');
  await tx.execute('DELETE FROM $localChessTreeNodesTable');
  await tx.execute('DELETE FROM $localChessGamesTable');
  await tx.execute('DELETE FROM $localChessDatabasesTable');
  await tx.execute('DELETE FROM $localChessPlayersTable WHERE id <> 0');
  await tx.execute('DELETE FROM $localChessEventsTable WHERE id <> 0');
  await tx.execute('DELETE FROM $localChessSitesTable WHERE id <> 0');
  await tx.execute(
    'DELETE FROM $_localChessMigrationsTable WHERE name = ?',
    const <Object?>[_legacySqfliteMigrationName],
  );
  await tx.execute(
    'DELETE FROM $_localChessMigrationsTable WHERE name = ?',
    const <Object?>[_legacySqfliteMigrationV1Name],
  );
  await tx.execute(
    'DELETE FROM $_localChessMigrationsTable WHERE name = ?',
    const <Object?>[_localChessTreeDepthGenerationName],
  );
  await tx.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[
      _localChessCacheGenerationName,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

Future<void> _ensureLocalChessTreePositionIdentityGeneration(
  resqlite.Transaction tx, {
  bool invalidateExisting = false,
}) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessTreePositionIdentityGenerationName],
  );
  if (markerRows.isNotEmpty && !invalidateExisting) return;

  // Do not count or delete the generated tree tables here. A large desktop
  // cache can contain millions of rows, and schema opening runs on the app's
  // startup path. Clearing only the small per-database metadata makes every
  // loader reject the old identity generation immediately; the stale rows are
  // reclaimed when that database is explicitly rebuilt, replaced, or purged.
  final invalidatedMetadata = await tx.execute(
    '''
    UPDATE $localChessDatabasesTable
    SET position_count = 0,
        tree_snapshot = NULL,
        tree_max_ply = NULL,
        updated_at_ms = ?
    WHERE position_count <> 0
       OR tree_snapshot IS NOT NULL
       OR tree_max_ply IS NOT NULL
    ''',
    <Object?>[DateTime.now().millisecondsSinceEpoch],
  );
  if (invalidatedMetadata.affectedRows > 0) {
    localChessLog.info(
      'Marked stale local chess trees for lazy rebuild',
      context: <String, Object?>{
        'databases': invalidatedMetadata.affectedRows,
        'generation': _localChessTreePositionIdentityGenerationName,
      },
    );
  }

  await tx.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[
      _localChessTreePositionIdentityGenerationName,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

Future<void> _ensureLocalChessTreeDepthGeneration(
  resqlite.Transaction tx,
) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessTreeDepthGenerationName],
  );
  if (markerRows.isNotEmpty) return;

  final usableMetadataRows = await tx.select('''
    SELECT 1
    FROM $localChessDatabasesTable
    WHERE position_count > 0
      AND tree_max_ply IS NOT NULL
      AND tree_max_ply > 0
    LIMIT 1
    ''');
  if (usableMetadataRows.isEmpty) {
    await tx.execute(
      '''
      INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
      VALUES (?, ?)
      ''',
      <Object?>[
        _localChessTreeDepthGenerationName,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return;
  }

  final treeRows = await tx.select(
    'SELECT COALESCE(MAX(ply), 0) AS max_ply FROM $localChessTreeNodesTable',
  );
  final maxPly = treeRows.isEmpty ? 0 : _readInt(treeRows.single['max_ply']);
  if (maxPly <= 0) return;

  final metadataRows = await tx.select('''
    SELECT
      COALESCE(MIN(NULLIF(tree_max_ply, 0)), 0) AS min_tree_max_ply,
      COALESCE(MAX(ply_count), 0) AS max_game_ply
    FROM $localChessDatabasesTable d
    LEFT JOIN $localChessGamesTable g
      ON g.database_id = d.id
    WHERE d.deleted_at_ms IS NULL
    ''');
  final metadata = metadataRows.single;
  final storedTreeMaxPly = _readInt(metadata['min_tree_max_ply']);
  final maxGamePly = _readInt(metadata['max_game_ply']);
  final isStoredCapShallow =
      storedTreeMaxPly > 0 && storedTreeMaxPly < localOpeningTreeDefaultMaxPly;
  final isLegacyTreeProbablyShallow =
      storedTreeMaxPly <= 0 &&
      maxPly < localOpeningTreeDefaultMaxPly &&
      maxGamePly > maxPly;

  if (isStoredCapShallow || isLegacyTreeProbablyShallow) {
    localChessLog.info(
      'Invalidating shallow local chess tree cache',
      context: <String, Object?>{
        'maxPly': maxPly,
        'storedTreeMaxPly': storedTreeMaxPly,
        'maxGamePly': maxGamePly,
        'targetMaxPly': localOpeningTreeDefaultMaxPly,
        'generation': _localChessTreeDepthGenerationName,
      },
    );
    await _clearLocalChessTreeCache(tx);
  }

  await tx.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[
      _localChessTreeDepthGenerationName,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

Future<void> _clearLocalChessTreeCache(resqlite.Transaction tx) async {
  await tx.execute('DELETE FROM $localChessPositionGamesTable');
  await tx.execute('DELETE FROM $localChessTreeMovesTable');
  await tx.execute('DELETE FROM $localChessTreeNodesTable');
  await tx.execute(
    '''
    UPDATE $localChessDatabasesTable
    SET position_count = 0,
        tree_snapshot = NULL,
        tree_max_ply = NULL,
        updated_at_ms = ?
    ''',
    <Object?>[DateTime.now().millisecondsSinceEpoch],
  );
}

Future<void> migrateLegacyLocalChessSqfliteCache(
  resqlite.Database target, {
  LocalChessLegacySqfliteDatabaseFactory? legacyDatabase,
  Iterable<LocalChessLegacySqfliteDatabaseFactory>? legacyDatabaseCandidates,
  @visibleForTesting Iterable<String>? legacyDatabasePathCandidates,
  LocalChessScanProgressSink? onProgress,
}) {
  return LocalChessDatabaseRepository._runLocalCacheWriteQueued(
    () => _migrateLegacyLocalChessSqfliteCacheUnlocked(
      target,
      legacyDatabase: legacyDatabase,
      legacyDatabaseCandidates: legacyDatabaseCandidates,
      legacyDatabasePathCandidates: legacyDatabasePathCandidates,
      onProgress: onProgress,
    ),
  );
}

Future<void> _migrateLegacyLocalChessSqfliteCacheUnlocked(
  resqlite.Database target, {
  LocalChessLegacySqfliteDatabaseFactory? legacyDatabase,
  Iterable<LocalChessLegacySqfliteDatabaseFactory>? legacyDatabaseCandidates,
  Iterable<String>? legacyDatabasePathCandidates,
  LocalChessScanProgressSink? onProgress,
}) async {
  void emit(double fraction, String message) {
    onProgress?.call(
      LocalChessScanProgress(fraction: fraction, message: message),
    );
  }

  try {
    if (await _hasMigrationMarker(target, _legacySqfliteMigrationName)) {
      return;
    }
    emit(0.06, 'Checking for previous local databases...');
    if (await _targetHasLocalChessData(target)) {
      await _markMigration(target, _legacySqfliteMigrationName);
      return;
    }

    final lookup = await _findLegacyLocalChessSqfliteCache(
      legacyDatabase: legacyDatabase,
      legacyDatabaseCandidates: legacyDatabaseCandidates,
      legacyDatabasePathCandidates: legacyDatabasePathCandidates,
    );
    final legacyCandidate = lookup.candidate;
    if (legacyCandidate == null) {
      if (lookup.hadUnreadableCandidate) {
        // A legacy cache exists but could not be read (e.g. the sqflite WAL
        // file is locked / unreadable on Windows). Do NOT mark the migration
        // complete — leaving the marker unset lets it retry on the next launch
        // instead of permanently hiding the user's local databases.
        emit(0.12, 'Local database cache is busy; will retry on next launch.');
        // Pass a concrete error so this reaches Sentry (the logger only
        // forwards to Sentry when error != null). This is the Windows case
        // where the legacy sqflite WAL cache is present but unreadable, so we
        // want visibility into how often it happens and whether retries
        // eventually recover the user's local databases.
        localChessLog.warning(
          'Deferring legacy sqflite local chess migration: existing cache '
          'could not be read',
          error: StateError(
            'Legacy sqflite local chess cache present but unreadable; '
            'deferring migration to retry on next launch',
          ),
          tag: 'local-chess-legacy-migration',
          report: true,
        );
        return;
      }
      emit(0.12, 'No previous local database cache found.');
      await _markMigration(target, _legacySqfliteMigrationName);
      return;
    }
    try {
      final legacy = legacyCandidate.database;
      final legacyDatabaseCount = legacyCandidate.databaseCount;
      localChessLog.info(
        'Legacy sqflite local chess migration started',
        context: <String, Object?>{
          'databases': legacyDatabaseCount,
          'source': legacyCandidate.label,
        },
      );
      emit(0.12, 'Migrating existing local databases...');

      final gameColumns = await _legacyColumnNames(
        legacy,
        localChessGamesTable,
      );

      await target.transaction((tx) async {
        await _copyLegacyTable(
          tx,
          legacy,
          localChessDatabasesTable,
          onCopiedRows:
              (rows) =>
                  emit(0.20, 'Migrating local database list... $rows rows'),
        );
        await _copyLegacyTable(
          tx,
          legacy,
          localChessPlayersTable,
          onCopiedRows:
              (rows) => emit(0.28, 'Migrating player index... $rows rows'),
        );
        await _copyLegacyTable(
          tx,
          legacy,
          localChessEventsTable,
          onCopiedRows:
              (rows) => emit(0.34, 'Migrating event index... $rows rows'),
        );
        await _copyLegacyTable(
          tx,
          legacy,
          localChessSitesTable,
          onCopiedRows:
              (rows) => emit(0.40, 'Migrating site index... $rows rows'),
        );
        await _copyLegacyGames(
          tx,
          legacy,
          gameColumns,
          onCopiedRows:
              (rows) => emit(0.52, 'Migrating local games... $rows rows'),
        );
        // Opening trees are derived data and the legacy cache uses the old
        // position identity. Do not spend startup time copying millions of
        // rows that must remain unusable; games are retained and each tree is
        // rebuilt explicitly on demand.
        await _copyLegacyTable(
          tx,
          legacy,
          localChessGameAnalysisTable,
          onCopiedRows:
              (rows) => emit(0.88, 'Migrating local analysis... $rows rows'),
        );
        emit(0.94, 'Finalizing local database migration...');
        await _ensureLocalChessTreePositionIdentityGeneration(
          tx,
          invalidateExisting: true,
        );
        await _ensureLocalChessTreeDepthGeneration(tx);
        await tx.execute(
          '''
        INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
        VALUES (?, ?)
        ''',
          <Object?>[
            _legacySqfliteMigrationName,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      });
      emit(0.98, 'Local database migration complete.');
      localChessLog.info(
        'Legacy sqflite local chess migration finished',
        context: <String, Object?>{
          'databases': legacyDatabaseCount,
          'source': legacyCandidate.label,
        },
      );
    } finally {
      await legacyCandidate.closeIfOwned();
    }
  } catch (error, stackTrace) {
    localChessLog.warning(
      'Legacy sqflite local chess migration failed',
      error: error,
      stackTrace: stackTrace,
      tag: 'local-chess-legacy-migration',
      report: true,
    );
    if (kDebugMode) {
      debugPrint('Legacy local chess migration failed: $error\n$stackTrace');
    }
  }
}

Future<_LegacySqfliteLookup> _findLegacyLocalChessSqfliteCache({
  LocalChessLegacySqfliteDatabaseFactory? legacyDatabase,
  Iterable<LocalChessLegacySqfliteDatabaseFactory>? legacyDatabaseCandidates,
  Iterable<String>? legacyDatabasePathCandidates,
}) async {
  var hadUnreadableCandidate = false;
  final explicit = <LocalChessLegacySqfliteDatabaseFactory>[
    if (legacyDatabase != null) legacyDatabase,
    ...?legacyDatabaseCandidates,
  ];
  for (var i = 0; i < explicit.length; i++) {
    try {
      final db = await explicit[i]();
      final count = await _legacyLocalChessDatabaseCount(db);
      if (count > 0) {
        return _LegacySqfliteLookup(
          _LegacySqfliteCandidate(
            database: db,
            databaseCount: count,
            label: 'explicit:$i',
            closeAfterUse: false,
          ),
        );
      }
    } catch (error, stackTrace) {
      // The live/explicit connection could not be read. Remember it so the
      // caller defers (rather than permanently marks-complete), then fall
      // through to the path-scan candidates.
      hadUnreadableCandidate = true;
      localChessLog.warning(
        'Failed to inspect explicit legacy sqflite local chess candidate',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'candidate': 'explicit:$i'},
        tag: 'local-chess-legacy-migration-candidate',
      );
    }
  }

  final pathCandidates =
      legacyDatabasePathCandidates ??
      await _legacySqfliteDatabasePathCandidates();
  for (final path in pathCandidates) {
    if (!await File(path).exists()) continue;
    sqflite.Database? db;
    try {
      db = await sqflite.openDatabase(
        path,
        readOnly: true,
        singleInstance: false,
      );
      final count = await _legacyLocalChessDatabaseCount(db);
      if (count > 0) {
        return _LegacySqfliteLookup(
          _LegacySqfliteCandidate(
            database: db,
            databaseCount: count,
            label: path,
            closeAfterUse: true,
          ),
        );
      }
    } catch (error, stackTrace) {
      // An on-disk legacy cache exists but could not be opened/read (a locked
      // or read-only WAL file on Windows is the common case). Flag it so the
      // migration retries next launch instead of giving up.
      hadUnreadableCandidate = true;
      localChessLog.warning(
        'Failed to inspect legacy sqflite local chess database candidate',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'path': path},
        tag: 'local-chess-legacy-migration-candidate',
      );
    }
    await db?.close();
  }

  return _LegacySqfliteLookup(
    null,
    hadUnreadableCandidate: hadUnreadableCandidate,
  );
}

/// Result of scanning for a legacy sqflite local-chess cache.
///
/// [hadUnreadableCandidate] is true when a legacy cache was present but could
/// not be read (locked/unreadable). The migration uses it to defer instead of
/// marking itself complete, so transient failures never permanently hide a
/// user's local databases.
class _LegacySqfliteLookup {
  const _LegacySqfliteLookup(
    this.candidate, {
    this.hadUnreadableCandidate = false,
  });

  final _LegacySqfliteCandidate? candidate;
  final bool hadUnreadableCandidate;
}

Future<int> _legacyLocalChessDatabaseCount(sqflite.Database db) async {
  if (!await _legacyTableExists(db, localChessDatabasesTable)) return 0;
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS count FROM $localChessDatabasesTable',
  );
  return _readInt(rows.single['count']);
}

Future<List<String>> _legacySqfliteDatabasePathCandidates() async {
  String? applicationSupportPath;
  String? sqfliteDatabasesPath;
  String? documentsPath;

  try {
    applicationSupportPath = (await getApplicationSupportDirectory()).path;
  } catch (_) {
    applicationSupportPath = null;
  }
  try {
    sqfliteDatabasesPath = await sqflite.getDatabasesPath();
  } catch (_) {
    sqfliteDatabasesPath = null;
  }
  // Documents is a shared, app-independent location. Production keeps this
  // legacy lookup so existing users can migrate old databases, but a
  // development build must never import production data automatically.
  if (kReleaseMode) {
    try {
      documentsPath = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      documentsPath = null;
    }
  }

  return localChessLegacySqfliteDatabasePathCandidates(
    applicationSupportPath: applicationSupportPath,
    sqfliteDatabasesPath: sqfliteDatabasesPath,
    documentsPath: documentsPath,
  );
}

@visibleForTesting
List<String> localChessLegacySqfliteDatabasePathCandidates({
  required String? applicationSupportPath,
  required String? sqfliteDatabasesPath,
  required String? documentsPath,
  p.Context? pathContext,
}) {
  final context = pathContext ?? p.context;
  final paths = <String>[];
  final seen = <String>{};

  void add(String? directory) {
    final trimmed = directory?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    final path = context.join(trimmed, AppDatabase.dbFileName);
    final key = context.normalize(path).toLowerCase();
    if (seen.add(key)) paths.add(path);
  }

  add(applicationSupportPath);
  add(sqfliteDatabasesPath);
  add(documentsPath);
  return paths;
}

class _LegacySqfliteCandidate {
  const _LegacySqfliteCandidate({
    required this.database,
    required this.databaseCount,
    required this.label,
    required this.closeAfterUse,
  });

  final sqflite.Database database;
  final int databaseCount;
  final String label;
  final bool closeAfterUse;

  Future<void> closeIfOwned() async {
    if (closeAfterUse) await database.close();
  }
}

Future<bool> _hasMigrationMarker(resqlite.Database db, String name) async {
  final rows = await db.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    <Object?>[name],
  );
  return rows.isNotEmpty;
}

Future<void> _markMigration(resqlite.Database db, String name) async {
  await db.execute(
    '''
    INSERT OR REPLACE INTO $_localChessMigrationsTable(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    <Object?>[name, DateTime.now().millisecondsSinceEpoch],
  );
}

Future<bool> _targetHasLocalChessData(resqlite.Database db) async {
  final rows = await db.select(
    'SELECT COUNT(*) AS count FROM $localChessDatabasesTable',
  );
  return _readInt(rows.single['count']) > 0;
}

Future<bool> _legacyTableExists(sqflite.Database db, String table) async {
  final rows = await db.rawQuery(
    '''
    SELECT 1
    FROM sqlite_master
    WHERE type = 'table' AND name = ?
    LIMIT 1
    ''',
    <Object?>[table],
  );
  return rows.isNotEmpty;
}

Future<Set<String>> _legacyColumnNames(
  sqflite.Database db,
  String table,
) async {
  if (!await _legacyTableExists(db, table)) return const <String>{};
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows
      .map((row) => row['name']?.toString() ?? '')
      .where((name) => name.isNotEmpty)
      .toSet();
}

Future<void> _copyLegacyTable(
  resqlite.Transaction tx,
  sqflite.Database legacy,
  String table, {
  void Function(int copiedRows)? onCopiedRows,
}) async {
  if (!await _legacyTableExists(legacy, table)) return;
  var offset = 0;
  while (true) {
    final rows = await legacy.query(
      table,
      orderBy: 'rowid ASC',
      limit: _kLegacyMigrationRowPageSize,
      offset: offset,
    );
    if (rows.isEmpty) return;
    await _insertOrReplaceBatch(
      tx,
      table,
      rows.map((row) => Map<String, Object?>.from(row)).toList(growable: false),
    );
    onCopiedRows?.call(offset + rows.length);
    if (rows.length < _kLegacyMigrationRowPageSize) return;
    offset += rows.length;
    await _yieldAfterSqlBatch();
  }
}

Future<void> _copyLegacyGames(
  resqlite.Transaction tx,
  sqflite.Database legacy,
  Set<String> legacyColumns, {
  void Function(int copiedRows)? onCopiedRows,
}) async {
  if (!await _legacyTableExists(legacy, localChessGamesTable)) return;
  var offset = 0;
  while (true) {
    final rows = await legacy.query(
      localChessGamesTable,
      orderBy: 'rowid ASC',
      limit: _kLegacyMigrationGamePageSize,
      offset: offset,
    );
    if (rows.isEmpty) return;
    await _insertOrReplaceBatch(
      tx,
      localChessGamesTable,
      rows
          .map(
            (row) => <String, Object?>{
              'id': row['id'],
              'database_id': row['database_id'],
              'event_id': row['event_id'],
              'site_id': row['site_id'],
              'date': row['date'],
              'utc_time': row['utc_time'],
              'round': row['round'],
              'white_id': row['white_id'],
              'white_elo': row['white_elo'],
              'black_id': row['black_id'],
              'black_elo': row['black_elo'],
              'white_material': row['white_material'],
              'black_material': row['black_material'],
              'result': row['result'],
              'time_control': row['time_control'],
              // Prefer the current source-aware classifier because older
              // caches collapsed Bullet/UltraBullet into Blitz. If the PGN
              // carries no usable evidence, preserve and canonicalize its
              // valid stored category instead of degrading it to Unknown.
              'time_control_category': _localGameTimeControlCategory(
                timeControl: row['time_control'],
                headersJson: row['headers_json'],
                storedCategory:
                    legacyColumns.contains('time_control_category')
                        ? row['time_control_category']
                        : null,
              ),
              'is_online':
                  legacyColumns.contains('is_online')
                      ? row['is_online']
                      : _inferLocalGameIsOnline(
                        timeControl: row['time_control'],
                        headersJson: row['headers_json'],
                      )
                      ? 1
                      : 0,
              'eco': row['eco'],
              'ply_count': row['ply_count'],
              'fen': row['fen'],
              'moves': row['moves'] ?? '[]',
              'pawn_home': row['pawn_home'],
              'raw_pgn': row['raw_pgn'] ?? '',
              'pgn_hash':
                  legacyColumns.contains('pgn_hash') &&
                          row['pgn_hash']?.toString().trim().isNotEmpty == true
                      ? row['pgn_hash']
                      : localChessPgnFingerprint(
                        row['raw_pgn']?.toString() ?? '',
                      ),
              'headers_json': row['headers_json'] ?? '{}',
              'source_path': row['source_path'],
              'source_relative_path': row['source_relative_path'],
              'file_name': row['file_name'],
              'index_in_file': row['index_in_file'],
              'file_game_count': row['file_game_count'],
              'has_moves': row['has_moves'],
              'source_byte_start':
                  legacyColumns.contains('source_byte_start')
                      ? row['source_byte_start']
                      : null,
              'source_byte_end':
                  legacyColumns.contains('source_byte_end')
                      ? row['source_byte_end']
                      : null,
            },
          )
          .toList(growable: false),
    );
    onCopiedRows?.call(offset + rows.length);
    if (rows.length < _kLegacyMigrationGamePageSize) return;
    offset += rows.length;
    await _yieldAfterSqlBatch();
  }
}

const List<String> _localChessSchemaStatements = <String>[
  '''
    CREATE TABLE IF NOT EXISTS $_localChessMigrationsTable (
      name TEXT PRIMARY KEY,
      completed_at_ms INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessDatabasesTable (
      id TEXT PRIMARY KEY,
      path TEXT UNIQUE NOT NULL,
      label TEXT NOT NULL,
      extension TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      modified_at_ms INTEGER,
      file_count INTEGER NOT NULL DEFAULT 1,
      game_count INTEGER NOT NULL DEFAULT 0,
      position_count INTEGER NOT NULL DEFAULT 0,
      tree_snapshot TEXT,
      tree_max_ply INTEGER,
      imported_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER,
      content_fingerprint TEXT
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessPlayersTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE,
      elo INTEGER
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessEventsTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessSitesTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessGamesTable (
      id TEXT PRIMARY KEY,
      database_id TEXT NOT NULL,
      event_id INTEGER NOT NULL DEFAULT 0,
      site_id INTEGER NOT NULL DEFAULT 0,
      date TEXT,
      utc_time TEXT,
      round TEXT,
      white_id INTEGER NOT NULL DEFAULT 0,
      white_elo INTEGER,
      black_id INTEGER NOT NULL DEFAULT 0,
      black_elo INTEGER,
      white_material INTEGER NOT NULL DEFAULT 39,
      black_material INTEGER NOT NULL DEFAULT 39,
      result TEXT,
      time_control TEXT,
      time_control_category TEXT,
      is_online INTEGER,
      eco TEXT,
      ply_count INTEGER NOT NULL DEFAULT 0,
      fen TEXT,
      moves TEXT NOT NULL DEFAULT '[]',
      pawn_home INTEGER NOT NULL DEFAULT 65535,
      raw_pgn TEXT NOT NULL,
      pgn_hash TEXT,
      headers_json TEXT NOT NULL DEFAULT '{}',
      source_path TEXT NOT NULL,
      source_relative_path TEXT NOT NULL,
      file_name TEXT NOT NULL,
      index_in_file INTEGER NOT NULL,
      file_game_count INTEGER NOT NULL,
      has_moves INTEGER NOT NULL DEFAULT 0,
      source_byte_start INTEGER,
      source_byte_end INTEGER,
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE,
      FOREIGN KEY(event_id) REFERENCES $localChessEventsTable(id),
      FOREIGN KEY(site_id) REFERENCES $localChessSitesTable(id),
      FOREIGN KEY(white_id) REFERENCES $localChessPlayersTable(id),
      FOREIGN KEY(black_id) REFERENCES $localChessPlayersTable(id)
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessTreeNodesTable (
      database_id TEXT NOT NULL,
      node_id INTEGER NOT NULL,
      fen_key TEXT NOT NULL,
      ply INTEGER NOT NULL,
      PRIMARY KEY(database_id, node_id),
      UNIQUE(database_id, fen_key),
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessTreeMovesTable (
      database_id TEXT NOT NULL,
      node_id INTEGER NOT NULL,
      uci TEXT NOT NULL,
      child_node_id INTEGER NOT NULL,
      white INTEGER NOT NULL DEFAULT 0,
      black INTEGER NOT NULL DEFAULT 0,
      draws INTEGER NOT NULL DEFAULT 0,
      total INTEGER NOT NULL DEFAULT 0,
      last_played_ms INTEGER,
      sample_game_id TEXT,
      PRIMARY KEY(database_id, node_id, uci),
      FOREIGN KEY(database_id, node_id) REFERENCES $localChessTreeNodesTable(database_id, node_id) ON DELETE CASCADE,
      FOREIGN KEY(database_id, child_node_id) REFERENCES $localChessTreeNodesTable(database_id, node_id) ON DELETE CASCADE,
      FOREIGN KEY(sample_game_id) REFERENCES $localChessGamesTable(id) ON DELETE SET NULL
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessPositionGamesTable (
      database_id TEXT NOT NULL,
      fen_key TEXT NOT NULL,
      fen TEXT NOT NULL,
      game_id TEXT NOT NULL,
      ply INTEGER NOT NULL,
      next_uci TEXT,
      PRIMARY KEY(database_id, fen_key, game_id),
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE,
      FOREIGN KEY(game_id) REFERENCES $localChessGamesTable(id) ON DELETE CASCADE
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS $localChessGameAnalysisTable (
      game_id TEXT PRIMARY KEY,
      database_id TEXT NOT NULL,
      analysis_state TEXT NOT NULL DEFAULT '{}',
      variation_comments TEXT NOT NULL DEFAULT '{}',
      move_nags TEXT NOT NULL DEFAULT '{}',
      last_viewed_position INTEGER NOT NULL DEFAULT -1,
      notes TEXT,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_database ON $localChessGamesTable(database_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_database_index ON $localChessGamesTable(database_id, index_in_file)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_date ON $localChessGamesTable(date)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_white ON $localChessGamesTable(white_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_black ON $localChessGamesTable(black_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_event ON $localChessGamesTable(event_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_site ON $localChessGamesTable(site_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_result ON $localChessGamesTable(result)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_result ON $localChessGamesTable(database_id, result)',
  // Indexes that depend on upgrade-added columns must be created only after
  // their `_ensureColumn` calls in createLocalChessResqliteDatabaseSchema.
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_white_elo ON $localChessGamesTable(white_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_black_elo ON $localChessGamesTable(black_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_date ON $localChessGamesTable(database_id, date)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_white_elo ON $localChessGamesTable(database_id, white_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_db_black_elo ON $localChessGamesTable(database_id, black_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_plycount ON $localChessGamesTable(ply_count)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_eco ON $localChessGamesTable(database_id, eco)',
  // Covers the `tree_moves.sample_game_id -> games.id ON DELETE SET NULL`
  // foreign key. Without it, deleting each `local_chess_games` row forces a full
  // scan of `local_chess_tree_moves` to null out referencing rows, so a
  // player-deletion purge of 512 games could take >5s on a large opening tree
  // and froze the UI isolate (resqlite runs the delete synchronously). See the
  // already-present `idx_local_chess_position_games_game` for the CASCADE twin.
  'CREATE INDEX IF NOT EXISTS idx_local_chess_tree_moves_sample_game ON $localChessTreeMovesTable(sample_game_id)',
  // Covers the `tree_moves(database_id, child_node_id) -> tree_nodes ON DELETE
  // CASCADE` foreign key. Same class of bug as the sample_game index above:
  // deleting a tree node otherwise full-scans tree_moves for referencing child
  // edges, so the tree-node step of the same player-deletion purge would stall
  // the UI isolate on a large cache. The (database_id, node_id) parent edge is
  // already covered by the tree_moves primary key prefix.
  'CREATE INDEX IF NOT EXISTS idx_local_chess_tree_moves_child_node ON $localChessTreeMovesTable(database_id, child_node_id)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_position_games_fen ON $localChessPositionGamesTable(database_id, fen_key)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_position_games_game ON $localChessPositionGamesTable(game_id)',
];

class LocalChessGameAnalysis {
  const LocalChessGameAnalysis({
    required this.gameId,
    required this.databaseId,
    required this.analysisState,
    required this.variationComments,
    required this.moveNags,
    required this.lastViewedPosition,
    this.notes,
    this.isFavorite = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String gameId;
  final String databaseId;
  final Map<String, dynamic> analysisState;
  final Map<String, String> variationComments;
  final Map<String, List<int>> moveNags;
  final int lastViewedPosition;
  final String? notes;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime updatedAt;
}

@immutable
class LocalChessAppendedPgn {
  const LocalChessAppendedPgn({
    required this.rawPgn,
    this.sourceByteStart,
    this.sourceByteEnd,
  });

  final String rawPgn;
  final int? sourceByteStart;
  final int? sourceByteEnd;
}

@immutable
class LocalChessDatabaseResultStats {
  const LocalChessDatabaseResultStats({
    required this.gameCount,
    required this.winCount,
    required this.drawCount,
    required this.lossCount,
  });

  final int gameCount;
  final int winCount;
  final int drawCount;
  final int lossCount;
}

@immutable
class LocalOpeningTreeCatalogEntry {
  const LocalOpeningTreeCatalogEntry({
    required this.databaseId,
    required this.databasePath,
    required this.title,
    required this.gameCount,
    required this.positionCount,
    required this.maxPly,
    required this.updatedAt,
  });

  final String databaseId;
  final String databasePath;
  final String title;
  final int gameCount;
  final int positionCount;
  final int? maxPly;
  final DateTime? updatedAt;
}

enum LocalChessGameSortField {
  originalOrder,
  white,
  whiteElo,
  black,
  blackElo,
  result,
  eco,
  opening,
  event,
  date,
}

enum LocalChessGameSortDirection { asc, desc }

class LocalChessGameQueryPage {
  const LocalChessGameQueryPage({
    required this.games,
    required this.totalCount,
    required this.pageNumber,
    required this.pageSize,
  });

  final List<LocalChessGame> games;
  final int totalCount;
  final int pageNumber;
  final int pageSize;

  bool get hasMore => (pageNumber + 1) * pageSize < totalCount;
}

class LocalChessOpeningTreeRebuildResult {
  const LocalChessOpeningTreeRebuildResult({
    required this.index,
    required this.skippedGames,
  });

  final PlayerOpeningTreeIndex index;
  final int skippedGames;
}

class _LocalTreeRebuildWorkerRequest {
  const _LocalTreeRebuildWorkerRequest({
    required this.sendPort,
    required this.databaseFilePath,
    required this.databasePath,
  });

  final SendPort sendPort;
  final String databaseFilePath;
  final String databasePath;
}

class _LocalTreeRebuildWorkerSuccess {
  const _LocalTreeRebuildWorkerSuccess({
    required this.treeId,
    required this.databaseId,
    required this.maxPly,
    required this.positionCount,
    required this.gameCount,
    required this.generatedAtMs,
    required this.skippedGames,
  });

  final String treeId;
  final String databaseId;
  final int maxPly;
  final int positionCount;
  final int gameCount;
  final int generatedAtMs;
  final int skippedGames;
}

class _LocalTreeRebuildWorkerFailure {
  const _LocalTreeRebuildWorkerFailure(this.message, this.stackTrace);

  final String message;
  final String stackTrace;
}

/// Player fields resolvable from the global FIDE ratings table, used to
/// backfill header tags the source PGN omitted.
class LocalPlayerEnrichment {
  const LocalPlayerEnrichment({this.title, this.federation});

  final String? title;
  final String? federation;
}

const int _kEnrichmentScanPageSize = 2000;

bool _sideNeedsPlayerEnrichment(Map<String, dynamic> metadata, String side) {
  if (localPgnFideId(metadata, side) == null) return false;
  return localPgnTitle(metadata, side).isEmpty ||
      localPgnFederation(metadata, side).isEmpty;
}

class LocalChessCacheDeletionLease {
  LocalChessCacheDeletionLease._(this._release);

  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class LocalChessDatabaseRepository {
  LocalChessDatabaseRepository({
    required Future<resqlite.Database> Function() database,
    LocalChessDatabaseWithProgress? databaseWithProgress,
    LocalChessDatabaseFilePathResolver? databaseFilePath,
    Future<resqlite.Database> Function()? purgeDatabase,
    this.slowPurgeBatchThreshold = _kSlowPurgeBatchThreshold,
    this.onSlowPurgeBatch,
    this.eagerPositionRefLoadLimit = _kEagerPositionRefLoadLimit,
    this.eagerTreeMoveLoadLimit = _kEagerTreeMoveLoadLimit,
    this.cachedFileNodeGamePreviewLimit = _kCachedFileNodeGamePreviewLimit,
  }) : _database = database,
       _databaseWithProgress = databaseWithProgress,
       _databaseFilePathResolver = databaseFilePath,
       _purgeDatabase = purgeDatabase;

  final Future<resqlite.Database> Function() _database;
  final LocalChessDatabaseWithProgress? _databaseWithProgress;
  final LocalChessDatabaseFilePathResolver? _databaseFilePathResolver;
  final Future<resqlite.Database> Function()? _purgeDatabase;
  final Duration slowPurgeBatchThreshold;
  final LocalChessPurgeDiagnosticSink? onSlowPurgeBatch;
  final int eagerPositionRefLoadLimit;
  final int eagerTreeMoveLoadLimit;
  final int cachedFileNodeGamePreviewLimit;

  static const List<Duration> _sqliteBusyRetryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(milliseconds: 1500),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
  ];

  static Future<void> _localCacheWriteQueue = Future<void>.value();
  static final Object _localCacheWriteQueueZoneKey = Object();
  static final Map<String, _LocalChessSingleFileImport>
  _singleFileImportsByPath = <String, _LocalChessSingleFileImport>{};
  static Future<void> _backgroundPurgeQueue = Future<void>.value();
  static final Map<String, int> _cacheDeletionScopeRefCounts = <String, int>{};
  static int _globalCacheDeletionGuardRefCount = 0;
  final Set<String> _reusedImportedGameRows = <String>{};
  final Map<String, String> _reusedImportedContentFingerprints =
      <String, String>{};
  final Map<String, String> _activeImportedContentFingerprints =
      <String, String>{};

  /// Prevents a stale Library/import worker from recreating cache rows while
  /// a persisted player deletion is physically draining them. Unrelated paths
  /// remain writable and can interleave between purge batches.
  LocalChessCacheDeletionLease acquireCacheDeletionGuard(
    Iterable<String> sourcePaths,
  ) {
    return _acquireCacheDeletionGuard(sourcePaths, allSources: false);
  }

  LocalChessCacheDeletionLease _acquireCacheDeletionGuard(
    Iterable<String> sourcePaths, {
    required bool allSources,
  }) {
    final scopes = <String>{
      for (final path in _normalizedCacheSourcePaths(sourcePaths))
        _databaseId(path),
    };
    if (allSources) _globalCacheDeletionGuardRefCount += 1;
    for (final scope in scopes) {
      _cacheDeletionScopeRefCounts.update(
        scope,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return LocalChessCacheDeletionLease._(() {
      if (allSources && _globalCacheDeletionGuardRefCount > 0) {
        _globalCacheDeletionGuardRefCount -= 1;
      }
      for (final scope in scopes) {
        final count = _cacheDeletionScopeRefCounts[scope] ?? 0;
        if (count <= 1) {
          _cacheDeletionScopeRefCounts.remove(scope);
        } else {
          _cacheDeletionScopeRefCounts[scope] = count - 1;
        }
      }
    });
  }

  static void _throwIfCacheSourceDeletionInProgress(String path) {
    if (_globalCacheDeletionGuardRefCount > 0 ||
        _cacheDeletionScopeRefCounts.keys.any(
          (scope) => _cachePathBelongsToSource(scope, path),
        )) {
      throw const OperationCanceledException(
        'Local cache source is being deleted.',
      );
    }
  }

  Future<resqlite.Database> _openDatabase({
    LocalChessScanProgressSink? onProgress,
  }) {
    final withProgress = _databaseWithProgress;
    if (onProgress != null && withProgress != null) {
      return withProgress(onProgress: onProgress);
    }
    return _database();
  }

  Future<_LocalChessInlineImportSession?> _openInlineImportSession({
    LocalChessScanProgressSink? onProgress,
  }) async {
    final resolver = _databaseFilePathResolver;
    try {
      await _openDatabase(onProgress: onProgress);
      return _LocalChessInlineImportSession(repository: this);
    } catch (error) {
      if (resolver == null) rethrow;
      localChessLog.warning(
        'Falling back to path-only local import cache',
        context: <String, Object?>{'error': error.toString()},
      );
    }

    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.01,
        message: 'Opening local database cache...',
      ),
    );
    final path = await resolver();
    if (path == null || path.trim().isEmpty) return null;
    final db = await resqlite.Database.open(path);
    try {
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.02,
          message: 'Preparing local database cache...',
        ),
      );
      await _runLocalCacheWriteQueued(() async {
        await _configureStandaloneLocalChessDatabase(db);
        onProgress?.call(
          LocalChessScanProgress(
            fraction: 0.03,
            message: 'Checking local database schema...',
          ),
        );
        await createLocalChessResqliteDatabaseSchema(db);
      });
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.04,
          message: 'Local database cache ready.',
        ),
      );
      return _LocalChessInlineImportSession(
        repository: LocalChessDatabaseRepository(
          database: () async => db,
          eagerPositionRefLoadLimit: eagerPositionRefLoadLimit,
          eagerTreeMoveLoadLimit: eagerTreeMoveLoadLimit,
          cachedFileNodeGamePreviewLimit: cachedFileNodeGamePreviewLimit,
        ),
        ownedDatabase: db,
      );
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<String?> _workerDatabaseFilePath({
    LocalChessScanProgressSink? onProgress,
  }) async {
    final resolver = _databaseFilePathResolver;
    if (resolver != null) return resolver();
    final db = await _openDatabase(onProgress: onProgress);
    return _databaseFilePath(db);
  }

  Future<void> persistSource(LocalChessSource source) async {
    for (final file in _playableFiles(source.root)) {
      await persistFileNode(file, sourceLabel: source.label);
    }
  }

  Future<void> persistFileNode(
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    _throwIfCacheSourceDeletionInProgress(file.path);
    if (file.isPlayable && file.games.length < file.gameCount) {
      throw StateError(
        'Refusing to persist partial local chess preview for ${file.path}: '
        '${file.games.length} of ${file.gameCount} games are loaded.',
      );
    }
    var preparedFile = file;
    if (file.isPlayable && file.contentFingerprint.trim().isEmpty) {
      final probe = await probeLocalChessPathInWorker(
        file.path,
        includeContentFingerprint: true,
      );
      if (!probe.isFile ||
          probe.sizeBytes != file.sizeBytes ||
          (file.modifiedAt != null && probe.modifiedAt != file.modifiedAt) ||
          probe.contentFingerprint == null) {
        throw LocalChessFileAccessException.changed(path: file.path);
      }
      preparedFile = LocalChessFileNode(
        name: file.name,
        path: file.path,
        relativePath: file.relativePath,
        extension: file.extension,
        status: file.status,
        games: file.games,
        gameCount: file.gameCount,
        sizeBytes: probe.sizeBytes!,
        modifiedAt: probe.modifiedAt,
        message: file.message,
        openingTreeIndex: file.openingTreeIndex,
        pgnOffsetIndex: file.pgnOffsetIndex,
        contentFingerprint: probe.contentFingerprint!,
      );
    }
    final db = await _database();
    await _lockedTransaction(db, (txn) async {
      _throwIfCacheSourceDeletionInProgress(preparedFile.path);
      if (!preparedFile.isPlayable) {
        await _deleteFileCache(txn, preparedFile.path);
        return;
      }
      await _replaceFileNode(txn, preparedFile, sourceLabel: sourceLabel);
    });
  }

  Future<List<LocalOpeningTreeCatalogEntry>> listBuiltOpeningTrees() async {
    final db = await _database();
    final rows = await db.select('''
      SELECT
        d.id AS id,
        d.path AS path,
        d.label AS label,
        d.game_count AS game_count,
        d.position_count AS position_count,
        d.tree_max_ply AS tree_max_ply,
        d.updated_at_ms AS updated_at_ms
      FROM $localChessDatabasesTable d
      WHERE d.deleted_at_ms IS NULL
        AND d.position_count > 0
        AND d.tree_max_ply IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM $localChessTreeNodesTable tn
          WHERE tn.database_id = d.id AND tn.node_id = 0
          LIMIT 1
        )
      ORDER BY d.updated_at_ms DESC, d.label COLLATE NOCASE ASC
      ''');

    return rows
        .map((row) {
          final path = row['path']?.toString().trim() ?? '';
          final label = row['label']?.toString().trim() ?? '';
          return LocalOpeningTreeCatalogEntry(
            databaseId: row['id']?.toString().trim() ?? _databaseId(path),
            databasePath: path,
            title:
                label.isEmpty
                    ? localChessDatabaseDisplayNameForPath(path)
                    : label,
            gameCount: _readInt(row['game_count']),
            positionCount: _readInt(row['position_count']),
            maxPly: _readNullableInt(row['tree_max_ply']),
            updatedAt: _dateFromMillis(row['updated_at_ms']),
          );
        })
        .where((entry) => entry.databasePath.isNotEmpty)
        .toList(growable: false);
  }

  Future<PlayerOpeningTreeIndex?> loadOpeningTreeIndexForDatabase({
    required String databasePath,
  }) async {
    final databaseId = _databaseId(databasePath);
    if (databaseId.isEmpty) return null;
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT *
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;
    final row = databaseRows.single;
    try {
      return await _loadOpeningTreeIndex(
        db,
        databaseId,
        generatedAtMs: row['updated_at_ms'],
        expectedPositionCount: _readInt(row['position_count']),
        expectedGameCount: _readInt(row['game_count']),
        expectedMaxPly: _readNullableInt(row['tree_max_ply']),
      );
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<LocalChessSource?> importSingleFileSource({
    required String path,
    String? sourceLabel,
    OperationCancellationToken? cancellationToken,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    cancellationToken?.throwIfCanceled();
    if (!looksLikeLocalChessFile(trimmed)) return null;
    final importKey = _databaseId(trimmed);
    final existingImport = _singleFileImportsByPath[importKey];
    if (existingImport?.isCanceled == true) {
      _singleFileImportsByPath.remove(importKey);
    } else if (existingImport != null) {
      localChessLog.info(
        'PGN import joined existing worker',
        context: <String, Object?>{'path': trimmed},
      );
      return existingImport.future;
    }

    late final Future<LocalChessSource?> importFuture;
    importFuture = _importSingleFileSourceUnlocked(
      path: trimmed,
      sourceLabel: sourceLabel,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    final importRecord = _LocalChessSingleFileImport(
      importFuture,
      cancellationToken,
    );
    _singleFileImportsByPath[importKey] = importRecord;
    try {
      return await importFuture;
    } finally {
      if (identical(_singleFileImportsByPath[importKey], importRecord)) {
        _singleFileImportsByPath.remove(importKey);
      }
    }
  }

  /// Materializes a Combined database from source rows that were already
  /// imported into the local cache. Returns false when any source cache is
  /// missing or its deduplicated count does not match the generated PGN, so
  /// callers can safely fall back to the normal file importer.
  Future<bool> rebuildCombinedCacheFromCachedSources({
    required String combinedPath,
    required String sourceLabel,
    required List<String> sourcePaths,
    required Map<String, String> sourceTagsByPath,
    required String combinedFormatVersion,
    required int expectedGameCount,
    OperationCancellationToken? cancellationToken,
  }) async {
    final cleanCombinedPath = combinedPath.trim();
    final normalizedSources = <String>[];
    final sourceTagsById = <String, String>{};
    for (final path in sourcePaths) {
      final databaseId = _databaseId(path);
      if (databaseId.isEmpty || sourceTagsById.containsKey(databaseId)) {
        continue;
      }
      final sourceTag = sourceTagsByPath[path]?.trim();
      if (sourceTag == null || sourceTag.isEmpty) return false;
      normalizedSources.add(databaseId);
      sourceTagsById[databaseId] = sourceTag;
    }
    if (cleanCombinedPath.isEmpty ||
        normalizedSources.isEmpty ||
        expectedGameCount <= 0) {
      return false;
    }

    cancellationToken?.throwIfCanceled();
    final file = File(cleanCombinedPath);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return false;
    final contentFingerprint = await computeLocalChessFileContentFingerprint(
      cleanCombinedPath,
      stat: stat,
    );
    cancellationToken?.throwIfCanceled();

    final stopwatch = Stopwatch()..start();
    final combinedDatabaseId = _databaseId(cleanCombinedPath);
    final combinedGameIdPrefix =
        'local_combined_${_stableId(combinedDatabaseId)}_';
    final db = await _database();
    try {
      final rebuilt = await _lockedTransaction(db, (txn) async {
        cancellationToken?.throwIfCanceled();
        final sourcePlaceholders = _sqlPlaceholders(normalizedSources.length);
        final cachedSourceRows = await txn.select(
          '''
          SELECT id
          FROM $localChessDatabasesTable
          WHERE id IN ($sourcePlaceholders)
            AND deleted_at_ms IS NULL
          ''',
          <Object?>[...normalizedSources],
        );
        if (cachedSourceRows.length != normalizedSources.length) return false;

        final distinctRows = await txn.select(
          '''
          SELECT COUNT(*) AS count
          FROM (
            SELECT 1
            FROM $localChessGamesTable
            WHERE database_id IN ($sourcePlaceholders)
            GROUP BY CASE
              WHEN TRIM(COALESCE(pgn_hash, '')) = ''
                THEN 'id:' || id
              ELSE 'hash:' || TRIM(pgn_hash)
            END
          )
          ''',
          <Object?>[...normalizedSources],
        );
        if (_readInt(distinctRows.single['count']) != expectedGameCount) {
          return false;
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        final existingCountRows = await txn.select(
          '''
          SELECT COUNT(*) AS count
          FROM $localChessGamesTable
          WHERE database_id = ?
          ''',
          <Object?>[combinedDatabaseId],
        );
        final existingGameCount = _readInt(existingCountRows.single['count']);
        if (existingGameCount == expectedGameCount) {
          final matchingRows = await txn.select(
            '''
            SELECT COUNT(*) AS count
            FROM $localChessGamesTable AS combined
            WHERE combined.database_id = ?
              AND TRIM(COALESCE(combined.pgn_hash, '')) <> ''
              AND EXISTS (
                SELECT 1
                FROM $localChessGamesTable AS source
                WHERE source.database_id IN ($sourcePlaceholders)
                  AND source.pgn_hash = combined.pgn_hash
              )
            ''',
            <Object?>[combinedDatabaseId, ...normalizedSources],
          );
          if (_readInt(matchingRows.single['count']) == expectedGameCount) {
            // The generated file changed only in app-owned Combined metadata.
            // Its cached game set and any already-built tree are still valid.
            await _upsertLocalChessDatabaseRow(txn, <String, Object?>{
              'id': combinedDatabaseId,
              'path': cleanCombinedPath,
              'label': sourceLabel,
              'extension': p.extension(cleanCombinedPath),
              'size_bytes': stat.size,
              'modified_at_ms': stat.modified.millisecondsSinceEpoch,
              'file_count': 1,
              'game_count': expectedGameCount,
              'imported_at_ms': now,
              'updated_at_ms': now,
              'deleted_at_ms': null,
              'content_fingerprint': contentFingerprint,
            });
            return true;
          }
        }

        await _upsertLocalChessDatabaseRow(txn, <String, Object?>{
          'id': combinedDatabaseId,
          'path': cleanCombinedPath,
          'label': sourceLabel,
          'extension': p.extension(cleanCombinedPath),
          'size_bytes': stat.size,
          'modified_at_ms': stat.modified.millisecondsSinceEpoch,
          'file_count': 1,
          'game_count': expectedGameCount,
          'position_count': 0,
          'tree_snapshot': null,
          'tree_max_ply': null,
          'imported_at_ms': now,
          'updated_at_ms': now,
          'deleted_at_ms': null,
          'content_fingerprint': contentFingerprint,
        });

        // Invalid tree rows may remain until the next rebuild, but metadata is
        // already unpublished above. Keeping those aggregate rows avoids
        // making the Combined button wait while a previous large tree is
        // deleted; the tree rebuild replaces them before publishing.
        await txn.execute(
          'DELETE FROM $localChessGameAnalysisTable WHERE database_id = ?',
          <Object?>[combinedDatabaseId],
        );
        await txn.execute(
          'DELETE FROM $localChessGamesTable WHERE database_id = ?',
          <Object?>[combinedDatabaseId],
        );

        final sourceValues = List<String>.filled(
          normalizedSources.length,
          '(?, ?, ?)',
        ).join(', ');
        final sourceParams = <Object?>[];
        for (var index = 0; index < normalizedSources.length; index++) {
          final sourceId = normalizedSources[index];
          sourceParams.addAll(<Object?>[
            sourceId,
            index,
            sourceTagsById[sourceId],
          ]);
        }
        final inserted = await txn.execute(
          '''
          WITH source_order(database_id, source_priority, source_tag) AS (
            VALUES $sourceValues
          ),
          source_games AS (
            SELECT
              g.*,
              s.source_priority,
              s.source_tag,
              CASE
                WHEN TRIM(COALESCE(g.pgn_hash, '')) = ''
                  THEN 'id:' || g.id
                ELSE 'hash:' || TRIM(g.pgn_hash)
              END AS dedup_key
            FROM $localChessGamesTable g
            INNER JOIN source_order s ON s.database_id = g.database_id
          ),
          ranked AS (
            SELECT
              *,
              ROW_NUMBER() OVER (
                PARTITION BY dedup_key
                ORDER BY source_priority ASC, index_in_file ASC, id ASC
              ) AS duplicate_rank
            FROM source_games
          ),
          selected AS (
            SELECT
              *,
              ROW_NUMBER() OVER (
                ORDER BY source_priority ASC, index_in_file ASC, id ASC
              ) - 1 AS combined_index,
              COUNT(*) OVER () AS combined_count
            FROM ranked
            WHERE duplicate_rank = 1
          )
          INSERT INTO $localChessGamesTable(
            id,
            database_id,
            event_id,
            site_id,
            date,
            utc_time,
            round,
            white_id,
            white_elo,
            black_id,
            black_elo,
            white_material,
            black_material,
            result,
            time_control,
            time_control_category,
            is_online,
            eco,
            ply_count,
            fen,
            moves,
            pawn_home,
            raw_pgn,
            pgn_hash,
            headers_json,
            source_path,
            source_relative_path,
            file_name,
            index_in_file,
            file_game_count,
            has_moves,
            source_byte_start,
            source_byte_end
          )
          SELECT
            ? || id,
            ?,
            event_id,
            site_id,
            date,
            utc_time,
            round,
            white_id,
            white_elo,
            black_id,
            black_elo,
            white_material,
            black_material,
            result,
            time_control,
            time_control_category,
            is_online,
            eco,
            ply_count,
            fen,
            moves,
            pawn_home,
            raw_pgn,
            pgn_hash,
            json_set(
              CASE
                WHEN json_valid(headers_json) THEN headers_json
                ELSE '{}'
              END,
              '\$.ChessEverCombinedVersion', ?,
              '\$.ChessEverSource', source_tag,
              '\$.ChessEverTimeControlCategory',
                COALESCE(NULLIF(time_control_category, ''), 'unknown')
            ),
            source_path,
            source_relative_path,
            file_name,
            combined_index,
            combined_count,
            has_moves,
            source_byte_start,
            source_byte_end
          FROM selected
          ''',
          <Object?>[
            ...sourceParams,
            combinedGameIdPrefix,
            combinedDatabaseId,
            combinedFormatVersion,
          ],
        );
        if (inserted.affectedRows != expectedGameCount) {
          throw const _CachedCombinedCacheInsertMismatch();
        }
        cancellationToken?.throwIfCanceled();
        return true;
      });
      stopwatch.stop();
      if (rebuilt) {
        localChessLog.info(
          'Combined cache materialized from indexed sources',
          context: <String, Object?>{
            'path': cleanCombinedPath,
            'sources': normalizedSources.length,
            'games': expectedGameCount,
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        );
      }
      return rebuilt;
    } on _CachedCombinedCacheInsertMismatch {
      return false;
    }
  }

  Future<LocalChessSource?> _importSingleFileSourceUnlocked({
    required String path,
    String? sourceLabel,
    OperationCancellationToken? cancellationToken,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final trimmed = path.trim();
    cancellationToken?.throwIfCanceled();
    final importStopwatch = Stopwatch()..start();
    localChessLog.info(
      'PGN import started',
      context: <String, Object?>{'path': trimmed, 'label': sourceLabel},
    );

    final session = await _cancelableLocalChessFuture(
      _openInlineImportSession(onProgress: onProgress),
      cancellationToken,
    );
    if (session == null) {
      return null;
    }
    cancellationToken?.throwIfCanceled();

    try {
      // Open the cache/session before taking the global write queue. Opening the
      // app cache may itself need that queue for schema or migration work; if
      // import holds it while awaiting a pending open, the UI stalls around the
      // early import progress range.
      final source = await _runLocalCacheWriteQueued(
        () => _importSingleLocalChessFileInline(
          path: trimmed,
          sourceLabel: sourceLabel,
          writerRepository: session.repository,
          cancellationToken: cancellationToken,
          onProgress: onProgress,
        ),
        onWaiting:
            onProgress == null
                ? null
                : () => onProgress(
                  LocalChessScanProgress(
                    fraction: 0,
                    message: 'Waiting for local database...',
                  ),
                ),
      );
      cancellationToken?.throwIfCanceled();
      importStopwatch.stop();
      final importedFile = source.nodeForPath(trimmed);
      localChessLog.info(
        'PGN import finished',
        context: <String, Object?>{
          'path': trimmed,
          'elapsedMs': importStopwatch.elapsedMilliseconds,
          'games':
              importedFile is LocalChessFileNode
                  ? importedFile.gameCount
                  : null,
          'preview':
              importedFile is LocalChessFileNode
                  ? importedFile.games.length
                  : null,
        },
      );
      return source;
    } catch (error, stackTrace) {
      importStopwatch.stop();
      if (isOperationCanceled(error)) {
        localChessLog.info(
          'PGN import canceled',
          context: <String, Object?>{
            'path': trimmed,
            'elapsedMs': importStopwatch.elapsedMilliseconds,
          },
        );
        rethrow;
      }
      localChessLog.error(
        'PGN import failed',
        error,
        stackTrace,
        tag: 'local_chess.import',
        context: <String, Object?>{
          'path': trimmed,
          'elapsedMs': importStopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    } finally {
      await session.close();
    }
  }

  Future<LocalChessSource> _importSingleLocalChessFileInline({
    required String path,
    String? sourceLabel,
    required LocalChessDatabaseRepository writerRepository,
    OperationCancellationToken? cancellationToken,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    void emit(LocalChessScanProgress progress) {
      cancellationToken?.throwIfCanceled();
      onProgress?.call(progress);
    }

    final rootPath = p.dirname(path);
    final label = sourceLabel ?? localChessDatabaseDisplayNameForPath(path);
    _ImportedFilePreparation? preparation;
    var finalized = false;
    try {
      final node = await scanLocalChessFileNodeForImportWithProgress(
        path: path,
        rootPath: rootPath,
        previewGameLimit: cachedFileNodeGamePreviewLimit,
        batchSize: _kInteractiveImportBatchSize,
        onProgress: emit,
        onImportStart: (start) async {
          cancellationToken?.throwIfCanceled();
          await writerRepository._beginImportedFileNode(
            start,
            sourceLabel: label,
            onProgress: emit,
            cancellationToken: cancellationToken,
            onPreparationStarted: (value) => preparation = value,
          );
          cancellationToken?.throwIfCanceled();
        },
        onGameBatch: (batch) async {
          cancellationToken?.throwIfCanceled();
          await writerRepository._persistImportedGameBatch(path, batch.games);
          cancellationToken?.throwIfCanceled();
        },
      );

      cancellationToken?.throwIfCanceled();
      if (node.isPlayable) {
        if (preparation == null) {
          await writerRepository._beginImportedFileNode(
            LocalChessFileImportStart(
              path: node.path,
              relativePath: node.relativePath,
              extension: node.extension,
              sizeBytes: node.sizeBytes,
              modifiedAt: node.modifiedAt,
              totalEntries: node.gameCount,
              contentFingerprint: node.contentFingerprint,
              pgnOffsetIndex: node.pgnOffsetIndex,
            ),
            sourceLabel: label,
            onProgress: emit,
            cancellationToken: cancellationToken,
            onPreparationStarted: (value) => preparation = value,
          );
        }
        emit(
          LocalChessScanProgress(
            fraction: 0.985,
            message: 'Saving local cache...',
          ),
        );
        await writerRepository._completeImportedFileNode(node);
      } else {
        await writerRepository._discardImportedFileNode(path);
      }
      finalized = true;

      final root = LocalChessFolderNode.fromChildren(
        name: label,
        path: 'local-file:${_stableId(path)}',
        relativePath: '',
        children: <LocalChessNode>[node],
      );
      return LocalChessSource(
        id: _stableId(path),
        label: label,
        paths: <String>[path],
        rootPath: rootPath,
        scannedAt: DateTime.now(),
        root: root,
      );
    } finally {
      final activePreparation = preparation;
      if (!finalized && activePreparation != null) {
        try {
          await writerRepository._abortImportedFileNode(
            path,
            deleteCache:
                activePreparation == _ImportedFilePreparation.replacing,
          );
        } catch (_) {
          // Preserve the read, cancellation, or finalization failure.
        }
      }
    }
  }

  /// The single, process-global write lock for the local-chess resqlite cache.
  ///
  /// resqlite opens one writer per database file and every transaction runs
  /// `BEGIN IMMEDIATE` (it acquires the write lock upfront on the assumption
  /// that its connection is the only writer). This app, however, opens several
  /// connections to the same `chessever_local_chess.db` — the shared main
  /// connection, dedicated import connections, and the transient tree-rebuild
  /// isolate — so two of them issuing `BEGIN IMMEDIATE` at once
  /// race for the single SQLite write lock and the loser throws
  /// `SQLITE_BUSY` ("database is locked", code 5) once `busy_timeout` elapses.
  ///
  /// Funnelling every writer through this FIFO guarantees at most one write
  /// transaction is ever in flight, so the lock is always free when a writer
  /// begins. Reads never go through here — WAL readers never block. Nested
  /// calls from the same queued action run inline; this lets first-open schema
  /// and migration work share the caller's lock instead of self-deadlocking.
  ///
  /// [onWaiting] fires once if another writer still owns the queue after a
  /// short delay so import / tree UI can show "Waiting for local database..."
  /// instead of looking frozen at 0%.
  static Future<T> _runLocalCacheWriteQueued<T>(
    Future<T> Function() action, {
    void Function()? onWaiting,
  }) async {
    if (Zone.current[_localCacheWriteQueueZoneKey] == true) {
      return action();
    }

    final previous = _localCacheWriteQueue;
    final current = Completer<void>();
    _localCacheWriteQueue = current.future;
    try {
      var waitingNotified = false;
      void notifyWaiting() {
        if (waitingNotified || onWaiting == null) return;
        waitingNotified = true;
        onWaiting();
      }

      // Future.any does not cancel its losing delayed future. The old version
      // therefore emitted "Waiting..." 80ms later even when the queue was
      // already free—and could overwrite a fast operation's final "ready"
      // status. A cancelable timer keeps this strictly tied to real queue wait.
      final waitingTimer = Timer(
        const Duration(milliseconds: 80),
        notifyWaiting,
      );
      try {
        await previous;
      } catch (_) {
        // Earlier import failures must not permanently poison the writer queue.
      } finally {
        waitingTimer.cancel();
      }
      return await runZoned<Future<T>>(
        action,
        zoneValues: <Object, Object?>{_localCacheWriteQueueZoneKey: true},
      );
    } finally {
      if (!current.isCompleted) current.complete();
    }
  }

  /// Runs a write [body] on [db] inside a transaction serialized through the
  /// global [_runLocalCacheWriteQueued] lock, so its `BEGIN IMMEDIATE` never
  /// races another connection's writer. Use for every main-connection write
  /// that is not already nested inside a queued action.
  Future<T> _lockedTransaction<T>(
    resqlite.Database db,
    Future<T> Function(resqlite.Transaction txn) body,
  ) {
    return _runLocalCacheWriteQueued(() => db.transaction(body));
  }

  /// Runs a single write [statement] serialized through the global write lock.
  Future<void> _lockedExecute(
    resqlite.Database db,
    String statement, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    return _runLocalCacheWriteQueued(() => db.execute(statement, parameters));
  }

  /// Test-only access to the global write lock so serialization can be asserted
  /// without spinning up isolates.
  @visibleForTesting
  static Future<T> debugRunWriteSerialized<T>(Future<T> Function() action) =>
      _runLocalCacheWriteQueued(action);

  @visibleForTesting
  static Future<void> debugDrainBackgroundPurgeQueue() async {
    try {
      await _backgroundPurgeQueue;
    } catch (_) {
      // The production queue logs failures through its own unawaited handler.
    }
  }

  Future<bool> persistOpeningTreeIndex({
    required String databasePath,
    required PlayerOpeningTreeIndex index,
  }) async {
    _throwIfCacheSourceDeletionInProgress(databasePath);
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return false;

    await _lockedTransaction(db, (txn) async {
      _throwIfCacheSourceDeletionInProgress(databasePath);
      final gameIds =
          index.gamesByFen.isEmpty
              ? const <String>{}
              : await _localGameIds(txn, databaseId);
      await _deleteOpeningTreeRows(txn, databaseId);
      await _insertTree(txn, databaseId, index);
      await _insertPositionGameRefs(txn, databaseId, index, gameIds);
      await txn.execute(
        '''
        UPDATE $localChessDatabasesTable
        SET
          position_count = ?,
          tree_snapshot = NULL,
          tree_max_ply = ?,
          updated_at_ms = ?
        WHERE id = ? AND deleted_at_ms IS NULL
        ''',
        <Object?>[
          index.positionCount,
          index.maxPly,
          DateTime.now().millisecondsSinceEpoch,
          databaseId,
        ],
      );
    });
    return true;
  }

  Future<LocalChessOpeningTreeRebuildResult?>
  rebuildOpeningTreeFromCachedGames({
    required String databasePath,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    // The rebuild worker runs in its own isolate on a separate connection and
    // writes the tree back into the shared cache file; serialize its whole run
    // through the global write lock so its BEGIN IMMEDIATE never races another
    // writer. Opening the DB happens inside (unqueued), so this does not nest.
    return _runLocalCacheWriteQueued(
      () {
        cancellationToken?.throwIfCanceled();
        _throwIfCacheSourceDeletionInProgress(databasePath);
        return _rebuildOpeningTreeFromCachedGamesUnlocked(
          databasePath: databasePath,
          onProgress: onProgress,
          cancellationToken: cancellationToken,
        );
      },
      onWaiting:
          onProgress == null
              ? null
              : () => onProgress(
                LocalChessScanProgress(
                  fraction: 0,
                  message: 'Waiting for local database...',
                ),
              ),
    );
  }

  Future<LocalChessOpeningTreeRebuildResult?>
  _rebuildOpeningTreeFromCachedGamesUnlocked({
    required String databasePath,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final stopwatch = Stopwatch()..start();
    localChessLog.info(
      'Local tree rebuild started',
      context: <String, Object?>{'path': databasePath},
    );
    final databaseFilePath = await _workerDatabaseFilePath(
      onProgress: onProgress,
    );
    cancellationToken?.throwIfCanceled();
    if (databaseFilePath == null || databaseFilePath.isEmpty) {
      throw StateError('Local chess database file path is unavailable.');
    }

    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    Isolate? isolate;
    VoidCallback removeCancellationListener = () {};
    try {
      isolate = await Isolate.spawn(
        _rebuildOpeningTreeFromCachedGamesWorker,
        _LocalTreeRebuildWorkerRequest(
          sendPort: receivePort.sendPort,
          databaseFilePath: databaseFilePath,
          databasePath: databasePath,
        ),
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
        errorsAreFatal: true,
      );
      removeCancellationListener =
          cancellationToken?.addListener(() {
            isolate?.kill(priority: Isolate.immediate);
            receivePort.close();
          }) ??
          () {};

      final exitDone = Completer<void>();
      final errorDone = Completer<Object>();
      late final StreamSubscription<dynamic> exitSubscription;
      late final StreamSubscription<dynamic> errorSubscription;
      exitSubscription = exitPort.listen((_) {
        if (!exitDone.isCompleted) exitDone.complete();
        unawaited(exitSubscription.cancel());
      });
      errorSubscription = errorPort.listen((message) {
        if (errorDone.isCompleted) return;
        errorDone.complete(_isolateErrorMessage(message));
        unawaited(errorSubscription.cancel());
      });

      await for (final message in receivePort) {
        switch (message) {
          case LocalChessScanProgress():
            onProgress?.call(message);
          case _LocalTreeRebuildWorkerSuccess():
            await exitDone.future;
            stopwatch.stop();
            localChessLog.info(
              'Local tree rebuild finished',
              context: <String, Object?>{
                'path': databasePath,
                'games': message.gameCount,
                'positions': message.positionCount,
                'maxPly': message.maxPly,
                'skippedGames': message.skippedGames,
                'elapsedMs': stopwatch.elapsedMilliseconds,
              },
            );
            return LocalChessOpeningTreeRebuildResult(
              index: PlayerOpeningTreeIndex(
                treeId: message.treeId,
                playerId: message.databaseId,
                maxPly: message.maxPly,
                rootNodeId: 0,
                generatedAt: DateTime.fromMillisecondsSinceEpoch(
                  message.generatedAtMs,
                ),
                nodesById: const <int, PlayerOpeningTreeNode>{},
                nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
                gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
                gameRowsById: const <String, Map<String, dynamic>>{},
                persistedPositionCount: message.positionCount,
                persistedGameCount: message.gameCount,
              ),
              skippedGames: message.skippedGames,
            );
          case _LocalTreeRebuildWorkerFailure():
            throw StateError(message.message);
        }

        if (errorDone.isCompleted) {
          throw await errorDone.future;
        }
      }
      cancellationToken?.throwIfCanceled();
      if (errorDone.isCompleted) throw await errorDone.future;
      return null;
    } catch (error, stackTrace) {
      stopwatch.stop();
      if (isOperationCanceled(error)) {
        localChessLog.info(
          'Local tree rebuild canceled',
          context: <String, Object?>{
            'path': databasePath,
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        );
        rethrow;
      }
      localChessLog.error(
        'Local tree rebuild failed',
        error,
        stackTrace,
        tag: 'local_chess.tree_rebuild',
        context: <String, Object?>{
          'path': databasePath,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    } finally {
      removeCancellationListener();
      receivePort.close();
      exitPort.close();
      errorPort.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<int> deleteCachedSource(
    String path, {
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final guard = acquireCacheDeletionGuard(<String>[path]);
    try {
      return await _deleteCachedSourceUnlocked(path, onProgress: onProgress);
    } finally {
      guard.release();
    }
  }

  Future<int> _deleteCachedSourceUnlocked(
    String path, {
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final marked = await _retryWhenSqliteBusy(
      operation: 'mark local source deleted',
      context: const <String, Object?>{'sourceCount': 1},
      action: () => markCachedSourceDeleted(path),
    );
    final purged = await _retryWhenSqliteBusy(
      operation: 'purge deleted local source',
      context: const <String, Object?>{'sourceCount': 1},
      action:
          () => purgeDeletedCaches(sourcePath: path, onProgress: onProgress),
    );
    return marked == 0 ? purged : marked;
  }

  /// Marks every path in [sourcePaths] deleted and then runs one exact,
  /// consolidated purge pass. This remains restart-safe when every row was
  /// already marked by a previous process.
  ///
  /// Removing a player that owns several generated sources used to enqueue one
  /// fire-and-forget [scheduleCachedSourceDelete] per source, and each of those
  /// opened (and closed) its own dedicated resqlite connection — spawning a
  /// reader pool + writer isolate every time. Doing the whole player in one
  /// marked-then-purged pass collapses that to a single connection open, and
  /// because it is awaitable, background cleanup can retain its persisted
  /// tombstone until every owned cache record is gone.
  Future<int> deleteCachedSourcesAwaitingPurge({
    required Iterable<String> sourcePaths,
    int batchSize = _kCooperativePurgeBatchSize,
    bool cleanupOrphanMetadata = false,
    bool checkpoint = false,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final paths = _normalizedCacheSourcePaths(sourcePaths);
    if (paths.isEmpty) {
      onProgress?.call(
        LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
      );
      return 0;
    }
    final guard = acquireCacheDeletionGuard(paths);
    try {
      await _retryWhenSqliteBusy(
        operation: 'mark local sources deleted',
        context: <String, Object?>{'sourceCount': paths.length},
        action: () => markCachedSourcesDeleted(paths),
      );
      // Do not short-circuit when this cleanup was already marked by an
      // earlier process. The deletion guard prevents a stale same-path import
      // from clearing the tombstone between these cooperative queue slices.
      final purged = await _retryWhenSqliteBusy(
        operation: 'purge deleted local sources',
        context: <String, Object?>{'sourceCount': paths.length},
        action:
            () => purgeDeletedCaches(
              sourcePaths: paths,
              batchSize: batchSize,
              cleanupOrphanMetadata: cleanupOrphanMetadata,
              checkpoint: checkpoint,
              onProgress: onProgress,
            ),
      );
      final remaining = await deletedCacheCount(sourcePaths: paths);
      if (remaining > 0) {
        throw StateError(
          'Local cache purge incomplete: $remaining database records remain.',
        );
      }
      return purged;
    } finally {
      guard.release();
    }
  }

  void scheduleCachedSourceDelete({
    required String sourcePath,
    int batchSize = _kCooperativePurgeBatchSize,
    bool cleanupOrphanMetadata = false,
    bool checkpoint = false,
  }) {
    final trimmedSourcePath = sourcePath.trim();
    if (trimmedSourcePath.isEmpty) return;
    _backgroundPurgeQueue = _backgroundPurgeQueue
        .catchError((Object _) {})
        .then((_) async {
          try {
            localChessLog.info(
              'Local database background delete queued',
              context: <String, Object?>{
                'sourceCount': 1,
                'batchSize': batchSize,
                'cleanupOrphanMetadata': cleanupOrphanMetadata,
                'checkpoint': checkpoint,
              },
            );
            final purged = await deleteCachedSourcesAwaitingPurge(
              sourcePaths: <String>[trimmedSourcePath],
              batchSize: batchSize,
              cleanupOrphanMetadata: cleanupOrphanMetadata,
              checkpoint: checkpoint,
            );
            localChessLog.info(
              'Local database background delete finished',
              context: <String, Object?>{
                'sourceCount': 1,
                'purgedDatabases': purged,
              },
            );
          } catch (error, stackTrace) {
            localChessLog.error(
              'Local database background delete failed',
              error,
              stackTrace,
              tag: 'local_chess.background_delete',
              context: const <String, Object?>{'sourceCount': 1},
            );
          }
        });
    unawaited(_backgroundPurgeQueue);
  }

  Future<int> markCachedSourceDeleted(String path) {
    return markCachedSourcesDeleted(<String>[path]);
  }

  /// Logically deletes every cache belonging to [sourcePaths] in one shared
  /// write-queue pass. Calling it again is safe: already-marked rows remain
  /// hidden and contribute zero to the return value.
  Future<int> markCachedSourcesDeleted(Iterable<String> sourcePaths) {
    final paths = _normalizedCacheSourcePaths(sourcePaths);
    if (paths.isEmpty) return Future<int>.value(0);
    return _runLocalCacheWriteQueued(
      () => _markCachedSourcesDeletedUnlocked(paths),
    );
  }

  Future<int> _markCachedSourcesDeletedUnlocked(Set<String> paths) async {
    if (paths.isEmpty) return 0;
    final stopwatch = Stopwatch()..start();
    localChessLog.info(
      'Local database delete mark started',
      context: <String, Object?>{'sourceCount': paths.length},
    );
    final db = await _database();
    try {
      final rows = await db.select('''
      SELECT id, path
      FROM $localChessDatabasesTable
      WHERE deleted_at_ms IS NULL
      ''');
      final databaseIds = <String>[
        for (final row in rows)
          if (paths.any(
            (sourcePath) => _cachePathBelongsToSource(
              sourcePath,
              row['path']?.toString() ?? '',
            ),
          ))
            row['id'] as String,
      ];
      if (databaseIds.isEmpty) {
        stopwatch.stop();
        localChessLog.info(
          'Local database delete mark skipped',
          context: <String, Object?>{
            'sourceCount': paths.length,
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        );
        return 0;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.executeBatch(
        '''
      UPDATE $localChessDatabasesTable
      SET deleted_at_ms = ?, updated_at_ms = ?
      WHERE id = ? AND deleted_at_ms IS NULL
      ''',
        <List<Object?>>[
          for (final databaseId in databaseIds) <Object?>[now, now, databaseId],
        ],
      );
      stopwatch.stop();
      localChessLog.info(
        'Local database delete mark finished',
        context: <String, Object?>{
          'sourceCount': paths.length,
          'databases': databaseIds.length,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      return databaseIds.length;
    } catch (error, stackTrace) {
      stopwatch.stop();
      localChessLog.error(
        'Local database delete mark failed',
        error,
        stackTrace,
        tag: 'local_chess.mark_deleted',
        context: <String, Object?>{
          'sourceCount': paths.length,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    }
  }

  Future<int> deletedCacheCount({
    String? sourcePath,
    Iterable<String>? sourcePaths,
  }) async {
    final scopedPaths = _normalizedOptionalCacheSourcePaths(
      sourcePath: sourcePath,
      sourcePaths: sourcePaths,
    );
    if (scopedPaths?.isEmpty == true) return 0;
    final db = await _database();
    final rows = await db.select('''
      SELECT path
      FROM $localChessDatabasesTable
      WHERE deleted_at_ms IS NOT NULL
      ''');
    if (scopedPaths == null) return rows.length;
    return rows.where((row) {
      final cachedPath = row['path']?.toString() ?? '';
      return scopedPaths.any(
        (path) => _cachePathBelongsToSource(path, cachedPath),
      );
    }).length;
  }

  Future<int> purgeDeletedCaches({
    String? sourcePath,
    Iterable<String>? sourcePaths,
    int batchSize = _kCooperativePurgeBatchSize,
    bool cleanupOrphanMetadata = true,
    bool checkpoint = true,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final scopedPaths = _normalizedOptionalCacheSourcePaths(
      sourcePath: sourcePath,
      sourcePaths: sourcePaths,
    );
    final guard = _acquireCacheDeletionGuard(
      scopedPaths ?? const <String>[],
      allSources: scopedPaths == null,
    );
    try {
      return await _purgeDeletedCachesUnlocked(
        sourcePaths: scopedPaths,
        batchSize: batchSize,
        cleanupOrphanMetadata: cleanupOrphanMetadata,
        checkpoint: checkpoint,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    } finally {
      guard.release();
    }
  }

  Future<int> _purgeDeletedCachesUnlocked({
    Set<String>? sourcePaths,
    int batchSize = _kCooperativePurgeBatchSize,
    bool cleanupOrphanMetadata = true,
    bool checkpoint = true,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effectiveBatchSize =
        batchSize <= 0 ? _kCooperativePurgeBatchSize : batchSize;
    resqlite.Database? dedicatedDb;
    final slowDiagnostics = _LocalChessPurgeDiagnostics();
    try {
      cancellationToken?.throwIfCanceled();
      onProgress?.call(
        LocalChessScanProgress(fraction: 0, message: 'Preparing delete...'),
      );
      if (sourcePaths?.isEmpty == true) {
        onProgress?.call(
          LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
        );
        return 0;
      }
      final purgeDatabase = _purgeDatabase;
      final db =
          purgeDatabase == null
              ? await _database()
              : dedicatedDb = await purgeDatabase();
      final allRows = await db.select('''
      SELECT id, path
      FROM $localChessDatabasesTable
      WHERE deleted_at_ms IS NOT NULL
      ORDER BY deleted_at_ms ASC
      ''');
      cancellationToken?.throwIfCanceled();
      final rows =
          sourcePaths == null
              ? allRows
              : <Map<String, Object?>>[
                for (final row in allRows)
                  if (sourcePaths.any(
                    (path) => _cachePathBelongsToSource(
                      path,
                      row['path']?.toString() ?? '',
                    ),
                  ))
                    row,
              ];
      if (rows.isEmpty) {
        onProgress?.call(
          LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
        );
        return 0;
      }
      localChessLog.info(
        'Local database purge started',
        context: <String, Object?>{
          'databases': rows.length,
          'batchSize': effectiveBatchSize,
          'cleanupOrphanMetadata': cleanupOrphanMetadata,
          'checkpoint': checkpoint,
          'dedicatedConnection': dedicatedDb != null,
          'scoped': sourcePaths != null,
          if (sourcePaths != null) 'sourceCount': sourcePaths.length,
        },
      );
      // Never pre-count child rows for cosmetic percentages. Those COUNT(*)
      // scans were themselves multi-million-row foreground work when a
      // Chess.com replacement import supplied a progress callback.
      var completedDatabases = 0;
      String? lastProgressTable;

      void emitProgress(String message) {
        if (onProgress == null) return;
        final fraction =
            (completedDatabases / rows.length).clamp(0.0, 0.98).toDouble();
        onProgress(
          LocalChessScanProgress(fraction: fraction, message: message),
        );
      }

      emitProgress('Cleaning generated local cache...');
      var purged = 0;
      for (final row in rows) {
        cancellationToken?.throwIfCanceled();
        final databaseId = row['id']?.toString() ?? '';
        if (databaseId.isEmpty) continue;
        final perDatabase = Stopwatch()..start();
        try {
          final removed = await _purgeDeletedDatabaseCache(
            db,
            databaseId,
            batchSize: effectiveBatchSize,
            cancellationToken: cancellationToken,
            onBatchCompleted:
                (table, batchSize, affectedRows, elapsedMilliseconds) =>
                    _recordPurgeBatchDiagnostic(
                      slowDiagnostics,
                      table,
                      batchSize,
                      affectedRows,
                      elapsedMilliseconds,
                    ),
            onDeletedRows:
                onProgress == null
                    ? null
                    : (table, deletedRows) {
                      final tableLabel = _localChessPurgeTableLabel(table);
                      if (lastProgressTable != table) {
                        lastProgressTable = table;
                        emitProgress('Deleting $tableLabel...');
                      }
                    },
          );
          if (removed) purged += 1;
          completedDatabases += 1;
          emitProgress('Cleaning generated local cache...');
          if (checkpoint) {
            await _runLocalCacheWriteQueued(
              () => _checkpointLocalChessCacheBestEffort(db),
            );
          }
          perDatabase.stop();
          localChessLog.info(
            'Local database purge item finished',
            context: <String, Object?>{
              'removed': removed,
              'elapsedMs': perDatabase.elapsedMilliseconds,
            },
          );
        } catch (error, stackTrace) {
          perDatabase.stop();
          if (isOperationCanceled(error)) rethrow;
          localChessLog.error(
            'Local database purge item failed',
            error,
            stackTrace,
            tag: 'local_chess.purge_deleted_item',
            context: <String, Object?>{
              'elapsedMs': perDatabase.elapsedMilliseconds,
            },
          );
        }
      }
      if (purged > 0 && cleanupOrphanMetadata) {
        try {
          emitProgress('Cleaning local metadata...');
          await _deleteOrphanLocalMetadataInChunks(
            db,
            batchSize: effectiveBatchSize,
            cancellationToken: cancellationToken,
            onBatchCompleted:
                (table, batchSize, affectedRows, elapsedMilliseconds) =>
                    _recordPurgeBatchDiagnostic(
                      slowDiagnostics,
                      table,
                      batchSize,
                      affectedRows,
                      elapsedMilliseconds,
                    ),
          );
        } catch (error, stackTrace) {
          if (isOperationCanceled(error)) rethrow;
          localChessLog.error(
            'Local database orphan metadata purge failed',
            error,
            stackTrace,
            tag: 'local_chess.purge_orphans',
            context: <String, Object?>{'purgedDatabases': purged},
          );
        }
      }
      if (checkpoint) {
        await _runLocalCacheWriteQueued(
          () => _checkpointLocalChessCacheBestEffort(db),
        );
      }
      stopwatch.stop();
      localChessLog.info(
        'Local database purge finished',
        context: <String, Object?>{
          'purgedDatabases': purged,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      onProgress?.call(
        LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
      );
      _recordPurgeDiagnosticSummary(slowDiagnostics);
      return purged;
    } catch (error, stackTrace) {
      stopwatch.stop();
      if (isOperationCanceled(error)) {
        localChessLog.info(
          'Local database purge canceled',
          context: <String, Object?>{
            'batchSize': effectiveBatchSize,
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        );
        rethrow;
      }
      localChessLog.error(
        'Local database purge failed',
        error,
        stackTrace,
        tag: 'local_chess.purge_deleted',
        context: <String, Object?>{
          'batchSize': effectiveBatchSize,
          'cleanupOrphanMetadata': cleanupOrphanMetadata,
          'checkpoint': checkpoint,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    } finally {
      await dedicatedDb?.close();
    }
  }

  void scheduleDeletedCachePurge({
    String? sourcePath,
    int batchSize = _kCooperativePurgeBatchSize,
    bool cleanupOrphanMetadata = false,
    bool checkpoint = false,
  }) {
    final trimmedSourcePath = sourcePath?.trim();
    _backgroundPurgeQueue = _backgroundPurgeQueue
        .catchError((Object _) {})
        .then((_) async {
          localChessLog.info(
            'Local database background purge queued',
            context: <String, Object?>{
              'batchSize': batchSize,
              'cleanupOrphanMetadata': cleanupOrphanMetadata,
              'checkpoint': checkpoint,
              if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
                'sourceCount': 1,
            },
          );
          final purged = await _retryWhenSqliteBusy(
            operation: 'background purge deleted local source',
            context: <String, Object?>{
              'batchSize': batchSize,
              if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
                'sourceCount': 1,
            },
            action:
                () => purgeDeletedCaches(
                  sourcePath: trimmedSourcePath,
                  batchSize: batchSize,
                  cleanupOrphanMetadata: cleanupOrphanMetadata,
                  checkpoint: checkpoint,
                ),
          );
          localChessLog.info(
            'Local database background purge finished',
            context: <String, Object?>{
              'purgedDatabases': purged,
              if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
                'sourceCount': 1,
            },
          );
        });
    unawaited(
      _backgroundPurgeQueue.catchError((Object error, StackTrace stackTrace) {
        localChessLog.error(
          'Local database background purge failed',
          error,
          stackTrace,
          tag: 'local_chess.background_purge',
          context: <String, Object?>{
            if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
              'sourceCount': 1,
          },
        );
      }),
    );
  }

  static Future<T> _retryWhenSqliteBusy<T>({
    required String operation,
    required Future<T> Function() action,
    Map<String, Object?> context = const <String, Object?>{},
  }) async {
    for (var attempt = 0; ; attempt += 1) {
      try {
        return await action();
      } on Object catch (error, stackTrace) {
        final retryable = _isSqliteBusy(error);
        final exhausted = attempt >= _sqliteBusyRetryDelays.length;
        if (!retryable || exhausted) {
          if (retryable) {
            localChessLog.warning(
              'Local database busy retry exhausted',
              context: <String, Object?>{
                ...context,
                'operation': operation,
                'attempts': attempt + 1,
              },
              error: error,
              stackTrace: stackTrace,
              tag: 'local_chess.sqlite_busy_retry',
            );
          }
          rethrow;
        }
        final delay = _sqliteBusyRetryDelays[attempt];
        localChessLog.warning(
          'Local database busy; retrying',
          context: <String, Object?>{
            ...context,
            'operation': operation,
            'attempt': attempt + 1,
            'retryDelayMs': delay.inMilliseconds,
          },
          error: error,
          stackTrace: stackTrace,
          tag: 'local_chess.sqlite_busy_retry',
        );
        await Future<void>.delayed(delay);
      }
    }
  }

  static bool _isSqliteBusy(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('database table is locked') ||
        message.contains('database is busy') ||
        message.contains('sqlite_busy') ||
        message.contains('sqlite code: 5');
  }

  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    LocalChessScanProgressSink? onProgress,
  }) async {
    if (paths.isEmpty) return null;
    try {
      if (paths.length == 1) {
        return await _loadFreshSingleSource(
          paths.single,
          sourceLabel: sourceLabel,
          onProgress: onProgress,
        );
      }

      final children = <LocalChessNode>[];
      for (final path in paths) {
        final probe = await probeLocalChessPathInWorker(path);
        switch (probe.type) {
          case FileSystemEntityType.directory:
            final node = await _loadFreshDirectory(
              path,
              rootPath: path,
              force: true,
              onProgress: onProgress,
            );
            children.add(node);
          case FileSystemEntityType.file:
            final parent = p.dirname(path);
            final node = await _loadFreshFileNodeOrUnsupported(
              path,
              rootPath: parent,
              onProgress: onProgress,
            );
            if (node != null) children.add(node);
          case FileSystemEntityType.link:
          case FileSystemEntityType.notFound:
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
            throw const _LocalChessCacheMiss();
        }
      }
      if (children.isEmpty) return null;
      _sortNodes(children);
      final label = sourceLabel ?? localChessDatabaseDisplayNameForPaths(paths);
      final root = LocalChessFolderNode.fromChildren(
        name: label,
        path: 'local-batch:${_stableId(paths.join('|'))}',
        relativePath: '',
        children: children,
      );
      return LocalChessSource(
        id: _stableId(paths.join('|')),
        label: label,
        paths: paths,
        rootPath: root.path,
        scannedAt: DateTime.now(),
        root: root,
      );
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    try {
      return await _loadFreshFileNode(
        path,
        rootPath: rootPath,
        onProgress: onProgress,
      );
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<LocalChessGameQueryPage?> localDatabaseGamesPage({
    required String databasePath,
    String search = '',
    LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
    LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
    LocalChessGameFilter? filter,
    String? playerFideId,
    List<String> playerAliases = const <String>[],
    required int pageNumber,
    required int pageSize,
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;

    final where = StringBuffer('g.database_id = ?');
    final parameters = <Object?>[databaseId];
    _appendLocalGameSearch(where, parameters, search);
    final activeFilter = filter;
    if (activeFilter != null && activeFilter.hasActiveFilters) {
      appendLocalChessGameFilter(
        where,
        parameters,
        activeFilter,
        playerFideId: playerFideId,
        playerAliases: playerAliases,
      );
    }

    const fromClause = '''
      FROM $localChessGamesTable g
      LEFT JOIN $localChessPlayersTable wp ON wp.id = g.white_id
      LEFT JOIN $localChessPlayersTable bp ON bp.id = g.black_id
      LEFT JOIN $localChessEventsTable ev ON ev.id = g.event_id
      LEFT JOIN $localChessSitesTable st ON st.id = g.site_id
    ''';
    final totalRows = await db.select(
      'SELECT COUNT(*) AS count $fromClause WHERE $where',
      parameters,
    );
    final total = _readInt(totalRows.single['count']);
    final size = pageSize <= 0 ? 50 : pageSize;
    final page = pageNumber < 0 ? 0 : pageNumber;
    final rows = await db.select(
      '''
      SELECT ${_localChessGameProjection('g')}
      $fromClause
      WHERE $where
      ORDER BY ${_localDatabaseGamesOrderBy(sortBy, sortDirection)}
      LIMIT ? OFFSET ?
      ''',
      <Object?>[...parameters, size, page * size],
    );

    return LocalChessGameQueryPage(
      games: rows.map(_localGameFromRow).toList(growable: false),
      totalCount: total,
      pageNumber: page,
      pageSize: size,
    );
  }

  /// Fills missing `WhiteTitle`/`BlackTitle`/`WhiteFed`/`BlackFed` header
  /// tags from the global FIDE player table for every game in the database
  /// that carries a FIDE ID. Existing tags are never overwritten.
  ///
  /// Runs at most once per database (guarded by `player_enrichment_at_ms`,
  /// which game inserts reset); pass [force] to rescan regardless. Returns
  /// the number of games whose headers changed. If [resolve] throws, the
  /// marker stays unset so a later call retries.
  Future<int> enrichLocalDatabasePlayers({
    required String databasePath,
    required Future<Map<int, LocalPlayerEnrichment>> Function(Set<int> fideIds)
    resolve,
    bool force = false,
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT player_enrichment_at_ms
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return 0;
    if (!force && databaseRows.single['player_enrichment_at_ms'] != null) {
      return 0;
    }

    var updatedGames = 0;
    var lastId = '';
    while (true) {
      final rows = await db.select(
        '''
        SELECT id, headers_json
        FROM $localChessGamesTable
        WHERE database_id = ?
          AND id > ?
          AND headers_json LIKE '%FideId%'
        ORDER BY id
        LIMIT ?
        ''',
        <Object?>[databaseId, lastId, _kEnrichmentScanPageSize],
      );
      if (rows.isEmpty) break;
      lastId = rows.last['id']?.toString() ?? lastId;

      final pending = <({String id, Map<String, dynamic> metadata})>[];
      final fideIds = <int>{};
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        Map<String, dynamic> metadata;
        try {
          metadata = _jsonMap(row['headers_json']);
        } on FormatException {
          // One corrupt header bag must not wedge the whole pass into a
          // retry loop; skip the row and let the marker complete.
          continue;
        }
        var needsWork = false;
        for (final side in const <String>['White', 'Black']) {
          if (!_sideNeedsPlayerEnrichment(metadata, side)) continue;
          fideIds.add(localPgnFideId(metadata, side)!);
          needsWork = true;
        }
        if (needsWork) pending.add((id: id, metadata: metadata));
      }

      if (pending.isNotEmpty) {
        final resolved = await resolve(fideIds);
        final updates = <List<Object?>>[];
        for (final entry in pending) {
          final metadata = Map<String, dynamic>.of(entry.metadata);
          var changed = false;
          for (final side in const <String>['White', 'Black']) {
            final fideId = localPgnFideId(metadata, side);
            final player = fideId == null ? null : resolved[fideId];
            if (player == null) continue;
            final title = player.title?.trim() ?? '';
            if (title.isNotEmpty && localPgnTitle(metadata, side).isEmpty) {
              metadata['${side}Title'] = title;
              changed = true;
            }
            final federation = player.federation?.trim() ?? '';
            if (federation.isNotEmpty &&
                localPgnFederation(metadata, side).isEmpty) {
              metadata['${side}Fed'] = federation;
              changed = true;
            }
          }
          if (!changed) continue;
          updates.add(<Object?>[jsonEncode(metadata), databaseId, entry.id]);
        }
        if (updates.isNotEmpty) {
          await _lockedTransaction(db, (txn) async {
            await _executeBatchChunked(txn, '''
              UPDATE $localChessGamesTable
              SET headers_json = ?
              WHERE database_id = ? AND id = ?
              ''', updates);
          });
          updatedGames += updates.length;
        }
      }
      if (rows.length < _kEnrichmentScanPageSize) break;
    }

    await _lockedExecute(
      db,
      'UPDATE $localChessDatabasesTable SET player_enrichment_at_ms = ? '
      'WHERE id = ?',
      <Object?>[DateTime.now().millisecondsSinceEpoch, databaseId],
    );
    return updatedGames;
  }

  Future<Set<String>?> localDatabasePgnFingerprints({
    required String databasePath,
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;
    final rows = await db.select(
      '''
      SELECT pgn_hash
      FROM $localChessGamesTable
      WHERE database_id = ?
        AND pgn_hash IS NOT NULL
        AND pgn_hash <> ''
      ''',
      <Object?>[databaseId],
    );
    if (rows.isEmpty) return null;
    return rows
        .map((row) => row['pgn_hash']?.toString().trim() ?? '')
        .where((hash) => hash.isNotEmpty)
        .toSet();
  }

  Future<Set<String>?> localDatabaseMatchingPgnFingerprints({
    required String databasePath,
    required Iterable<String> fingerprints,
  }) async {
    final databaseId = _databaseId(databasePath);
    final candidates = fingerprints
        .map((hash) => hash.trim())
        .where((hash) => hash.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;
    if (candidates.isEmpty) return const <String>{};

    final existing = <String>{};
    for (final chunk in _chunks(candidates, 800)) {
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rows = await db.select(
        '''
        SELECT pgn_hash
        FROM $localChessGamesTable
        WHERE database_id = ?
          AND pgn_hash IN ($placeholders)
        ''',
        <Object?>[databaseId, ...chunk],
      );
      for (final row in rows) {
        final hash = row['pgn_hash']?.toString().trim();
        if (hash != null && hash.isNotEmpty) existing.add(hash);
      }
    }
    return existing;
  }

  Future<LocalChessDatabaseResultStats> localDatabaseResultStats({
    required String databasePath,
    required Iterable<String> playerAliases,
    String? playerFideId,
  }) {
    return resultStatsForDatabases(
      databasePaths: <String>[databasePath],
      playerAliases: playerAliases,
      playerFideId: playerFideId,
    );
  }

  /// Result stats over the union of several local databases, deduplicated by
  /// PGN fingerprint (`pgn_hash`).
  ///
  /// This is the single counting method behind both the per-source numbers
  /// (one path) and the "Combined" number (every source path) in the player
  /// workspace. Because each unique game is counted exactly once across the
  /// union, the Combined count always equals the number of distinct games —
  /// and for disjoint sources (Lichess vs Chess.com vs OTB, the common case)
  /// the per-source counts partition that set and sum to it. Games missing a
  /// hash fall back to their row id so hash-less rows are never collapsed.
  Future<LocalChessDatabaseResultStats> resultStatsForDatabases({
    required Iterable<String> databasePaths,
    required Iterable<String> playerAliases,
    String? playerFideId,
  }) async {
    final databaseIds = databasePaths
        .map(_databaseId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (databaseIds.isEmpty) {
      return const LocalChessDatabaseResultStats(
        gameCount: 0,
        winCount: 0,
        drawCount: 0,
        lossCount: 0,
      );
    }
    final aliases =
        playerAliases
            .map(_normalizePlayerAliasForStats)
            .where((name) => name.isNotEmpty)
            .toSet();
    final fideId = _normalizeFideIdForStats(playerFideId);
    final db = await _database();
    final placeholders = List.filled(databaseIds.length, '?').join(', ');
    final aliasList = aliases.toList(growable: false);
    final hasAliases = aliasList.isNotEmpty;
    final aliasPlaceholders = List.filled(aliasList.length, '?').join(', ');

    // Counting happens entirely in SQL so only four integers cross the isolate
    // boundary. The previous implementation `SELECT`ed every game row of the
    // target databases and deduplicated/classified them in a Dart loop on the
    // UI isolate — for prolific players' Combined databases (tens of thousands
    // of games) that pinned the main thread for seconds (App Hang) and could
    // exhaust the heap, because the Players workspace repairs stats for every
    // player on open. The predicates below mirror that classification exactly
    // (locked by the resultStatsForDatabases regression tests): FIDE id takes
    // priority, a present-but-different FIDE id excludes the row even when the
    // name matches, and names are normalized with the same stripping rule as
    // `_normalizePlayerAliasForStats`.
    final params = <Object?>[];
    final whiteName = _statsNameNormalizationSql('wp.name');
    final blackName = _statsNameNormalizationSql('bp.name');
    const whiteFide =
        "NULLIF(LOWER(TRIM(COALESCE("
        "json_extract(g.headers_json, '\$.WhiteFideId'), ''))), '')";
    const blackFide =
        "NULLIF(LOWER(TRIM(COALESCE("
        "json_extract(g.headers_json, '\$.BlackFideId'), ''))), '')";

    String sidePredicate({
      required String fideExpression,
      required String nameExpression,
      required bool matchesEverythingWhenUnfiltered,
    }) {
      if (fideId != null) {
        params.add(fideId);
        if (hasAliases) {
          params.addAll(aliasList);
          return 'COALESCE($fideExpression = ? OR ($fideExpression IS NULL '
              'AND $nameExpression IN ($aliasPlaceholders)), 0)';
        }
        return 'COALESCE($fideExpression = ?, 0)';
      }
      if (!hasAliases) {
        return matchesEverythingWhenUnfiltered ? '1' : '0';
      }
      params.addAll(aliasList);
      return 'COALESCE($nameExpression IN ($aliasPlaceholders), 0)';
    }

    final isWhite = sidePredicate(
      fideExpression: whiteFide,
      nameExpression: whiteName,
      matchesEverythingWhenUnfiltered: true,
    );
    final isBlack = sidePredicate(
      fideExpression: blackFide,
      nameExpression: blackName,
      matchesEverythingWhenUnfiltered: false,
    );
    params.addAll(databaseIds);

    // Innermost: one row per game with the player-side flags and dedup key.
    // Middle: keep only the player's games, collapse duplicates (same
    // fingerprint across sources) via GROUP BY. Then classify each distinct
    // game once (draw wins ties over win/loss, matching the old precedence) and
    // sum. COALESCE keeps the flags 0 instead of NULL when a FIDE compare is
    // against a NULL id.
    final rows = await db.select('''
      SELECT
        COUNT(*) AS games,
        COALESCE(SUM(CASE WHEN outcome = 'w' THEN 1 ELSE 0 END), 0) AS wins,
        COALESCE(SUM(CASE WHEN outcome = 'd' THEN 1 ELSE 0 END), 0) AS draws,
        COALESCE(SUM(CASE WHEN outcome = 'l' THEN 1 ELSE 0 END), 0) AS losses
      FROM (
        SELECT
          CASE
            WHEN res IN ('1/2-1/2', '1/2', '½-½') THEN 'd'
            WHEN (res = '1-0' AND iw = 1) OR (res = '0-1' AND ib = 1) THEN 'w'
            WHEN (res = '0-1' AND iw = 1) OR (res = '1-0' AND ib = 1) THEN 'l'
            ELSE 'o'
          END AS outcome
        FROM (
          SELECT MAX(iw) AS iw, MAX(ib) AS ib, MIN(res) AS res
          FROM (
            SELECT
              CASE
                WHEN TRIM(COALESCE(g.pgn_hash, '')) = ''
                  THEN 'id:' || CAST(g.id AS TEXT)
                ELSE 'hash:' || TRIM(g.pgn_hash)
              END AS dedup_key,
              $isWhite AS iw,
              $isBlack AS ib,
              TRIM(COALESCE(g.result, '')) AS res
            FROM $localChessGamesTable g
            INNER JOIN $localChessDatabasesTable d ON d.id = g.database_id
            LEFT JOIN $localChessPlayersTable wp ON wp.id = g.white_id
            LEFT JOIN $localChessPlayersTable bp ON bp.id = g.black_id
            WHERE g.database_id IN ($placeholders)
              AND d.deleted_at_ms IS NULL
          )
          WHERE iw = 1 OR ib = 1
          GROUP BY dedup_key
        )
      )
      ''', params);

    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return LocalChessDatabaseResultStats(
      gameCount: _readInt(row['games']),
      winCount: _readInt(row['wins']),
      drawCount: _readInt(row['draws']),
      lossCount: _readInt(row['losses']),
    );
  }

  Future<DateTime?> latestLocalGameDate({required String databasePath}) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final rows = await db.select(
      '''
      SELECT g.date
      FROM $localChessGamesTable g
      INNER JOIN $localChessDatabasesTable d ON d.id = g.database_id
      WHERE g.database_id = ?
        AND d.deleted_at_ms IS NULL
        AND TRIM(COALESCE(g.date, '')) NOT IN ('', '?', '-')
      ORDER BY REPLACE(TRIM(g.date), '.', '-') DESC
      LIMIT 256
      ''',
      <Object?>[databaseId],
    );
    for (final row in rows) {
      final date = _dateFromLocalDate(row['date']);
      if (date != null) return date;
    }
    return null;
  }

  Future<bool> persistAppendedPgnGames({
    required String databasePath,
    required List<LocalChessAppendedPgn> appendedPgns,
  }) async {
    _throwIfCacheSourceDeletionInProgress(databasePath);
    if (appendedPgns.isEmpty) return false;
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT label
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return false;

    final existingCountRows = await db.select(
      '''
      SELECT
        COALESCE(MAX(file_game_count), 0) AS file_game_count,
        COALESCE(MAX(index_in_file), -1) AS max_index
      FROM $localChessGamesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final existingFileGameCount = _readInt(
      existingCountRows.single['file_game_count'],
    );
    final maxIndex = _readInt(existingCountRows.single['max_index']);
    final startIndex =
        existingFileGameCount > maxIndex ? existingFileGameCount : maxIndex + 1;
    final nextFileGameCount = startIndex + appendedPgns.length;

    final relativeRows = await db.select(
      '''
      SELECT source_relative_path
      FROM $localChessGamesTable
      WHERE database_id = ?
      ORDER BY index_in_file ASC
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    final rootPath =
        relativeRows.isEmpty
            ? p.dirname(databasePath)
            : _rootPathFromRelativePath(
              databasePath,
              relativeRows.single['source_relative_path']?.toString(),
            );

    final games = <LocalChessGame>[];
    final treeInputs = <LocalOpeningTreeGameInput>[];
    for (var i = 0; i < appendedPgns.length; i++) {
      final chunk = appendedPgns[i];
      final indexInFile = startIndex + i;
      final game = localChessGameFromRawPgnChunk(
        rawPgn: chunk.rawPgn,
        sourcePath: databasePath,
        rootPath: rootPath,
        indexInFile: indexInFile,
        fileGameCount: nextFileGameCount,
        sourceByteStart: chunk.sourceByteStart,
        sourceByteEnd: chunk.sourceByteEnd,
      );
      if (game == null) continue;
      games.add(game);
      treeInputs.add(
        LocalOpeningTreeGameInput(
          id: game.id,
          rawPgn: chunk.rawPgn,
          sourcePath: databasePath,
          sourceRelativePath: game.sourceRelativePath,
          fileName: game.fileName,
          indexInFile: indexInFile,
          fileGameCount: nextFileGameCount,
          sourceByteStart: chunk.sourceByteStart,
          sourceByteEnd: chunk.sourceByteEnd,
        ),
      );
    }
    if (games.isEmpty) return false;

    final treeMaxPly = await _currentTreeMaxPly(db, databaseId);
    final buildResult = await buildLocalOpeningTreeIndexWithDiagnosticsAsync(
      treeId: 'local:${_stableId(databaseId)}:append',
      databaseId: databaseId,
      maxPly: treeMaxPly,
      includePositionGameRefs: true,
      games: treeInputs,
    );
    final index = buildResult.index;
    final stat = await File(databasePath).stat();
    final now = DateTime.now().millisecondsSinceEpoch;

    await _lockedTransaction(db, (txn) async {
      final updateOpeningTree = await _transactionHasUsableOpeningTreeMetadata(
        txn,
        databaseId,
      );
      final playerNames = <String>{};
      final eventNames = <String>{};
      final siteNames = <String>{};
      for (final game in games) {
        final treeRow = index.gameRowsById[game.id];
        _addNormalizedName(
          playerNames,
          game.game.metadata['White'] ?? treeRow?['white'],
        );
        _addNormalizedName(
          playerNames,
          game.game.metadata['Black'] ?? treeRow?['black'],
        );
        _addNormalizedName(
          eventNames,
          game.game.metadata['Event'] ?? treeRow?['event'],
        );
        _addNormalizedName(
          siteNames,
          game.game.metadata['Site'] ?? treeRow?['site'],
        );
      }

      final playerIds = await _idsForNames(
        txn,
        localChessPlayersTable,
        playerNames,
      );
      final eventIds = await _idsForNames(
        txn,
        localChessEventsTable,
        eventNames,
      );
      final siteIds = await _idsForNames(txn, localChessSitesTable, siteNames);

      await _insertGameRows(
        txn,
        databaseId,
        games,
        index.gameRowsById,
        playerIds: playerIds,
        eventIds: eventIds,
        siteIds: siteIds,
      );
      if (updateOpeningTree) {
        await _upsertTreeDelta(txn, databaseId, index);
        await _insertPositionGameRefs(txn, databaseId, index, <String>{
          for (final game in games) game.id,
        });
      }
      await txn.execute(
        '''
        UPDATE $localChessGamesTable
        SET file_game_count = ?
        WHERE database_id = ?
        ''',
        <Object?>[nextFileGameCount, databaseId],
      );
      var nextPositionCount = 0;
      if (updateOpeningTree) {
        final positionCountRows = await txn.select(
          '''
          SELECT COUNT(*) AS count
          FROM $localChessTreeNodesTable
          WHERE database_id = ?
          ''',
          <Object?>[databaseId],
        );
        nextPositionCount = _readInt(positionCountRows.single['count']);
      }
      await txn.execute(
        '''
        UPDATE $localChessDatabasesTable
        SET
          size_bytes = ?,
          modified_at_ms = ?,
          game_count = game_count + ?,
          position_count = ?,
          tree_snapshot = NULL,
          tree_max_ply = ?,
          updated_at_ms = ?
        WHERE id = ? AND deleted_at_ms IS NULL
        ''',
        <Object?>[
          stat.size,
          stat.modified.millisecondsSinceEpoch,
          games.length,
          nextPositionCount,
          updateOpeningTree ? treeMaxPly : null,
          now,
          databaseId,
        ],
      );
    });

    return true;
  }

  Future<bool?> replaceLocalPgnGame({
    required String databasePath,
    required int indexInFile,
    required String rawPgn,
  }) async {
    final replacementRawPgn = rawPgn.trim();
    if (indexInFile < 0 || replacementRawPgn.isEmpty) return false;

    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT size_bytes, modified_at_ms
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;

    final file = File(databasePath);
    if (!await file.exists()) return null;
    final currentStat = await file.stat();
    final databaseRow = databaseRows.single;
    if (_readInt(databaseRow['size_bytes']) != currentStat.size ||
        _readNullableInt(databaseRow['modified_at_ms']) !=
            currentStat.modified.millisecondsSinceEpoch) {
      return null;
    }

    final rows = await db.select(
      '''
      SELECT ${_localChessGameProjection('g')}
      FROM $localChessGamesTable g
      WHERE g.database_id = ?
      ORDER BY g.index_in_file ASC
      ''',
      <Object?>[databaseId],
    );
    if (rows.isEmpty) return null;

    Map<String, Object?>? targetRow;
    var targetOrdinal = -1;
    for (final (ordinal, row) in rows.indexed) {
      if (_readInt(row['index_in_file']) == indexInFile) {
        targetRow = row;
        targetOrdinal = ordinal;
        break;
      }
    }
    if (targetRow == null) return false;

    final targetId = targetRow['id'] as String;
    final replacementFingerprint = localChessPgnFingerprint(replacementRawPgn);
    final duplicateRows = await db.select(
      '''
      SELECT 1
      FROM $localChessGamesTable
      WHERE database_id = ?
        AND pgn_hash = ?
        AND id <> ?
      LIMIT 1
      ''',
      <Object?>[databaseId, replacementFingerprint, targetId],
    );
    if (duplicateRows.isNotEmpty) return false;

    final oldRawPgn = _rawPgnForRow(targetRow).trim();
    if (oldRawPgn.isEmpty) return null;

    final fileGameCount = rows.length;
    final oldInput = LocalOpeningTreeGameInput(
      id: targetId,
      rawPgn: oldRawPgn,
      sourcePath: databasePath,
      sourceRelativePath: targetRow['source_relative_path'] as String,
      fileName: targetRow['file_name'] as String,
      indexInFile: targetOrdinal,
      fileGameCount: fileGameCount,
      sourceByteStart: _readNullableInt(targetRow['source_byte_start']),
      sourceByteEnd: _readNullableInt(targetRow['source_byte_end']),
    );
    final newInput = LocalOpeningTreeGameInput(
      id: targetId,
      rawPgn: replacementRawPgn,
      sourcePath: databasePath,
      sourceRelativePath: targetRow['source_relative_path'] as String,
      fileName: targetRow['file_name'] as String,
      indexInFile: targetOrdinal,
      fileGameCount: fileGameCount,
    );

    final treeMaxPly = await _currentTreeMaxPly(db, databaseId);
    final oldDelta = await buildLocalOpeningTreeIndexWithDiagnosticsAsync(
      treeId: 'local:${_stableId(databaseId)}:replace-old',
      databaseId: databaseId,
      maxPly: treeMaxPly,
      includePositionGameRefs: true,
      games: <LocalOpeningTreeGameInput>[oldInput],
    );
    if (oldDelta.skippedGames.isNotEmpty) return null;
    final newDelta = await buildLocalOpeningTreeIndexWithDiagnosticsAsync(
      treeId: 'local:${_stableId(databaseId)}:replace-new',
      databaseId: databaseId,
      maxPly: treeMaxPly,
      includePositionGameRefs: true,
      games: <LocalOpeningTreeGameInput>[newInput],
    );
    if (newDelta.skippedGames.isNotEmpty) return false;

    final rootPath = _rootPathFromRelativePath(
      databasePath,
      targetRow['source_relative_path']?.toString(),
    );
    final parsedReplacement = localChessGameFromRawPgnChunk(
      rawPgn: replacementRawPgn,
      sourcePath: databasePath,
      rootPath: rootPath,
      indexInFile: targetOrdinal,
      fileGameCount: fileGameCount,
    );
    if (parsedReplacement == null) return false;

    final rewriteRows = <Map<String, Object?>>[
      for (final (ordinal, row) in rows.indexed)
        ordinal == targetOrdinal
            ? <String, Object?>{
              ...row,
              'raw_pgn': replacementRawPgn,
              'pgn_hash': replacementFingerprint,
              'source_byte_start': null,
              'source_byte_end': null,
            }
            : row,
    ];
    final rewrite = await _rewritePgnFileFromCachedRows(
      databasePath,
      rewriteRows,
    );
    if (rewrite == null) return null;

    final targetSpan = rewrite.spans.firstWhere(
      (span) => span.gameId == targetId,
    );
    final replacementWithSpan = _localChessGameWithIdentity(
      localChessGameFromRawPgnChunk(
        rawPgn: replacementRawPgn,
        sourcePath: databasePath,
        rootPath: rootPath,
        indexInFile: targetOrdinal,
        fileGameCount: fileGameCount,
        sourceByteStart: targetSpan.start,
        sourceByteEnd: targetSpan.end,
      )!,
      targetId,
    );
    final nextStat = await file.stat();
    final now = DateTime.now().millisecondsSinceEpoch;

    await _lockedTransaction(db, (txn) async {
      final updateOpeningTree = await _transactionHasUsableOpeningTreeMetadata(
        txn,
        databaseId,
      );
      await txn.execute(
        'DELETE FROM $localChessPositionGamesTable WHERE database_id = ? AND game_id = ?',
        <Object?>[databaseId, targetId],
      );
      await txn.execute(
        'DELETE FROM $localChessGameAnalysisTable WHERE game_id = ?',
        <Object?>[targetId],
      );
      await txn.execute(
        'DELETE FROM $localChessGamesTable WHERE database_id = ? AND id = ?',
        <Object?>[databaseId, targetId],
      );
      if (updateOpeningTree) {
        await _subtractTreeDelta(txn, databaseId, oldDelta.index);
        await _deleteUnreferencedTreeNodes(txn, databaseId);
      }

      final treeRow = newDelta.index.gameRowsById[targetId];
      final playerNames = <String>{};
      final eventNames = <String>{};
      final siteNames = <String>{};
      _addNormalizedName(
        playerNames,
        replacementWithSpan.game.metadata['White'] ?? treeRow?['white'],
      );
      _addNormalizedName(
        playerNames,
        replacementWithSpan.game.metadata['Black'] ?? treeRow?['black'],
      );
      _addNormalizedName(
        eventNames,
        replacementWithSpan.game.metadata['Event'] ?? treeRow?['event'],
      );
      _addNormalizedName(
        siteNames,
        replacementWithSpan.game.metadata['Site'] ?? treeRow?['site'],
      );
      final playerIds = await _idsForNames(
        txn,
        localChessPlayersTable,
        playerNames,
      );
      final eventIds = await _idsForNames(
        txn,
        localChessEventsTable,
        eventNames,
      );
      final siteIds = await _idsForNames(txn, localChessSitesTable, siteNames);
      await _insertGameRows(
        txn,
        databaseId,
        <LocalChessGame>[replacementWithSpan],
        newDelta.index.gameRowsById,
        playerIds: playerIds,
        eventIds: eventIds,
        siteIds: siteIds,
      );
      if (updateOpeningTree) {
        await _upsertTreeDelta(txn, databaseId, newDelta.index);
        await _insertPositionGameRefs(txn, databaseId, newDelta.index, <String>{
          targetId,
        });
      }
      await _executeBatchChunked(
        txn,
        '''
        UPDATE $localChessGamesTable
        SET
          file_game_count = ?,
          index_in_file = ?,
          source_byte_start = ?,
          source_byte_end = ?
        WHERE database_id = ? AND id = ?
        ''',
        <List<Object?>>[
          for (final (ordinal, span) in rewrite.spans.indexed)
            <Object?>[
              fileGameCount,
              ordinal,
              span.start,
              span.end,
              databaseId,
              span.gameId,
            ],
        ],
      );
      var nextPositionCount = 0;
      if (updateOpeningTree) {
        final positionCountRows = await txn.select(
          '''
          SELECT COUNT(*) AS count
          FROM $localChessTreeNodesTable
          WHERE database_id = ?
          ''',
          <Object?>[databaseId],
        );
        nextPositionCount = _readInt(positionCountRows.single['count']);
      }
      await txn.execute(
        '''
        UPDATE $localChessDatabasesTable
        SET
          size_bytes = ?,
          modified_at_ms = ?,
          game_count = ?,
          position_count = ?,
          tree_snapshot = NULL,
          tree_max_ply = ?,
          updated_at_ms = ?
        WHERE id = ? AND deleted_at_ms IS NULL
        ''',
        <Object?>[
          nextStat.size,
          nextStat.modified.millisecondsSinceEpoch,
          fileGameCount,
          nextPositionCount,
          updateOpeningTree ? treeMaxPly : null,
          now,
          databaseId,
        ],
      );
    });

    return true;
  }

  Future<int?> removeLocalPgnGames({
    required String databasePath,
    required Set<int> indexesInFile,
  }) async {
    if (indexesInFile.isEmpty) return 0;
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;

    final rows = await db.select(
      '''
      SELECT ${_localChessGameProjection('g')}
      FROM $localChessGamesTable g
      WHERE g.database_id = ?
      ORDER BY g.index_in_file ASC
      ''',
      <Object?>[databaseId],
    );
    if (rows.isEmpty) return null;

    final deletedRows = <Map<String, Object?>>[];
    final keptRows = <Map<String, Object?>>[];
    for (final row in rows) {
      if (indexesInFile.contains(_readInt(row['index_in_file']))) {
        deletedRows.add(row);
      } else {
        keptRows.add(row);
      }
    }
    if (deletedRows.isEmpty) return 0;

    final deletedInputs = <LocalOpeningTreeGameInput>[];
    for (final row in deletedRows) {
      final rawPgn = _rawPgnForRow(row).trim();
      if (rawPgn.isEmpty) return null;
      deletedInputs.add(
        LocalOpeningTreeGameInput(
          id: row['id'] as String,
          rawPgn: rawPgn,
          sourcePath: databasePath,
          sourceRelativePath: row['source_relative_path'] as String,
          fileName: row['file_name'] as String,
          indexInFile: _readInt(row['index_in_file']),
          fileGameCount: _readInt(row['file_game_count']),
          sourceByteStart: _readNullableInt(row['source_byte_start']),
          sourceByteEnd: _readNullableInt(row['source_byte_end']),
        ),
      );
    }
    final treeMaxPly = await _currentTreeMaxPly(db, databaseId);
    final deleteDelta = await buildLocalOpeningTreeIndexWithDiagnosticsAsync(
      treeId: 'local:${_stableId(databaseId)}:delete',
      databaseId: databaseId,
      maxPly: treeMaxPly,
      includePositionGameRefs: true,
      games: deletedInputs,
    );
    if (deleteDelta.skippedGames.isNotEmpty) return null;

    final rewrite = await _rewritePgnFileFromCachedRows(databasePath, keptRows);
    if (rewrite == null) return null;
    final stat = await File(databasePath).stat();
    final now = DateTime.now().millisecondsSinceEpoch;
    final deletedIds = <String>{
      for (final row in deletedRows) row['id'] as String,
    };

    await _lockedTransaction(db, (txn) async {
      if (keptRows.isEmpty) {
        await _deleteFileCache(txn, databasePath);
        return;
      }
      final updateOpeningTree = await _transactionHasUsableOpeningTreeMetadata(
        txn,
        databaseId,
      );

      await _executeBatchChunked(
        txn,
        'DELETE FROM $localChessPositionGamesTable WHERE database_id = ? AND game_id = ?',
        <List<Object?>>[
          for (final id in deletedIds) <Object?>[databaseId, id],
        ],
      );
      await _executeBatchChunked(
        txn,
        'DELETE FROM $localChessGameAnalysisTable WHERE game_id = ?',
        <List<Object?>>[
          for (final id in deletedIds) <Object?>[id],
        ],
      );
      await _executeBatchChunked(
        txn,
        'DELETE FROM $localChessGamesTable WHERE database_id = ? AND id = ?',
        <List<Object?>>[
          for (final id in deletedIds) <Object?>[databaseId, id],
        ],
      );
      if (updateOpeningTree) {
        await _subtractTreeDelta(txn, databaseId, deleteDelta.index);
        await _deleteUnreferencedTreeNodes(txn, databaseId);
      }
      await _executeBatchChunked(
        txn,
        '''
        UPDATE $localChessGamesTable
        SET
          file_game_count = ?,
          index_in_file = ?,
          source_byte_start = ?,
          source_byte_end = ?
        WHERE database_id = ? AND id = ?
        ''',
        <List<Object?>>[
          for (final (ordinal, span) in rewrite.spans.indexed)
            <Object?>[
              keptRows.length,
              ordinal,
              span.start,
              span.end,
              databaseId,
              span.gameId,
            ],
        ],
      );
      var nextPositionCount = 0;
      if (updateOpeningTree) {
        final positionCountRows = await txn.select(
          '''
          SELECT COUNT(*) AS count
          FROM $localChessTreeNodesTable
          WHERE database_id = ?
          ''',
          <Object?>[databaseId],
        );
        nextPositionCount = _readInt(positionCountRows.single['count']);
      }
      await txn.execute(
        '''
        UPDATE $localChessDatabasesTable
        SET
          size_bytes = ?,
          modified_at_ms = ?,
          game_count = ?,
          position_count = ?,
          tree_snapshot = NULL,
          tree_max_ply = ?,
          updated_at_ms = ?
        WHERE id = ? AND deleted_at_ms IS NULL
        ''',
        <Object?>[
          stat.size,
          stat.modified.millisecondsSinceEpoch,
          keptRows.length,
          nextPositionCount,
          updateOpeningTree ? treeMaxPly : null,
          now,
          databaseId,
        ],
      );
    });

    return deletedRows.length;
  }

  Future<List<MoveAggregate>> localMoveAggregatesForFen({
    required String databasePath,
    required String fen,
    List<String> moves = const <String>[],
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final hasUsableTree = await _databaseHasUsableOpeningTreeMetadata(
      db,
      databaseId,
    );
    if (!hasUsableTree) {
      return _localMoveAggregatesForMovePrefix(
        db,
        databaseId: databaseId,
        moves: moves,
        filters: filters,
      );
    }
    if (!filters.hasFilters) {
      return _localTreeMoveAggregatesForFen(
        db,
        databaseId: databaseId,
        fen: fen,
      );
    }

    final availableRefRows = await db.select(
      'SELECT 1 FROM $localChessPositionGamesTable WHERE database_id = ? LIMIT 1',
      <Object?>[databaseId],
    );
    if (availableRefRows.isEmpty) {
      return _localMoveAggregatesForMovePrefix(
        db,
        databaseId: databaseId,
        moves: moves,
        filters: filters,
      );
    }

    final where = StringBuffer('pg.database_id = ? AND pg.fen_key = ?');
    final parameters = <Object?>[databaseId, playerOpeningTreeFenKey(fen)];
    _appendLocalPositionFilters(where, parameters, filters);
    final rows = await db.select('''
      SELECT
        next_uci AS uci,
        SUM(CASE WHEN result = '1-0' THEN 1 ELSE 0 END) AS white,
        SUM(CASE WHEN result = '0-1' THEN 1 ELSE 0 END) AS black,
        SUM(
          CASE
            WHEN COALESCE(result, '') NOT IN ('1-0', '0-1') THEN 1
            ELSE 0
          END
        ) AS draws,
        COUNT(*) AS total,
        CASE WHEN COUNT(*) = 1 THEN MAX(game_id) ELSE NULL END AS game_id,
        MAX(date_key) AS last_played
      FROM (
        SELECT
          pg.next_uci AS next_uci,
          g.result AS result,
          g.id AS game_id,
          NULLIF(REPLACE(COALESCE(g.date, ''), '.', '-'), '') AS date_key
        FROM $localChessPositionGamesTable pg
        JOIN $localChessGamesTable g
          ON g.database_id = pg.database_id AND g.id = pg.game_id
        WHERE $where
      )
      WHERE next_uci IS NOT NULL AND next_uci <> ''
      GROUP BY next_uci
      ORDER BY total DESC, next_uci ASC
      ''', parameters);

    return List<MoveAggregate>.unmodifiable(
      rows
          .map((row) {
            return MoveAggregate(
              uci: row['uci']?.toString().trim().toLowerCase() ?? '',
              white: _readInt(row['white']),
              black: _readInt(row['black']),
              draws: _readInt(row['draws']),
              total: _readInt(row['total']),
              gameId: row['game_id']?.toString(),
              lastPlayed: _dateFromLocalDate(row['last_played']),
            );
          })
          .where((move) => move.uci.isNotEmpty && move.total > 0),
    );
  }

  Future<List<MoveAggregate>> _localMoveAggregatesForMovePrefix(
    resqlite.Database db, {
    required String databaseId,
    required List<String> moves,
    required PlayerOpeningTreeFilterCriteria filters,
  }) async {
    final prefix = moves
        .map((move) => move.trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
    final where = StringBuffer('g.database_id = ?');
    final parameters = <Object?>[databaseId];
    _appendLocalMovePrefixFilter(where, parameters, prefix);
    _appendLocalPositionFilters(where, parameters, filters);

    final nextMoveExpression =
        "LOWER(TRIM(CAST(json_extract(g.moves, '\$[${prefix.length}]') AS TEXT)))";
    final rows = await db.select('''
      SELECT
        next_uci AS uci,
        SUM(CASE WHEN result = '1-0' THEN 1 ELSE 0 END) AS white,
        SUM(CASE WHEN result = '0-1' THEN 1 ELSE 0 END) AS black,
        SUM(
          CASE
            WHEN COALESCE(result, '') NOT IN ('1-0', '0-1') THEN 1
            ELSE 0
          END
        ) AS draws,
        COUNT(*) AS total,
        CASE WHEN COUNT(*) = 1 THEN MAX(game_id) ELSE NULL END AS game_id,
        MAX(date_key) AS last_played
      FROM (
        SELECT
          $nextMoveExpression AS next_uci,
          g.result AS result,
          g.id AS game_id,
          NULLIF(REPLACE(COALESCE(g.date, ''), '.', '-'), '') AS date_key
        FROM $localChessGamesTable g
        WHERE $where
      )
      WHERE next_uci IS NOT NULL AND next_uci <> ''
      GROUP BY next_uci
      ORDER BY total DESC, next_uci ASC
      ''', parameters);

    return List<MoveAggregate>.unmodifiable(
      rows
          .map((row) {
            return MoveAggregate(
              uci: row['uci']?.toString().trim().toLowerCase() ?? '',
              white: _readInt(row['white']),
              black: _readInt(row['black']),
              draws: _readInt(row['draws']),
              total: _readInt(row['total']),
              gameId: row['game_id']?.toString(),
              lastPlayed: _dateFromLocalDate(row['last_played']),
            );
          })
          .where((move) => move.uci.isNotEmpty && move.total > 0),
    );
  }

  Future<List<MoveAggregate>> _localTreeMoveAggregatesForFen(
    resqlite.Database db, {
    required String databaseId,
    required String fen,
  }) async {
    final rows = await db.select(
      '''
      SELECT
        tm.uci,
        tm.white,
        tm.black,
        tm.draws,
        tm.total,
        tm.sample_game_id,
        tm.last_played_ms
      FROM $localChessTreeNodesTable tn
      JOIN $localChessTreeMovesTable tm
        ON tm.database_id = tn.database_id
       AND tm.node_id = tn.node_id
      WHERE tn.database_id = ?
        AND tn.fen_key = ?
        AND tm.uci IS NOT NULL
        AND tm.uci <> ''
        AND tm.total > 0
      ORDER BY tm.total DESC, tm.uci ASC
      ''',
      <Object?>[databaseId, playerOpeningTreeFenKey(fen)],
    );

    return List<MoveAggregate>.unmodifiable(
      rows
          .map((row) {
            return MoveAggregate(
              uci: row['uci']?.toString().trim().toLowerCase() ?? '',
              white: _readInt(row['white']),
              black: _readInt(row['black']),
              draws: _readInt(row['draws']),
              total: _readInt(row['total']),
              gameId: row['sample_game_id']?.toString(),
              lastPlayed: _dateFromMillis(row['last_played_ms']),
            );
          })
          .where((move) => move.uci.isNotEmpty && move.total > 0),
    );
  }

  Future<GamebaseSearchQueryResponse?> localPositionGamesResponse({
    required String databasePath,
    required String fen,
    List<String> moves = const <String>[],
    String? uci,
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
    required GamebaseSortField sortBy,
    required GamebaseSortDirection sortDirection,
    required int pageNumber,
    required int pageSize,
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    final databaseRows = await db.select(
      '''
      SELECT position_count, tree_max_ply
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;
    final databaseRow = databaseRows.single;
    if (!_localChessTreeMetadataIsUsable(
      positionCount: _readInt(databaseRow['position_count']),
      maxPly: _readNullableInt(databaseRow['tree_max_ply']),
    )) {
      return _localPositionGamesResponseFromMovePrefix(
        db,
        databaseId: databaseId,
        fen: fen,
        moves: moves,
        uci: uci,
        filters: filters,
        sortBy: sortBy,
        sortDirection: sortDirection,
        pageNumber: pageNumber,
        pageSize: pageSize,
      );
    }

    final availableRefRows = await db.select(
      'SELECT 1 FROM $localChessPositionGamesTable WHERE database_id = ? LIMIT 1',
      <Object?>[databaseId],
    );
    if (availableRefRows.isEmpty) {
      return _localPositionGamesResponseFromMovePrefix(
        db,
        databaseId: databaseId,
        fen: fen,
        moves: moves,
        uci: uci,
        filters: filters,
        sortBy: sortBy,
        sortDirection: sortDirection,
        pageNumber: pageNumber,
        pageSize: pageSize,
      );
    }

    final fenKey = playerOpeningTreeFenKey(fen);
    final where = StringBuffer('pg.database_id = ? AND pg.fen_key = ?');
    final parameters = <Object?>[databaseId, fenKey];

    final pinnedUci = uci?.trim().toLowerCase();
    if (pinnedUci != null && pinnedUci.isNotEmpty) {
      where.write(' AND pg.next_uci = ?');
      parameters.add(pinnedUci);
    }

    _appendLocalPositionFilters(where, parameters, filters);

    const fromClause = '''
      FROM $localChessPositionGamesTable pg
      JOIN $localChessGamesTable g
        ON g.database_id = pg.database_id AND g.id = pg.game_id
      LEFT JOIN $localChessPlayersTable wp ON wp.id = g.white_id
      LEFT JOIN $localChessPlayersTable bp ON bp.id = g.black_id
      LEFT JOIN $localChessEventsTable ev ON ev.id = g.event_id
      LEFT JOIN $localChessSitesTable st ON st.id = g.site_id
    ''';
    final total = await _localPositionGamesTotalCount(
      db,
      databaseId: databaseId,
      fenKey: fenKey,
      pinnedUci: pinnedUci,
      filters: filters,
      joinedFromClause: fromClause,
      joinedWhere: where.toString(),
      joinedParameters: parameters,
    );
    if (total == 0 && moves.isNotEmpty) {
      return _localPositionGamesResponseFromMovePrefix(
        db,
        databaseId: databaseId,
        fen: fen,
        moves: moves,
        uci: uci,
        filters: filters,
        sortBy: sortBy,
        sortDirection: sortDirection,
        pageNumber: pageNumber,
        pageSize: pageSize,
      );
    }
    final size = pageSize <= 0 ? 20 : pageSize;
    final page = pageNumber < 0 ? 0 : pageNumber;
    final direction =
        sortDirection == GamebaseSortDirection.asc ? 'ASC' : 'DESC';
    final sortExpression = _localPositionGamesSortExpression(sortBy);
    final rows = await db.select(
      '''
      SELECT
        pg.fen AS position_fen,
        pg.ply AS ref_ply,
        g.*
      $fromClause
      WHERE $where
      ORDER BY $sortExpression $direction, g.index_in_file ASC
      LIMIT ? OFFSET ?
      ''',
      <Object?>[...parameters, size, page * size],
    );

    return GamebaseSearchQueryResponse(
      status: 'success',
      data: rows.map(_positionGameRowFromDb).toList(growable: false),
      metadata: GamebasePaginationMetadata(
        pageNumber: page,
        pageSize: size,
        totalCount: total,
        hasMoreValue: (page + 1) * size < total,
      ),
    );
  }

  Future<GamebaseSearchQueryResponse> _localPositionGamesResponseFromMovePrefix(
    resqlite.Database db, {
    required String databaseId,
    required String fen,
    required List<String> moves,
    required String? uci,
    required PlayerOpeningTreeFilterCriteria filters,
    required GamebaseSortField sortBy,
    required GamebaseSortDirection sortDirection,
    required int pageNumber,
    required int pageSize,
  }) async {
    final prefix = moves
        .map((move) => move.trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
    final where = StringBuffer('g.database_id = ?');
    final parameters = <Object?>[databaseId];
    _appendLocalMovePrefixFilter(where, parameters, prefix);
    final pinnedUci = uci?.trim().toLowerCase();
    if (pinnedUci != null && pinnedUci.isNotEmpty) {
      where.write(
        " AND LOWER(TRIM(CAST(json_extract(g.moves, '\$[${prefix.length}]') AS TEXT))) = ?",
      );
      parameters.add(pinnedUci);
    }
    _appendLocalPositionFilters(where, parameters, filters);

    const fromClause = '''
      FROM $localChessGamesTable g
      LEFT JOIN $localChessPlayersTable wp ON wp.id = g.white_id
      LEFT JOIN $localChessPlayersTable bp ON bp.id = g.black_id
      LEFT JOIN $localChessEventsTable ev ON ev.id = g.event_id
      LEFT JOIN $localChessSitesTable st ON st.id = g.site_id
    ''';
    final totalRows = await db.select(
      'SELECT COUNT(*) AS count $fromClause WHERE $where',
      parameters,
    );
    final total = _readInt(totalRows.single['count']);
    final size = pageSize <= 0 ? 20 : pageSize;
    final page = pageNumber < 0 ? 0 : pageNumber;
    final direction =
        sortDirection == GamebaseSortDirection.asc ? 'ASC' : 'DESC';
    final sortExpression = _localPositionGamesSortExpression(sortBy);
    final rows = await db.select(
      '''
      SELECT
        ? AS position_fen,
        ? AS ref_ply,
        g.*
      $fromClause
      WHERE $where
      ORDER BY $sortExpression $direction, g.index_in_file ASC
      LIMIT ? OFFSET ?
      ''',
      <Object?>[fen, prefix.length, ...parameters, size, page * size],
    );

    return GamebaseSearchQueryResponse(
      status: 'success',
      data: rows.map(_positionGameRowFromDb).toList(growable: false),
      metadata: GamebasePaginationMetadata(
        pageNumber: page,
        pageSize: size,
        totalCount: total,
        hasMoreValue: (page + 1) * size < total,
      ),
    );
  }

  Future<int> _localPositionGamesTotalCount(
    resqlite.Database db, {
    required String databaseId,
    required String fenKey,
    required String? pinnedUci,
    required PlayerOpeningTreeFilterCriteria filters,
    required String joinedFromClause,
    required String joinedWhere,
    required List<Object?> joinedParameters,
  }) async {
    if (!filters.hasFilters) {
      final where = StringBuffer('database_id = ? AND fen_key = ?');
      final parameters = <Object?>[databaseId, fenKey];
      if (pinnedUci != null && pinnedUci.isNotEmpty) {
        where.write(' AND next_uci = ?');
        parameters.add(pinnedUci);
      }
      final rows = await db.select('''
        SELECT COUNT(*) AS count
        FROM $localChessPositionGamesTable
        WHERE $where
        ''', parameters);
      return _readInt(rows.single['count']);
    }

    final rows = await db.select(
      'SELECT COUNT(*) AS count $joinedFromClause WHERE $joinedWhere',
      joinedParameters,
    );
    return _readInt(rows.single['count']);
  }

  Future<void> saveLocalGameAnalysis(LocalChessGameAnalysis analysis) async {
    final db = await _database();
    await _lockedExecute(
      db,
      '''
      INSERT OR REPLACE INTO $localChessGameAnalysisTable(
        game_id,
        database_id,
        analysis_state,
        variation_comments,
        move_nags,
        last_viewed_position,
        notes,
        is_favorite,
        created_at_ms,
        updated_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      <Object?>[
        analysis.gameId,
        analysis.databaseId,
        jsonEncode(analysis.analysisState),
        jsonEncode(analysis.variationComments),
        jsonEncode(analysis.moveNags),
        analysis.lastViewedPosition,
        analysis.notes,
        analysis.isFavorite ? 1 : 0,
        analysis.createdAt.millisecondsSinceEpoch,
        analysis.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  Future<LocalChessGameAnalysis?> localGameAnalysis(String gameId) async {
    final db = await _database();
    final rows = await db.select(
      'SELECT * FROM $localChessGameAnalysisTable WHERE game_id = ? LIMIT 1',
      <Object?>[gameId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LocalChessGameAnalysis(
      gameId: row['game_id'] as String,
      databaseId: row['database_id'] as String,
      analysisState: _jsonMap(row['analysis_state']),
      variationComments: _stringMap(row['variation_comments']),
      moveNags: _nagsMap(row['move_nags']),
      lastViewedPosition: _readInt(row['last_viewed_position'], fallback: -1),
      notes: row['notes'] as String?,
      isFavorite: _readInt(row['is_favorite']) == 1,
      createdAt: _dateFromMillis(row['created_at_ms']) ?? DateTime.now(),
      updatedAt: _dateFromMillis(row['updated_at_ms']) ?? DateTime.now(),
    );
  }

  Future<LocalChessSource?> _loadFreshSingleSource(
    String path, {
    String? sourceLabel,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final probe = await probeLocalChessPathInWorker(path);
    if (probe.isDirectory) {
      final root = await _loadFreshDirectory(
        path,
        rootPath: path,
        force: true,
        onProgress: onProgress,
      );
      return LocalChessSource(
        id: _stableId(path),
        label: sourceLabel ?? localChessDatabaseDisplayNameForPath(path),
        paths: <String>[path],
        rootPath: path,
        scannedAt: DateTime.now(),
        root: root,
      );
    }
    if (!probe.isFile) return null;
    final parent = p.dirname(path);
    final node = await _loadFreshFileNode(
      path,
      rootPath: parent,
      onProgress: onProgress,
    );
    final label = sourceLabel ?? localChessDatabaseDisplayNameForPath(path);
    final root = LocalChessFolderNode.fromChildren(
      name: label,
      path: 'local-file:${_stableId(path)}',
      relativePath: '',
      children: <LocalChessNode>[node],
    );
    return LocalChessSource(
      id: _stableId(path),
      label: label,
      paths: <String>[path],
      rootPath: parent,
      scannedAt: DateTime.now(),
      root: root,
    );
  }

  Future<LocalChessFolderNode> _loadFreshDirectory(
    String path, {
    required String rootPath,
    bool force = false,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final filePaths = await listLocalChessPgnFilesInWorker(
      path,
      allowedSuffixes: localChessRecognizedExtensions.toList(growable: false),
    );
    final files = <LocalChessFileNode>[];
    for (final filePath in filePaths) {
      final node = await _loadFreshFileNodeOrUnsupported(
        filePath,
        rootPath: rootPath,
        onProgress: onProgress,
      );
      if (node is LocalChessFileNode) files.add(node);
    }
    if (!force && files.isEmpty) throw const _LocalChessCacheMiss();
    return _freshFolderTreeFromFiles(
      directoryPath: path,
      rootPath: rootPath,
      files: files,
    );
  }

  Future<LocalChessNode?> _loadFreshFileNodeOrUnsupported(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    if (!looksLikeLocalChessFile(path)) return null;
    if (!isSupportedLocalChessFile(path)) {
      final probe = await probeLocalChessPathInWorker(path);
      if (!probe.isFile || probe.sizeBytes == null) {
        throw const _LocalChessCacheMiss();
      }
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: _extensionForPath(path),
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: probe.sizeBytes!,
        modifiedAt: probe.modifiedAt,
        message: localChessUnsupportedFormatMessage,
      );
    }
    return _loadFreshFileNode(path, rootPath: rootPath, onProgress: onProgress);
  }

  Future<LocalChessFileNode> _loadFreshFileNode(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final databaseId = _databaseId(path);
    final db = await _openDatabase(onProgress: onProgress);
    final databaseRows = await db.select(
      '''
      SELECT *
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) throw const _LocalChessCacheMiss();
    final databaseRow = databaseRows.single;
    final storedSize = _readInt(databaseRow['size_bytes']);
    final storedModified = _readNullableInt(databaseRow['modified_at_ms']);
    final storedContentFingerprint =
        databaseRow['content_fingerprint']?.toString().trim() ?? '';
    if (storedContentFingerprint.isEmpty) {
      // A legacy row without a content identity cannot safely distinguish a
      // same-size/same-mtime rewrite. Reimport once instead of blessing stale
      // game rows with a fingerprint sampled later in the background.
      throw const _LocalChessCacheMiss();
    }
    final probe = await probeLocalChessPathInWorker(
      path,
      includeContentFingerprint: true,
    );
    if (!probe.isFile ||
        probe.sizeBytes == null ||
        probe.modifiedAt == null ||
        probe.contentFingerprint != storedContentFingerprint ||
        storedSize != probe.sizeBytes) {
      throw const _LocalChessCacheMiss();
    }
    final modifiedMs = probe.modifiedAt!.millisecondsSinceEpoch;
    if (storedModified != modifiedMs) {
      await _refreshLocalChessDatabaseFileStatIfUnchanged(
        db,
        databaseId: databaseId,
        sizeBytes: probe.sizeBytes!,
        modifiedAtMs: modifiedMs,
        contentFingerprint: storedContentFingerprint,
        expectedSizeBytes: storedSize,
        expectedModifiedAtMs: storedModified,
        expectedContentFingerprint: storedContentFingerprint,
      );
    }

    final gameCount = _readInt(databaseRow['game_count']);
    final actualGameCountRows = await db.select(
      '''
      SELECT COUNT(*) AS count
      FROM $localChessGamesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final actualGameCount = _readInt(actualGameCountRows.single['count']);
    if (actualGameCount != gameCount) {
      throw const _LocalChessCacheMiss();
    }

    final previewSize =
        gameCount < cachedFileNodeGamePreviewLimit
            ? gameCount
            : cachedFileNodeGamePreviewLimit;
    final gameRows = await db.select(
      '''
      SELECT ${_localChessGameProjection('g')}
      FROM $localChessGamesTable g
      WHERE g.database_id = ?
      ORDER BY g.index_in_file ASC
      LIMIT ?
      ''',
      <Object?>[databaseId, previewSize],
    );
    if (gameRows.isEmpty) throw const _LocalChessCacheMiss();
    final games = gameRows.map(_localGameFromRow).toList(growable: false);
    PlayerOpeningTreeIndex? index;
    try {
      index = await _loadOpeningTreeIndex(
        db,
        databaseId,
        generatedAtMs: databaseRow['updated_at_ms'],
        expectedPositionCount: _readInt(databaseRow['position_count']),
        expectedGameCount: gameCount,
        expectedMaxPly: _readNullableInt(databaseRow['tree_max_ply']),
      );
    } on _LocalChessCacheMiss {
      index = null;
    }

    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: _relative(rootPath, path),
      extension: _extensionForPath(path),
      status: LocalChessFileStatus.parsed,
      games: games,
      gameCount: gameCount,
      sizeBytes: probe.sizeBytes!,
      modifiedAt: probe.modifiedAt,
      openingTreeIndex: index,
    );
  }

  Future<void> _replaceFileNode(
    resqlite.Transaction txn,
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    final databaseId = _databaseId(file.path);
    final index = file.openingTreeIndex;
    final now = DateTime.now().millisecondsSinceEpoch;
    final contentFingerprint =
        file.contentFingerprint.trim().isNotEmpty
            ? file.contentFingerprint.trim()
            : throw StateError('Stable PGN fingerprint was not captured.');

    final databaseRow = <String, Object?>{
      'id': databaseId,
      'path': file.path,
      'label': sourceLabel,
      'extension': file.extension,
      'size_bytes': file.sizeBytes,
      'modified_at_ms': file.modifiedAt?.millisecondsSinceEpoch,
      'content_fingerprint': contentFingerprint,
      'file_count': 1,
      'game_count': file.games.length,
      'position_count': index?.positionCount ?? 0,
      'tree_snapshot': null,
      'tree_max_ply': index?.maxPly,
      'imported_at_ms': now,
      'updated_at_ms': now,
      'deleted_at_ms': null,
    };
    await _insertOrReplace(txn, localChessDatabasesTable, databaseRow);

    await _deleteDatabaseRows(txn, databaseId);

    final gameIds = <String>{for (final game in file.games) game.id};
    final playerNames = <String>{};
    final eventNames = <String>{};
    final siteNames = <String>{};
    for (final game in file.games) {
      final treeRow = index?.gameRowsById[game.id];
      _addNormalizedName(
        playerNames,
        game.game.metadata['White'] ?? treeRow?['white'],
      );
      _addNormalizedName(
        playerNames,
        game.game.metadata['Black'] ?? treeRow?['black'],
      );
      _addNormalizedName(
        eventNames,
        game.game.metadata['Event'] ?? treeRow?['event'],
      );
      _addNormalizedName(
        siteNames,
        game.game.metadata['Site'] ?? treeRow?['site'],
      );
    }

    final playerIds = await _idsForNames(
      txn,
      localChessPlayersTable,
      playerNames,
    );
    final eventIds = await _idsForNames(txn, localChessEventsTable, eventNames);
    final siteIds = await _idsForNames(txn, localChessSitesTable, siteNames);

    await _insertGameRows(
      txn,
      databaseId,
      file.games,
      index?.gameRowsById ?? const <String, Map<String, dynamic>>{},
      playerIds: playerIds,
      eventIds: eventIds,
      siteIds: siteIds,
    );
    if (index != null) {
      await _insertTree(txn, databaseId, index);
      await _insertPositionGameRefs(txn, databaseId, index, gameIds);
    }
  }

  Future<void> _deleteFileCache(resqlite.Transaction txn, String path) async {
    final databaseId = _databaseId(path);
    await _deleteDatabaseRows(txn, databaseId);
    await txn.execute(
      'DELETE FROM $localChessDatabasesTable WHERE id = ?',
      <Object?>[databaseId],
    );
  }

  Future<void> _deleteDatabaseRows(
    resqlite.Transaction txn,
    String databaseId,
  ) async {
    await _deleteOpeningTreeRows(txn, databaseId);
    await txn.execute(
      'DELETE FROM $localChessGameAnalysisTable WHERE database_id = ?',
      <Object?>[databaseId],
    );
    await txn.execute(
      'DELETE FROM $localChessGamesTable WHERE database_id = ?',
      <Object?>[databaseId],
    );
    await _deleteOrphanLocalMetadata(txn);
  }

  Future<bool> _purgeDeletedDatabaseCache(
    resqlite.Database db,
    String databaseId, {
    required int batchSize,
    OperationCancellationToken? cancellationToken,
    void Function(String table, int deletedRows)? onDeletedRows,
    void Function(
      String table,
      int batchSize,
      int affectedRows,
      int elapsedMilliseconds,
    )?
    onBatchCompleted,
  }) async {
    cancellationToken?.throwIfCanceled();
    if (!await _databaseIsMarkedDeleted(db, databaseId)) return false;
    final size = batchSize <= 0 ? _kCooperativePurgeBatchSize : batchSize;

    await _deleteDatabaseRowsInChunks(
      db,
      localChessPositionGamesTable,
      databaseId,
      batchSize: size,
      cancellationToken: cancellationToken,
      onDeletedRows: onDeletedRows,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeMovesTable,
      databaseId,
      batchSize: size,
      cancellationToken: cancellationToken,
      onDeletedRows: onDeletedRows,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeNodesTable,
      databaseId,
      batchSize: size,
      cancellationToken: cancellationToken,
      onDeletedRows: onDeletedRows,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessGameAnalysisTable,
      databaseId,
      batchSize: size,
      cancellationToken: cancellationToken,
      onDeletedRows: onDeletedRows,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessGamesTable,
      databaseId,
      batchSize: size,
      cancellationToken: cancellationToken,
      onDeletedRows: onDeletedRows,
      onBatchCompleted: onBatchCompleted,
    );
    cancellationToken?.throwIfCanceled();
    if (!await _databaseIsMarkedDeleted(db, databaseId)) return false;
    final stopwatch = Stopwatch()..start();
    final result = await _runLocalCacheWriteQueued(() {
      cancellationToken?.throwIfCanceled();
      return db.execute(
        '''
          DELETE FROM $localChessDatabasesTable
          WHERE id = ? AND deleted_at_ms IS NOT NULL
          ''',
        <Object?>[databaseId],
      );
    });
    stopwatch.stop();
    onBatchCompleted?.call(
      localChessDatabasesTable,
      1,
      result.affectedRows,
      stopwatch.elapsedMilliseconds,
    );
    if (result.affectedRows > 0) {
      onDeletedRows?.call(localChessDatabasesTable, result.affectedRows);
    }
    return result.affectedRows > 0;
  }

  Future<bool> _databaseIsMarkedDeleted(
    resqlite.Database db,
    String databaseId,
  ) async {
    final rows = await db.select(
      '''
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NOT NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    return rows.isNotEmpty;
  }

  Future<void> _deleteDatabaseRowsInChunks(
    resqlite.Database db,
    String table,
    String databaseId, {
    required int batchSize,
    OperationCancellationToken? cancellationToken,
    void Function(String table, int deletedRows)? onDeletedRows,
    void Function(
      String table,
      int batchSize,
      int affectedRows,
      int elapsedMilliseconds,
    )?
    onBatchCompleted,
  }) async {
    // Delete in bounded batches, but let the writer isolate pick the rows via a
    // subquery instead of SELECTing a batch of rowids back to the caller and
    // echoing them into an `IN (?, ?, …)` list. Materializing 4096-row id
    // batches on the calling (UI) isolate and re-encoding them per batch across
    // the millions of rows a heavy player can hold is what dropped frames while
    // a removal's cache purge ran. The `Future.delayed(Duration.zero)` between
    // batches still yields the event loop so the purge stays cooperative.
    var currentBatchSize = batchSize;
    while (true) {
      cancellationToken?.throwIfCanceled();
      final stopwatch = Stopwatch()..start();
      final result = await _runLocalCacheWriteQueued(() {
        cancellationToken?.throwIfCanceled();
        return db.execute(
          '''
            DELETE FROM $table
            WHERE rowid IN (
              SELECT rowid FROM $table WHERE database_id = ? LIMIT ?
            )
            ''',
          <Object?>[databaseId, currentBatchSize],
        );
      });
      stopwatch.stop();
      final deletedRows = result.affectedRows;
      onBatchCompleted?.call(
        table,
        currentBatchSize,
        deletedRows,
        stopwatch.elapsedMilliseconds,
      );
      if (deletedRows <= 0) return;
      onDeletedRows?.call(table, deletedRows);
      if (batchSize >= 128 && deletedRows >= currentBatchSize) {
        if (stopwatch.elapsedMilliseconds <= 4 &&
            currentBatchSize < _kMaximumAdaptivePurgeBatchSize) {
          currentBatchSize =
              (currentBatchSize * 2)
                  .clamp(batchSize, _kMaximumAdaptivePurgeBatchSize)
                  .toInt();
        } else if (stopwatch.elapsedMilliseconds >= 24 &&
            currentBatchSize > batchSize) {
          currentBatchSize =
              (currentBatchSize ~/ 2)
                  .clamp(batchSize, _kMaximumAdaptivePurgeBatchSize)
                  .toInt();
        }
      }
      cancellationToken?.throwIfCanceled();
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _recordPurgeBatchDiagnostic(
    _LocalChessPurgeDiagnostics diagnostics,
    String table,
    int batchSize,
    int affectedRows,
    int elapsedMilliseconds,
  ) {
    if (elapsedMilliseconds < slowPurgeBatchThreshold.inMilliseconds) return;
    final diagnostic = LocalChessPurgeBatchDiagnostic(
      table: table,
      batchSize: batchSize,
      affectedRows: affectedRows,
      elapsedMilliseconds: elapsedMilliseconds,
    );
    try {
      onSlowPurgeBatch?.call(diagnostic);
    } catch (_) {
      // Diagnostics are advisory and must never interrupt physical cleanup.
    }
    final firstForTable = diagnostics.record(diagnostic);
    if (firstForTable) {
      localChessLog.breadcrumb(
        'Slow local cache purge batch',
        category: 'local_chess.purge_batch',
        context: diagnostic.sentryData,
      );
    }
  }

  void _recordPurgeDiagnosticSummary(_LocalChessPurgeDiagnostics diagnostics) {
    if (diagnostics.slowBatchCount <= diagnostics.reportedTableCount) return;
    localChessLog.breadcrumb(
      'Local cache purge slow batch summary',
      category: 'local_chess.purge_batch',
      context: <String, Object?>{
        'slowBatchCount': diagnostics.slowBatchCount,
        'tableCount': diagnostics.reportedTableCount,
        'maxElapsedMs': diagnostics.maxElapsedMilliseconds,
      },
    );
  }

  Future<void> _checkpointLocalChessCacheBestEffort(
    resqlite.Database db,
  ) async {
    try {
      await db.select('PRAGMA wal_checkpoint(PASSIVE)');
    } catch (_) {
      // Checkpointing is only a disk-size optimization after a successful
      // purge. It must never turn delete into a user-visible failure.
    }
  }

  Future<void> _deleteOrphanLocalMetadata(resqlite.Transaction txn) async {
    await txn.execute('''
      DELETE FROM $localChessPlayersTable
      WHERE id <> 0
        AND id NOT IN (
          SELECT white_id FROM $localChessGamesTable
          UNION
          SELECT black_id FROM $localChessGamesTable
        )
    ''');
    await txn.execute('''
      DELETE FROM $localChessEventsTable
      WHERE id <> 0
        AND id NOT IN (
          SELECT event_id FROM $localChessGamesTable
        )
    ''');
    await txn.execute('''
      DELETE FROM $localChessSitesTable
      WHERE id <> 0
        AND id NOT IN (
          SELECT site_id FROM $localChessGamesTable
        )
    ''');
  }

  Future<void> _deleteOrphanLocalMetadataInChunks(
    resqlite.Database db, {
    required int batchSize,
    OperationCancellationToken? cancellationToken,
    void Function(
      String table,
      int batchSize,
      int affectedRows,
      int elapsedMilliseconds,
    )?
    onBatchCompleted,
  }) async {
    await _deleteOrphanLocalRowsInChunks(
      db,
      table: localChessPlayersTable,
      idSql: '''
        SELECT p.id
        FROM $localChessPlayersTable p
        WHERE p.id <> 0
          AND NOT EXISTS (
            SELECT 1
            FROM $localChessGamesTable g
            WHERE g.white_id = p.id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM $localChessGamesTable g
            WHERE g.black_id = p.id
          )
        LIMIT ?
      ''',
      batchSize: batchSize,
      cancellationToken: cancellationToken,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteOrphanLocalRowsInChunks(
      db,
      table: localChessEventsTable,
      idSql: '''
        SELECT e.id
        FROM $localChessEventsTable e
        WHERE e.id <> 0
          AND NOT EXISTS (
            SELECT 1
            FROM $localChessGamesTable g
            WHERE g.event_id = e.id
          )
        LIMIT ?
      ''',
      batchSize: batchSize,
      cancellationToken: cancellationToken,
      onBatchCompleted: onBatchCompleted,
    );
    await _deleteOrphanLocalRowsInChunks(
      db,
      table: localChessSitesTable,
      idSql: '''
        SELECT s.id
        FROM $localChessSitesTable s
        WHERE s.id <> 0
          AND NOT EXISTS (
            SELECT 1
            FROM $localChessGamesTable g
            WHERE g.site_id = s.id
          )
        LIMIT ?
      ''',
      batchSize: batchSize,
      cancellationToken: cancellationToken,
      onBatchCompleted: onBatchCompleted,
    );
  }

  Future<void> _deleteOrphanLocalRowsInChunks(
    resqlite.Database db, {
    required String table,
    required String idSql,
    required int batchSize,
    OperationCancellationToken? cancellationToken,
    void Function(
      String table,
      int batchSize,
      int affectedRows,
      int elapsedMilliseconds,
    )?
    onBatchCompleted,
  }) async {
    // Same rationale as _deleteDatabaseRowsInChunks: nest the id selection
    // (`idSql` already ends in `LIMIT ?`) as a subquery so the writer isolate
    // deletes each batch without shipping a batch of ids back to the caller.
    while (true) {
      cancellationToken?.throwIfCanceled();
      final stopwatch = Stopwatch()..start();
      final result = await _runLocalCacheWriteQueued(() {
        cancellationToken?.throwIfCanceled();
        return db.execute('DELETE FROM $table WHERE id IN ($idSql)', <Object?>[
          batchSize,
        ]);
      });
      stopwatch.stop();
      onBatchCompleted?.call(
        table,
        batchSize,
        result.affectedRows,
        stopwatch.elapsedMilliseconds,
      );
      if (result.affectedRows <= 0) return;
      cancellationToken?.throwIfCanceled();
      await Future<void>.delayed(Duration.zero);
    }
  }

  String _localChessPurgeTableLabel(String table) {
    switch (table) {
      case localChessPositionGamesTable:
        return 'position references';
      case localChessTreeMovesTable:
        return 'tree moves';
      case localChessTreeNodesTable:
        return 'tree positions';
      case localChessGameAnalysisTable:
        return 'local analysis';
      case localChessGamesTable:
        return 'games';
      case localChessDatabasesTable:
        return 'database record';
    }
    return 'cache rows';
  }

  Future<void> _deleteOpeningTreeRows(
    resqlite.Transaction txn,
    String databaseId,
  ) async {
    await _deleteDatabaseRowsInTransactionChunks(
      txn,
      localChessPositionGamesTable,
      databaseId,
    );
    await _deleteDatabaseRowsInTransactionChunks(
      txn,
      localChessTreeMovesTable,
      databaseId,
    );
    await _deleteDatabaseRowsInTransactionChunks(
      txn,
      localChessTreeNodesTable,
      databaseId,
    );
  }

  Future<void> _deleteDatabaseRowsInTransactionChunks(
    resqlite.Transaction txn,
    String table,
    String databaseId, {
    int batchSize = _kSqlWriteBatchSize,
  }) async {
    final size = batchSize <= 0 ? _kSqlWriteBatchSize : batchSize;
    while (true) {
      final rows = await txn.select(
        '''
        SELECT rowid
        FROM $table
        WHERE database_id = ?
        LIMIT ?
        ''',
        <Object?>[databaseId, size],
      );
      if (rows.isEmpty) return;
      final rowIds = <Object?>[for (final row in rows) row['rowid']];
      final placeholders = List<String>.filled(rowIds.length, '?').join(', ');
      await txn.execute(
        'DELETE FROM $table WHERE rowid IN ($placeholders)',
        rowIds,
      );
      await _yieldAfterSqlBatch();
    }
  }

  Future<void> _insertGameRows(
    resqlite.Transaction txn,
    String databaseId,
    List<LocalChessGame> games,
    Map<String, Map<String, dynamic>> treeRowsById, {
    required Map<String, int> playerIds,
    required Map<String, int> eventIds,
    required Map<String, int> siteIds,
    bool parseRawPgnLineFallback = true,
  }) async {
    if (games.isEmpty) return;
    final rows = <Map<String, Object?>>[];
    Future<void> flushRows() async {
      if (rows.isEmpty) return;
      await _insertOrReplaceBatch(
        txn,
        localChessGamesTable,
        List<Map<String, Object?>>.of(rows),
      );
      rows.clear();
    }

    for (final game in games) {
      final treeRow = treeRowsById[game.id];
      final eco = treeRow?['eco']?.toString() ?? game.game.metadata['ECO'];
      final metadata = _metadataWithCanonicalOpening(game.game.metadata, eco);
      final white = _normalizedName(metadata['White'] ?? treeRow?['white']);
      final black = _normalizedName(metadata['Black'] ?? treeRow?['black']);
      final event = _normalizedName(metadata['Event'] ?? treeRow?['event']);
      final site = _normalizedName(metadata['Site'] ?? treeRow?['site']);
      final timeControl =
          treeRow?['timeControl']?.toString() ??
          metadata['TimeControl']?.toString();
      final rowLine = _lineFromRow(treeRow);
      final line =
          rowLine.isEmpty
              ? parseRawPgnLineFallback
                  ? _lineFromLocalGame(game)
                  : _inlineLineFromLocalGame(game)
              : rowLine;
      final hasSourceRange =
          game.sourceByteStart != null &&
          game.sourceByteEnd != null &&
          game.sourceByteEnd! > game.sourceByteStart!;
      final rawPgn = game.hasInlineRawPgn || !hasSourceRange ? game.rawPgn : '';
      final pgnHash =
          game.pgnFingerprint.trim().isNotEmpty
              ? game.pgnFingerprint.trim()
              : localChessPgnFingerprint(rawPgn);
      rows.add(<String, Object?>{
        'id': game.id,
        'database_id': databaseId,
        'event_id': event == null ? 0 : eventIds[event] ?? 0,
        'site_id': site == null ? 0 : siteIds[site] ?? 0,
        'date': treeRow?['date']?.toString() ?? metadata['Date']?.toString(),
        'utc_time': metadata['UTCTime']?.toString(),
        'round': metadata['Round']?.toString(),
        'white_id': white == null ? 0 : playerIds[white] ?? 0,
        'white_elo': _rating(metadata['WhiteElo'] ?? treeRow?['whiteElo']),
        'black_id': black == null ? 0 : playerIds[black] ?? 0,
        'black_elo': _rating(metadata['BlackElo'] ?? treeRow?['blackElo']),
        'white_material': 39,
        'black_material': 39,
        'result':
            treeRow?['result']?.toString() ?? metadata['Result']?.toString(),
        'time_control': timeControl,
        'time_control_category': _localGameTimeControlCategory(
          timeControl: timeControl,
          metadata: metadata,
        ),
        'is_online':
            _inferLocalGameIsOnline(
                  timeControl: timeControl,
                  metadata: metadata,
                  sourcePath: game.sourcePath,
                  fileName: game.fileName,
                )
                ? 1
                : 0,
        'eco': eco?.toString(),
        'ply_count': line.length,
        'fen': game.game.startingFen,
        'moves': jsonEncode(line),
        'pawn_home': 65535,
        'raw_pgn': rawPgn,
        'pgn_hash': pgnHash,
        'headers_json': jsonEncode(metadata),
        'source_path': game.sourcePath,
        'source_relative_path': game.sourceRelativePath,
        'file_name': game.fileName,
        'index_in_file': game.indexInFile,
        'file_game_count': game.fileGameCount,
        'has_moves': game.hasMoves ? 1 : 0,
        'source_byte_start': game.sourceByteStart,
        'source_byte_end': game.sourceByteEnd,
      });
      if (rows.length >= _kSqlWriteBatchSize) {
        await flushRows();
      }
    }
    await flushRows();
    // New rows may reference players the FIDE backfill has never seen; clear
    // the marker so the next enrichment pass rescans this database.
    await txn.execute(
      'UPDATE $localChessDatabasesTable SET player_enrichment_at_ms = NULL '
      'WHERE id = ?',
      <Object?>[databaseId],
    );
  }

  Future<Map<String, int>> _idsForNames(
    resqlite.Transaction txn,
    String table,
    Set<String> names,
  ) async {
    if (names.isEmpty) return const <String, int>{};
    final sorted = names.toList(growable: false)..sort();
    await _executeBatchChunked(
      txn,
      'INSERT OR IGNORE INTO $table(name) VALUES (?)',
      <List<Object?>>[
        for (final name in sorted) <Object?>[name],
      ],
    );

    final ids = <String, int>{};
    for (final chunk in _chunks(sorted, 800)) {
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rows = await txn.select(
        'SELECT id, name FROM $table WHERE name IN ($placeholders)',
        <Object?>[...chunk],
      );
      for (final row in rows) {
        final name = row['name']?.toString();
        if (name == null || name.isEmpty) continue;
        ids[name] = _readInt(row['id']);
      }
    }

    if (ids.length != sorted.length) {
      final missing = sorted.where((name) => !ids.containsKey(name)).join(', ');
      throw StateError(
        'Failed to persist local chess metadata in $table: $missing',
      );
    }
    return ids;
  }

  Future<Set<String>> _localGameIds(
    resqlite.Transaction txn,
    String databaseId,
  ) async {
    final rows = await txn.select(
      'SELECT id FROM $localChessGamesTable WHERE database_id = ?',
      <Object?>[databaseId],
    );
    return <String>{
      for (final row in rows)
        if (row['id']?.toString().isNotEmpty == true) row['id'].toString(),
    };
  }

  Future<void> _insertTree(
    resqlite.Transaction txn,
    String databaseId,
    PlayerOpeningTreeIndex index,
  ) async {
    final nodeRows = <List<Object?>>[];
    Future<void> flushNodeRows() async {
      if (nodeRows.isEmpty) return;
      await _executeBatchChunked(txn, '''
      INSERT OR REPLACE INTO $localChessTreeNodesTable(
        database_id,
        node_id,
        fen_key,
        ply
      ) VALUES (?, ?, ?, ?)
      ''', List<List<Object?>>.of(nodeRows));
      nodeRows.clear();
    }

    for (final node in index.nodesById.values) {
      nodeRows.add(<Object?>[databaseId, node.id, node.fenKey, node.ply]);
      if (nodeRows.length >= _kSqlWriteBatchSize) {
        await flushNodeRows();
      }
    }
    await flushNodeRows();

    final moveRows = <List<Object?>>[];
    Future<void> flushMoveRows() async {
      if (moveRows.isEmpty) return;
      await _executeBatchChunked(txn, '''
        INSERT OR REPLACE INTO $localChessTreeMovesTable(
          database_id,
          node_id,
          uci,
          child_node_id,
          white,
          black,
          draws,
          total,
          last_played_ms,
          sample_game_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', List<List<Object?>>.of(moveRows));
      moveRows.clear();
    }

    for (final node in index.nodesById.values) {
      for (final move in node.moves) {
        moveRows.add(<Object?>[
          databaseId,
          node.id,
          move.uci,
          move.childNodeId,
          move.white,
          move.black,
          move.draws,
          move.total,
          move.lastPlayed?.millisecondsSinceEpoch,
          move.sampleGameId,
        ]);
        if (moveRows.length >= _kSqlWriteBatchSize) {
          await flushMoveRows();
        }
      }
    }
    await flushMoveRows();
  }

  Future<void> _upsertTreeDelta(
    resqlite.Transaction txn,
    String databaseId,
    PlayerOpeningTreeIndex index,
  ) async {
    if (index.nodesById.isEmpty) return;
    final fenKeys = index.nodesByFenKey.keys.toList(growable: false);
    final persistedNodeIdsByFen = <String, int>{};
    for (final chunk in _chunks(fenKeys, 800)) {
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rows = await txn.select(
        '''
        SELECT fen_key, node_id
        FROM $localChessTreeNodesTable
        WHERE database_id = ? AND fen_key IN ($placeholders)
        ''',
        <Object?>[databaseId, ...chunk],
      );
      for (final row in rows) {
        final fenKey = row['fen_key']?.toString();
        if (fenKey == null || fenKey.isEmpty) continue;
        persistedNodeIdsByFen[fenKey] = _readInt(row['node_id']);
      }
    }

    final maxNodeRows = await txn.select(
      '''
      SELECT COALESCE(MAX(node_id), -1) AS max_node_id
      FROM $localChessTreeNodesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    var nextNodeId = _readInt(maxNodeRows.single['max_node_id']) + 1;
    final idMap = <int, int>{};
    final newNodeRows = <List<Object?>>[];
    Future<void> flushNewNodeRows() async {
      if (newNodeRows.isEmpty) return;
      await _executeBatchChunked(txn, '''
        INSERT INTO $localChessTreeNodesTable(
          database_id,
          node_id,
          fen_key,
          ply
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT(database_id, node_id) DO UPDATE SET
          fen_key = excluded.fen_key,
          ply = CASE
            WHEN excluded.ply < $localChessTreeNodesTable.ply THEN excluded.ply
            ELSE $localChessTreeNodesTable.ply
          END
        ''', List<List<Object?>>.of(newNodeRows));
      newNodeRows.clear();
    }

    for (final node in index.nodesById.values) {
      final existingId = persistedNodeIdsByFen[node.fenKey];
      final persistedId = existingId ?? nextNodeId++;
      idMap[node.id] = persistedId;
      if (existingId == null) {
        newNodeRows.add(<Object?>[
          databaseId,
          persistedId,
          node.fenKey,
          node.ply,
        ]);
        if (newNodeRows.length >= _kSqlWriteBatchSize) {
          await flushNewNodeRows();
        }
      }
    }
    await flushNewNodeRows();

    final moveRows = <List<Object?>>[];
    Future<void> flushMoveRows() async {
      if (moveRows.isEmpty) return;
      await _executeBatchChunked(txn, '''
        INSERT INTO $localChessTreeMovesTable(
          database_id,
          node_id,
          uci,
          child_node_id,
          white,
          black,
          draws,
          total,
          last_played_ms,
          sample_game_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(database_id, node_id, uci) DO UPDATE SET
          child_node_id = excluded.child_node_id,
          white = $localChessTreeMovesTable.white + excluded.white,
          black = $localChessTreeMovesTable.black + excluded.black,
          draws = $localChessTreeMovesTable.draws + excluded.draws,
          total = $localChessTreeMovesTable.total + excluded.total,
          last_played_ms = CASE
            WHEN $localChessTreeMovesTable.last_played_ms IS NULL THEN excluded.last_played_ms
            WHEN excluded.last_played_ms IS NULL THEN $localChessTreeMovesTable.last_played_ms
            WHEN excluded.last_played_ms > $localChessTreeMovesTable.last_played_ms THEN excluded.last_played_ms
            ELSE $localChessTreeMovesTable.last_played_ms
          END,
          sample_game_id = COALESCE(
            $localChessTreeMovesTable.sample_game_id,
            excluded.sample_game_id
          )
        ''', List<List<Object?>>.of(moveRows));
      moveRows.clear();
    }

    for (final node in index.nodesById.values) {
      final persistedNodeId = idMap[node.id];
      if (persistedNodeId == null) continue;
      for (final move in node.moves) {
        final persistedChildId = idMap[move.childNodeId];
        if (persistedChildId == null) continue;
        moveRows.add(<Object?>[
          databaseId,
          persistedNodeId,
          move.uci,
          persistedChildId,
          move.white,
          move.black,
          move.draws,
          move.total,
          move.lastPlayed?.millisecondsSinceEpoch,
          move.sampleGameId,
        ]);
        if (moveRows.length >= _kSqlWriteBatchSize) {
          await flushMoveRows();
        }
      }
    }
    await flushMoveRows();
  }

  Future<void> _insertPositionGameRefs(
    resqlite.Transaction txn,
    String databaseId,
    PlayerOpeningTreeIndex index,
    Set<String> gameIds,
  ) async {
    if (index.gamesByFen.isEmpty) return;

    final rows = <List<Object?>>[];
    Future<void> flushRows() async {
      if (rows.isEmpty) return;
      await _executeBatchChunked(txn, '''
        INSERT OR REPLACE INTO $localChessPositionGamesTable(
          database_id,
          fen_key,
          fen,
          game_id,
          ply,
          next_uci
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''', List<List<Object?>>.of(rows));
      rows.clear();
    }

    for (final entry in index.gamesByFen.entries) {
      for (final ref in entry.value) {
        if (!gameIds.contains(ref.gameId)) {
          throw StateError(
            'Opening tree ref points to missing game: database=$databaseId fen=${entry.key} game=${ref.gameId}',
          );
        }
        final row = index.gameRowsById[ref.gameId];
        rows.add(<Object?>[
          databaseId,
          entry.key,
          ref.fen,
          ref.gameId,
          ref.ply,
          _nextUciForPositionRef(row, ref.ply),
        ]);
        if (rows.length >= _kPositionRefInsertBatchSize) {
          await flushRows();
        }
      }
    }
    await flushRows();
  }

  Future<PlayerOpeningTreeIndex> _loadOpeningTreeIndex(
    resqlite.Database db,
    String databaseId, {
    required Object? generatedAtMs,
    required int expectedPositionCount,
    required int expectedGameCount,
    required int? expectedMaxPly,
  }) async {
    // Metadata is the cheap validity boundary. Generation migrations clear it
    // without touching potentially millions of stale tree rows, so reject the
    // cache before issuing any count or materialization query against them.
    if (!_localChessTreeMetadataIsUsable(
      positionCount: expectedPositionCount,
      maxPly: expectedMaxPly,
    )) {
      throw const _LocalChessCacheMiss();
    }
    final nodeStatsRows = await db.select(
      '''
      SELECT COUNT(*) AS count, MAX(ply) AS max_ply
      FROM $localChessTreeNodesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final nodeCount = _readInt(nodeStatsRows.single['count']);
    if (expectedPositionCount > 0 && nodeCount != expectedPositionCount) {
      throw const _LocalChessCacheMiss();
    }
    if (nodeCount <= 0) throw const _LocalChessCacheMiss();

    final rootRows = await db.select(
      '''
      SELECT 1
      FROM $localChessTreeNodesTable
      WHERE database_id = ? AND node_id = 0
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (rootRows.isEmpty) throw const _LocalChessCacheMiss();

    final actualMaxPly = _readInt(nodeStatsRows.single['max_ply']);
    final maxPly =
        expectedMaxPly != null && expectedMaxPly > 0
            ? expectedMaxPly
            : actualMaxPly;
    final moveCountRows = await db.select(
      '''
      SELECT COUNT(*) AS count
      FROM $localChessTreeMovesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final moveCount = _readInt(moveCountRows.single['count']);
    final refCountRows = await db.select(
      'SELECT COUNT(*) AS count FROM $localChessPositionGamesTable WHERE database_id = ?',
      <Object?>[databaseId],
    );
    final refCount = _readInt(refCountRows.single['count']);
    final loadTreeNodesEagerly =
        nodeCount <= eagerTreeMoveLoadLimit &&
        moveCount <= eagerTreeMoveLoadLimit;
    if (!loadTreeNodesEagerly) {
      return PlayerOpeningTreeIndex(
        treeId: 'local:${_stableId(databaseId)}',
        playerId: databaseId,
        maxPly: maxPly,
        rootNodeId: 0,
        generatedAt: _dateFromMillis(generatedAtMs),
        nodesById: const <int, PlayerOpeningTreeNode>{},
        nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
        gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
        gameRowsById: const <String, Map<String, dynamic>>{},
        persistedPositionCount: nodeCount,
        persistedGameCount: expectedGameCount,
      );
    }

    final nodeRows = await db.select(
      '''
      SELECT * FROM $localChessTreeNodesTable
      WHERE database_id = ?
      ORDER BY node_id ASC
      ''',
      <Object?>[databaseId],
    );
    final loadTreeMovesEagerly = moveCount <= eagerTreeMoveLoadLimit;
    final moveRows =
        loadTreeMovesEagerly
            ? await db.select(
              '''
              SELECT * FROM $localChessTreeMovesTable
              WHERE database_id = ?
              ORDER BY node_id ASC, total DESC, uci ASC
              ''',
              <Object?>[databaseId],
            )
            : const <Map<String, Object?>>[];
    final movesByNode = <int, List<PlayerOpeningTreeMove>>{};
    for (final row in moveRows) {
      final nodeId = _readInt(row['node_id']);
      movesByNode
          .putIfAbsent(nodeId, () => <PlayerOpeningTreeMove>[])
          .add(
            PlayerOpeningTreeMove(
              uci: row['uci']?.toString() ?? '',
              childNodeId: _readInt(row['child_node_id']),
              white: _readInt(row['white']),
              black: _readInt(row['black']),
              draws: _readInt(row['draws']),
              total: _readInt(row['total']),
              lastPlayed: _dateFromMillis(row['last_played_ms']),
              sampleGameId: row['sample_game_id']?.toString(),
            ),
          );
    }

    if (nodeRows.isEmpty ||
        !nodeRows.any((row) => _readNullableInt(row['node_id']) == 0)) {
      throw const _LocalChessCacheMiss();
    }

    final nodesById = <int, PlayerOpeningTreeNode>{};
    final nodesByFenKey = <String, PlayerOpeningTreeNode>{};
    for (final row in nodeRows) {
      final node = PlayerOpeningTreeNode(
        id: _readInt(row['node_id']),
        fenKey: row['fen_key']?.toString() ?? '',
        ply: _readInt(row['ply']),
        moves: List<PlayerOpeningTreeMove>.unmodifiable(
          movesByNode[_readInt(row['node_id'])] ??
              const <PlayerOpeningTreeMove>[],
        ),
      );
      nodesById[node.id] = node;
      nodesByFenKey[node.fenKey] = node;
    }

    final loadGameRowsEagerly =
        refCount > 0 && refCount <= eagerPositionRefLoadLimit;
    final refsByFen = <String, List<PlayerOpeningTreeGameRef>>{};
    final gameRowsById = <String, Map<String, dynamic>>{};
    if (loadGameRowsEagerly) {
      final gameRows = await db.select(
        '''
        SELECT
          id,
          database_id,
          event_id,
          site_id,
          date,
          utc_time,
          round,
          white_id,
          white_elo,
          black_id,
          black_elo,
          white_material,
          black_material,
          result,
          time_control,
          eco,
          ply_count,
          fen,
          moves,
          pawn_home,
          raw_pgn,
          pgn_hash,
          headers_json,
          source_path,
          source_relative_path,
          file_name,
          index_in_file,
          file_game_count,
          has_moves,
          source_byte_start,
          source_byte_end
        FROM $localChessGamesTable
        WHERE database_id = ?
        ORDER BY index_in_file ASC
        ''',
        <Object?>[databaseId],
      );
      for (final row in gameRows) {
        gameRowsById[row['id'] as String] = _treeGameRowFromDb(row);
      }
    }

    if (refCount > 0 && refCount <= eagerPositionRefLoadLimit) {
      final refRows = await db.select(
        '''
        SELECT * FROM $localChessPositionGamesTable
        WHERE database_id = ?
        ORDER BY fen_key ASC, ply ASC
        ''',
        <Object?>[databaseId],
      );
      for (final row in refRows) {
        refsByFen
            .putIfAbsent(
              row['fen_key'] as String,
              () => <PlayerOpeningTreeGameRef>[],
            )
            .add(
              PlayerOpeningTreeGameRef(
                gameId: row['game_id'] as String,
                fen: row['fen'] as String,
                ply: _readInt(row['ply']),
              ),
            );
      }
    }

    return PlayerOpeningTreeIndex(
      treeId: 'local:${_stableId(databaseId)}',
      playerId: databaseId,
      maxPly: maxPly,
      rootNodeId: 0,
      generatedAt: _dateFromMillis(generatedAtMs),
      nodesById: Map<int, PlayerOpeningTreeNode>.unmodifiable(nodesById),
      nodesByFenKey: Map<String, PlayerOpeningTreeNode>.unmodifiable(
        nodesByFenKey,
      ),
      gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable({
        for (final entry in refsByFen.entries)
          entry.key: List<PlayerOpeningTreeGameRef>.unmodifiable(entry.value),
      }),
      gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
        gameRowsById,
      ),
      persistedPositionCount: nodeRows.length,
      persistedGameCount:
          loadGameRowsEagerly ? gameRowsById.length : expectedGameCount,
    );
  }

  Future<int> _currentTreeMaxPly(
    resqlite.Database db,
    String databaseId,
  ) async {
    final databaseRows = await db.select(
      '''
      SELECT position_count, tree_max_ply
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isNotEmpty) {
      final row = databaseRows.single;
      final stored = _readNullableInt(row['tree_max_ply']);
      if (_localChessTreeMetadataIsUsable(
        positionCount: _readInt(row['position_count']),
        maxPly: stored,
      )) {
        return stored!;
      }
    }
    return localOpeningTreeDefaultMaxPly;
  }

  Future<bool> _databaseHasUsableOpeningTreeMetadata(
    resqlite.Database db,
    String databaseId,
  ) async {
    final rows = await db.select(
      '''
      SELECT position_count, tree_max_ply
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (rows.isEmpty) return false;
    final row = rows.single;
    return _localChessTreeMetadataIsUsable(
      positionCount: _readInt(row['position_count']),
      maxPly: _readNullableInt(row['tree_max_ply']),
    );
  }

  Future<bool> _transactionHasUsableOpeningTreeMetadata(
    resqlite.Transaction txn,
    String databaseId,
  ) async {
    final rows = await txn.select(
      '''
      SELECT position_count, tree_max_ply
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (rows.isEmpty) return false;
    final row = rows.single;
    return _localChessTreeMetadataIsUsable(
      positionCount: _readInt(row['position_count']),
      maxPly: _readNullableInt(row['tree_max_ply']),
    );
  }

  LocalChessGame _localGameFromRow(Map<String, Object?> row) {
    final metadata = _jsonMap(row['headers_json']);
    final id = row['id'] as String;
    final startingFen = row['fen']?.toString().trim();
    final rawPgn = row['raw_pgn']?.toString() ?? '';
    final sourceByteStart = _readNullableInt(row['source_byte_start']);
    final sourceByteEnd = _readNullableInt(row['source_byte_end']);
    return LocalChessGame(
      id: id,
      game: ChessGame(
        gameId: id,
        startingFen:
            startingFen == null || startingFen.isEmpty
                ? Chess.initial.fen
                : startingFen,
        metadata: metadata,
        mainline: const [],
      ),
      rawPgn: rawPgn,
      sourcePath: row['source_path'] as String,
      sourceRelativePath: row['source_relative_path'] as String,
      fileName: row['file_name'] as String,
      indexInFile: _readInt(row['index_in_file']),
      fileGameCount: _readInt(row['file_game_count']),
      hasMoves: _readInt(row['has_moves']) == 1,
      moveLine: _jsonList(row['moves'])
          .map((move) => move.toString().trim().toLowerCase())
          .where((move) => move.isNotEmpty)
          .toList(growable: false),
      pgnFingerprint:
          row['pgn_hash']?.toString().trim().isNotEmpty == true
              ? row['pgn_hash'].toString()
              : rawPgn.isEmpty
              ? ''
              : localChessPgnFingerprint(rawPgn),
      sourceByteStart: sourceByteStart,
      sourceByteEnd: sourceByteEnd,
    );
  }

  Map<String, dynamic> _treeGameRowFromDb(Map<String, Object?> row) {
    final metadata = _jsonMap(row['headers_json']);
    String meta(String key) => metadata[key]?.toString().trim() ?? '';
    final rawDate = row['date']?.toString().trim();
    final date = _dateFromLocalDate(
      rawDate == null || rawDate.isEmpty ? meta('Date') : rawDate,
    );
    final line = _jsonList(row['moves'])
        .map((move) => move.toString().trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
    return <String, dynamic>{
      'id': row['id'],
      'white': _fallback(meta('White'), 'White'),
      'black': _fallback(meta('Black'), 'Black'),
      'whiteTitle': meta('WhiteTitle'),
      'blackTitle': meta('BlackTitle'),
      'whiteFed': _firstMetadata(metadata, const <String>[
        'WhiteFed',
        'WhiteFederation',
        'WhiteCountry',
        'WhiteTeamCountry',
      ]),
      'blackFed': _firstMetadata(metadata, const <String>[
        'BlackFed',
        'BlackFederation',
        'BlackCountry',
        'BlackTeamCountry',
      ]),
      'whiteElo': row['white_elo'],
      'blackElo': row['black_elo'],
      'whiteFideId': meta('WhiteFideId'),
      'blackFideId': meta('BlackFideId'),
      'result': row['result'] ?? '*',
      'date': date?.toIso8601String(),
      'timeControl': row['time_control'] ?? meta('TimeControl'),
      'timeControlCategory': row['time_control_category'],
      'isOnline': _readNullableInt(row['is_online']) == 1,
      'eco': row['eco'] ?? meta('ECO'),
      'opening': meta('Opening'),
      'variation': meta('Variation'),
      'event': _fallback(meta('Event'), 'Local PGN'),
      'site': meta('Site'),
      'sourcePath': row['source_path'],
      'sourceRelativePath': row['source_relative_path'],
      'fileName': row['file_name'],
      'indexInFile': row['index_in_file'],
      'fileGameCount': row['file_game_count'],
      'sourceByteStart': row['source_byte_start'],
      'sourceByteEnd': row['source_byte_end'],
      'startingFen': row['fen'],
      'pgn': row['raw_pgn'],
      'pgnHash': row['pgn_hash'],
      'line': line,
      'headers': metadata,
      'metadata': metadata,
    }..removeWhere((_, value) => value == null || value == '');
  }

  Map<String, dynamic> _positionGameRowFromDb(Map<String, Object?> row) {
    final out = _treeGameRowFromDb(row);
    final line = _jsonList(row['moves'])
        .map((move) => move.toString().trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
    final ply = _readInt(row['ref_ply']);
    out['fen'] = row['position_fen']?.toString() ?? '';
    out['continuation'] =
        ply >= 0 && ply < line.length
            ? List<String>.unmodifiable(line.sublist(ply))
            : const <String>[];
    return Map<String, dynamic>.unmodifiable(out);
  }

  List<LocalChessFileNode> _playableFiles(LocalChessNode node) {
    final out = <LocalChessFileNode>[];
    void visit(LocalChessNode node) {
      switch (node) {
        case LocalChessFileNode(:final isPlayable):
          if (isPlayable) out.add(node);
        case LocalChessFolderNode(:final children):
          for (final child in children) {
            visit(child);
          }
      }
    }

    visit(node);
    return out;
  }

  Future<void> _beginImportedFileNode(
    LocalChessFileImportStart start, {
    required String sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
    required void Function(_ImportedFilePreparation preparation)
    onPreparationStarted,
  }) async {
    cancellationToken?.throwIfCanceled();
    _throwIfCacheSourceDeletionInProgress(start.path);
    final databaseId = _databaseId(start.path);
    final now = DateTime.now().millisecondsSinceEpoch;
    final contentFingerprint = start.contentFingerprint.trim();
    if (contentFingerprint.isEmpty) {
      throw StateError('Stable PGN fingerprint was not captured.');
    }
    final db = await _database();
    final existingRows = await db.select(
      '''
      SELECT
        d.size_bytes,
        d.modified_at_ms,
        d.deleted_at_ms,
        d.content_fingerprint,
        d.game_count,
        COUNT(g.id) AS row_count,
        COALESCE(MAX(g.file_game_count), 0) AS file_game_count
      FROM $localChessDatabasesTable d
      LEFT JOIN $localChessGamesTable g
        ON g.database_id = d.id
      WHERE d.id = ?
      GROUP BY d.id
      ''',
      <Object?>[databaseId],
    );
    if (existingRows.isNotEmpty) {
      final existing = existingRows.single;
      final existingGameCount = _readInt(existing['game_count']);
      final existingRowCount = _readInt(existing['row_count']);
      final existingFileGameCount = _readInt(existing['file_game_count']);
      final existingFingerprint =
          existing['content_fingerprint']?.toString().trim() ?? '';
      final fingerprintMatches =
          existingFingerprint.isNotEmpty &&
          existingFingerprint == contentFingerprint;
      final canReuseGameRows =
          existing['deleted_at_ms'] == null &&
          existingRowCount > 0 &&
          existingRowCount == existingGameCount &&
          existingFileGameCount == start.totalEntries &&
          _readInt(existing['size_bytes']) == start.sizeBytes &&
          fingerprintMatches;
      if (canReuseGameRows) {
        onPreparationStarted(_ImportedFilePreparation.reused);
        _activeImportedContentFingerprints[databaseId] = contentFingerprint;
        _reusedImportedGameRows.add(databaseId);
        _reusedImportedContentFingerprints[databaseId] = contentFingerprint;
        localChessLog.info(
          'PGN import reusing unchanged cache',
          context: <String, Object?>{
            'path': start.path,
            'games': existingGameCount,
            'totalEntries': start.totalEntries,
            'matchedBy': 'content_fingerprint',
          },
        );
        onProgress?.call(
          LocalChessScanProgress(
            fraction: 0.30,
            message: 'Using existing local cache...',
          ),
        );
        await _refreshLocalChessDatabaseFileStat(
          db,
          databaseId: databaseId,
          sizeBytes: start.sizeBytes,
          modifiedAtMs: start.modifiedAt?.millisecondsSinceEpoch ?? now,
          contentFingerprint: contentFingerprint,
        );
        return;
      }
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.30,
          message: 'Replacing existing local cache...',
        ),
      );
      onPreparationStarted(_ImportedFilePreparation.replacing);
      _activeImportedContentFingerprints[databaseId] = contentFingerprint;
      await markCachedSourceDeleted(start.path);
      _reusedImportedGameRows.remove(databaseId);
      _reusedImportedContentFingerprints.remove(databaseId);
      await purgeDeletedCaches(
        sourcePath: start.path,
        batchSize: _kCooperativePurgeBatchSize,
        cancellationToken: cancellationToken,
        onProgress:
            onProgress == null
                ? null
                : (progress) {
                  onProgress(
                    LocalChessScanProgress(
                      fraction: 0.30,
                      message: progress.message,
                    ),
                  );
                },
      );
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.30,
          message: 'Existing local cache replaced.',
        ),
      );
    } else {
      onPreparationStarted(_ImportedFilePreparation.replacing);
      _activeImportedContentFingerprints[databaseId] = contentFingerprint;
    }
    await db.transaction((txn) async {
      await _upsertLocalChessDatabaseRow(txn, <String, Object?>{
        'id': databaseId,
        'path': start.path,
        'label': sourceLabel,
        'extension': start.extension,
        'size_bytes': start.sizeBytes,
        'modified_at_ms': start.modifiedAt?.millisecondsSinceEpoch,
        'content_fingerprint': contentFingerprint,
        'file_count': 1,
        'game_count': 0,
        'position_count': 0,
        'tree_snapshot': null,
        'tree_max_ply': null,
        'imported_at_ms': now,
        'updated_at_ms': now,
        'deleted_at_ms': null,
      });
    });
  }

  Future<void> _persistImportedGameBatch(
    String databasePath,
    List<LocalChessGame> games,
  ) async {
    _throwIfCacheSourceDeletionInProgress(databasePath);
    if (games.isEmpty) return;
    final databaseId = _databaseId(databasePath);
    if (_reusedImportedGameRows.contains(databaseId)) return;
    final db = await _database();
    await db.transaction((txn) async {
      final playerNames = <String>{};
      final eventNames = <String>{};
      final siteNames = <String>{};
      for (final game in games) {
        _addNormalizedName(playerNames, game.game.metadata['White']);
        _addNormalizedName(playerNames, game.game.metadata['Black']);
        _addNormalizedName(eventNames, game.game.metadata['Event']);
        _addNormalizedName(siteNames, game.game.metadata['Site']);
      }

      final playerIds = await _idsForNames(
        txn,
        localChessPlayersTable,
        playerNames,
      );
      final eventIds = await _idsForNames(
        txn,
        localChessEventsTable,
        eventNames,
      );
      final siteIds = await _idsForNames(txn, localChessSitesTable, siteNames);
      await _insertGameRows(
        txn,
        databaseId,
        games,
        const <String, Map<String, dynamic>>{},
        playerIds: playerIds,
        eventIds: eventIds,
        siteIds: siteIds,
        // Derive the UCI move line (and ply_count) from the retained PGN. The
        // opening-explorer games list for large local databases (> the
        // position-game-ref limit, where per-position refs are skipped) is
        // served by _localPositionGamesResponseFromMovePrefix, which matches
        // the board's move prefix against g.moves. Persisting an empty moves
        // array here left that fallback with nothing to match, so every
        // non-root position reported "No Games Found" while the FEN-keyed move
        // tree still rendered. See regression test in
        // local_chess_position_games_move_prefix_test.dart.
        parseRawPgnLineFallback: true,
      );
    });
  }

  Future<void> _completeImportedFileNode(LocalChessFileNode file) async {
    _throwIfCacheSourceDeletionInProgress(file.path);
    final databaseId = _databaseId(file.path);
    final reusedExistingRows = _reusedImportedGameRows.remove(databaseId);
    final reusedContentFingerprint = _reusedImportedContentFingerprints.remove(
      databaseId,
    );
    final importedContentFingerprint = _activeImportedContentFingerprints
        .remove(databaseId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _database();
    if (reusedExistingRows) {
      await db.execute(
        '''
        UPDATE $localChessDatabasesTable
        SET
          size_bytes = ?,
          modified_at_ms = ?,
          content_fingerprint = COALESCE(?, content_fingerprint),
          game_count = ?,
          deleted_at_ms = NULL
        WHERE id = ?
        ''',
        <Object?>[
          file.sizeBytes,
          file.modifiedAt?.millisecondsSinceEpoch,
          reusedContentFingerprint ?? importedContentFingerprint,
          file.gameCount,
          databaseId,
        ],
      );
      return;
    }
    final contentFingerprint =
        importedContentFingerprint ?? file.contentFingerprint.trim();
    if (contentFingerprint.isEmpty) {
      throw StateError('Stable PGN fingerprint was lost before finalization.');
    }
    await db.execute(
      '''
      UPDATE $localChessDatabasesTable
      SET
        size_bytes = ?,
        modified_at_ms = ?,
        content_fingerprint = ?,
        game_count = ?,
        position_count = 0,
        tree_snapshot = NULL,
        tree_max_ply = NULL,
        updated_at_ms = ?,
        deleted_at_ms = NULL
      WHERE id = ?
      ''',
      <Object?>[
        file.sizeBytes,
        file.modifiedAt?.millisecondsSinceEpoch,
        contentFingerprint,
        file.gameCount,
        now,
        databaseId,
      ],
    );
    _reusedImportedGameRows.remove(databaseId);
  }

  Future<void> _discardImportedFileNode(String path) async {
    await _abortImportedFileNode(path, deleteCache: true);
  }

  Future<void> _abortImportedFileNode(
    String path, {
    required bool deleteCache,
  }) async {
    final databaseId = _databaseId(path);
    _activeImportedContentFingerprints.remove(databaseId);
    _reusedImportedGameRows.remove(databaseId);
    _reusedImportedContentFingerprints.remove(databaseId);
    if (!deleteCache) return;
    final db = await _database();
    await db.transaction((txn) async {
      await _deleteFileCache(txn, path);
    });
  }
}

final localChessDatabaseRepositoryProvider =
    Provider<LocalChessDatabaseRepository>((_) {
      return LocalChessDatabaseRepository(
        database: () => LocalChessResqliteDatabase.instance.database,
        databaseWithProgress:
            ({onProgress}) => LocalChessResqliteDatabase.instance
                .databaseWithProgress(onProgress: onProgress),
        databaseFilePath: () async => LocalChessResqliteDatabase.instance.path,
        purgeDatabase:
            () => LocalChessResqliteDatabase.instance.openDedicatedConnection(),
      );
    });

class _LocalChessInlineImportSession {
  const _LocalChessInlineImportSession({
    required this.repository,
    this.ownedDatabase,
  });

  final LocalChessDatabaseRepository repository;
  final resqlite.Database? ownedDatabase;

  Future<void> close() async {
    await ownedDatabase?.close();
  }
}

Future<void> _rebuildOpeningTreeFromCachedGamesWorker(
  _LocalTreeRebuildWorkerRequest request,
) async {
  void emit(LocalChessScanProgress progress) {
    request.sendPort.send(progress);
  }

  resqlite.Database? db;
  _LocalTreePositionRefStage? positionRefStage;
  try {
    emit(LocalChessScanProgress(fraction: 0.01, message: 'Opening cache...'));
    db = await resqlite.Database.open(request.databaseFilePath);
    emit(LocalChessScanProgress(fraction: 0.02, message: 'Preparing cache...'));
    await _configureStandaloneLocalChessDatabase(db);

    final repository = LocalChessDatabaseRepository(database: () async => db!);
    final databaseId = _databaseId(request.databasePath);
    final databaseRows = await db.select(
      '''
      SELECT path, size_bytes, game_count, updated_at_ms
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Local database cache is not available.',
          '',
        ),
      );
      return;
    }

    final databaseRow = databaseRows.single;
    final gameCount = _readInt(databaseRow['game_count']);
    final sizeBytes = _readInt(databaseRow['size_bytes']);
    if (gameCount <= 0) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Local database has no cached games to index.',
          '',
        ),
      );
      return;
    }

    emit(LocalChessScanProgress(fraction: 0.08, message: 'Counting games...'));
    final countRows = await db.select(
      '''
      SELECT COUNT(*) AS count
      FROM $localChessGamesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final cachedGameCount =
        countRows.isEmpty ? 0 : _readInt(countRows.single['count']);
    if (cachedGameCount <= 0) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Local database has no cached games to index.',
          '',
        ),
      );
      return;
    }

    final maxPly = _treeMaxPlyForCachedRebuild(
      fileSizeBytes: sizeBytes,
      gameCount: cachedGameCount,
    );
    emit(LocalChessScanProgress(fraction: 0.16, message: 'Building tree...'));

    final persistPositionGameRefs =
        cachedGameCount <= _kPersistedPositionGameRefLimit;
    if (persistPositionGameRefs) {
      positionRefStage = await _openLocalTreePositionRefStage(databaseId);
    }
    final pendingPositionRefs = <LocalOpeningTreePositionGameRef>[];
    final buildStopwatch = Stopwatch()..start();
    final builder = LocalOpeningTreeIncrementalBuilder(
      treeId: 'local:${_stableId(databaseId)}',
      databaseId: databaseId,
      maxPly: maxPly,
      includePositionGameRefs: false,
      includeGameRows: false,
      onPositionGameRef:
          persistPositionGameRefs ? pendingPositionRefs.add : null,
    );
    var processed = 0;
    var lastIndexInFile = -1;
    while (true) {
      final gameRows = await db.select(
        '''
        SELECT
          id,
          fen,
          moves,
          headers_json,
          source_path,
          source_relative_path,
          file_name,
          index_in_file,
          file_game_count,
          source_byte_start,
          source_byte_end
        FROM $localChessGamesTable
        WHERE database_id = ?
          AND index_in_file > ?
        ORDER BY index_in_file ASC
        LIMIT ?
        ''',
        <Object?>[databaseId, lastIndexInFile, _kCachedTreeRebuildPageSize],
      );
      if (gameRows.isEmpty) break;

      for (final gameRowBatch in _chunks(
        gameRows,
        _kCachedTreeBuildInputBatchSize,
      )) {
        builder.addGames(
          _treeInputsForCachedGameRows(
            rows: gameRowBatch,
            totalRows: cachedGameCount,
            processedOffset: processed,
            onProgress: emit,
          ),
        );
        processed += gameRowBatch.length;
        final refStage = positionRefStage;
        if (refStage != null) {
          await _stageLocalTreePositionRefs(
            refStage.database,
            pendingPositionRefs,
          );
          pendingPositionRefs.clear();
        }
        await Future<void>.delayed(Duration.zero);
      }
      lastIndexInFile = _readInt(
        gameRows.last['index_in_file'],
        fallback: lastIndexInFile,
      );
      // Page-level progress even when the per-game throttle is still warming up
      // (small first page, or a long gap before the next 512-game tick).
      final pageFraction =
          cachedGameCount <= 0
              ? 0.32
              : 0.18 + ((processed / cachedGameCount) * 0.64);
      emit(
        LocalChessScanProgress(
          fraction: pageFraction.clamp(0.18, 0.82).toDouble(),
          message:
              cachedGameCount > 0
                  ? 'Building tree... $processed of $cachedGameCount games'
                  : 'Building tree...',
        ),
      );
      if (await repository._databaseIsMarkedDeleted(db, databaseId)) {
        request.sendPort.send(
          const _LocalTreeRebuildWorkerFailure(
            'Local database was deleted before tree rebuild completed.',
            '',
          ),
        );
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (processed <= 0) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Local database has no cached games to index.',
          '',
        ),
      );
      return;
    }

    emit(LocalChessScanProgress(fraction: 0.83, message: 'Finalizing tree...'));
    final buildResult = builder.finishAndRelease();
    buildStopwatch.stop();

    final index = buildResult.index;
    localChessLog.info(
      'Local tree build phase finished',
      context: <String, Object?>{
        'path': request.databasePath,
        'cachedGames': cachedGameCount,
        'indexedGames': index.downloadedGameCount,
        'positions': index.positionCount,
        'skippedGames': buildResult.skippedGames.length,
        'elapsedMs': buildStopwatch.elapsedMilliseconds,
      },
    );
    if (index.positionCount <= 0) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Opening tree build did not produce an index.',
          '',
        ),
      );
      return;
    }

    emit(
      LocalChessScanProgress(
        fraction: 0.84,
        message: 'Preparing tree storage...',
      ),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final persistenceStopwatch = Stopwatch()..start();
    final persisted = await _persistCachedOpeningTreeInBatches(
      db: db,
      databaseId: databaseId,
      index: index,
      generatedAtMs: now,
      positionRefStageDatabase: positionRefStage?.database,
      emit: emit,
    );
    persistenceStopwatch.stop();
    localChessLog.info(
      'Local tree persistence phase finished',
      context: <String, Object?>{
        'path': request.databasePath,
        'positions': index.positionCount,
        'elapsedMs': persistenceStopwatch.elapsedMilliseconds,
      },
    );
    if (!persisted) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Local database cache disappeared before saving tree.',
          '',
        ),
      );
      return;
    }

    emit(LocalChessScanProgress(fraction: 1, message: 'Tree ready.'));
    request.sendPort.send(
      _LocalTreeRebuildWorkerSuccess(
        treeId: 'local:${_stableId(databaseId)}',
        databaseId: databaseId,
        maxPly: index.maxPly,
        positionCount: index.positionCount,
        gameCount: cachedGameCount,
        generatedAtMs: now,
        skippedGames: buildResult.skippedGames.length,
      ),
    );
  } catch (error, stackTrace) {
    request.sendPort.send(
      _LocalTreeRebuildWorkerFailure(error.toString(), stackTrace.toString()),
    );
  } finally {
    await positionRefStage?.close();
    await db?.close();
  }
}

class _LocalTreePositionRefStage {
  const _LocalTreePositionRefStage({
    required this.database,
    required this.path,
  });

  final resqlite.Database database;
  final String path;

  Future<void> close() async {
    await database.close();
    await deleteLocalChessResqliteCacheFilesAt(path);
  }
}

Future<_LocalTreePositionRefStage> _openLocalTreePositionRefStage(
  String databaseId,
) async {
  // Keep the per-position game fan-out out of the Dart heap. The stage is
  // stored in a disposable sidecar database so even a dense 10k-game tree
  // stays bounded while the aggregate nodes are built. It is deliberately not
  // a TEMP table: resqlite may serve reads and writes from different pooled
  // connections, while a normal table is visible to the entire stage pool.
  final path = p.join(
    Directory.systemTemp.path,
    'chessever-tree-stage-${_stableId(databaseId)}-'
    '${DateTime.now().microsecondsSinceEpoch}.db',
  );
  final db = await resqlite.Database.open(path);
  await db.execute('''
    CREATE TABLE $_localTreePositionRefStageTable (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      fen_key TEXT NOT NULL,
      game_id TEXT NOT NULL,
      ply INTEGER NOT NULL,
      next_uci TEXT,
      UNIQUE(fen_key, game_id)
    )
  ''');
  return _LocalTreePositionRefStage(database: db, path: path);
}

Future<void> _stageLocalTreePositionRefs(
  resqlite.Database db,
  List<LocalOpeningTreePositionGameRef> refs,
) async {
  if (refs.isEmpty) return;
  await db.executeBatch(
    '''
    INSERT INTO $_localTreePositionRefStageTable(
      fen_key,
      game_id,
      ply,
      next_uci
    ) VALUES (?, ?, ?, ?)
    ON CONFLICT(fen_key, game_id) DO UPDATE SET
      ply = excluded.ply,
      next_uci = excluded.next_uci
    ''',
    <List<Object?>>[
      for (final ref in refs)
        <Object?>[ref.fenKey, ref.gameId, ref.ply, ref.nextUci],
    ],
  );
}

Future<bool> _persistCachedOpeningTreeInBatches({
  required resqlite.Database db,
  required String databaseId,
  required PlayerOpeningTreeIndex index,
  required int generatedAtMs,
  required resqlite.Database? positionRefStageDatabase,
  required void Function(LocalChessScanProgress progress) emit,
}) async {
  final persistStopwatch = Stopwatch()..start();

  void logPhase(String phase, Stopwatch phaseStopwatch) {
    debugPrint(
      'Local opening tree persistence $phase: '
      '${phaseStopwatch.elapsedMilliseconds}ms '
      '(total ${persistStopwatch.elapsedMilliseconds}ms)',
    );
  }

  Future<bool> persistRows() async {
    // Metadata is the validity boundary for readers. Clear it before touching
    // tree rows so an interrupted rebuild is ignored and safely rebuilt later.
    final invalidated = await db.execute(
      '''
    UPDATE $localChessDatabasesTable
    SET position_count = 0,
        tree_snapshot = NULL,
        tree_max_ply = NULL
    WHERE id = ? AND deleted_at_ms IS NULL
    ''',
      <Object?>[databaseId],
    );
    if (invalidated.affectedRows <= 0) return false;

    emit(
      LocalChessScanProgress(
        fraction: 0.845,
        message: 'Clearing previous tree...',
      ),
    );
    final clearStopwatch = Stopwatch()..start();
    if (positionRefStageDatabase == null) {
      // Large trees already run inside one transaction. Delete each old
      // generation with one indexed statement instead of hundreds of LIMITed
      // statements and event-loop round trips.
      await _deleteCachedTreeRows(db, localChessPositionGamesTable, databaseId);
      await _deleteCachedTreeRows(db, localChessTreeMovesTable, databaseId);
      await _deleteCachedTreeRows(db, localChessTreeNodesTable, databaseId);
    } else {
      await _deleteCachedTreeRowsInAutocommitBatches(
        db,
        localChessPositionGamesTable,
        databaseId,
        label: 'position references',
        emit: emit,
      );
      await _deleteCachedTreeRowsInAutocommitBatches(
        db,
        localChessTreeMovesTable,
        databaseId,
        label: 'tree moves',
        emit: emit,
      );
      await _deleteCachedTreeRowsInAutocommitBatches(
        db,
        localChessTreeNodesTable,
        databaseId,
        label: 'tree positions',
        emit: emit,
      );
    }
    logPhase('clear', clearStopwatch);

    final nodesStopwatch = Stopwatch()..start();
    await _insertCachedTreeNodesInAutocommitBatches(
      db,
      databaseId,
      index,
      emit: emit,
    );
    logPhase('nodes', nodesStopwatch);
    final movesStopwatch = Stopwatch()..start();
    await _insertCachedTreeMovesInAutocommitBatches(
      db,
      databaseId,
      index,
      emit: emit,
    );
    logPhase('moves', movesStopwatch);
    if (positionRefStageDatabase != null) {
      final refsStopwatch = Stopwatch()..start();
      await _insertStagedPositionRefsInAutocommitBatches(
        db,
        databaseId,
        positionRefStageDatabase: positionRefStageDatabase,
        emit: emit,
      );
      logPhase('position references', refsStopwatch);
    }

    emit(
      LocalChessScanProgress(fraction: 0.995, message: 'Publishing tree...'),
    );
    final published = await db.execute(
      '''
    UPDATE $localChessDatabasesTable
    SET position_count = ?,
        tree_snapshot = NULL,
        tree_max_ply = ?,
        updated_at_ms = ?
    WHERE id = ? AND deleted_at_ms IS NULL
    ''',
      <Object?>[index.positionCount, index.maxPly, generatedAtMs, databaseId],
    );
    logPhase('complete', persistStopwatch);
    return published.affectedRows > 0;
  }

  if (positionRefStageDatabase == null) {
    // Large trees do not persist per-position game references. Keep their
    // delete/insert/publish sequence in one SQLite transaction so hundreds of
    // 4096-row batches do not each pay an fsync/commit cost. WAL readers keep
    // seeing the previous complete generation until this one commits.
    return db.transaction((_) => persistRows());
  }
  return persistRows();
}

Future<void> _deleteCachedTreeRows(
  resqlite.Database db,
  String table,
  String databaseId,
) async {
  await db.execute('DELETE FROM $table WHERE database_id = ?', <Object?>[
    databaseId,
  ]);
}

Future<void> _deleteCachedTreeRowsInAutocommitBatches(
  resqlite.Database db,
  String table,
  String databaseId, {
  required String label,
  required void Function(LocalChessScanProgress progress) emit,
}) async {
  var deleted = 0;
  while (true) {
    final result = await db.execute(
      '''
      DELETE FROM $table
      WHERE rowid IN (
        SELECT rowid
        FROM $table
        WHERE database_id = ?
        LIMIT ?
      )
      ''',
      <Object?>[databaseId, _kSqlWriteBatchSize],
    );
    if (result.affectedRows <= 0) return;
    deleted += result.affectedRows;
    emit(
      LocalChessScanProgress(
        fraction: 0.85,
        message: 'Clearing previous $label... $deleted',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _insertCachedTreeNodesInAutocommitBatches(
  resqlite.Database db,
  String databaseId,
  PlayerOpeningTreeIndex index, {
  required void Function(LocalChessScanProgress progress) emit,
}) async {
  final rows = <List<Object?>>[];
  var saved = 0;
  final total = index.nodesById.length;

  Future<void> flush() async {
    if (rows.isEmpty) return;
    final batch = List<List<Object?>>.of(rows);
    rows.clear();
    await _executeMultiRowInsert(db, '''
      INSERT INTO $localChessTreeNodesTable(
        database_id,
        node_id,
        fen_key,
        ply
      ) VALUES
      ''', batch);
    saved += batch.length;
    emit(
      LocalChessScanProgress(
        fraction: _treeSaveFraction(0.86, 0.90, saved, total),
        message: 'Saving tree positions... $saved of $total',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  for (final node in index.nodesById.values) {
    rows.add(<Object?>[databaseId, node.id, node.fenKey, node.ply]);
    if (rows.length >= _kTreeMultiRowBindLimit ~/ 4) await flush();
  }
  await flush();
}

Future<void> _insertCachedTreeMovesInAutocommitBatches(
  resqlite.Database db,
  String databaseId,
  PlayerOpeningTreeIndex index, {
  required void Function(LocalChessScanProgress progress) emit,
}) async {
  final rows = <List<Object?>>[];
  final total = index.nodesById.values.fold<int>(
    0,
    (count, node) => count + node.moves.length,
  );
  var saved = 0;

  Future<void> flush() async {
    if (rows.isEmpty) return;
    final batch = List<List<Object?>>.of(rows);
    rows.clear();
    await _executeMultiRowInsert(db, '''
      INSERT INTO $localChessTreeMovesTable(
        database_id,
        node_id,
        uci,
        child_node_id,
        white,
        black,
        draws,
        total,
        last_played_ms,
        sample_game_id
      ) VALUES
      ''', batch);
    saved += batch.length;
    emit(
      LocalChessScanProgress(
        fraction: _treeSaveFraction(0.90, 0.94, saved, total),
        message: 'Saving tree moves... $saved of $total',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  for (final node in index.nodesById.values) {
    for (final move in node.moves) {
      rows.add(<Object?>[
        databaseId,
        node.id,
        move.uci,
        move.childNodeId,
        move.white,
        move.black,
        move.draws,
        move.total,
        move.lastPlayed?.millisecondsSinceEpoch,
        move.sampleGameId,
      ]);
      if (rows.length >= _kTreeMultiRowBindLimit ~/ 10) await flush();
    }
  }
  await flush();
}

Future<void> _executeMultiRowInsert(
  resqlite.Database db,
  String insertPrefix,
  List<List<Object?>> rows,
) async {
  if (rows.isEmpty) return;
  final columnCount = rows.first.length;
  final rowPlaceholders = '(${_sqlPlaceholders(columnCount)})';
  final sql =
      '$insertPrefix${List<String>.filled(rows.length, rowPlaceholders).join(',')}';
  await db.execute(sql, <Object?>[for (final row in rows) ...row]);
}

Future<void> _insertStagedPositionRefsInAutocommitBatches(
  resqlite.Database db,
  String databaseId, {
  required resqlite.Database positionRefStageDatabase,
  required void Function(LocalChessScanProgress progress) emit,
}) async {
  final countRows = await positionRefStageDatabase.select(
    'SELECT COUNT(*) AS count FROM $_localTreePositionRefStageTable',
  );
  final total = countRows.isEmpty ? 0 : _readInt(countRows.single['count']);
  var saved = 0;
  var lastSequence = 0;
  while (true) {
    final stagedRows = await positionRefStageDatabase.select(
      '''
      SELECT sequence, fen_key, game_id, ply, next_uci
      FROM $_localTreePositionRefStageTable
      WHERE sequence > ?
      ORDER BY sequence ASC
      LIMIT ?
      ''',
      <Object?>[lastSequence, _kPositionRefInsertBatchSize],
    );
    if (stagedRows.isEmpty) return;
    await db.executeBatch(
      '''
      INSERT OR REPLACE INTO $localChessPositionGamesTable(
        database_id,
        fen_key,
        fen,
        game_id,
        ply,
        next_uci
      ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      <List<Object?>>[
        for (final row in stagedRows)
          <Object?>[
            databaseId,
            row['fen_key'],
            row['fen_key'],
            row['game_id'],
            row['ply'],
            row['next_uci'],
          ],
      ],
    );
    lastSequence = _readInt(stagedRows.last['sequence']);
    saved += stagedRows.length;
    emit(
      LocalChessScanProgress(
        fraction: _treeSaveFraction(0.94, 0.99, saved, total),
        message: 'Saving position references... $saved of $total',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

double _treeSaveFraction(double start, double end, int completed, int total) {
  if (total <= 0) return end;
  final ratio = (completed / total).clamp(0.0, 1.0).toDouble();
  return start + ((end - start) * ratio);
}

class _LocalChessCacheMiss implements Exception {
  const _LocalChessCacheMiss();
}

class _CachedCombinedCacheInsertMismatch implements Exception {
  const _CachedCombinedCacheInsertMismatch();
}

enum _ImportedFilePreparation { reused, replacing }

String _databaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

Future<void> _refreshLocalChessDatabaseFileStat(
  resqlite.Database db, {
  required String databaseId,
  required int sizeBytes,
  required int modifiedAtMs,
  required String contentFingerprint,
}) async {
  await LocalChessDatabaseRepository._runLocalCacheWriteQueued(
    () => db.execute(
      '''
      UPDATE $localChessDatabasesTable
      SET size_bytes = ?,
          modified_at_ms = ?,
          content_fingerprint = ?
      WHERE id = ? AND deleted_at_ms IS NULL
      ''',
      <Object?>[sizeBytes, modifiedAtMs, contentFingerprint, databaseId],
    ),
  );
}

Future<void> _refreshLocalChessDatabaseFileStatIfUnchanged(
  resqlite.Database db, {
  required String databaseId,
  required int sizeBytes,
  required int modifiedAtMs,
  required String contentFingerprint,
  required int expectedSizeBytes,
  required int? expectedModifiedAtMs,
  required String expectedContentFingerprint,
}) async {
  await LocalChessDatabaseRepository._runLocalCacheWriteQueued(
    () => db.execute(
      '''
      UPDATE $localChessDatabasesTable
      SET size_bytes = ?,
          modified_at_ms = ?,
          content_fingerprint = ?
      WHERE id = ?
        AND deleted_at_ms IS NULL
        AND size_bytes = ?
        AND modified_at_ms IS ?
        AND content_fingerprint = ?
      ''',
      <Object?>[
        sizeBytes,
        modifiedAtMs,
        contentFingerprint,
        databaseId,
        expectedSizeBytes,
        expectedModifiedAtMs,
        expectedContentFingerprint,
      ],
    ),
  );
}

Future<String?> _databaseFilePath(resqlite.Database db) async {
  final rows = await db.select('PRAGMA database_list');
  for (final row in rows) {
    final name = row['name']?.toString();
    final file = row['file']?.toString();
    if (name == 'main' && file != null && file.trim().isNotEmpty) {
      return file;
    }
  }
  return null;
}

Future<void> _configureStandaloneLocalChessDatabase(
  resqlite.Database db,
) async {
  for (final statement in const <String>[
    'PRAGMA foreign_keys=ON',
    'PRAGMA journal_mode=WAL',
    'PRAGMA synchronous=NORMAL',
    'PRAGMA temp_store=MEMORY',
    'PRAGMA busy_timeout=20000',
    'PRAGMA cache_size=-65536',
  ]) {
    try {
      await db.execute(statement);
    } catch (_) {
      // Pragmas are performance hints here; a failed hint must not turn a
      // recoverable tree rebuild into a failed import.
    }
  }
}

Iterable<LocalOpeningTreeGameInput> _treeInputsForCachedGameRows({
  required List<Map<String, Object?>> rows,
  required int totalRows,
  required int processedOffset,
  required void Function(LocalChessScanProgress progress) onProgress,
}) sync* {
  var processed = processedOffset;
  final initialFenKey = playerOpeningTreeFenKey(Chess.initial.fen);
  for (final row in rows) {
    processed++;
    if (processed == 1 ||
        processed % _kTreeWorkerProgressGameInterval == 0 ||
        processed == totalRows) {
      final fraction =
          totalRows <= 0 ? 0.32 : 0.18 + ((processed / totalRows) * 0.64);
      onProgress(
        LocalChessScanProgress(
          fraction: fraction.clamp(0.18, 0.82).toDouble(),
          message:
              totalRows > 0
                  ? 'Building tree... $processed of $totalRows games'
                  : 'Building tree...',
        ),
      );
    }

    List<String> uciLine;
    Map<String, String> metadata;
    try {
      uciLine = _jsonList(row['moves'])
          .map((move) => move.toString().trim().toLowerCase())
          .where((move) => move.isNotEmpty)
          .toList(growable: false);
      metadata = _jsonMap(
        row['headers_json'],
      ).map((key, value) => MapEntry(key, value?.toString() ?? ''));
    } on FormatException {
      continue;
    }
    if (uciLine.isEmpty) continue;
    final variant = metadata['Variant']?.trim().toLowerCase() ?? '';
    if (variant.isNotEmpty &&
        variant != 'standard' &&
        variant != 'chess' &&
        variant != 'classical') {
      continue;
    }
    final declaredStartingFen = metadata['FEN']?.trim() ?? '';
    if (declaredStartingFen.isNotEmpty &&
        playerOpeningTreeFenKey(declaredStartingFen) != initialFenKey) {
      continue;
    }
    final storedStartingFen = row['fen']?.toString().trim() ?? '';
    if (storedStartingFen.isNotEmpty &&
        playerOpeningTreeFenKey(storedStartingFen) != initialFenKey) {
      continue;
    }
    final id = row['id']?.toString().trim() ?? '';
    final sourcePath = row['source_path']?.toString().trim() ?? '';
    final sourceRelativePath =
        row['source_relative_path']?.toString().trim() ?? '';
    final fileName = row['file_name']?.toString().trim() ?? '';
    if (id.isEmpty ||
        sourcePath.isEmpty ||
        sourceRelativePath.isEmpty ||
        fileName.isEmpty) {
      continue;
    }
    final indexInFile = _readInt(row['index_in_file'], fallback: -1);
    final fileGameCount = _readInt(row['file_game_count']);
    if (indexInFile < 0 || fileGameCount <= 0 || indexInFile >= fileGameCount) {
      continue;
    }
    yield LocalOpeningTreeGameInput(
      id: id,
      uciLine: uciLine,
      metadata: metadata,
      startingFen: storedStartingFen,
      sourcePath: sourcePath,
      sourceRelativePath: sourceRelativePath,
      fileName: fileName,
      indexInFile: indexInFile,
      fileGameCount: fileGameCount,
      sourceByteStart: _readNullableInt(row['source_byte_start']),
      sourceByteEnd: _readNullableInt(row['source_byte_end']),
    );
  }
}

int _treeMaxPlyForCachedRebuild({
  required int fileSizeBytes,
  required int gameCount,
}) {
  if (fileSizeBytes >= _kSingleWorkerTreeBuildBytes || gameCount >= 50000) {
    return localOpeningTreeLargeImportMaxPly;
  }
  return localOpeningTreeDefaultMaxPly;
}

Object _isolateErrorMessage(Object? message) {
  if (message is List && message.isNotEmpty) {
    final error = message.first;
    final stack = message.length > 1 ? message[1] : null;
    return StateError('$error\n$stack');
  }
  return StateError(message?.toString() ?? 'Local tree worker failed.');
}

Set<String> _normalizedCacheSourcePaths(Iterable<String> sourcePaths) =>
    <String>{
      for (final path in sourcePaths)
        if (path.trim().isNotEmpty) path.trim(),
    };

Set<String>? _normalizedOptionalCacheSourcePaths({
  String? sourcePath,
  Iterable<String>? sourcePaths,
}) {
  if (sourcePath == null && sourcePaths == null) return null;
  return _normalizedCacheSourcePaths(<String>[
    if (sourcePath != null) sourcePath,
    if (sourcePaths != null) ...sourcePaths,
  ]);
}

bool _cachePathBelongsToSource(String sourcePath, String cachedPath) {
  if (sourcePath.trim().isEmpty || cachedPath.trim().isEmpty) return false;
  final source = _databaseId(sourcePath);
  final cached = _databaseId(cachedPath);
  if (source == cached) return true;
  try {
    return p.isWithin(source, cached);
  } on Object {
    return false;
  }
}

String _rootPathFromRelativePath(String databasePath, String? relativePath) {
  final relative = relativePath?.trim();
  if (relative == null || relative.isEmpty) return p.dirname(databasePath);
  final relativeParts = p.split(p.normalize(relative));
  final databaseParts = p.split(p.normalize(databasePath));
  if (relativeParts.length >= databaseParts.length) {
    return p.dirname(databasePath);
  }
  return p.joinAll(
    databaseParts.take(databaseParts.length - relativeParts.length),
  );
}

LocalChessGame _localChessGameWithIdentity(LocalChessGame game, String id) {
  return LocalChessGame(
    id: id,
    game: game.game.copyWith(gameId: id),
    rawPgn: game.inlineRawPgn,
    sourcePath: game.sourcePath,
    sourceRelativePath: game.sourceRelativePath,
    fileName: game.fileName,
    indexInFile: game.indexInFile,
    fileGameCount: game.fileGameCount,
    hasMoves: game.hasMoves,
    moveLine: game.moveLine,
    pgnFingerprint: game.pgnFingerprint,
    sourceByteStart: game.sourceByteStart,
    sourceByteEnd: game.sourceByteEnd,
  );
}

String _rawPgnForRow(Map<String, Object?> row) {
  final inline = row['raw_pgn']?.toString() ?? '';
  if (inline.trim().isNotEmpty) return inline;
  final path = row['source_path']?.toString();
  final start = _readNullableInt(row['source_byte_start']);
  final end = _readNullableInt(row['source_byte_end']);
  if (path == null || path.isEmpty || start == null || end == null) return '';
  if (end <= start) return '';
  try {
    final raf = File(path).openSync();
    try {
      raf.setPositionSync(start);
      return utf8.decode(raf.readSync(end - start), allowMalformed: true);
    } finally {
      raf.closeSync();
    }
  } on Object {
    return '';
  }
}

Future<_PgnRewriteResult?> _rewritePgnFileFromCachedRows(
  String databasePath,
  List<Map<String, Object?>> rows,
) async {
  final buffer = StringBuffer();
  final spans = <_PgnRewriteSpan>[];
  var cursor = 0;
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final rawPgn = _rawPgnForRow(row).trim();
    if (rawPgn.isEmpty) return null;
    if (i > 0) {
      buffer.write('\n\n');
      cursor += 2;
    }
    final start = cursor;
    buffer.write(rawPgn);
    cursor += utf8.encode(rawPgn).length;
    spans.add(
      _PgnRewriteSpan(gameId: row['id'] as String, start: start, end: cursor),
    );
  }
  if (rows.isNotEmpty) {
    buffer.write('\n');
  }
  await File(databasePath).writeAsString(buffer.toString(), flush: true);
  return _PgnRewriteResult(spans);
}

Future<void> _subtractTreeDelta(
  resqlite.Transaction tx,
  String databaseId,
  PlayerOpeningTreeIndex index,
) async {
  if (index.nodesById.isEmpty) return;
  final fenKeys = index.nodesByFenKey.keys.toList(growable: false);
  final persistedNodeIdsByFen = <String, int>{};
  for (final chunk in _chunks(fenKeys, 800)) {
    final placeholders = List<String>.filled(chunk.length, '?').join(', ');
    final rows = await tx.select(
      '''
      SELECT fen_key, node_id
      FROM $localChessTreeNodesTable
      WHERE database_id = ? AND fen_key IN ($placeholders)
      ''',
      <Object?>[databaseId, ...chunk],
    );
    for (final row in rows) {
      final fenKey = row['fen_key']?.toString();
      if (fenKey == null || fenKey.isEmpty) continue;
      persistedNodeIdsByFen[fenKey] = _readInt(row['node_id']);
    }
  }

  final rows = <List<Object?>>[];
  for (final node in index.nodesById.values) {
    final persistedNodeId = persistedNodeIdsByFen[node.fenKey];
    if (persistedNodeId == null) continue;
    for (final move in node.moves) {
      rows.add(<Object?>[
        move.white,
        move.black,
        move.draws,
        move.total,
        databaseId,
        persistedNodeId,
        move.uci,
      ]);
    }
  }
  if (rows.isEmpty) return;
  await _executeBatchChunked(tx, '''
    UPDATE $localChessTreeMovesTable
    SET
      white = MAX(white - ?, 0),
      black = MAX(black - ?, 0),
      draws = MAX(draws - ?, 0),
      total = MAX(total - ?, 0)
    WHERE database_id = ? AND node_id = ? AND uci = ?
    ''', rows);
  await tx.execute(
    '''
    DELETE FROM $localChessTreeMovesTable
    WHERE database_id = ? AND total <= 0
    ''',
    <Object?>[databaseId],
  );
}

Future<void> _deleteUnreferencedTreeNodes(
  resqlite.Transaction tx,
  String databaseId,
) async {
  await tx.execute(
    '''
    DELETE FROM $localChessTreeNodesTable
    WHERE database_id = ?
      AND node_id <> 0
      AND node_id NOT IN (
        SELECT child_node_id
        FROM $localChessTreeMovesTable
        WHERE database_id = ?
      )
      AND node_id NOT IN (
        SELECT node_id
        FROM $localChessTreeMovesTable
        WHERE database_id = ?
      )
    ''',
    <Object?>[databaseId, databaseId, databaseId],
  );
}

class _PgnRewriteResult {
  const _PgnRewriteResult(this.spans);

  final List<_PgnRewriteSpan> spans;
}

class _PgnRewriteSpan {
  const _PgnRewriteSpan({
    required this.gameId,
    required this.start,
    required this.end,
  });

  final String gameId;
  final int start;
  final int end;
}

String _stableId(String value) => sha1.convert(utf8.encode(value)).toString();

String _localChessGameProjection(String alias) {
  final column = alias.isEmpty ? '' : '$alias.';
  return '''
        ${column}id AS id,
        ${column}database_id AS database_id,
        ${column}event_id AS event_id,
        ${column}site_id AS site_id,
        ${column}date AS date,
        ${column}utc_time AS utc_time,
        ${column}round AS round,
        ${column}white_id AS white_id,
        ${column}white_elo AS white_elo,
        ${column}black_id AS black_id,
        ${column}black_elo AS black_elo,
        ${column}white_material AS white_material,
        ${column}black_material AS black_material,
        ${column}result AS result,
        ${column}time_control AS time_control,
        ${column}eco AS eco,
        ${column}ply_count AS ply_count,
        ${column}fen AS fen,
        ${column}moves AS moves,
        ${column}pawn_home AS pawn_home,
        CASE
          WHEN ${column}source_byte_start IS NOT NULL
            AND ${column}source_byte_end IS NOT NULL
          THEN ''
          ELSE ${column}raw_pgn
        END AS raw_pgn,
        ${column}pgn_hash AS pgn_hash,
        ${column}headers_json AS headers_json,
        ${column}source_path AS source_path,
        ${column}source_relative_path AS source_relative_path,
        ${column}file_name AS file_name,
        ${column}index_in_file AS index_in_file,
        ${column}file_game_count AS file_game_count,
        ${column}has_moves AS has_moves,
        ${column}source_byte_start AS source_byte_start,
        ${column}source_byte_end AS source_byte_end
      ''';
}

void _appendLocalGameSearch(
  StringBuffer where,
  List<Object?> parameters,
  String rawSearch,
) {
  // Every whitespace-separated term must match somewhere (file name, path,
  // or any PGN header value), so "magnus carlsen", "carlsen 1-0", and
  // "gm berlin 2024" all narrow the way users expect.
  final terms = rawSearch
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty);
  for (final term in terms) {
    final like = '%${_escapeSqlLike(term)}%';
    where.write('''
    AND (
      LOWER(g.file_name) LIKE ? ESCAPE '\\'
      OR LOWER(g.source_relative_path) LIKE ? ESCAPE '\\'
      OR EXISTS (
        SELECT 1
        FROM json_each(g.headers_json) header
        WHERE LOWER(CAST(header.value AS TEXT)) LIKE ? ESCAPE '\\'
      )
    )
  ''');
    parameters.addAll(<Object?>[like, like, like]);
  }
}

void _appendLocalMovePrefixFilter(
  StringBuffer where,
  List<Object?> parameters,
  List<String> moves,
) {
  for (var i = 0; i < moves.length; i++) {
    where.write(
      " AND LOWER(TRIM(CAST(json_extract(g.moves, '\$[$i]') AS TEXT))) = ?",
    );
    parameters.add(moves[i]);
  }
}

String _escapeSqlLike(String value) {
  final out = StringBuffer();
  for (final codePoint in value.runes) {
    final char = String.fromCharCode(codePoint);
    if (char == r'\' || char == '%' || char == '_') {
      out.write(r'\');
    }
    out.write(char);
  }
  return out.toString();
}

String _localDatabaseGamesOrderBy(
  LocalChessGameSortField sortBy,
  LocalChessGameSortDirection sortDirection,
) {
  final direction =
      sortDirection == LocalChessGameSortDirection.asc ? 'ASC' : 'DESC';
  const stableTieBreak =
      'g.source_relative_path COLLATE NOCASE ASC, g.index_in_file ASC, g.id ASC';
  return switch (sortBy) {
    LocalChessGameSortField.originalOrder =>
      'g.source_relative_path COLLATE NOCASE $direction, '
          'g.index_in_file $direction, g.id $direction',
    LocalChessGameSortField.white =>
      '${_localTextSortExpression("COALESCE(wp.name, json_extract(g.headers_json, '\$.White'), '')", direction)}, $stableTieBreak',
    LocalChessGameSortField.whiteElo =>
      '${_localIntSortExpression('g.white_elo', direction)}, $stableTieBreak',
    LocalChessGameSortField.black =>
      '${_localTextSortExpression("COALESCE(bp.name, json_extract(g.headers_json, '\$.Black'), '')", direction)}, $stableTieBreak',
    LocalChessGameSortField.blackElo =>
      '${_localIntSortExpression('g.black_elo', direction)}, $stableTieBreak',
    LocalChessGameSortField.result =>
      '${_localTextSortExpression("COALESCE(g.result, '')", direction)}, '
          '$stableTieBreak',
    LocalChessGameSortField.eco =>
      '${_localTextSortExpression("COALESCE(g.eco, '')", direction)}, '
          '$stableTieBreak',
    LocalChessGameSortField.opening =>
      '${_localTextSortExpression("COALESCE(json_extract(g.headers_json, '\$.Opening'), '')", direction)}, $stableTieBreak',
    LocalChessGameSortField.event =>
      '${_localTextSortExpression("COALESCE(ev.name, json_extract(g.headers_json, '\$.Event'), '')", direction)}, $stableTieBreak',
    LocalChessGameSortField.date =>
      '${_localDateSortExpression("COALESCE(g.date, '')", direction)}, '
          '$stableTieBreak',
  };
}

String _localDateSortExpression(String expression, String direction) {
  final trimmed = 'TRIM($expression)';
  return '''
    CASE
      WHEN $trimmed = ''
        OR $trimmed = '?'
        OR $trimmed = '-'
        OR INSTR($trimmed, '?') > 0
        OR LENGTH($trimmed) < 4
        OR SUBSTR($trimmed, 1, 4) NOT GLOB '[0-9][0-9][0-9][0-9]'
        OR CAST(SUBSTR($trimmed, 1, 4) AS INTEGER) <= 0
      THEN 1
      ELSE 0
    END ASC,
    LOWER($trimmed) $direction
  ''';
}

String _localTextSortExpression(String expression, String direction) {
  final trimmed = 'TRIM($expression)';
  return '''
    CASE
      WHEN $trimmed = '' OR $trimmed = '?' OR $trimmed = '-' THEN 1
      ELSE 0
    END ASC,
    LOWER($trimmed) $direction
  ''';
}

String _localIntSortExpression(String expression, String direction) {
  return '''
    CASE WHEN $expression IS NULL THEN 1 ELSE 0 END ASC,
    $expression $direction
  ''';
}

void _appendLocalPositionFilters(
  StringBuffer where,
  List<Object?> parameters,
  PlayerOpeningTreeFilterCriteria filters,
) {
  final timeControl = filters.timeControl;
  if (timeControl != null) {
    if (timeControl == TimeControl.ultrabullet) {
      where.write(
        " AND LOWER(COALESCE(g.time_control_category, '')) "
        "IN ('ultrabullet', 'ultra_bullet', 'ultra-bullet', "
        "'ultra bullet')",
      );
    } else {
      where.write(" AND LOWER(COALESCE(g.time_control_category, '')) = ?");
      parameters.add(timeControl.name.toLowerCase());
    }
  }

  _appendLocalPlayerIdentityFilter(where, parameters, filters);

  final result = _sqlResultForFilter(filters.result);
  if (result != null) {
    where.write(' AND g.result = ?');
    parameters.add(result);
  } else if (filters.result?.trim().isNotEmpty == true) {
    where.write(' AND 0 = 1');
  }

  if (filters.isOnline != null) {
    where.write(' AND COALESCE(g.is_online, 0) = ?');
    parameters.add(filters.isOnline! ? 1 : 0);
  }

  final yearFrom = filters.yearFrom;
  if (yearFrom != null) {
    where.write(
      " AND CAST(substr(COALESCE(g.date, ''), 1, 4) AS INTEGER) >= ?",
    );
    parameters.add(yearFrom);
  }
  final yearTo = filters.yearTo;
  if (yearTo != null) {
    where.write(
      " AND CAST(substr(COALESCE(g.date, ''), 1, 4) AS INTEGER) <= ?",
    );
    parameters.add(yearTo);
  }

  final ratingExpression = _ratingSqlExpression(filters);
  if (filters.minRating != null || filters.maxRating != null) {
    if (filters.hasPlayerIdentityFilters &&
        filters.color?.trim().toLowerCase() != 'white' &&
        filters.color?.trim().toLowerCase() != 'black') {
      _appendLocalPlayerRatingFilter(where, parameters, filters);
      return;
    }
    where.write(' AND $ratingExpression > 0');
  }
  final minRating = filters.minRating;
  if (minRating != null) {
    where.write(' AND $ratingExpression >= ?');
    parameters.add(minRating);
  }
  final maxRating = filters.maxRating;
  if (maxRating != null) {
    where.write(' AND $ratingExpression <= ?');
    parameters.add(maxRating);
  }
}

void _appendLocalPlayerIdentityFilter(
  StringBuffer where,
  List<Object?> parameters,
  PlayerOpeningTreeFilterCriteria filters,
) {
  if (!filters.hasPlayerIdentityFilters) return;

  final sides = switch (filters.color?.trim().toLowerCase()) {
    'white' => const <String>['white'],
    'black' => const <String>['black'],
    _ => const <String>['white', 'black'],
  };
  final clauses = <String>[];

  for (final side in sides) {
    final clause = _localSidePlayerIdentityClause(side, filters, parameters);
    if (clause != null) clauses.add(clause);
  }

  if (clauses.isEmpty) {
    where.write(' AND 0 = 1');
    return;
  }
  where.write(' AND (${clauses.join(' OR ')})');
}

void _appendLocalPlayerRatingFilter(
  StringBuffer where,
  List<Object?> parameters,
  PlayerOpeningTreeFilterCriteria filters,
) {
  final minRating = filters.minRating;
  final maxRating = filters.maxRating;
  if (minRating == null && maxRating == null) return;

  final sideClauses = <String>[];
  for (final side in const <String>['white', 'black']) {
    final sideParams = <Object?>[];
    final identityClause = _localSidePlayerIdentityClause(
      side,
      filters,
      sideParams,
    );
    if (identityClause == null) continue;
    final eloColumn = side == 'white' ? 'g.white_elo' : 'g.black_elo';
    final ratingParts = <String>['($identityClause)', '$eloColumn > 0'];
    if (minRating != null) {
      ratingParts.add('$eloColumn >= ?');
      sideParams.add(minRating);
    }
    if (maxRating != null) {
      ratingParts.add('$eloColumn <= ?');
      sideParams.add(maxRating);
    }
    sideClauses.add('(${ratingParts.join(' AND ')})');
    parameters.addAll(sideParams);
  }

  if (sideClauses.isEmpty) {
    where.write(' AND 0 = 1');
    return;
  }
  where.write(' AND (${sideClauses.join(' OR ')})');
}

String? _localSidePlayerIdentityClause(
  String side,
  PlayerOpeningTreeFilterCriteria filters,
  List<Object?> parameters,
) {
  final rawIds = _normalizedFilterValues(<Object?>[
    filters.playerId,
    ...filters.playerIds,
  ]);
  final localNumericIds =
      rawIds.where((id) => int.tryParse(id) != null).toSet();
  final fideIds = <String>{
    ..._normalizedFilterValues(filters.playerFideIds),
    // Imported files sometimes expose FIDE ids as the only player id.
    ...rawIds.where((id) => int.tryParse(id) != null),
  };
  final names = _normalizedPlayerNames(filters.playerNames);

  final columnPrefix = side == 'white' ? 'white' : 'black';
  final jsonPrefix = side == 'white' ? 'White' : 'Black';
  final clauses = <String>[];
  if (localNumericIds.isNotEmpty) {
    clauses.add(
      'CAST(g.${columnPrefix}_id AS TEXT) IN (${_sqlPlaceholders(localNumericIds.length)})',
    );
    parameters.addAll(localNumericIds);
  }
  if (fideIds.isNotEmpty) {
    clauses.add(
      "LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.${jsonPrefix}FideId'), ''))) "
      'IN (${_sqlPlaceholders(fideIds.length)})',
    );
    parameters.addAll(fideIds);
  }
  if (names.isNotEmpty) {
    clauses.add(
      "LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.$jsonPrefix'), ''))) "
      'IN (${_sqlPlaceholders(names.length)})',
    );
    parameters.addAll(names);
  }
  if (clauses.isEmpty) return null;
  return '(${clauses.join(' OR ')})';
}

String _localPositionGamesSortExpression(GamebaseSortField sortBy) {
  return switch (sortBy) {
    GamebaseSortField.id => 'g.id',
    GamebaseSortField.date => "COALESCE(g.date, '')",
    GamebaseSortField.eco => "LOWER(COALESCE(g.eco, ''))",
    GamebaseSortField.opening =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.Opening'), ''))",
    GamebaseSortField.variation =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.Variation'), ''))",
    GamebaseSortField.event =>
      "LOWER(COALESCE(ev.name, json_extract(g.headers_json, '\$.Event'), ''))",
    GamebaseSortField.site =>
      "LOWER(COALESCE(st.name, json_extract(g.headers_json, '\$.Site'), ''))",
    GamebaseSortField.whiteName =>
      "LOWER(COALESCE(wp.name, json_extract(g.headers_json, '\$.White'), ''))",
    GamebaseSortField.blackName =>
      "LOWER(COALESCE(bp.name, json_extract(g.headers_json, '\$.Black'), ''))",
    GamebaseSortField.whiteTitle =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.WhiteTitle'), ''))",
    GamebaseSortField.blackTitle =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.BlackTitle'), ''))",
    GamebaseSortField.whiteFideId =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.WhiteFideId'), ''))",
    GamebaseSortField.blackFideId =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.BlackFideId'), ''))",
    GamebaseSortField.whiteElo => 'COALESCE(g.white_elo, 0)',
    GamebaseSortField.blackElo => 'COALESCE(g.black_elo, 0)',
    GamebaseSortField.whiteFed =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.WhiteFed'), json_extract(g.headers_json, '\$.WhiteFederation'), json_extract(g.headers_json, '\$.WhiteCountry'), ''))",
    GamebaseSortField.blackFed =>
      "LOWER(COALESCE(json_extract(g.headers_json, '\$.BlackFed'), json_extract(g.headers_json, '\$.BlackFederation'), json_extract(g.headers_json, '\$.BlackCountry'), ''))",
    GamebaseSortField.whitePlayerId => 'g.white_id',
    GamebaseSortField.blackPlayerId => 'g.black_id',
    GamebaseSortField.timeControl => "LOWER(COALESCE(g.time_control, ''))",
    GamebaseSortField.result => "COALESCE(g.result, '')",
    GamebaseSortField.avgElo => _averageRatingSqlExpression,
  };
}

String _ratingSqlExpression(PlayerOpeningTreeFilterCriteria filters) {
  return switch (filters.color?.trim().toLowerCase()) {
    'white' => 'COALESCE(g.white_elo, 0)',
    'black' => 'COALESCE(g.black_elo, 0)',
    _ => _averageRatingSqlExpression,
  };
}

const String _averageRatingSqlExpression = '''
  CASE
    WHEN COALESCE(g.white_elo, 0) <= 0 THEN COALESCE(g.black_elo, 0)
    WHEN COALESCE(g.black_elo, 0) <= 0 THEN COALESCE(g.white_elo, 0)
    ELSE ROUND((g.white_elo + g.black_elo) / 2.0)
  END
''';

String? _sqlResultForFilter(String? raw) {
  switch (raw?.trim().toUpperCase()) {
    case 'W':
    case '1-0':
      return '1-0';
    case 'B':
    case '0-1':
      return '0-1';
    case 'D':
    case '1/2-1/2':
    case '½-½':
      return '1/2-1/2';
  }
  return null;
}

String? _nextUciForPositionRef(Map<String, dynamic>? row, int ply) {
  final line = _lineFromRow(row);
  if (ply < 0 || ply >= line.length) return null;
  final next = line[ply].trim().toLowerCase();
  return next.isEmpty ? null : next;
}

String _relative(String rootPath, String path) {
  try {
    final relative = p.relative(path, from: rootPath);
    return relative == '.' ? '' : relative;
  } catch (_) {
    return path;
  }
}

void _sortNodes(List<LocalChessNode> nodes) {
  nodes.sort((a, b) {
    final af = a is LocalChessFolderNode;
    final bf = b is LocalChessFolderNode;
    if (af != bf) return af ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

LocalChessFolderNode _freshFolderTreeFromFiles({
  required String directoryPath,
  required String rootPath,
  required List<LocalChessFileNode> files,
}) {
  final children = <LocalChessNode>[];
  final nestedFiles = <String, List<LocalChessFileNode>>{};
  for (final file in files) {
    final relative = p.relative(file.path, from: directoryPath);
    final parts = p.split(relative);
    if (parts.length <= 1) {
      children.add(file);
      continue;
    }
    final childDirectory = p.join(directoryPath, parts.first);
    (nestedFiles[childDirectory] ??= <LocalChessFileNode>[]).add(file);
  }
  for (final entry in nestedFiles.entries) {
    children.add(
      _freshFolderTreeFromFiles(
        directoryPath: entry.key,
        rootPath: rootPath,
        files: entry.value,
      ),
    );
  }
  _sortNodes(children);
  return LocalChessFolderNode.fromChildren(
    name: localChessDatabaseDisplayNameForPath(directoryPath),
    path: directoryPath,
    relativePath: _relative(rootPath, directoryPath),
    children: children,
  );
}

void _addNormalizedName(Set<String> names, Object? value) {
  final name = _normalizedName(value?.toString());
  if (name != null) names.add(name);
}

Future<void> _insertOrReplace(
  resqlite.Transaction txn,
  String table,
  Map<String, Object?> row,
) async {
  await _insertOrReplaceBatch(txn, table, <Map<String, Object?>>[row]);
}

Future<void> _insertOrReplaceBatch(
  resqlite.Transaction txn,
  String table,
  List<Map<String, Object?>> rows,
) async {
  if (rows.isEmpty) return;
  final columns = rows.first.keys.toList(growable: false);
  final placeholders = List<String>.filled(columns.length, '?').join(', ');
  final sql =
      'INSERT OR REPLACE INTO $table(${columns.join(', ')}) '
      'VALUES ($placeholders)';
  for (final chunk in _chunks(rows, _kSqlWriteBatchSize)) {
    await txn.executeBatch(sql, <List<Object?>>[
      for (final row in chunk)
        <Object?>[for (final column in columns) row[column]],
    ]);
    await _yieldAfterSqlBatch();
  }
}

Future<void> _upsertLocalChessDatabaseRow(
  resqlite.Transaction txn,
  Map<String, Object?> row,
) async {
  final columns = row.keys.toList(growable: false);
  final placeholders = List<String>.filled(columns.length, '?').join(', ');
  final updates = columns
      .where((column) => column != 'id')
      .map((column) => '$column = excluded.$column')
      .join(', ');
  await txn.execute(
    '''
    INSERT INTO $localChessDatabasesTable(${columns.join(', ')})
    VALUES ($placeholders)
    ON CONFLICT(id) DO UPDATE SET $updates
    ''',
    <Object?>[for (final column in columns) row[column]],
  );
}

Future<void> _executeBatchChunked(
  resqlite.Transaction txn,
  String sql,
  List<List<Object?>> rows, {
  int size = _kSqlWriteBatchSize,
}) async {
  if (rows.isEmpty) return;
  for (final chunk in _chunks(rows, size)) {
    await txn.executeBatch(sql, chunk);
    await _yieldAfterSqlBatch();
  }
}

Future<void> _yieldAfterSqlBatch() => Future<void>.delayed(Duration.zero);

Iterable<List<T>> _chunks<T>(List<T> values, int size) sync* {
  for (var start = 0; start < values.length; start += size) {
    final end = start + size > values.length ? values.length : start + size;
    yield values.sublist(start, end);
  }
}

String _sqlPlaceholders(int count) =>
    List<String>.filled(count, '?').join(', ');

Set<String> _normalizedFilterValues(Iterable<Object?> values) {
  return {
    for (final value in values)
      if (value?.toString().trim().isNotEmpty == true)
        value!.toString().trim().toLowerCase(),
  };
}

Set<String> _normalizedPlayerNames(Iterable<Object?> values) {
  return {
    for (final value in values)
      if (_normalizePlayerName(value?.toString()) case final normalized?)
        normalized,
  };
}

String? _normalizePlayerName(String? value) {
  final raw = value?.trim().toLowerCase();
  if (raw == null || raw.isEmpty || raw == '?') return null;
  return raw.replaceAll(RegExp(r'\s+'), ' ');
}

String? _localGameTimeControlCategory({
  Object? timeControl,
  Object? headersJson,
  Map<String, dynamic>? metadata,
  Object? storedCategory,
}) {
  final data = metadata ?? _jsonMap(headersJson);
  final category = classifyTimeControlCategory(
    timeControl,
    event: data['Event'],
    site: data['Site'],
    source: data['ChessEverSource'],
  );
  if (category != null) return category;
  return classifyPgnTimeControlCategory(data['ChessEverTimeControlCategory']) ??
      classifyPgnTimeControlCategory(storedCategory) ??
      'unknown';
}

Map<String, dynamic> _metadataWithCanonicalOpening(
  Map<String, dynamic> metadata,
  Object? eco,
) {
  final opening = metadata['Opening']?.toString().trim();
  final normalized = opening?.toLowerCase();
  final needsFallback =
      normalized == null ||
      normalized.isEmpty ||
      normalized == '?' ||
      normalized == '-' ||
      normalized == 'unknown' ||
      normalized == 'unknown opening';
  if (!needsFallback) return metadata;
  final fallback = EcoOpenings.getOpeningName(eco?.toString());
  if (fallback == null || fallback.isEmpty) return metadata;
  return Map<String, dynamic>.of(metadata)..['Opening'] = fallback;
}

bool _inferLocalGameIsOnline({
  Object? timeControl,
  Object? headersJson,
  Map<String, dynamic>? metadata,
  String? sourcePath,
  String? fileName,
}) {
  final data = metadata ?? _jsonMap(headersJson);
  final haystack =
      <String>[
        for (final key in const <String>[
          'Site',
          'Event',
          'Source',
          'ChessEverSource',
          'Annotator',
          'WhiteTeam',
          'BlackTeam',
        ])
          data[key]?.toString() ?? '',
        timeControl?.toString() ?? '',
        sourcePath ?? '',
        fileName ?? '',
      ].join(' ').toLowerCase();

  if (haystack.contains('lichess') ||
      haystack.contains('chess.com') ||
      haystack.contains('chess24') ||
      haystack.contains('playchess') ||
      haystack.contains('fics') ||
      haystack.contains('internet chess club') ||
      haystack.contains('chessclub.com') ||
      haystack.contains('tornelo') ||
      haystack.contains('online')) {
    return true;
  }
  return false;
}

String _extensionForPath(String path) {
  final lower = path.toLowerCase();
  for (final extension in localChessSupportedExtensions) {
    if (lower.endsWith(extension)) return extension;
  }
  return p.extension(path).toLowerCase();
}

String? _normalizedName(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == '?') return null;
  return trimmed;
}

String _normalizePlayerAliasForStats(String? value) {
  return (value ?? '')
      .toLowerCase()
      .replaceAll(RegExp(r'[\s,._-]+'), '')
      .trim();
}

/// SQL expression that normalizes [column] the same way
/// [_normalizePlayerAliasForStats] normalizes a Dart string: lower-cased with
/// every whitespace character and `, . _ -` separator stripped, so
/// "Carlsen, Magnus" and "magnus carlsen" compare equal. Kept in lockstep with
/// the regex above (`[\s,._-]`, where `\s` is space/tab/LF/VT/FF/CR) so the
/// in-SQL alias match in [LocalChessDatabaseRepository.resultStatsForDatabases]
/// stays byte-identical to the old on-isolate comparison.
String _statsNameNormalizationSql(String column) {
  const separators = <String>[
    "' '",
    'char(9)',
    'char(10)',
    'char(11)',
    'char(12)',
    'char(13)',
    "','",
    "'.'",
    "'_'",
    "'-'",
  ];
  var expression = "LOWER(COALESCE($column, ''))";
  for (final separator in separators) {
    expression = "REPLACE($expression, $separator, '')";
  }
  return expression;
}

String? _normalizeFideIdForStats(Object? value) {
  final clean = value?.toString().trim().toLowerCase();
  if (clean == null || clean.isEmpty) return null;
  return clean;
}

String _firstMetadata(Map<String, dynamic> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key]?.toString().trim() ?? '';
    if (value.isNotEmpty && value != '?') return value;
  }
  return '';
}

int? _rating(Object? raw) {
  final value = int.tryParse(raw?.toString() ?? '');
  return value == null || value <= 0 ? null : value;
}

int _readInt(Object? raw, {int fallback = 0}) {
  return _readNullableInt(raw) ?? fallback;
}

int? _readNullableInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

DateTime? _dateFromMillis(Object? raw) {
  final ms = _readNullableInt(raw);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

DateTime? _dateFromLocalDate(Object? raw) {
  final text = raw?.toString().trim();
  if (text == null || text.isEmpty || text == '?' || text == '-') return null;
  return DateTime.tryParse(text.replaceAll('.', '-'));
}

List<String> _lineFromRow(Map<String, dynamic>? row) {
  final raw = row?['line'];
  if (raw is! List) return const <String>[];
  return raw
      .map((move) => move.toString().trim().toLowerCase())
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
}

List<String> _lineFromLocalGame(LocalChessGame game) {
  final inlineLine = _inlineLineFromLocalGame(game);
  if (inlineLine.isNotEmpty) return inlineLine;

  final rawPgn = game.rawPgn.trim();
  if (rawPgn.isEmpty) return const <String>[];
  try {
    return ChessGame.fromPgn(game.id, rawPgn).mainline
        .map((move) => move.uci.trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}

List<String> _inlineLineFromLocalGame(LocalChessGame game) {
  if (game.moveLine.isNotEmpty) return game.moveLine;
  return game.game.mainline
      .map((move) => move.uci.trim().toLowerCase())
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
}

Map<String, dynamic> _jsonMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is! String || raw.trim().isEmpty) return <String, dynamic>{};
  final decoded = jsonDecode(raw);
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return <String, dynamic>{};
}

List<dynamic> _jsonList(Object? raw) {
  if (raw is List) return raw;
  if (raw is! String || raw.trim().isEmpty) return const <dynamic>[];
  final decoded = jsonDecode(raw);
  return decoded is List ? decoded : const <dynamic>[];
}

Map<String, String> _stringMap(Object? raw) {
  final map = _jsonMap(raw);
  return map.map((key, value) => MapEntry(key, value.toString()));
}

Map<String, List<int>> _nagsMap(Object? raw) {
  final map = _jsonMap(raw);
  return map.map((key, value) {
    if (value is List) {
      return MapEntry(
        key,
        value.map((item) => _readInt(item)).toList(growable: false),
      );
    }
    return MapEntry(key, const <int>[]);
  });
}

String _fallback(String value, String fallback) {
  final trimmed = value.trim();
  return trimmed.isEmpty || trimmed == '?' ? fallback : trimmed;
}
