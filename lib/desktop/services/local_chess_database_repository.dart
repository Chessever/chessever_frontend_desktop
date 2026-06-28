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
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/models/models.dart';

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
    final opened = _database;
    if (opened != null) return opened;

    final pending = _initCompleter;
    if (pending != null) return pending.future;

    final completer = _initCompleter = Completer<resqlite.Database>();
    try {
      final db = await _open();
      _database = db;
      completer.complete(db);
      return db;
    } catch (error) {
      completer.completeError(error);
      completer.future.ignore();
      _initCompleter = null;
      rethrow;
    }
  }

  Future<resqlite.Database> openDedicatedConnection() async {
    final path = await _resolvePath();
    final db = await resqlite.Database.open(path);
    await _configure(db);
    return db;
  }

  Future<String> get path async => _resolvePath();

  Future<resqlite.Database> _open() async {
    final path = await _resolvePath();
    final purgedForDevelopment = await _maybePurgeDevelopmentCacheOnOpen(path);
    final db = await resqlite.Database.open(path);
    await _configure(db);
    await createLocalChessResqliteDatabaseSchema(db);
    if (purgedForDevelopment) {
      localChessLog.warning(
        'Skipping legacy sqflite local chess migration for development purge',
        context: <String, Object?>{'path': path},
      );
    } else {
      await migrateLegacyLocalChessSqfliteCache(db);
    }
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
    await _executePragmaSafe(db, 'PRAGMA busy_timeout=2000');
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
    if (kReleaseMode) return false;
    final flagFile = File(
      p.join(p.dirname(dbPath), localChessDevelopmentPurgeFlagFileName),
    );
    final shouldPurge = shouldPurgeLocalChessResqliteCacheForDevelopment(
      isReleaseMode: kReleaseMode,
      dartDefineEnabled: const bool.fromEnvironment(
        _localChessDevelopmentPurgeEnv,
      ),
      environmentValue: Platform.environment[_localChessDevelopmentPurgeEnv],
      flagFileExists: await flagFile.exists(),
    );
    if (!shouldPurge) return false;
    if (_didApplyDevelopmentPurge) return true;

    _didApplyDevelopmentPurge = true;
    final deleted = await deleteLocalChessResqliteCacheFilesAt(dbPath);
    localChessLog.warning(
      'Purged local chess resqlite cache for development startup',
      context: <String, Object?>{
        'deletedFiles': deleted,
        'path': dbPath,
        'flag': flagFile.path,
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

@visibleForTesting
bool shouldPurgeLocalChessResqliteCacheForDevelopment({
  required bool isReleaseMode,
  required bool dartDefineEnabled,
  required String? environmentValue,
  required bool flagFileExists,
}) {
  if (isReleaseMode) return false;
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
const int _kEagerPositionRefLoadLimit = 250000;
const int _kEagerTreeMoveLoadLimit = 250000;
const int _kCachedFileNodeGamePreviewLimit = 1000;
const int _kPersistedTreeGameRowLimit = 10000;
const int _kPersistedPositionGameRefLimit = 10000;
const int _kTreeWorkerProgressGameInterval = 512;
const int _kCachedTreeRebuildPageSize = 2048;
const int _kSingleWorkerTreeBuildBytes = 128 * 1024 * 1024;
const int _kLegacyMigrationGamePageSize = 256;
const int _kLegacyMigrationRowPageSize = 4096;
const String _legacySqfliteMigrationName = 'legacy_sqflite_local_chess_v1';
const String _localChessMigrationsTable = 'local_chess_migrations';
const String _localChessCacheGenerationName =
    'local_chess_resqlite_cache_generation_20260628_safe_streaming_v1';
const String _localChessTreeDepthGenerationName =
    'local_chess_tree_depth_50_v1';

Future<void> createLocalChessResqliteDatabaseSchema(
  resqlite.Database db,
) async {
  await db.transaction((tx) async {
    for (final statement in _localChessSchemaStatements) {
      await tx.execute(statement);
    }
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

Future<void> _ensureLocalChessTreeDepthGeneration(
  resqlite.Transaction tx,
) async {
  final markerRows = await tx.select(
    'SELECT 1 FROM $_localChessMigrationsTable WHERE name = ? LIMIT 1',
    const <Object?>[_localChessTreeDepthGenerationName],
  );
  if (markerRows.isNotEmpty) return;

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
  Future<sqflite.Database> Function()? legacyDatabase,
}) async {
  try {
    if (await _hasMigrationMarker(target, _legacySqfliteMigrationName)) {
      return;
    }
    if (await _targetHasLocalChessData(target)) {
      await _markMigration(target, _legacySqfliteMigrationName);
      return;
    }

    final legacy =
        await (legacyDatabase?.call() ?? AppDatabase.instance.database);
    if (!await _legacyTableExists(legacy, localChessDatabasesTable)) {
      await _markMigration(target, _legacySqfliteMigrationName);
      return;
    }
    final legacyCountRows = await legacy.rawQuery(
      'SELECT COUNT(*) AS count FROM $localChessDatabasesTable',
    );
    if (_readInt(legacyCountRows.single['count']) <= 0) {
      await _markMigration(target, _legacySqfliteMigrationName);
      return;
    }
    final legacyDatabaseCount = _readInt(legacyCountRows.single['count']);
    localChessLog.info(
      'Legacy sqflite local chess migration started',
      context: <String, Object?>{'databases': legacyDatabaseCount},
    );

    final gameColumns = await _legacyColumnNames(legacy, localChessGamesTable);
    final positionColumns = await _legacyColumnNames(
      legacy,
      localChessPositionGamesTable,
    );

    await target.transaction((tx) async {
      await _copyLegacyTable(tx, legacy, localChessDatabasesTable);
      await _copyLegacyTable(tx, legacy, localChessPlayersTable);
      await _copyLegacyTable(tx, legacy, localChessEventsTable);
      await _copyLegacyTable(tx, legacy, localChessSitesTable);
      await _copyLegacyGames(tx, legacy, gameColumns);
      await _copyLegacyTable(tx, legacy, localChessTreeNodesTable);
      await _copyLegacyTable(tx, legacy, localChessTreeMovesTable);
      await _copyLegacyPositionGames(tx, legacy, positionColumns);
      await _copyLegacyTable(tx, legacy, localChessGameAnalysisTable);
      await _backfillPositionGameNextUci(tx);
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
    localChessLog.info(
      'Legacy sqflite local chess migration finished',
      context: <String, Object?>{'databases': legacyDatabaseCount},
    );
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
  String table,
) async {
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
    if (rows.length < _kLegacyMigrationRowPageSize) return;
    offset += rows.length;
    await _yieldAfterSqlBatch();
  }
}

Future<void> _copyLegacyGames(
  resqlite.Transaction tx,
  sqflite.Database legacy,
  Set<String> legacyColumns,
) async {
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
    if (rows.length < _kLegacyMigrationGamePageSize) return;
    offset += rows.length;
    await _yieldAfterSqlBatch();
  }
}

Future<void> _copyLegacyPositionGames(
  resqlite.Transaction tx,
  sqflite.Database legacy,
  Set<String> legacyColumns,
) async {
  if (!await _legacyTableExists(legacy, localChessPositionGamesTable)) return;
  var offset = 0;
  while (true) {
    final rows = await legacy.query(
      localChessPositionGamesTable,
      orderBy: 'rowid ASC',
      limit: _kLegacyMigrationRowPageSize,
      offset: offset,
    );
    if (rows.isEmpty) return;
    await _insertOrReplaceBatch(
      tx,
      localChessPositionGamesTable,
      rows
          .map(
            (row) => <String, Object?>{
              'database_id': row['database_id'],
              'fen_key': row['fen_key'],
              'fen': row['fen'],
              'game_id': row['game_id'],
              'ply': row['ply'],
              'next_uci':
                  legacyColumns.contains('next_uci') ? row['next_uci'] : null,
            },
          )
          .toList(growable: false),
    );
    if (rows.length < _kLegacyMigrationRowPageSize) return;
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
      deleted_at_ms INTEGER
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
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_white_elo ON $localChessGamesTable(white_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_black_elo ON $localChessGamesTable(black_elo)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_plycount ON $localChessGamesTable(ply_count)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_games_eco ON $localChessGamesTable(database_id, eco)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_tree_nodes_fen ON $localChessTreeNodesTable(database_id, fen_key)',
  'CREATE INDEX IF NOT EXISTS idx_local_chess_tree_moves_total ON $localChessTreeMovesTable(database_id, node_id, total DESC)',
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

class _LocalChessImportWorkerRequest {
  const _LocalChessImportWorkerRequest({
    required this.sendPort,
    required this.databaseFilePath,
    required this.path,
    required this.sourceLabel,
    required this.previewGameLimit,
  });

  final SendPort sendPort;
  final String databaseFilePath;
  final String path;
  final String? sourceLabel;
  final int previewGameLimit;
}

class _LocalChessImportWorkerSuccess {
  const _LocalChessImportWorkerSuccess(this.source);

  final LocalChessSource source;
}

class _LocalChessImportWorkerFailure {
  const _LocalChessImportWorkerFailure(this.message, this.stackTrace);

  final String message;
  final String stackTrace;
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

class LocalChessDatabaseRepository {
  LocalChessDatabaseRepository({
    required Future<resqlite.Database> Function() database,
    Future<resqlite.Database> Function()? purgeDatabase,
    this.eagerPositionRefLoadLimit = _kEagerPositionRefLoadLimit,
    this.eagerTreeMoveLoadLimit = _kEagerTreeMoveLoadLimit,
    this.cachedFileNodeGamePreviewLimit = _kCachedFileNodeGamePreviewLimit,
  }) : _database = database,
       _purgeDatabase = purgeDatabase;

  final Future<resqlite.Database> Function() _database;
  final Future<resqlite.Database> Function()? _purgeDatabase;
  final int eagerPositionRefLoadLimit;
  final int eagerTreeMoveLoadLimit;
  final int cachedFileNodeGamePreviewLimit;

  static Future<void> _singleFileImportQueue = Future<void>.value();
  static final Map<String, Future<LocalChessSource?>> _singleFileImportsByPath =
      <String, Future<LocalChessSource?>>{};
  static Future<void> _backgroundPurgeQueue = Future<void>.value();
  final Set<String> _reusedImportedGameRows = <String>{};

  Future<void> persistSource(LocalChessSource source) async {
    for (final file in _playableFiles(source.root)) {
      await persistFileNode(file, sourceLabel: source.label);
    }
  }

  Future<void> persistFileNode(
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    if (file.isPlayable && file.games.length < file.gameCount) {
      throw StateError(
        'Refusing to persist partial local chess preview for ${file.path}: '
        '${file.games.length} of ${file.gameCount} games are loaded.',
      );
    }
    final db = await _database();
    await db.transaction((txn) async {
      if (!file.isPlayable) {
        await _deleteFileCache(txn, file.path);
        return;
      }
      await _replaceFileNode(txn, file, sourceLabel: sourceLabel);
    });
  }

  Future<LocalChessSource?> importSingleFileSource({
    required String path,
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final type = await FileSystemEntity.type(trimmed, followLinks: false);
    if (type != FileSystemEntityType.file ||
        !looksLikeLocalChessFile(trimmed)) {
      return null;
    }
    final importKey = _databaseId(trimmed);
    final existingImport = _singleFileImportsByPath[importKey];
    if (existingImport != null) {
      localChessLog.info(
        'PGN import joined existing worker',
        context: <String, Object?>{'path': trimmed},
      );
      return existingImport;
    }

    late final Future<LocalChessSource?> importFuture;
    importFuture = _runSingleFileImportQueued(
      () => _importSingleFileSourceUnlocked(
        path: trimmed,
        sourceLabel: sourceLabel,
        onProgress: onProgress,
      ),
    );
    _singleFileImportsByPath[importKey] = importFuture;
    try {
      return await importFuture;
    } finally {
      if (identical(_singleFileImportsByPath[importKey], importFuture)) {
        _singleFileImportsByPath.remove(importKey);
      }
    }
  }

  Future<LocalChessSource?> _importSingleFileSourceUnlocked({
    required String path,
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final trimmed = path.trim();
    final importStopwatch = Stopwatch()..start();
    int? fileSizeBytes;
    try {
      fileSizeBytes = await File(trimmed).length();
    } on Object {
      fileSizeBytes = null;
    }
    localChessLog.info(
      'PGN import started',
      context: <String, Object?>{
        'path': trimmed,
        'bytes': fileSizeBytes,
        'label': sourceLabel,
      },
    );

    final db = await _database();
    final databaseFilePath = await _databaseFilePath(db);
    if (databaseFilePath == null || databaseFilePath.trim().isEmpty) {
      return null;
    }

    final receivePort = ReceivePort();
    final completer = Completer<LocalChessSource>();
    late final StreamSubscription<dynamic> subscription;
    Isolate? isolate;

    void completeWithError(Object error, StackTrace stackTrace) {
      if (completer.isCompleted) return;
      completer.completeError(error, stackTrace);
    }

    subscription = receivePort.listen((message) {
      switch (message) {
        case LocalChessScanProgress progress:
          onProgress?.call(progress);
        case _LocalChessImportWorkerSuccess(:final source):
          if (!completer.isCompleted) completer.complete(source);
        case _LocalChessImportWorkerFailure(:final message, :final stackTrace):
          completeWithError(
            StateError(message),
            StackTrace.fromString(stackTrace),
          );
        case null:
          if (!completer.isCompleted) {
            completeWithError(
              StateError('PGN import worker exited before returning a result.'),
              StackTrace.current,
            );
          }
      }
    });

    try {
      isolate = await Isolate.spawn(
        _importSingleLocalChessFileWorker,
        _LocalChessImportWorkerRequest(
          sendPort: receivePort.sendPort,
          databaseFilePath: databaseFilePath,
          path: trimmed,
          sourceLabel: sourceLabel,
          previewGameLimit: cachedFileNodeGamePreviewLimit,
        ),
        onExit: receivePort.sendPort,
        errorsAreFatal: true,
      );
      final source = await completer.future;
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
      completeWithError(error, stackTrace);
      importStopwatch.stop();
      localChessLog.error(
        'PGN import failed',
        error,
        stackTrace,
        tag: 'local_chess.import',
        context: <String, Object?>{
          'path': trimmed,
          'elapsedMs': importStopwatch.elapsedMilliseconds,
          'bytes': fileSizeBytes,
        },
      );
      rethrow;
    } finally {
      receivePort.close();
      await subscription.cancel();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  static Future<T> _runSingleFileImportQueued<T>(
    Future<T> Function() action,
  ) async {
    final previous = _singleFileImportQueue;
    final current = Completer<void>();
    _singleFileImportQueue = current.future;
    try {
      try {
        await previous;
      } catch (_) {
        // Earlier import failures must not permanently poison the writer queue.
      }
      return await action();
    } finally {
      if (!current.isCompleted) current.complete();
    }
  }

  Future<bool> persistOpeningTreeIndex({
    required String databasePath,
    required PlayerOpeningTreeIndex index,
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
    if (databaseRows.isEmpty) return false;

    await db.transaction((txn) async {
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
  }) async {
    final stopwatch = Stopwatch()..start();
    localChessLog.info(
      'Local tree rebuild started',
      context: <String, Object?>{'path': databasePath},
    );
    final db = await _database();
    final databaseFilePath = await _databaseFilePath(db);
    if (databaseFilePath == null || databaseFilePath.isEmpty) {
      throw StateError('Local chess database file path is unavailable.');
    }

    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    Isolate? isolate;
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
      if (errorDone.isCompleted) throw await errorDone.future;
      return null;
    } catch (error, stackTrace) {
      stopwatch.stop();
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
    final marked = await markCachedSourceDeleted(path);
    if (marked == 0) return 0;
    await purgeDeletedCaches(sourcePath: path, onProgress: onProgress);
    return marked;
  }

  Future<int> markCachedSourceDeleted(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return 0;
    final stopwatch = Stopwatch()..start();
    localChessLog.info(
      'Local database delete mark started',
      context: <String, Object?>{'path': trimmed},
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
          if (_cachePathBelongsToSource(trimmed, row['path']?.toString() ?? ''))
            row['id'] as String,
      ];
      if (databaseIds.isEmpty) {
        stopwatch.stop();
        localChessLog.info(
          'Local database delete mark skipped',
          context: <String, Object?>{
            'path': trimmed,
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
          'path': trimmed,
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
          'path': trimmed,
          'elapsedMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    }
  }

  Future<int> deletedCacheCount() async {
    final db = await _database();
    final rows = await db.select('''
      SELECT COUNT(*) AS count
      FROM $localChessDatabasesTable
      WHERE deleted_at_ms IS NOT NULL
      ''');
    return rows.isEmpty ? 0 : _readInt(rows.single['count']);
  }

  Future<int> purgeDeletedCaches({
    String? sourcePath,
    int batchSize = 1024,
    bool cleanupOrphanMetadata = true,
    bool checkpoint = true,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final trimmedSourcePath = sourcePath?.trim();
    resqlite.Database? dedicatedDb;
    try {
      onProgress?.call(
        LocalChessScanProgress(fraction: 0, message: 'Preparing delete...'),
      );
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
      final rows =
          trimmedSourcePath == null || trimmedSourcePath.isEmpty
              ? allRows
              : <Map<String, Object?>>[
                for (final row in allRows)
                  if (_cachePathBelongsToSource(
                    trimmedSourcePath,
                    row['path']?.toString() ?? '',
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
          'batchSize': batchSize,
          'cleanupOrphanMetadata': cleanupOrphanMetadata,
          'checkpoint': checkpoint,
          'dedicatedConnection': dedicatedDb != null,
          if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
            'sourcePath': trimmedSourcePath,
        },
      );
      final unitCounts = <String, int>{};
      var totalUnits = 0;
      for (final row in rows) {
        final databaseId = row['id']?.toString() ?? '';
        if (databaseId.isEmpty) continue;
        final units = await _databasePurgeUnitCount(db, databaseId);
        unitCounts[databaseId] = units;
        totalUnits += units;
      }
      if (totalUnits <= 0) totalUnits = rows.length;
      var completedUnits = 0;
      var lastProgressEmitUnits = -1;

      void emitProgress(String message, {bool force = false}) {
        if (onProgress == null) return;
        if (!force && completedUnits == lastProgressEmitUnits) return;
        lastProgressEmitUnits = completedUnits;
        final fraction =
            totalUnits <= 0
                ? 0.98
                : (completedUnits / totalUnits).clamp(0.0, 0.98).toDouble();
        onProgress(
          LocalChessScanProgress(fraction: fraction, message: message),
        );
      }

      emitProgress('Cleaning generated local cache...', force: true);
      var purged = 0;
      for (final row in rows) {
        final databaseId = row['id']?.toString() ?? '';
        if (databaseId.isEmpty) continue;
        final perDatabase = Stopwatch()..start();
        try {
          final removed = await _purgeDeletedDatabaseCache(
            db,
            databaseId,
            batchSize: batchSize,
            onDeletedRows: (table, deletedRows) {
              completedUnits += deletedRows;
              final tableLabel = _localChessPurgeTableLabel(table);
              final shouldEmit =
                  completedUnits == totalUnits ||
                  completedUnits - lastProgressEmitUnits >= batchSize * 8;
              if (shouldEmit) {
                emitProgress('Deleting $tableLabel...');
              }
            },
          );
          if (removed) purged += 1;
          if (checkpoint) {
            await _checkpointLocalChessCacheBestEffort(db);
          }
          perDatabase.stop();
          localChessLog.info(
            'Local database purge item finished',
            context: <String, Object?>{
              'databaseId': databaseId,
              'removed': removed,
              'rows': unitCounts[databaseId],
              'elapsedMs': perDatabase.elapsedMilliseconds,
            },
          );
        } catch (error, stackTrace) {
          perDatabase.stop();
          localChessLog.error(
            'Local database purge item failed',
            error,
            stackTrace,
            tag: 'local_chess.purge_deleted_item',
            context: <String, Object?>{
              'databaseId': databaseId,
              'elapsedMs': perDatabase.elapsedMilliseconds,
            },
          );
        }
      }
      if (purged > 0 && cleanupOrphanMetadata) {
        try {
          emitProgress('Cleaning local metadata...', force: true);
          await _deleteOrphanLocalMetadataInChunks(db, batchSize: batchSize);
        } catch (error, stackTrace) {
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
        await _checkpointLocalChessCacheBestEffort(db);
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
      return purged;
    } catch (error, stackTrace) {
      stopwatch.stop();
      localChessLog.error(
        'Local database purge failed',
        error,
        stackTrace,
        tag: 'local_chess.purge_deleted',
        context: <String, Object?>{
          'batchSize': batchSize,
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
    int batchSize = 4096,
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
                'sourcePath': trimmedSourcePath,
            },
          );
          final purged = await purgeDeletedCaches(
            sourcePath: trimmedSourcePath,
            batchSize: batchSize,
            cleanupOrphanMetadata: cleanupOrphanMetadata,
            checkpoint: checkpoint,
          );
          localChessLog.info(
            'Local database background purge finished',
            context: <String, Object?>{
              'purgedDatabases': purged,
              if (trimmedSourcePath != null && trimmedSourcePath.isNotEmpty)
                'sourcePath': trimmedSourcePath,
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
              'sourcePath': trimmedSourcePath,
          },
        );
      }),
    );
  }

  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
  }) async {
    if (paths.isEmpty) return null;
    try {
      if (paths.length == 1) {
        return await _loadFreshSingleSource(
          paths.single,
          sourceLabel: sourceLabel,
        );
      }

      final children = <LocalChessNode>[];
      for (final path in paths) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        switch (type) {
          case FileSystemEntityType.directory:
            final node = await _loadFreshDirectory(
              path,
              rootPath: path,
              force: true,
            );
            children.add(node);
          case FileSystemEntityType.file:
            final parent = p.dirname(path);
            final node = await _loadFreshFileNodeOrUnsupported(
              path,
              rootPath: parent,
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
      final root = LocalChessFolderNode.fromChildren(
        name: sourceLabel ?? 'Dropped chess files',
        path: 'local-batch:${_stableId(paths.join('|'))}',
        relativePath: '',
        children: children,
      );
      return LocalChessSource(
        id: _stableId(paths.join('|')),
        label: sourceLabel ?? 'Dropped chess files',
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
  }) async {
    try {
      return await _loadFreshFileNode(path, rootPath: rootPath);
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<LocalChessGameQueryPage?> localDatabaseGamesPage({
    required String databasePath,
    String search = '',
    LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
    LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
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

  Future<bool> persistAppendedPgnGames({
    required String databasePath,
    required List<LocalChessAppendedPgn> appendedPgns,
  }) async {
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

    await db.transaction((txn) async {
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
      await _upsertTreeDelta(txn, databaseId, index);
      await _insertPositionGameRefs(txn, databaseId, index, <String>{
        for (final game in games) game.id,
      });
      await txn.execute(
        '''
        UPDATE $localChessGamesTable
        SET file_game_count = ?
        WHERE database_id = ?
        ''',
        <Object?>[nextFileGameCount, databaseId],
      );
      final positionCountRows = await txn.select(
        '''
        SELECT COUNT(*) AS count
        FROM $localChessTreeNodesTable
        WHERE database_id = ?
        ''',
        <Object?>[databaseId],
      );
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
          _readInt(positionCountRows.single['count']),
          treeMaxPly,
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

    await db.transaction((txn) async {
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
      await _subtractTreeDelta(txn, databaseId, oldDelta.index);
      await _deleteUnreferencedTreeNodes(txn, databaseId);

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
      await _upsertTreeDelta(txn, databaseId, newDelta.index);
      await _insertPositionGameRefs(txn, databaseId, newDelta.index, <String>{
        targetId,
      });
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
      final positionCountRows = await txn.select(
        '''
        SELECT COUNT(*) AS count
        FROM $localChessTreeNodesTable
        WHERE database_id = ?
        ''',
        <Object?>[databaseId],
      );
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
          _readInt(positionCountRows.single['count']),
          treeMaxPly,
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

    await db.transaction((txn) async {
      if (keptRows.isEmpty) {
        await _deleteFileCache(txn, databasePath);
        return;
      }

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
      await _subtractTreeDelta(txn, databaseId, deleteDelta.index);
      await _deleteUnreferencedTreeNodes(txn, databaseId);
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
      final positionCountRows = await txn.select(
        '''
        SELECT COUNT(*) AS count
        FROM $localChessTreeNodesTable
        WHERE database_id = ?
        ''',
        <Object?>[databaseId],
      );
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
          _readInt(positionCountRows.single['count']),
          treeMaxPly,
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
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) async {
    final databaseId = _databaseId(databasePath);
    final db = await _database();
    if (!filters.hasFilters) {
      return _localTreeMoveAggregatesForFen(
        db,
        databaseId: databaseId,
        fen: fen,
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
      SELECT 1
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isEmpty) return null;

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
    await db.execute(
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
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final root = await _loadFreshDirectory(path, rootPath: path, force: true);
      return LocalChessSource(
        id: _stableId(path),
        label: sourceLabel ?? localChessDatabaseDisplayNameForPath(path),
        paths: <String>[path],
        rootPath: path,
        scannedAt: DateTime.now(),
        root: root,
      );
    }
    if (type != FileSystemEntityType.file) return null;
    final parent = p.dirname(path);
    final node = await _loadFreshFileNode(path, rootPath: parent);
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
  }) async {
    final children = <LocalChessNode>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          final child = await _loadFreshDirectory(
            entity.path,
            rootPath: rootPath,
            force: true,
          );
          if (child.children.isNotEmpty || child.scanError != null) {
            children.add(child);
          }
        case FileSystemEntityType.file:
          final node = await _loadFreshFileNodeOrUnsupported(
            entity.path,
            rootPath: rootPath,
          );
          if (node != null) children.add(node);
        case FileSystemEntityType.link:
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          break;
      }
    }
    _sortNodes(children);
    if (!force && children.isEmpty) throw const _LocalChessCacheMiss();
    return LocalChessFolderNode.fromChildren(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: _relative(rootPath, path),
      children: children,
    );
  }

  Future<LocalChessNode?> _loadFreshFileNodeOrUnsupported(
    String path, {
    required String rootPath,
  }) async {
    if (!looksLikeLocalChessFile(path)) return null;
    if (!isSupportedLocalChessFile(path)) {
      final stat = await File(path).stat();
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: _extensionForPath(path),
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: localChessUnsupportedFormatMessage,
      );
    }
    return _loadFreshFileNode(path, rootPath: rootPath);
  }

  Future<LocalChessFileNode> _loadFreshFileNode(
    String path, {
    required String rootPath,
  }) async {
    final stat = await File(path).stat();
    final databaseId = _databaseId(path);
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
    if (databaseRows.isEmpty) throw const _LocalChessCacheMiss();
    final databaseRow = databaseRows.single;
    final storedSize = _readInt(databaseRow['size_bytes']);
    final storedModified = _readNullableInt(databaseRow['modified_at_ms']);
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    if (storedSize != stat.size || storedModified != modifiedMs) {
      throw const _LocalChessCacheMiss();
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
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
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

    final databaseRow = <String, Object?>{
      'id': databaseId,
      'path': file.path,
      'label': sourceLabel,
      'extension': file.extension,
      'size_bytes': file.sizeBytes,
      'modified_at_ms': file.modifiedAt?.millisecondsSinceEpoch,
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
    void Function(String table, int deletedRows)? onDeletedRows,
  }) async {
    if (!await _databaseIsMarkedDeleted(db, databaseId)) return false;
    final size = batchSize <= 0 ? 4096 : batchSize;

    await _deleteDatabaseRowsInChunks(
      db,
      localChessPositionGamesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeMovesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeNodesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessGameAnalysisTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessGamesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    if (!await _databaseIsMarkedDeleted(db, databaseId)) return false;
    final result = await db.execute(
      '''
      DELETE FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NOT NULL
      ''',
      <Object?>[databaseId],
    );
    if (result.affectedRows > 0) {
      onDeletedRows?.call(localChessDatabasesTable, result.affectedRows);
    }
    return result.affectedRows > 0;
  }

  Future<void> _deleteGeneratedDatabaseRowsInChunks(
    resqlite.Database db,
    String databaseId, {
    required int batchSize,
    void Function(String table, int deletedRows)? onDeletedRows,
  }) async {
    final size = batchSize <= 0 ? 4096 : batchSize;
    await _deleteDatabaseRowsInChunks(
      db,
      localChessPositionGamesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeMovesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessTreeNodesTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
    await _deleteDatabaseRowsInChunks(
      db,
      localChessGameAnalysisTable,
      databaseId,
      batchSize: size,
      onDeletedRows: onDeletedRows,
    );
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
    void Function(String table, int deletedRows)? onDeletedRows,
  }) async {
    while (true) {
      final rows = await db.select(
        '''
        SELECT rowid
        FROM $table
        WHERE database_id = ?
        LIMIT ?
        ''',
        <Object?>[databaseId, batchSize],
      );
      if (rows.isEmpty) return;
      final rowIds = <Object?>[for (final row in rows) row['rowid']];
      final placeholders = List<String>.filled(rowIds.length, '?').join(', ');
      final result = await db.execute(
        'DELETE FROM $table WHERE rowid IN ($placeholders)',
        rowIds,
      );
      final deletedRows = result.affectedRows;
      if (deletedRows <= 0) {
        throw StateError(
          'Local chess purge could not delete selected rows from $table.',
        );
      }
      onDeletedRows?.call(table, deletedRows);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<int> _databasePurgeUnitCount(
    resqlite.Database db,
    String databaseId,
  ) async {
    var total = 1;
    for (final table in const <String>[
      localChessPositionGamesTable,
      localChessTreeMovesTable,
      localChessTreeNodesTable,
      localChessGameAnalysisTable,
      localChessGamesTable,
    ]) {
      final rows = await db.select(
        'SELECT COUNT(*) AS count FROM $table WHERE database_id = ?',
        <Object?>[databaseId],
      );
      total += rows.isEmpty ? 0 : _readInt(rows.single['count']);
      await Future<void>.delayed(Duration.zero);
    }
    return total;
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
    );
  }

  Future<void> _deleteOrphanLocalRowsInChunks(
    resqlite.Database db, {
    required String table,
    required String idSql,
    required int batchSize,
  }) async {
    while (true) {
      final rows = await db.select(idSql, <Object?>[batchSize]);
      if (rows.isEmpty) return;
      final ids = <Object?>[for (final row in rows) row['id']];
      final placeholders = List<String>.filled(ids.length, '?').join(', ');
      await db.execute('DELETE FROM $table WHERE id IN ($placeholders)', ids);
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
      final metadata = game.game.metadata;
      final treeRow = treeRowsById[game.id];
      final white = _normalizedName(metadata['White'] ?? treeRow?['white']);
      final black = _normalizedName(metadata['Black'] ?? treeRow?['black']);
      final event = _normalizedName(metadata['Event'] ?? treeRow?['event']);
      final site = _normalizedName(metadata['Site'] ?? treeRow?['site']);
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
        'time_control':
            treeRow?['timeControl']?.toString() ??
            metadata['TimeControl']?.toString(),
        'eco': treeRow?['eco']?.toString() ?? metadata['ECO']?.toString(),
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
      SELECT tree_max_ply
      FROM $localChessDatabasesTable
      WHERE id = ? AND deleted_at_ms IS NULL
      LIMIT 1
      ''',
      <Object?>[databaseId],
    );
    if (databaseRows.isNotEmpty) {
      final stored = _readNullableInt(databaseRows.single['tree_max_ply']);
      if (stored != null && stored > 0) return stored;
    }

    final rows = await db.select(
      '''
      SELECT MAX(ply) AS max_ply
      FROM $localChessTreeNodesTable
      WHERE database_id = ?
      ''',
      <Object?>[databaseId],
    );
    final maxPly = rows.isEmpty ? 0 : _readInt(rows.single['max_ply']);
    return maxPly > 0 ? maxPly : localOpeningTreeDefaultMaxPly;
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
      'date': row['date'] ?? meta('Date'),
      'timeControl': row['time_control'] ?? meta('TimeControl'),
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
  }) async {
    final databaseId = _databaseId(start.path);
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _database();
    final existingRows = await db.select(
      '''
      SELECT
        d.size_bytes,
        d.modified_at_ms,
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
      final canReuseGameRows =
          existingRowCount > 0 &&
          existingRowCount == existingGameCount &&
          existingFileGameCount == start.totalEntries &&
          _readInt(existing['size_bytes']) == start.sizeBytes &&
          _readNullableInt(existing['modified_at_ms']) ==
              start.modifiedAt?.millisecondsSinceEpoch;
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.30,
          message: 'Replacing existing local cache...',
        ),
      );
      await markCachedSourceDeleted(start.path);
      if (canReuseGameRows) {
        _reusedImportedGameRows.add(databaseId);
        localChessLog.info(
          'PGN import reusing existing game rows',
          context: <String, Object?>{
            'path': start.path,
            'games': existingGameCount,
            'totalEntries': start.totalEntries,
          },
        );
        await _deleteGeneratedDatabaseRowsInChunks(
          db,
          databaseId,
          batchSize: _kSqlWriteBatchSize,
          onDeletedRows:
              onProgress == null
                  ? null
                  : (table, _) {
                    onProgress(
                      LocalChessScanProgress(
                        fraction: 0.30,
                        message:
                            'Deleting ${_localChessPurgeTableLabel(table)}...',
                      ),
                    );
                  },
        );
      } else {
        _reusedImportedGameRows.remove(databaseId);
        await purgeDeletedCaches(
          sourcePath: start.path,
          batchSize: _kSqlWriteBatchSize,
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
      }
      onProgress?.call(
        LocalChessScanProgress(
          fraction: 0.30,
          message: 'Existing local cache replaced.',
        ),
      );
    }
    await db.transaction((txn) async {
      await _upsertLocalChessDatabaseRow(txn, <String, Object?>{
        'id': databaseId,
        'path': start.path,
        'label': sourceLabel,
        'extension': start.extension,
        'size_bytes': start.sizeBytes,
        'modified_at_ms': start.modifiedAt?.millisecondsSinceEpoch,
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
        parseRawPgnLineFallback: false,
      );
    });
  }

  Future<void> _completeImportedFileNode(LocalChessFileNode file) async {
    final databaseId = _databaseId(file.path);
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _database();
    await db.execute(
      '''
      UPDATE $localChessDatabasesTable
      SET
        size_bytes = ?,
        modified_at_ms = ?,
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
        file.gameCount,
        now,
        databaseId,
      ],
    );
    _reusedImportedGameRows.remove(databaseId);
  }

  Future<void> _discardImportedFileNode(String path) async {
    final db = await _database();
    await db.transaction((txn) async {
      await _deleteFileCache(txn, path);
    });
  }
}

final localChessDatabaseRepositoryProvider =
    Provider<LocalChessDatabaseRepository>((_) {
      final repository = LocalChessDatabaseRepository(
        database: () => LocalChessResqliteDatabase.instance.database,
        purgeDatabase:
            () => LocalChessResqliteDatabase.instance.openDedicatedConnection(),
      );
      repository.scheduleDeletedCachePurge(
        batchSize: 4096,
        cleanupOrphanMetadata: false,
        checkpoint: false,
      );
      return repository;
    });

Future<void> _importSingleLocalChessFileWorker(
  _LocalChessImportWorkerRequest request,
) async {
  void emit(LocalChessScanProgress progress) {
    request.sendPort.send(progress);
  }

  resqlite.Database? db;
  try {
    emit(LocalChessScanProgress(fraction: 0, message: 'Opening cache...'));
    db = await resqlite.Database.open(request.databaseFilePath);
    await _configureStandaloneLocalChessDatabase(db);
    await createLocalChessResqliteDatabaseSchema(db);

    final repository = LocalChessDatabaseRepository(database: () async => db!);
    final rootPath = p.dirname(request.path);
    final label =
        request.sourceLabel ??
        localChessDatabaseDisplayNameForPath(request.path);
    var importStarted = false;

    final node = await scanLocalChessFileNodeForImportWithProgress(
      path: request.path,
      rootPath: rootPath,
      previewGameLimit: request.previewGameLimit,
      batchSize: _kSqlWriteBatchSize,
      onProgress: emit,
      onImportStart: (start) async {
        importStarted = true;
        await repository._beginImportedFileNode(
          start,
          sourceLabel: label,
          onProgress: emit,
        );
      },
      onGameBatch: (batch) async {
        await repository._persistImportedGameBatch(request.path, batch.games);
      },
    );

    if (node.isPlayable) {
      if (!importStarted) {
        await repository._beginImportedFileNode(
          LocalChessFileImportStart(
            path: node.path,
            relativePath: node.relativePath,
            extension: node.extension,
            sizeBytes: node.sizeBytes,
            modifiedAt: node.modifiedAt,
            totalEntries: node.gameCount,
            pgnOffsetIndex: node.pgnOffsetIndex,
          ),
          sourceLabel: label,
          onProgress: emit,
        );
      }
      await repository._completeImportedFileNode(node);
    } else {
      await repository._discardImportedFileNode(request.path);
    }

    final root = LocalChessFolderNode.fromChildren(
      name: label,
      path: 'local-file:${_stableId(request.path)}',
      relativePath: '',
      children: <LocalChessNode>[node],
    );
    request.sendPort.send(
      _LocalChessImportWorkerSuccess(
        LocalChessSource(
          id: _stableId(request.path),
          label: label,
          paths: <String>[request.path],
          rootPath: rootPath,
          scannedAt: DateTime.now(),
          root: root,
        ),
      ),
    );
  } catch (error, stackTrace) {
    request.sendPort.send(
      _LocalChessImportWorkerFailure(error.toString(), stackTrace.toString()),
    );
  } finally {
    await db?.close();
  }
}

Future<void> _rebuildOpeningTreeFromCachedGamesWorker(
  _LocalTreeRebuildWorkerRequest request,
) async {
  void emit(LocalChessScanProgress progress) {
    request.sendPort.send(progress);
  }

  resqlite.Database? db;
  try {
    emit(LocalChessScanProgress(fraction: 0, message: 'Opening cache...'));
    db = await resqlite.Database.open(request.databaseFilePath);
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
    final includeGameRows = cachedGameCount <= _kPersistedTreeGameRowLimit;
    final includePositionGameRefs =
        cachedGameCount <= _kPersistedPositionGameRefLimit;
    emit(LocalChessScanProgress(fraction: 0.16, message: 'Building tree...'));

    final builder = LocalOpeningTreeIncrementalBuilder(
      treeId: 'local:${_stableId(databaseId)}',
      databaseId: databaseId,
      maxPly: maxPly,
      includePositionGameRefs: includePositionGameRefs,
      includeGameRows: includeGameRows,
    );
    var processed = 0;
    var lastIndexInFile = -1;
    while (true) {
      final gameRows = await db.select(
        '''
        SELECT
          id,
          raw_pgn,
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

      builder.addGames(
        _treeInputsForCachedGameRows(
          rows: gameRows,
          totalRows: cachedGameCount,
          processedOffset: processed,
          onProgress: emit,
        ),
      );
      processed += gameRows.length;
      lastIndexInFile = _readInt(
        gameRows.last['index_in_file'],
        fallback: lastIndexInFile,
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

    final buildResult = builder.finish();

    final index = buildResult.index;
    if (index.positionCount <= 0) {
      request.sendPort.send(
        const _LocalTreeRebuildWorkerFailure(
          'Opening tree build did not produce an index.',
          '',
        ),
      );
      return;
    }

    emit(LocalChessScanProgress(fraction: 0.86, message: 'Saving tree...'));
    final now = DateTime.now().millisecondsSinceEpoch;
    var persisted = false;
    await db.transaction((txn) async {
      final activeRows = await txn.select(
        '''
        SELECT 1
        FROM $localChessDatabasesTable
        WHERE id = ? AND deleted_at_ms IS NULL
        LIMIT 1
        ''',
        <Object?>[databaseId],
      );
      if (activeRows.isEmpty) return;
      final gameIds =
          index.gamesByFen.isEmpty
              ? const <String>{}
              : await repository._localGameIds(txn, databaseId);
      await repository._deleteOpeningTreeRows(txn, databaseId);
      await repository._insertTree(txn, databaseId, index);
      await repository._insertPositionGameRefs(txn, databaseId, index, gameIds);
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
        <Object?>[index.positionCount, index.maxPly, now, databaseId],
      );
      persisted = true;
    });
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
    await db?.close();
  }
}

class _LocalChessCacheMiss implements Exception {
  const _LocalChessCacheMiss();
}

String _databaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
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
    'PRAGMA busy_timeout=5000',
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
  final openFiles = <String, RandomAccessFile>{};
  try {
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
            message: 'Building tree...',
          ),
        );
      }

      final rawPgn = _rawPgnForCachedTreeRow(row, openFiles).trim();
      if (rawPgn.isEmpty) continue;
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
      if (indexInFile < 0 ||
          fileGameCount <= 0 ||
          indexInFile >= fileGameCount) {
        continue;
      }
      yield LocalOpeningTreeGameInput(
        id: id,
        rawPgn: rawPgn,
        sourcePath: sourcePath,
        sourceRelativePath: sourceRelativePath,
        fileName: fileName,
        indexInFile: indexInFile,
        fileGameCount: fileGameCount,
        sourceByteStart: _readNullableInt(row['source_byte_start']),
        sourceByteEnd: _readNullableInt(row['source_byte_end']),
      );
    }
  } finally {
    for (final file in openFiles.values) {
      try {
        file.closeSync();
      } catch (_) {}
    }
  }
}

String _rawPgnForCachedTreeRow(
  Map<String, Object?> row,
  Map<String, RandomAccessFile> openFiles,
) {
  final inline = row['raw_pgn']?.toString() ?? '';
  if (inline.trim().isNotEmpty) return inline;
  final path = row['source_path']?.toString();
  final start = _readNullableInt(row['source_byte_start']);
  final end = _readNullableInt(row['source_byte_end']);
  if (path == null || path.isEmpty || start == null || end == null) return '';
  if (end <= start) return '';
  try {
    final raf = openFiles.putIfAbsent(path, () => File(path).openSync());
    raf.setPositionSync(start);
    return utf8.decode(raf.readSync(end - start), allowMalformed: true);
  } on Object {
    return '';
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
  final query = rawSearch.trim().toLowerCase();
  if (query.isEmpty) return;
  final like = '%${_escapeSqlLike(query)}%';
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
      '${_localTextSortExpression("COALESCE(g.date, '')", direction)}, '
          '$stableTieBreak',
  };
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
    final name = timeControl.name.toLowerCase();
    where.write(' AND LOWER(g.time_control) IN (?, ?, ?)');
    parameters.addAll(<Object?>[
      name,
      timeControl.displayName.toLowerCase(),
      'timecontrol.$name',
    ]);
  }

  final result = _sqlResultForFilter(filters.result);
  if (result != null) {
    where.write(' AND g.result = ?');
    parameters.add(result);
  } else if (filters.result?.trim().isNotEmpty == true) {
    where.write(' AND 0 = 1');
  }

  if (filters.isOnline != null) {
    // Imported PGNs are local/offline rows without an online discriminator.
    // Match PlayerOpeningTreeFilterCriteria.matches(), which rejects null.
    where.write(' AND 0 = 1');
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
