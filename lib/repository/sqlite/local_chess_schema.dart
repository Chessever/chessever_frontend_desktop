import 'package:sqflite/sqflite.dart';

const int localChessDatabaseSchemaVersion = 2;

const String localChessDatabasesTable = 'local_chess_databases';
const String localChessPlayersTable = 'local_chess_players';
const String localChessEventsTable = 'local_chess_events';
const String localChessSitesTable = 'local_chess_sites';
const String localChessGamesTable = 'local_chess_games';
const String localChessTreeNodesTable = 'local_chess_tree_nodes';
const String localChessTreeMovesTable = 'local_chess_tree_moves';
const String localChessPositionGamesTable = 'local_chess_position_games';
const String localChessGameAnalysisTable = 'local_chess_game_analysis';

Future<void> createLocalChessDatabaseSchema(DatabaseExecutor db) async {
  await db.execute('''
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
      imported_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS $localChessPlayersTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE,
      elo INTEGER
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS $localChessEventsTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS $localChessSitesTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE
    )
  ''');

  await db.execute('''
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
      headers_json TEXT NOT NULL DEFAULT '{}',
      source_path TEXT NOT NULL,
      source_relative_path TEXT NOT NULL,
      file_name TEXT NOT NULL,
      index_in_file INTEGER NOT NULL,
      file_game_count INTEGER NOT NULL,
      has_moves INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE,
      FOREIGN KEY(event_id) REFERENCES $localChessEventsTable(id),
      FOREIGN KEY(site_id) REFERENCES $localChessSitesTable(id),
      FOREIGN KEY(white_id) REFERENCES $localChessPlayersTable(id),
      FOREIGN KEY(black_id) REFERENCES $localChessPlayersTable(id)
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS $localChessTreeNodesTable (
      database_id TEXT NOT NULL,
      node_id INTEGER NOT NULL,
      fen_key TEXT NOT NULL,
      ply INTEGER NOT NULL,
      PRIMARY KEY(database_id, node_id),
      UNIQUE(database_id, fen_key),
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE
    )
  ''');

  await db.execute('''
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
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS $localChessPositionGamesTable (
      database_id TEXT NOT NULL,
      fen_key TEXT NOT NULL,
      fen TEXT NOT NULL,
      game_id TEXT NOT NULL,
      ply INTEGER NOT NULL,
      PRIMARY KEY(database_id, fen_key, game_id),
      FOREIGN KEY(database_id) REFERENCES $localChessDatabasesTable(id) ON DELETE CASCADE,
      FOREIGN KEY(game_id) REFERENCES $localChessGamesTable(id) ON DELETE CASCADE
    )
  ''');

  await db.execute('''
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
  ''');

  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_database ON $localChessGamesTable(database_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_date ON $localChessGamesTable(date)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_white ON $localChessGamesTable(white_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_black ON $localChessGamesTable(black_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_result ON $localChessGamesTable(result)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_white_elo ON $localChessGamesTable(white_elo)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_black_elo ON $localChessGamesTable(black_elo)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_games_plycount ON $localChessGamesTable(ply_count)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_tree_nodes_fen ON $localChessTreeNodesTable(database_id, fen_key)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_local_chess_position_games_fen ON $localChessPositionGamesTable(database_id, fen_key)',
  );

  await db.insert(localChessPlayersTable, <String, Object?>{
    'id': 0,
    'name': 'Unknown',
    'elo': null,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert(localChessEventsTable, <String, Object?>{
    'id': 0,
    'name': 'Unknown',
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert(localChessSitesTable, <String, Object?>{
    'id': 0,
    'name': 'Unknown',
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
