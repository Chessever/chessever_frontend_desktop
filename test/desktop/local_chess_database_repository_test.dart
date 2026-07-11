import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess, NormalMove;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/gamebase_game.dart';

const String _legacySqfliteMigrationV1 = 'legacy_sqflite_local_chess_v1';
const String _legacySqfliteMigrationV2 =
    'legacy_sqflite_local_chess_v2_desktop_path_scan';
const String _treeFen4Generation = 'local_chess_tree_position_identity_fen4_v1';

void main() {
  late resqlite.Database db;
  late Directory temp;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-local-db-');
    db = await resqlite.Database.open('${temp.path}/local_chess.db');
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('PRAGMA journal_mode=WAL');
    await createLocalChessResqliteDatabaseSchema(db);
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('repairs source-specific time-control categories', () async {
    await db.execute('PRAGMA foreign_keys=OFF');
    const chessComHeaders =
        '{"Site":"https://www.chess.com/game/live/1",'
        '"ChessEverTimeControlCategory":"blitz"}';
    const lichessHeaders =
        '{"Site":"https://lichess.org/game-id",'
        '"ChessEverTimeControlCategory":"blitz"}';
    const lichessCorrespondenceHeaders =
        '{"Event":"rated correspondence game",'
        '"Site":"https://lichess.org/game-id"}';
    const combinedLichessHeaders = '{"Site":"?","ChessEverSource":"lichess"}';
    const genericHeaders = '{"Site":"OTB Hall"}';
    const unknownHeaders = '{"Site":"?"}';
    for (final entry in <(String, String, String, String)>[
      ('chesscom-ultra', '30', 'blitz', chessComHeaders),
      ('chesscom-bullet', '60', 'blitz', chessComHeaders),
      ('generic-fast', '60', 'bullet', genericHeaders),
      ('stored-bullet-without-clock', '-', ' Bullet ', unknownHeaders),
      ('stored-mixed-case-blitz', '180', ' Blitz ', genericHeaders),
      ('lichess-bullet', '30', 'ultrabullet', lichessHeaders),
      ('lichess-combined-provenance', '15', 'blitz', combinedLichessHeaders),
      ('lichess-blitz', '180', 'blitz', lichessHeaders),
      ('lichess-rapid', '480', 'blitz', lichessHeaders),
      ('lichess-classical', '1500', 'rapid', lichessHeaders),
      ('lichess-correspondence', '21600', 'classical', lichessHeaders),
      (
        'lichess-correspondence-unknown',
        '-',
        'unknown',
        lichessCorrespondenceHeaders,
      ),
    ]) {
      await db.execute(
        '''
        INSERT INTO local_chess_games
          (id, database_id, time_control, time_control_category, headers_json,
           is_online, raw_pgn, source_path, source_relative_path, file_name,
           index_in_file, file_game_count)
        VALUES (?, 'hikaru', ?, ?, ?, 1, '', 'hikaru.pgn', 'hikaru.pgn',
                'hikaru.pgn', 0, 1)
        ''',
        <Object?>[entry.$1, entry.$2, entry.$3, entry.$4],
      );
    }
    await db.execute(
      "DELETE FROM local_chess_migrations WHERE name = "
      "'local_chess_source_time_control_backfill_v2'",
    );

    await createLocalChessResqliteDatabaseSchema(db);

    final rows = await db.select('''
      SELECT id, time_control_category
      FROM local_chess_games
      WHERE database_id = 'hikaru'
      ORDER BY id
    ''');
    expect(
      <String, String>{
        for (final row in rows)
          row['id']! as String: row['time_control_category']! as String,
      },
      <String, String>{
        'chesscom-ultra': 'ultrabullet',
        'chesscom-bullet': 'bullet',
        'generic-fast': 'blitz',
        'stored-bullet-without-clock': 'bullet',
        'stored-mixed-case-blitz': 'blitz',
        'lichess-bullet': 'bullet',
        'lichess-combined-provenance': 'ultrabullet',
        'lichess-blitz': 'blitz',
        'lichess-rapid': 'rapid',
        'lichess-classical': 'classical',
        'lichess-correspondence': 'correspondence',
        'lichess-correspondence-unknown': 'correspondence',
      },
    );
  });

  test('migrates existing sqflite local chess cache into resqlite', () async {
    final pgnFile = File('${temp.path}/legacy.pgn');
    await pgnFile.writeAsString(_legacyPgn.trim());
    final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
      '${temp.path}/legacy_app.db',
    );
    addTearDown(legacyDb.close);
    await legacyDb.execute('PRAGMA foreign_keys=ON');
    await createLocalChessDatabaseSchema(legacyDb);
    await _seedLegacyLocalChessCache(legacyDb, pgnFile);
    await legacyDb.update(
      'local_chess_games',
      <String, Object?>{'time_control_category': ' Bullet '},
      where: 'database_id = ?',
      whereArgs: <Object?>[pgnFile.path],
    );

    await migrateLegacyLocalChessSqfliteCache(
      db,
      legacyDatabase: () async => legacyDb,
    );

    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 1);
    expect(await _count(db, 'local_chess_tree_nodes'), 0);
    expect(await _count(db, 'local_chess_tree_moves'), 0);
    expect(await _count(db, 'local_chess_position_games'), 0);
    final marker = await db.select(
      'SELECT 1 FROM local_chess_migrations WHERE name = ?',
      const <Object?>[_legacySqfliteMigrationV2],
    );
    expect(marker, isNotEmpty);
    final migrated =
        (await db.select(
          '''
      SELECT pgn_hash, headers_json, time_control_category
      FROM local_chess_games
      WHERE database_id = ?
      ''',
          <Object?>[pgnFile.path],
        )).single;
    expect(migrated['pgn_hash']?.toString(), isNotEmpty);
    expect(migrated['time_control_category'], 'bullet');
    final metadata =
        jsonDecode(migrated['headers_json'] as String) as Map<String, dynamic>;
    expect(metadata['WhiteTitle'], 'GM');
    expect(metadata['WhiteFed'], 'TUR');

    final migratedDatabase =
        (await db.select(
          '''
          SELECT position_count, tree_snapshot, tree_max_ply
          FROM local_chess_databases
          WHERE id = ?
          ''',
          <Object?>[pgnFile.path],
        )).single;
    expect(migratedDatabase['position_count'], 0);
    expect(migratedDatabase['tree_snapshot'], isNull);
    expect(migratedDatabase['tree_max_ply'], isNull);

    final repo = LocalChessDatabaseRepository(database: () async => db);
    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );
    expect(restored, isNotNull);
    expect(restored!.games.single.game.metadata['BlackTitle'], 'IM');
    expect(restored.openingTreeIndex, isNull);
    final moves = await repo.localMoveAggregatesForFen(
      databasePath: pgnFile.path,
      fen: Chess.initial.fen,
    );
    expect(moves, isEmpty);
  });

  test(
    'defers instead of marking complete when the legacy cache is unreadable, '
    'then migrates once it can be read',
    () async {
      // First launch (Windows-style failure): the legacy sqflite cache exists
      // but cannot be opened/read — e.g. a locked / read-only WAL file. The
      // explicit source throws.
      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase:
            () async =>
                throw Exception('unable to open database file (simulated)'),
        legacyDatabasePathCandidates: const <String>[],
      );

      // The migration must NOT mark itself complete, so it retries next launch
      // instead of permanently hiding the user's local databases.
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isEmpty,
      );
      expect(await _count(db, 'local_chess_databases'), 0);

      // Next launch: the legacy cache is now readable and holds data.
      final pgnFile = File('${temp.path}/legacy.pgn');
      await pgnFile.writeAsString(_legacyPgn.trim());
      final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/legacy_app.db',
      );
      addTearDown(legacyDb.close);
      await legacyDb.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(legacyDb);
      await _seedLegacyLocalChessCache(legacyDb, pgnFile);

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase: () async => legacyDb,
        legacyDatabasePathCandidates: const <String>[],
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 1);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isNotEmpty,
      );
    },
  );

  test('legacy migration copies large game tables in pages', () async {
    final pgnFile = File('${temp.path}/paged-legacy.pgn');
    await pgnFile.writeAsString(_legacyPgn.trim());
    final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
      '${temp.path}/paged_legacy_app.db',
    );
    addTearDown(legacyDb.close);
    await legacyDb.execute('PRAGMA foreign_keys=ON');
    await createLocalChessDatabaseSchema(legacyDb);
    await _seedPagedLegacyLocalChessGames(legacyDb, pgnFile, count: 300);

    await migrateLegacyLocalChessSqfliteCache(
      db,
      legacyDatabase: () async => legacyDb,
    );

    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 300);
    final rows = await db.select(
      '''
      SELECT MAX(index_in_file) AS max_index, MIN(pgn_hash) AS min_hash
      FROM local_chess_games
      WHERE database_id = ?
      ''',
      <Object?>[pgnFile.path],
    );
    expect(rows.single['max_index'], 299);
    expect(rows.single['min_hash']?.toString(), isNotEmpty);
  });

  test(
    'legacy migration recovers when an earlier empty attempt wrote the marker',
    () async {
      final pgnFile = File('${temp.path}/marked-legacy.pgn');
      await pgnFile.writeAsString(_legacyPgn.trim());
      final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/marked_legacy_app.db',
      );
      addTearDown(legacyDb.close);
      await legacyDb.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(legacyDb);
      await _seedLegacyLocalChessCache(legacyDb, pgnFile);
      await db.execute(
        '''
        INSERT OR REPLACE INTO local_chess_migrations(name, completed_at_ms)
        VALUES (?, ?)
        ''',
        <Object?>[_legacySqfliteMigrationV1, 1],
      );

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase: () async => legacyDb,
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 1);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'legacy migration marker skips retry after corrected empty pass',
    () async {
      final emptyLegacy = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/empty_noop_legacy.db',
      );
      addTearDown(emptyLegacy.close);
      await emptyLegacy.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(emptyLegacy);

      var inspections = 0;
      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabaseCandidates: <LocalChessLegacySqfliteDatabaseFactory>[
          () async {
            inspections++;
            return emptyLegacy;
          },
        ],
        legacyDatabasePathCandidates: const <String>[],
      );

      expect(inspections, 1);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isNotEmpty,
      );

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabaseCandidates: <LocalChessLegacySqfliteDatabaseFactory>[
          () async {
            inspections++;
            throw StateError('migration should not retry after v2 marker');
          },
        ],
        legacyDatabasePathCandidates: const <String>[],
      );

      expect(inspections, 1);
      expect(await _count(db, 'local_chess_databases'), 0);
    },
  );

  test(
    'legacy migration scans later sqflite candidates when first path is empty',
    () async {
      final emptyLegacy = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/empty_current_app.db',
      );
      addTearDown(emptyLegacy.close);
      await emptyLegacy.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(emptyLegacy);

      final pgnFile = File('${temp.path}/fallback-legacy.pgn');
      await pgnFile.writeAsString(_legacyPgn.trim());
      final fallbackLegacy = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/fallback_legacy_app.db',
      );
      addTearDown(fallbackLegacy.close);
      await fallbackLegacy.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(fallbackLegacy);
      await _seedLegacyLocalChessCache(fallbackLegacy, pgnFile);

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabaseCandidates: <LocalChessLegacySqfliteDatabaseFactory>[
          () async => emptyLegacy,
          () async => fallbackLegacy,
        ],
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      final rows = await db.select(
        'SELECT path FROM local_chess_databases LIMIT 1',
      );
      expect(rows.single['path'], pgnFile.path);
    },
  );

  test(
    'legacy migration opens sqflite cache from desktop path candidate',
    () async {
      final pgnFile = File('${temp.path}/windows-path-legacy.pgn');
      await pgnFile.writeAsString(_legacyPgn.trim());
      final legacyPath = p.join(
        temp.path,
        'AppData',
        'Roaming',
        'chessever',
        'chessever_app.db',
      );
      await Directory(p.dirname(legacyPath)).create(recursive: true);
      final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
        legacyPath,
      );
      await legacyDb.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(legacyDb);
      await _seedLegacyLocalChessCache(legacyDb, pgnFile);
      await legacyDb.close();

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabasePathCandidates: <String>[
          p.join(temp.path, 'missing', 'chessever_app.db'),
          legacyPath,
        ],
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 1);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      final rows = await db.select('SELECT path FROM local_chess_databases');
      expect(rows.single['path'], pgnFile.path);
    },
  );

  test(
    'legacy migration does not overwrite an existing resqlite cache',
    () async {
      final pgnFile = File('${temp.path}/current.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final legacyFile = File('${temp.path}/legacy-only.pgn');
      await legacyFile.writeAsString(_legacyPgn.trim());
      final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/legacy_skip.db',
      );
      addTearDown(legacyDb.close);
      await legacyDb.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(legacyDb);
      await _seedLegacyLocalChessCache(legacyDb, legacyFile);

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase: () async => legacyDb,
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      final paths = await db.select(
        'SELECT path FROM local_chess_databases ORDER BY path ASC',
      );
      expect(paths.map((row) => row['path']), [pgnFile.path]);
      final marker = await db.select(
        'SELECT 1 FROM local_chess_migrations WHERE name = ?',
        const <Object?>[_legacySqfliteMigrationV2],
      );
      expect(marker, isNotEmpty);
    },
  );

  test(
    'stale resqlite generation clears legacy marker so sqflite can recover',
    () async {
      final pgnFile = File('${temp.path}/recover-legacy.pgn');
      await pgnFile.writeAsString(_legacyPgn.trim());
      final legacyDb = await databaseFactoryFfiNoIsolate.openDatabase(
        '${temp.path}/recover_legacy_app.db',
      );
      addTearDown(legacyDb.close);
      await legacyDb.execute('PRAGMA foreign_keys=ON');
      await createLocalChessDatabaseSchema(legacyDb);
      await _seedLegacyLocalChessCache(legacyDb, pgnFile);

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase: () async => legacyDb,
      );
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isNotEmpty,
      );

      await db.execute(
        '''
        DELETE FROM local_chess_migrations
        WHERE name LIKE ?
        ''',
        const <Object?>['local_chess_resqlite_cache_generation_%'],
      );
      await createLocalChessResqliteDatabaseSchema(db);

      expect(await _count(db, 'local_chess_databases'), 0);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_legacySqfliteMigrationV2],
        ),
        isEmpty,
      );

      await migrateLegacyLocalChessSqfliteCache(
        db,
        legacyDatabase: () async => legacyDb,
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 1);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
    },
  );

  test(
    'schema invalidates stale generated resqlite cache but keeps local analysis',
    () async {
      final pgnFile = File('${temp.path}/stale-cache.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final gameId = fileNode.games.first.id;
      final now = DateTime.now();
      await repo.saveLocalGameAnalysis(
        LocalChessGameAnalysis(
          gameId: gameId,
          databaseId: pgnFile.path,
          analysisState: const <String, Object?>{'keep': true},
          variationComments: const <String, String>{'0': 'keep me'},
          moveNags: const <String, List<int>>{},
          lastViewedPosition: 1,
          notes: 'local user analysis survives cache reset',
          isFavorite: true,
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
      expect(await _count(db, 'local_chess_game_analysis'), 1);

      await db.execute('DELETE FROM local_chess_migrations');
      await createLocalChessResqliteDatabaseSchema(db);

      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 1);
      final analysis = await repo.localGameAnalysis(gameId);
      expect(analysis, isNotNull);
      expect(analysis!.notes, 'local user analysis survives cache reset');
      expect(analysis.isFavorite, isTrue);
      final generationMarkers = await db.select(
        '''
        SELECT name
        FROM local_chess_migrations
        WHERE name LIKE ?
        ''',
        const <Object?>['local_chess_resqlite_cache_generation_%'],
      );
      expect(generationMarkers, hasLength(1));
    },
  );

  test(
    'schema invalidates only stale position-key trees and preserves games',
    () async {
      final pgnFile = File('${temp.path}/stale-position-keys.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final now = DateTime.now();
      await repo.saveLocalGameAnalysis(
        LocalChessGameAnalysis(
          gameId: fileNode.games.first.id,
          databaseId: pgnFile.path,
          analysisState: const <String, Object?>{'keep': true},
          variationComments: const <String, String>{},
          moveNags: const <String, List<int>>{},
          lastViewedPosition: 0,
          notes: 'tree-only invalidation keeps analysis',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.execute(
        '''
        INSERT OR REPLACE INTO local_chess_migrations(name, completed_at_ms)
        VALUES (?, ?)
        ''',
        const <Object?>['unrelated_local_cache_state_v1', 1],
      );

      final storedKeys = await db.select(
        'SELECT fen_key FROM local_chess_tree_nodes WHERE database_id = ?',
        <Object?>[pgnFile.path],
      );
      expect(storedKeys, isNotEmpty);
      expect(
        storedKeys.map((row) => row['fen_key'].toString().split(' ')),
        everyElement(hasLength(4)),
      );
      final gameCount = await _count(db, 'local_chess_games');
      final playerCount = await _count(db, 'local_chess_players');
      final eventCount = await _count(db, 'local_chess_events');
      final siteCount = await _count(db, 'local_chess_sites');

      await db.execute(
        'DELETE FROM local_chess_migrations WHERE name = ?',
        const <Object?>[_treeFen4Generation],
      );
      await createLocalChessResqliteDatabaseSchema(db);

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), gameCount);
      expect(await _count(db, 'local_chess_players'), playerCount);
      expect(await _count(db, 'local_chess_events'), eventCount);
      expect(await _count(db, 'local_chess_sites'), siteCount);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 1);
      final databaseRows = await db.select(
        '''
        SELECT position_count, tree_snapshot, tree_max_ply
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(databaseRows.single['position_count'], 0);
      expect(databaseRows.single['tree_snapshot'], isNull);
      expect(databaseRows.single['tree_max_ply'], isNull);
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>[_treeFen4Generation],
        ),
        isNotEmpty,
      );
      expect(
        await db.select(
          'SELECT 1 FROM local_chess_migrations WHERE name = ?',
          const <Object?>['unrelated_local_cache_state_v1'],
        ),
        isNotEmpty,
      );
    },
  );

  test('tree identity invalidation waits for the shared write queue', () async {
    final pgnFile = File('${temp.path}/queued-tree-invalidation.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);
    final gameCount = await _count(db, 'local_chess_games');
    expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(0));
    await db.execute(
      'DELETE FROM local_chess_migrations WHERE name = ?',
      const <Object?>[_treeFen4Generation],
    );

    final queueEntered = Completer<void>();
    final releaseQueue = Completer<void>();
    final held = LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
      queueEntered.complete();
      await releaseQueue.future;
    });
    await queueEntered.future.timeout(const Duration(seconds: 5));

    var completed = false;
    final schema = createLocalChessResqliteDatabaseSchema(db).then((_) {
      completed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(completed, isFalse);
    expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(0));
    releaseQueue.complete();
    await schema.timeout(const Duration(seconds: 5));
    await held.timeout(const Duration(seconds: 5));

    expect(await _count(db, 'local_chess_games'), gameCount);
    expect(await _count(db, 'local_chess_tree_nodes'), 0);
  });

  test(
    'schema invalidates shallow cached tree depth while preserving games',
    () async {
      final pgnFile = File('${temp.path}/shallow-depth.pgn');
      final pgn = _repeatingKnightPgn(fullMoves: 30);
      await pgnFile.writeAsString(pgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final shallowIndex = buildLocalOpeningTreeIndex(
        treeId: 'local:test-shallow-depth',
        databaseId: pgnFile.path,
        maxPly: 20,
        games: [
          for (final game in fileNode.games)
            LocalOpeningTreeGameInput(
              id: game.id,
              rawPgn: game.rawPgn,
              sourcePath: game.sourcePath,
              sourceRelativePath: game.sourceRelativePath,
              fileName: game.fileName,
              indexInFile: game.indexInFile,
              fileGameCount: game.fileGameCount,
            ),
        ],
      );
      expect(
        await repo.persistOpeningTreeIndex(
          databasePath: pgnFile.path,
          index: shallowIndex,
        ),
        isTrue,
      );

      final beforeRows = await db.select(
        '''
        SELECT tree_max_ply, position_count
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(beforeRows.single['tree_max_ply'], 20);
      expect(await _count(db, 'local_chess_games'), 1);
      expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(0));

      await db.execute(
        'DELETE FROM local_chess_migrations WHERE name = ?',
        const <Object?>['local_chess_tree_depth_50_v1'],
      );
      await createLocalChessResqliteDatabaseSchema(db);

      expect(await _count(db, 'local_chess_games'), 1);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      final afterRows = await db.select(
        '''
        SELECT tree_max_ply, position_count, tree_snapshot
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(afterRows.single['tree_max_ply'], isNull);
      expect(afterRows.single['position_count'], 0);
      expect(afterRows.single['tree_snapshot'], isNull);
    },
  );

  test(
    'schema keeps short valid tree when stored max ply already matches target',
    () async {
      final pgnFile = File('${temp.path}/short-depth.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final nodeCount = await _count(db, 'local_chess_tree_nodes');
      expect(nodeCount, greaterThan(0));

      await db.execute(
        'DELETE FROM local_chess_migrations WHERE name = ?',
        const <Object?>['local_chess_tree_depth_50_v1'],
      );
      await createLocalChessResqliteDatabaseSchema(db);

      expect(await _count(db, 'local_chess_games'), fileNode.games.length);
      expect(await _count(db, 'local_chess_tree_nodes'), nodeCount);
      final databaseRows = await db.select(
        'SELECT tree_max_ply FROM local_chess_databases WHERE id = ?',
        <Object?>[pgnFile.path],
      );
      expect(databaseRows.single['tree_max_ply'], 50);
      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      expect(restored?.openingTreeIndex?.maxPly, 50);
    },
  );

  test('development purge switch honors opt-ins in release mode', () {
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: true,
        dartDefineEnabled: true,
        environmentValue: null,
        flagFileExists: false,
      ),
      isTrue,
    );
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: true,
        dartDefineEnabled: false,
        environmentValue: 'true',
        flagFileExists: false,
      ),
      isTrue,
    );
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: true,
        dartDefineEnabled: false,
        environmentValue: null,
        flagFileExists: true,
      ),
      isTrue,
    );
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: true,
        dartDefineEnabled: false,
        environmentValue: null,
        flagFileExists: false,
      ),
      isFalse,
    );
  });

  test('development purge switch accepts local flag and env opt-ins', () {
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: false,
        dartDefineEnabled: false,
        environmentValue: null,
        flagFileExists: true,
      ),
      isTrue,
    );
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: false,
        dartDefineEnabled: false,
        environmentValue: 'on',
        flagFileExists: false,
      ),
      isTrue,
    );
    expect(
      shouldPurgeLocalChessResqliteCacheForDevelopment(
        isReleaseMode: false,
        dartDefineEnabled: false,
        environmentValue: '0',
        flagFileExists: false,
      ),
      isFalse,
    );
  });

  test('development purge flag is consumed after one startup', () async {
    final flag = File(
      p.join(temp.path, localChessDevelopmentPurgeFlagFileName),
    );
    await flag.writeAsString('');

    expect(await consumeLocalChessDevelopmentPurgeFlagAt(flag.path), isTrue);
    expect(await flag.exists(), isFalse);
    expect(await consumeLocalChessDevelopmentPurgeFlagAt(flag.path), isFalse);
  });

  test('deletes local chess resqlite db sidecar files', () async {
    final dbPath = '${temp.path}/dev_cache.db';
    for (final path in <String>[
      dbPath,
      '$dbPath-wal',
      '$dbPath-shm',
      '$dbPath-journal',
    ]) {
      await File(path).writeAsString('cache');
    }

    final deleted = await deleteLocalChessResqliteCacheFilesAt(dbPath);

    expect(deleted, 4);
    for (final path in <String>[
      dbPath,
      '$dbPath-wal',
      '$dbPath-shm',
      '$dbPath-journal',
    ]) {
      expect(await File(path).exists(), isFalse);
    }
  });

  test('legacy sqflite path candidates are stable on desktop platforms', () {
    expect(
      localChessLegacySqfliteDatabasePathCandidates(
        applicationSupportPath:
            '/Users/u/Library/Application Support/chessever',
        sqfliteDatabasesPath:
            '/Users/u/app/.dart_tool/sqflite_common_ffi/databases',
        documentsPath: '/Users/u/Documents',
        pathContext: p.Context(style: p.Style.posix),
      ),
      <String>[
        '/Users/u/Library/Application Support/chessever/chessever_app.db',
        '/Users/u/app/.dart_tool/sqflite_common_ffi/databases/chessever_app.db',
        '/Users/u/Documents/chessever_app.db',
      ],
    );

    expect(
      localChessLegacySqfliteDatabasePathCandidates(
        applicationSupportPath: r'C:\Users\u\AppData\Roaming\chessever',
        sqfliteDatabasesPath: r'C:\app\.dart_tool\sqflite_common_ffi\databases',
        documentsPath: r'C:\Users\u\Documents',
        pathContext: p.Context(style: p.Style.windows),
      ),
      <String>[
        r'C:\Users\u\AppData\Roaming\chessever\chessever_app.db',
        r'C:\app\.dart_tool\sqflite_common_ffi\databases\chessever_app.db',
        r'C:\Users\u\Documents\chessever_app.db',
      ],
    );

    expect(
      localChessLegacySqfliteDatabasePathCandidates(
        applicationSupportPath: '/home/u/.local/share/chessever',
        sqfliteDatabasesPath:
            '/home/u/app/.dart_tool/sqflite_common_ffi/databases',
        documentsPath: '/home/u/Documents',
        pathContext: p.Context(style: p.Style.posix),
      ),
      <String>[
        '/home/u/.local/share/chessever/chessever_app.db',
        '/home/u/app/.dart_tool/sqflite_common_ffi/databases/chessever_app.db',
        '/home/u/Documents/chessever_app.db',
      ],
    );
  });

  test(
    'schema migrates existing resqlite cache missing delete tombstone',
    () async {
      final oldDb = await resqlite.Database.open('${temp.path}/old_cache.db');
      addTearDown(oldDb.close);
      await oldDb.execute('''
      CREATE TABLE local_chess_databases (
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

      await createLocalChessResqliteDatabaseSchema(oldDb);

      final columns = await oldDb.select(
        'PRAGMA table_info(local_chess_databases)',
      );
      expect(
        columns.map((row) => row['name']?.toString()),
        contains('deleted_at_ms'),
      );
      await oldDb.execute(
        '''
      INSERT INTO local_chess_databases(
        id, path, label, extension, size_bytes, modified_at_ms, file_count,
        game_count, position_count, tree_snapshot, imported_at_ms, updated_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        <Object?>[
          '/tmp/old-cache.pgn',
          '/tmp/old-cache.pgn',
          'Old cache',
          '.pgn',
          1,
          10,
          1,
          0,
          0,
          null,
          10,
          10,
        ],
      );

      final repo = LocalChessDatabaseRepository(database: () async => oldDb);
      expect(await repo.markCachedSourceDeleted('/tmp/old-cache.pgn'), 1);
      expect(await repo.purgeDeletedCaches(), 1);
      expect(await _count(oldDb, 'local_chess_databases'), 0);
    },
  );

  test(
    'schema upgrades pre-time-control cache before creating derived indexes',
    () async {
      final oldDb = await resqlite.Database.open(
        '${temp.path}/pre_time_control_cache.db',
      );
      addTearDown(oldDb.close);
      await _createPreTimeControlResqliteCache(
        oldDb,
        databaseId: '/tmp/hikaru-chess-com.pgn',
      );

      await createLocalChessResqliteDatabaseSchema(oldDb);
      await createLocalChessResqliteDatabaseSchema(oldDb);

      final columns = await oldDb.select(
        'PRAGMA table_info(local_chess_games)',
      );
      expect(
        columns.map((row) => row['name']?.toString()),
        containsAll(<String>['time_control_category', 'is_online']),
      );
      final indexes = await oldDb.select(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      expect(
        indexes.map((row) => row['name']?.toString()),
        containsAll(<String>[
          'idx_local_chess_games_db_time_category',
          'idx_local_chess_games_db_online',
        ]),
      );
      final games = await oldDb.select('''
        SELECT id, time_control_category, is_online
        FROM local_chess_games
      ''');
      expect(games, hasLength(1));
      expect(games.single['id'], 'legacy-hikaru-bullet');
      expect(games.single['time_control_category'], 'bullet');
      expect(games.single['is_online'], 1);
    },
  );

  test('persists imported PGN games and opening tree in SQLite rows', () async {
    final pgnFile = File('${temp.path}/mini.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);

    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 2);
    expect(await _count(db, 'local_chess_players'), greaterThanOrEqualTo(5));
    expect(await _count(db, 'local_chess_events'), greaterThanOrEqualTo(2));
    expect(await _count(db, 'local_chess_sites'), greaterThanOrEqualTo(2));
    expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(1));
    expect(await _count(db, 'local_chess_tree_moves'), greaterThan(1));
    expect(await _count(db, 'local_chess_position_games'), greaterThan(1));
    final initialRefRows = await db.select(
      '''
      SELECT next_uci
      FROM local_chess_position_games
      WHERE database_id = ? AND fen_key = ?
      ORDER BY next_uci ASC
      ''',
      <Object?>[pgnFile.path, playerOpeningTreeFenKey(Chess.initial.fen)],
    );
    expect(
      initialRefRows.map((row) => row['next_uci']?.toString()).toSet(),
      containsAll(<String>{'d2d4', 'e2e4'}),
    );
    final persistedHashes = await db.select(
      'SELECT pgn_hash FROM local_chess_games ORDER BY index_in_file ASC',
    );
    expect(
      persistedHashes.map((row) => row['pgn_hash']?.toString() ?? ''),
      everyElement(isNotEmpty),
    );

    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );

    expect(restored, isNotNull);
    expect(restored!.games, hasLength(2));
    expect(restored.gameCount, 2);
    expect(restored.games.first.pgnFingerprint, isNotEmpty);
    expect(restored.openingTreeIndex, isNotNull);
    expect(restored.openingTreeIndex!.downloadedGameCount, 2);
    expect(
      restored.openingTreeIndex!.movesForFen(Chess.initial.fen),
      isNotEmpty,
    );
    expect(restored.games.first.rawPgn, contains('[Event "Fast tree"]'));
    expect(restored.games.first.game.metadata['WhiteTitle'], 'GM');
    expect(restored.games.first.game.metadata['BlackTitle'], 'GM');
    expect(restored.games.first.game.metadata['WhiteFed'], 'CHN');
    expect(restored.games.first.game.metadata['BlackFed'], 'IND');
    final restoredRow =
        restored.openingTreeIndex!.gameRowsById[restored.games.first.id]!;
    expect(restoredRow, containsPair('whiteTitle', 'GM'));
    expect(restoredRow, containsPair('blackTitle', 'GM'));
    expect(restoredRow, containsPair('whiteFed', 'CHN'));
    expect(restoredRow, containsPair('blackFed', 'IND'));
    expect(restoredRow, containsPair('whiteFideId', '8602980'));
    expect(restoredRow, containsPair('blackFideId', '46616543'));
    expect(
      restoredRow,
      containsPair('pgnHash', restored.games.first.pgnFingerprint),
    );
    expect(restoredRow, containsPair('pgn', restored.games.first.rawPgn));
  });

  test(
    'purging a deleted source clears every child cache row across batches',
    () async {
      final pgnFile = File('${temp.path}/purge-me.pgn');
      await pgnFile.writeAsString(_bulkPgn(5));
      final repo = LocalChessDatabaseRepository(database: () async => db);

      final source = await repo.importSingleFileSource(path: pgnFile.path);
      expect(source, isNotNull);
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 5);

      expect(await repo.markCachedSourceDeleted(pgnFile.path), 1);

      final progress = <LocalChessScanProgress>[];
      // A batch size below the row count forces the chunked delete loop to run
      // several iterations. This is the path that used to SELECT a batch of
      // rowids back to the caller (materializing them on the calling isolate)
      // and now deletes via a writer-side subquery instead — the change that
      // stops a heavy player removal from dropping frames.
      final purged = await repo.purgeDeletedCaches(
        batchSize: 2,
        onProgress: progress.add,
      );

      expect(purged, 1);
      expect(await _count(db, 'local_chess_games'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(progress.last.message, 'Delete complete.');
    },
  );

  test(
    'queued import persists all PGN games while returning only preview rows',
    () async {
      final pgnFile = File('${temp.path}/bulk.pgn');
      await pgnFile.writeAsString(_bulkPgn(5));
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 2,
      );
      final progress = <LocalChessScanProgress>[];

      final source = await repo.importSingleFileSource(
        path: pgnFile.path,
        onProgress: progress.add,
      );

      expect(source, isNotNull);
      final fileNode = source!.root.singlePlayableDatabaseInSubtree!;
      expect(fileNode.gameCount, 5);
      expect(fileNode.games, hasLength(2));
      expect(fileNode.openingTreeIndex, isNull);
      expect(
        progress.map((event) => event.message),
        contains('Importing games...'),
      );
      expect(
        progress.map((event) => event.message),
        contains('Saving local cache...'),
      );
      expect(
        progress.map((event) => event.message),
        isNot(contains('Opening local database writer...')),
      );
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 5);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      final gameRows = await db.select(
        '''
        SELECT moves, ply_count
        FROM local_chess_games
        WHERE database_id = ?
        ORDER BY index_in_file ASC
        ''',
        <Object?>[pgnFile.path],
      );
      expect(gameRows, hasLength(5));
      // The streaming importer now derives the UCI move line (and ply_count)
      // from the retained PGN so the opening-explorer move-prefix fallback can
      // filter games at non-root positions on large local databases.
      expect(
        gameRows.map((row) => jsonDecode(row['moves'] as String)),
        everyElement(<String>['e2e4', 'e7e5', 'g1f3', 'b8c6']),
      );
      expect(gameRows.map((row) => row['ply_count']), everyElement(4));
      final databaseRows = await db.select(
        '''
        SELECT game_count, position_count, deleted_at_ms
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(databaseRows.single['game_count'], 5);
      expect(databaseRows.single['position_count'], 0);
      expect(databaseRows.single['deleted_at_ms'], isNull);

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      expect(restored, isNotNull);
      expect(restored!.gameCount, 5);
      expect(restored.games, hasLength(2));
      expect(restored.games.first.game.metadata['White'], 'White 0');
    },
  );

  test(
    'queued import replaces stale same-path cache with chunked purge',
    () async {
      final pgnFile = File('${temp.path}/stale-reimport.pgn');
      await pgnFile.writeAsString(_bulkPgn(3));
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 2,
      );
      final firstImport = await repo.importSingleFileSource(path: pgnFile.path);
      expect(firstImport, isNotNull);
      final gameIds = await db.select(
        '''
        SELECT id
        FROM local_chess_games
        WHERE database_id = ?
        ORDER BY index_in_file ASC
        ''',
        <Object?>[pgnFile.path],
      );
      await _seedGeneratedCacheRows(
        db,
        pgnFile.path,
        gameIds: <String>[for (final row in gameIds) row['id'] as String],
      );
      expect(await repo.markCachedSourceDeleted(pgnFile.path), 1);
      final progress = <LocalChessScanProgress>[];

      expect(await _count(db, 'local_chess_games'), 3);
      expect(await _count(db, 'local_chess_tree_nodes'), 95);
      expect(await _count(db, 'local_chess_position_games'), 80);
      expect(await _count(db, 'local_chess_game_analysis'), 1);

      final source = await repo.importSingleFileSource(
        path: pgnFile.path,
        onProgress: progress.add,
      );

      expect(source, isNotNull);
      final fileNode = source!.root.singlePlayableDatabaseInSubtree!;
      expect(fileNode.gameCount, 3);
      expect(fileNode.games, hasLength(2));
      expect(
        progress.map((event) => event.message),
        contains('Replacing existing local cache...'),
      );
      expect(
        progress.map((event) => event.message),
        contains('Importing games...'),
      );
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 3);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 0);
      final databaseRows = await db.select(
        '''
        SELECT game_count, position_count, tree_max_ply, deleted_at_ms
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(databaseRows, hasLength(1));
      expect(databaseRows.single['game_count'], 3);
      expect(databaseRows.single['position_count'], 0);
      expect(databaseRows.single['tree_max_ply'], isNull);
      expect(databaseRows.single['deleted_at_ms'], isNull);
    },
  );

  test(
    'queued import falls back to a cache path when app cache open fails',
    () async {
      final pgnFile = File('${temp.path}/worker-path-only.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final workerDbPath = p.join(temp.path, 'worker-only-local-chess.db');
      final legacyWorkerDb = await resqlite.Database.open(workerDbPath);
      await _createPreTimeControlResqliteCache(
        legacyWorkerDb,
        databaseId: pgnFile.path,
      );
      await legacyWorkerDb.close();
      var openedAppCache = false;
      final repo = LocalChessDatabaseRepository(
        database: () async {
          openedAppCache = true;
          throw StateError('app cache should not be opened for queued import');
        },
        databaseFilePath: () async => workerDbPath,
        cachedFileNodeGamePreviewLimit: 1,
      );

      final source = await repo.importSingleFileSource(path: pgnFile.path);

      expect(source, isNotNull);
      expect(openedAppCache, isTrue);
      final fileNode = source!.root.singlePlayableDatabaseInSubtree!;
      expect(fileNode.gameCount, 2);
      expect(fileNode.games, hasLength(1));
      final workerDb = await resqlite.Database.open(workerDbPath);
      addTearDown(workerDb.close);
      expect(await _count(workerDb, 'local_chess_databases'), 1);
      expect(await _count(workerDb, 'local_chess_games'), 2);
    },
  );

  test('path-only fallback prepares schema through the write queue', () async {
    final pgnFile = File('${temp.path}/queued-path-fallback.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final workerDbPath = p.join(temp.path, 'queued-path-only-local-chess.db');
    final progressMessages = <String>[];
    final repo = LocalChessDatabaseRepository(
      database: () async => throw StateError('app cache unavailable'),
      databaseFilePath: () async => workerDbPath,
      cachedFileNodeGamePreviewLimit: 1,
    );

    final queueEntered = Completer<void>();
    final releaseQueue = Completer<void>();
    final held = LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
      queueEntered.complete();
      await releaseQueue.future;
    });
    await queueEntered.future.timeout(const Duration(seconds: 5));

    final importFuture = repo.importSingleFileSource(
      path: pgnFile.path,
      onProgress: (progress) => progressMessages.add(progress.message),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(progressMessages, contains('Preparing local database cache...'));
    expect(
      progressMessages,
      isNot(contains('Checking local database schema...')),
    );
    expect(progressMessages, isNot(contains('Local database cache ready.')));

    releaseQueue.complete();
    final source = await importFuture.timeout(const Duration(seconds: 5));
    await held.timeout(const Duration(seconds: 5));

    expect(source, isNotNull);
    expect(progressMessages, contains('Checking local database schema...'));
    expect(progressMessages, contains('Local database cache ready.'));
  });

  test(
    'queued import prefers the open app cache over a path-only writer',
    () async {
      final pgnFile = File('${temp.path}/shared-cache-import.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final pathResolverUsed = Completer<void>();
      final neverResolvesPath = Completer<String>();
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        databaseFilePath: () {
          if (!pathResolverUsed.isCompleted) pathResolverUsed.complete();
          return neverResolvesPath.future;
        },
        cachedFileNodeGamePreviewLimit: 1,
      );

      final source = await repo
          .importSingleFileSource(path: pgnFile.path)
          .timeout(const Duration(seconds: 2));

      expect(source, isNotNull);
      final fileNode = source!.root.singlePlayableDatabaseInSubtree!;
      expect(fileNode.gameCount, 2);
      expect(fileNode.games, hasLength(1));
      expect(pathResolverUsed.isCompleted, isFalse);
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
    },
  );

  test('import does not hold write queue while app cache opens', () async {
    final pgnFile = File('${temp.path}/pending-cache-open.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final openRequested = Completer<void>();
    final openCache = Completer<resqlite.Database>();
    final repo = LocalChessDatabaseRepository(
      database: () {
        if (!openRequested.isCompleted) openRequested.complete();
        return openCache.future;
      },
      cachedFileNodeGamePreviewLimit: 1,
    );

    final importFuture = repo.importSingleFileSource(path: pgnFile.path);
    await openRequested.future.timeout(const Duration(seconds: 5));

    final queueEntered = Completer<void>();
    final openerSchemaWork =
        LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
          queueEntered.complete();
          if (!openCache.isCompleted) openCache.complete(db);
        });

    Object? queueWaitError;
    try {
      await queueEntered.future.timeout(const Duration(seconds: 1));
    } catch (error) {
      queueWaitError = error;
    } finally {
      if (!openCache.isCompleted) openCache.complete(db);
    }

    await importFuture.timeout(const Duration(seconds: 5));
    await openerSchemaWork.timeout(const Duration(seconds: 5));

    expect(
      queueWaitError,
      isNull,
      reason:
          'Import must not hold the local chess write queue while waiting for '
          'an app-cache open that may itself need the write queue for schema '
          'or migration work.',
    );
    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 2);
  });

  test(
    'canceled queued import does not poison same-path retry or write queue',
    () async {
      final pgnFile = File('${temp.path}/canceled-retry.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final token = OperationCancellationToken();
      final pathLookupStarted = Completer<void>();
      final blockedPathLookup = Completer<String>();
      final blockedRepo = LocalChessDatabaseRepository(
        database: () async {
          throw StateError('database should not open before path resolver');
        },
        databaseFilePath: () {
          if (!pathLookupStarted.isCompleted) pathLookupStarted.complete();
          return blockedPathLookup.future;
        },
      );

      final firstImport = blockedRepo.importSingleFileSource(
        path: pgnFile.path,
        cancellationToken: token,
      );
      await pathLookupStarted.future.timeout(const Duration(seconds: 5));
      token.cancel();

      await expectLater(
        firstImport,
        throwsA(isA<OperationCanceledException>()),
      );

      final retryRepo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 1,
      );
      final retried = await retryRepo
          .importSingleFileSource(path: pgnFile.path)
          .timeout(const Duration(seconds: 5));

      expect(retried, isNotNull);
      final fileNode = retried!.root.singlePlayableDatabaseInSubtree!;
      expect(fileNode.gameCount, 2);
      expect(fileNode.games, hasLength(1));
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
    },
  );

  test(
    'concurrent queued imports of the same PGN do not corrupt cache',
    () async {
      final pgnFile = File('${temp.path}/concurrent.pgn');
      await pgnFile.writeAsString(_bulkPgn(40));
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 3,
      );

      final imports = await Future.wait(<Future<LocalChessSource?>>[
        repo.importSingleFileSource(path: pgnFile.path),
        repo.importSingleFileSource(path: pgnFile.path),
      ]);

      expect(imports, everyElement(isNotNull));
      for (final source in imports.whereType<LocalChessSource>()) {
        final fileNode = source.root.singlePlayableDatabaseInSubtree!;
        expect(fileNode.gameCount, 40);
        expect(fileNode.games, hasLength(3));
      }
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 40);
      final databaseRows = await db.select(
        '''
        SELECT game_count, position_count, deleted_at_ms
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(databaseRows, hasLength(1));
      expect(databaseRows.single['game_count'], 40);
      expect(databaseRows.single['position_count'], 0);
      expect(databaseRows.single['deleted_at_ms'], isNull);
    },
  );

  test(
    'concurrent queued imports of different PGNs serialize writes',
    () async {
      final first = File('${temp.path}/concurrent-a.pgn');
      final second = File('${temp.path}/concurrent-b.pgn');
      await first.writeAsString(_bulkPgn(25));
      await second.writeAsString(_bulkPgn(30));
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 2,
      );

      final imports = await Future.wait(<Future<LocalChessSource?>>[
        repo.importSingleFileSource(path: first.path),
        repo.importSingleFileSource(path: second.path),
      ]);

      expect(imports, everyElement(isNotNull));
      expect(await _count(db, 'local_chess_databases'), 2);
      expect(await _count(db, 'local_chess_games'), 55);
      final rows = await db.select('''
        SELECT id, game_count, deleted_at_ms
        FROM local_chess_databases
        ORDER BY id ASC
        ''');
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['game_count']), containsAll(<int>[25, 30]));
      expect(rows.map((row) => row['deleted_at_ms']), everyElement(isNull));
    },
  );

  test(
    'large-import indexes skip blocking position refs but still page games',
    () async {
      final pgnFile = File('${temp.path}/large-mode.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final largeModeIndex = buildLocalOpeningTreeIndex(
        treeId: 'local:test-large-mode',
        databaseId: pgnFile.path,
        includePositionGameRefs: false,
        includeGameRows: false,
        games: [
          for (final game in fileNode.games)
            LocalOpeningTreeGameInput(
              id: game.id,
              rawPgn: game.rawPgn,
              sourcePath: game.sourcePath,
              sourceRelativePath: game.sourceRelativePath,
              fileName: game.fileName,
              indexInFile: game.indexInFile,
              fileGameCount: game.fileGameCount,
            ),
        ],
      );
      expect(largeModeIndex.gamesByFen, isEmpty);
      expect(largeModeIndex.gameRowsById, isEmpty);
      expect(largeModeIndex.downloadedGameCount, fileNode.games.length);
      final largeModeFile = LocalChessFileNode(
        name: fileNode.name,
        path: fileNode.path,
        relativePath: fileNode.relativePath,
        extension: fileNode.extension,
        status: fileNode.status,
        games: fileNode.games,
        sizeBytes: fileNode.sizeBytes,
        modifiedAt: fileNode.modifiedAt,
        message: fileNode.message,
        openingTreeIndex: largeModeIndex,
        pgnOffsetIndex: fileNode.pgnOffsetIndex,
      );
      final repo = LocalChessDatabaseRepository(database: () async => db);

      await repo.persistFileNode(largeModeFile, sourceLabel: source.label);

      expect(await _count(db, 'local_chess_position_games'), 0);
      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      expect(restored, isNotNull);
      expect(
        restored!.openingTreeIndex!.downloadedGameCount,
        fileNode.games.length,
      );
      final response = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'd2d4',
        filters: const PlayerOpeningTreeFilterCriteria(),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(response, isNotNull);
      expect(response!.metadata.totalCount, 1);
      expect(response.data.single['white'], 'Hou, Yifan');
      expect(response.data.single['pgn'], contains('[Event "Fast tree"]'));
      final moves = await repo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
      );
      expect(moves.map((move) => move.uci), contains('d2d4'));
      expect(moves.singleWhere((move) => move.uci == 'd2d4').total, 1);

      final filteredMovesWithoutRefs = await repo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        filters: const PlayerOpeningTreeFilterCriteria(result: 'D'),
      );
      expect(filteredMovesWithoutRefs.map((move) => move.uci), ['d2d4']);
      expect(filteredMovesWithoutRefs.single.draws, 1);

      final filteredResponse = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'd2d4',
        filters: const PlayerOpeningTreeFilterCriteria(result: 'D'),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(filteredResponse, isNotNull);
      expect(filteredResponse!.metadata.totalCount, 1);
      expect(filteredResponse.data.single['result'], '1/2-1/2');

      final emptyFilteredResponse = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'd2d4',
        filters: const PlayerOpeningTreeFilterCriteria(result: 'B'),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(emptyFilteredResponse, isNotNull);
      expect(emptyFilteredResponse!.metadata.totalCount, 0);

      final afterSicilian =
          Chess.initial
              .play(NormalMove.fromUci('e2e4'))
              .play(NormalMove.fromUci('c7c5'))
              .fen;
      final prefixResponse = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: afterSicilian,
        moves: const <String>['e2e4', 'c7c5'],
        filters: const PlayerOpeningTreeFilterCriteria(),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(prefixResponse, isNotNull);
      expect(prefixResponse!.metadata.totalCount, 1);
      expect(prefixResponse.data.single['white'], 'Polgar, Judit');
      expect(
        (prefixResponse.data.single['continuation'] as List).first,
        'g1f3',
      );
      expect(prefixResponse.data.single['pgn'], contains('[Event "Training"]'));

      final filteredPrefixMovesWithoutRefs = await repo
          .localMoveAggregatesForFen(
            databasePath: pgnFile.path,
            fen: afterSicilian,
            moves: const <String>['e2e4', 'c7c5'],
            filters: const PlayerOpeningTreeFilterCriteria(result: 'B'),
          );
      expect(filteredPrefixMovesWithoutRefs.map((move) => move.uci), ['g1f3']);
      expect(filteredPrefixMovesWithoutRefs.single.black, 1);
    },
  );

  test('persists rebuilt opening tree without rewriting game rows', () async {
    final pgnFile = File('${temp.path}/tree-only-rebuild.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    const sentinelRawPgn = '[Event "Do not rewrite games"]\n\n1. a3 *\n';
    await db.execute(
      'UPDATE local_chess_games SET raw_pgn = ? WHERE id = ?',
      <Object?>[sentinelRawPgn, fileNode.games.first.id],
    );

    final rebuiltIndex = buildLocalOpeningTreeIndex(
      treeId: 'local:test-tree-only-rebuild',
      databaseId: pgnFile.path,
      maxPly: 1,
      includePositionGameRefs: false,
      includeGameRows: false,
      games: [
        for (final game in fileNode.games)
          LocalOpeningTreeGameInput(
            id: game.id,
            rawPgn: game.rawPgn,
            sourcePath: game.sourcePath,
            sourceRelativePath: game.sourceRelativePath,
            fileName: game.fileName,
            indexInFile: game.indexInFile,
            fileGameCount: game.fileGameCount,
          ),
      ],
    );

    final persisted = await repo.persistOpeningTreeIndex(
      databasePath: pgnFile.path,
      index: rebuiltIndex,
    );

    expect(persisted, isTrue);
    expect(await _count(db, 'local_chess_games'), fileNode.games.length);
    expect(await _count(db, 'local_chess_position_games'), 0);

    final rawRows = await db.select(
      'SELECT raw_pgn FROM local_chess_games WHERE id = ?',
      <Object?>[fileNode.games.first.id],
    );
    expect(rawRows.single['raw_pgn'], sentinelRawPgn);

    final treeStats = await db.select(
      '''
      SELECT COUNT(*) AS count, MAX(ply) AS max_ply
      FROM local_chess_tree_nodes
      WHERE database_id = ?
      ''',
      <Object?>[pgnFile.path],
    );
    expect(treeStats.single['count'], rebuiltIndex.positionCount);
    expect(treeStats.single['max_ply'], 1);

    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );
    expect(restored, isNotNull);
    expect(
      restored!.openingTreeIndex!.downloadedGameCount,
      fileNode.games.length,
    );
  });

  test(
    'queries cached local games with SQL search sort pagination and lazy PGN',
    () async {
      final pgnFile = File('${temp.path}/games-page.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final firstPage = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        sortBy: LocalChessGameSortField.whiteElo,
        sortDirection: LocalChessGameSortDirection.desc,
        pageNumber: 0,
        pageSize: 1,
      );
      expect(firstPage, isNotNull);
      expect(firstPage!.totalCount, 2);
      expect(firstPage.hasMore, isTrue);
      expect(firstPage.games, hasLength(1));
      expect(firstPage.games.single.game.metadata['White'], 'Polgar, Judit');

      final secondPage = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        sortBy: LocalChessGameSortField.whiteElo,
        sortDirection: LocalChessGameSortDirection.desc,
        pageNumber: 1,
        pageSize: 1,
      );
      expect(secondPage, isNotNull);
      expect(secondPage!.hasMore, isFalse);
      expect(secondPage.games.single.game.metadata['White'], 'Hou, Yifan');

      final siteMatch = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        search: 'budapest',
        pageNumber: 0,
        pageSize: 10,
      );
      expect(siteMatch, isNotNull);
      expect(siteMatch!.totalCount, 1);
      expect(siteMatch.games.single.game.metadata['Site'], 'Budapest');

      final federationMatch = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        search: 'chn',
        pageNumber: 0,
        pageSize: 10,
      );
      expect(federationMatch, isNotNull);
      expect(federationMatch!.totalCount, 1);
      expect(federationMatch.games.single.game.metadata['WhiteTitle'], 'GM');
      expect(federationMatch.games.single.game.metadata['WhiteFed'], 'CHN');

      await db.execute(
        'UPDATE local_chess_games SET raw_pgn = ?',
        const <Object?>['[Event "Stale DB text"]\n\n1. a3 *\n'],
      );

      final titleMatch = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        search: 'gm',
        pageNumber: 0,
        pageSize: 10,
      );
      expect(titleMatch, isNotNull);
      expect(titleMatch!.totalCount, 1);
      expect(titleMatch.games.single.sourceByteStart, isNotNull);
      expect(titleMatch.games.single.sourceByteEnd, isNotNull);
      expect(titleMatch.games.single.rawPgn, contains('[Event "Fast tree"]'));
      expect(titleMatch.games.single.rawPgn, isNot(contains('Stale DB text')));
    },
  );

  test(
    'preserves alternate PGN title federation and custom headers in cached rows',
    () async {
      final pgnFile = File('${temp.path}/metadata.pgn');
      await pgnFile.writeAsString(_metadataPgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final page = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(page, isNotNull);
      final metadata = page!.games.single.game.metadata;
      expect(metadata['WhiteTitle'], 'GM');
      expect(metadata['BlackTitle'], 'IM');
      expect(metadata['WhiteCountry'], 'NOR');
      expect(metadata['BlackTeamCountry'], 'USA');
      expect(metadata['WhiteFideId'], '1503014');
      expect(metadata['CustomHeader'], 'Preserved');
      expect(page.games.single.rawPgn, contains('[CustomHeader "Preserved"]'));

      final response = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'd2d4',
        filters: const PlayerOpeningTreeFilterCriteria(),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(response, isNotNull);
      final row = response!.data.single;
      expect(row['whiteTitle'], 'GM');
      expect(row['blackTitle'], 'IM');
      expect(row['whiteFed'], 'NOR');
      expect(row['blackFed'], 'USA');
      expect(row['whiteFideId'], '1503014');
      expect(row['metadata'], containsPair('CustomHeader', 'Preserved'));
    },
  );

  test(
    'schema backfills missing PGN hashes for existing resqlite caches',
    () async {
      final pgnFile = File('${temp.path}/missing-hash.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      await db.execute(
        'UPDATE local_chess_games SET pgn_hash = NULL WHERE database_id = ?',
        <Object?>[pgnFile.path],
      );

      await createLocalChessResqliteDatabaseSchema(db);

      final missingRows = await db.select(
        '''
      SELECT COUNT(*) AS count
      FROM local_chess_games
      WHERE database_id = ?
        AND (pgn_hash IS NULL OR pgn_hash = '')
      ''',
        <Object?>[pgnFile.path],
      );
      expect(missingRows.single['count'], 0);
      final matching = await repo.localDatabaseMatchingPgnFingerprints(
        databasePath: pgnFile.path,
        fingerprints: <String>{fileNode.games.first.pgnFingerprint},
      );
      expect(matching, {fileNode.games.first.pgnFingerprint});
    },
  );

  test(
    'restores cached raw PGNs from source byte ranges without hydrating DB text',
    () async {
      final pgnFile = File('${temp.path}/range-backed.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final offsetRows = await db.select('''
      SELECT source_byte_start, source_byte_end
      FROM local_chess_games
      WHERE source_byte_start IS NOT NULL AND source_byte_end IS NOT NULL
      ORDER BY index_in_file ASC
      ''');
      expect(offsetRows, hasLength(2));

      await db.execute(
        'UPDATE local_chess_games SET raw_pgn = ?',
        const <Object?>['[Event "Stale DB text"]\n\n1. a3 *\n'],
      );

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNotNull);
      expect(restored!.games.first.sourceByteStart, isNotNull);
      expect(restored.games.first.sourceByteEnd, isNotNull);
      expect(restored.games.first.rawPgn, contains('[Event "Fast tree"]'));
      expect(restored.games.first.rawPgn, isNot(contains('Stale DB text')));
    },
  );

  test(
    'cached file node hydrates only preview games while keeping total count',
    () async {
      final pgnFile = File('${temp.path}/preview-cap.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final readRepo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 1,
      );

      final restored = await readRepo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNotNull);
      expect(restored!.gameCount, 2);
      expect(restored.games, hasLength(1));
      expect(restored.games.single.game.metadata['White'], 'Hou, Yifan');
      final page = await readRepo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        sortBy: LocalChessGameSortField.whiteElo,
        sortDirection: LocalChessGameSortDirection.desc,
        pageNumber: 0,
        pageSize: 1,
      );
      expect(page, isNotNull);
      expect(page!.totalCount, 2);
      expect(page.games.single.game.metadata['White'], 'Polgar, Judit');
    },
  );

  test(
    'refuses to persist partial preview nodes without truncating cache',
    () async {
      final pgnFile = File('${temp.path}/partial-preview.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final writeRepo = LocalChessDatabaseRepository(database: () async => db);
      await writeRepo.persistFileNode(fileNode, sourceLabel: source.label);
      final readRepo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 1,
      );
      final preview = await readRepo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      expect(preview, isNotNull);
      expect(preview!.games, hasLength(1));
      expect(preview.gameCount, 2);

      await expectLater(
        writeRepo.persistFileNode(preview, sourceLabel: source.label),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('partial local chess preview'),
          ),
        ),
      );

      final page = await writeRepo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(page, isNotNull);
      expect(page!.totalCount, 2);
      expect(await _count(db, 'local_chess_games'), 2);
    },
  );

  test(
    'large cached local tree skips eager game rows and serves position games from SQLite',
    () async {
      final pgnFile = File('${temp.path}/sql-backed-tree.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final readRepo = LocalChessDatabaseRepository(
        database: () async => db,
        eagerPositionRefLoadLimit: 0,
      );

      final restored = await readRepo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNotNull);
      final index = restored!.openingTreeIndex!;
      expect(index.positionCount, greaterThan(1));
      expect(index.gamesByFen, isEmpty);
      expect(index.gameRowsById, isEmpty);
      final response = await readRepo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'd2d4',
        filters: const PlayerOpeningTreeFilterCriteria(),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(response, isNotNull);
      expect(response!.metadata.totalCount, 1);
      expect(response.data.single['event'], 'Fast tree');
      expect(response.data.single['pgn'], contains('[Event "Fast tree"]'));
    },
  );

  test(
    'large cached local tree serves unfiltered moves from tree totals',
    () async {
      final pgnFile = File('${temp.path}/sql-backed-moves.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final readRepo = LocalChessDatabaseRepository(
        database: () async => db,
        eagerTreeMoveLoadLimit: 0,
      );

      final restored = await readRepo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      final index = restored!.openingTreeIndex!;
      expect(index.movesForFen(Chess.initial.fen), isEmpty);

      await db.execute(
        '''
        UPDATE local_chess_tree_moves
        SET black = 7, total = 7
        WHERE database_id = ? AND uci = ?
        ''',
        <Object?>[pgnFile.path, 'e2e4'],
      );

      final moves = await readRepo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
      );
      expect(
        moves.map((move) => move.uci),
        containsAll(<String>['d2d4', 'e2e4']),
      );
      final e4 = moves.singleWhere((move) => move.uci == 'e2e4');
      expect(e4.black, 7);
      expect(e4.total, 7);

      final blackWins = await readRepo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        filters: const PlayerOpeningTreeFilterCriteria(result: 'B'),
      );
      expect(blackWins.map((move) => move.uci), ['e2e4']);
      expect(blackWins.single.black, 1);

      await db.execute(
        '''
        UPDATE local_chess_position_games
        SET next_uci = NULL
        WHERE database_id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      await createLocalChessResqliteDatabaseSchema(db);
      final backfilled = await readRepo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
      );
      expect(backfilled.map((move) => move.uci), contains('e2e4'));
    },
  );

  test(
    'local position filters combine player side time result format year and rating in SQL',
    () async {
      final pgnFile = File('${temp.path}/filtered-local-tree.pgn');
      await pgnFile.writeAsString(_filterPgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final derivedRows = await db.select(
        '''
        SELECT
          json_extract(headers_json, '\$.Event') AS event,
          time_control_category,
          is_online
        FROM local_chess_games
        WHERE database_id = ?
        ORDER BY index_in_file ASC
        ''',
        <Object?>[pgnFile.path],
      );
      expect(derivedRows.map((row) => row['time_control_category']), [
        'rapid',
        'blitz',
        'classical',
      ]);
      expect(derivedRows.map((row) => row['is_online']), [0, 1, 0]);

      final sortedByEvent = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        filters: const PlayerOpeningTreeFilterCriteria(),
        sortBy: GamebaseSortField.event,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(sortedByEvent, isNotNull);
      expect(sortedByEvent!.data.map((row) => row['event']), [
        'Classical Local',
        'Online Blitz',
        'Rapid Local',
      ]);

      const carlsenWhiteRapid = PlayerOpeningTreeFilterCriteria(
        playerFideIds: <String>['1503014'],
        playerNames: <String>['Carlsen, Magnus'],
        color: 'white',
        timeControl: TimeControl.rapid,
        result: 'W',
        isOnline: false,
        yearFrom: 2024,
        yearTo: 2024,
        minRating: 2800,
        maxRating: 2900,
      );
      final rapidMoves = await repo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        filters: carlsenWhiteRapid,
      );
      expect(rapidMoves.map((move) => move.uci), ['e2e4']);
      expect(rapidMoves.single.white, 1);
      expect(rapidMoves.single.total, 1);

      final rapidGames = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'e2e4',
        filters: carlsenWhiteRapid,
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(rapidGames, isNotNull);
      expect(rapidGames!.metadata.totalCount, 1);
      expect(rapidGames.data.single['event'], 'Rapid Local');
      expect(rapidGames.data.single['white'], 'Carlsen, Magnus');

      // The opening tree still exposes the historical three-bucket control.
      // A newly precise Bullet row therefore remains reachable via Blitz.
      await db.execute(
        '''
        UPDATE local_chess_games
        SET time_control_category = 'bullet'
        WHERE database_id = ?
          AND json_extract(headers_json, '\$.Event') = 'Online Blitz'
        ''',
        <Object?>[pgnFile.path],
      );

      const carlsenBlackOnlineBlitz = PlayerOpeningTreeFilterCriteria(
        playerFideIds: <String>['1503014'],
        playerNames: <String>['Carlsen, Magnus'],
        color: 'black',
        timeControl: TimeControl.blitz,
        result: 'B',
        isOnline: true,
        yearFrom: 2025,
        yearTo: 2025,
        minRating: 2800,
        maxRating: 2900,
      );
      final blitzMoves = await repo.localMoveAggregatesForFen(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        filters: carlsenBlackOnlineBlitz,
      );
      expect(blitzMoves.map((move) => move.uci), ['e2e4']);
      expect(blitzMoves.single.black, 1);
      expect(blitzMoves.single.total, 1);

      final blitzGames = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'e2e4',
        filters: carlsenBlackOnlineBlitz,
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(blitzGames, isNotNull);
      expect(blitzGames!.metadata.totalCount, 1);
      expect(blitzGames.data.single['event'], 'Online Blitz');
      expect(blitzGames.data.single['black'], 'Carlsen, Magnus');

      final nameOnlyBlitz = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'e2e4',
        filters: const PlayerOpeningTreeFilterCriteria(
          playerNames: <String>['Carlsen, Magnus'],
          color: 'black',
          timeControl: TimeControl.blitz,
          isOnline: true,
        ),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(nameOnlyBlitz, isNotNull);
      expect(nameOnlyBlitz!.metadata.totalCount, 1);

      final impossibleSide = await repo.localPositionGamesResponse(
        databasePath: pgnFile.path,
        fen: Chess.initial.fen,
        uci: 'e2e4',
        filters: const PlayerOpeningTreeFilterCriteria(
          playerNames: <String>['Carlsen, Magnus'],
          color: 'white',
          timeControl: TimeControl.blitz,
          isOnline: true,
        ),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(impossibleSide, isNotNull);
      expect(impossibleSide!.metadata.totalCount, 0);
    },
  );

  test(
    'unclassified imports persist Unknown so derived-filter repair converges',
    () async {
      final pgnFile = File('${temp.path}/unknown-time-control.pgn');
      await pgnFile.writeAsString('''
[Event "Casual notebook game"]
[Site "?"]
[Date "2024.01.01"]
[White "Player One"]
[Black "Player Two"]
[Result "1-0"]

1. e4 e5 1-0
''');
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      Future<Object?> storedCategory() async {
        final rows = await db.select(
          'SELECT time_control_category FROM local_chess_games '
          'WHERE database_id = ?',
          <Object?>[pgnFile.path],
        );
        return rows.single['time_control_category'];
      }

      expect(await storedCategory(), 'unknown');
      await createLocalChessResqliteDatabaseSchema(
        db,
      ).timeout(const Duration(seconds: 2));
      expect(await storedCategory(), 'unknown');
    },
  );

  test(
    'import indexes ECO opening fallback for display search and sort',
    () async {
      final pgnFile = File('${temp.path}/eco-opening-fallback.pgn');
      await pgnFile.writeAsString('''
[Event "Opening fallback"]
[Site "OTB Hall"]
[Date "2024.01.01"]
[White "Player One"]
[Black "Player Two"]
[ECO "C02"]
[Result "1-0"]

1. e4 e6 2. d4 d5 3. e5 1-0
''');
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final all = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        sortBy: LocalChessGameSortField.opening,
        sortDirection: LocalChessGameSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(all, isNotNull);
      expect(all!.games.single.game.metadata['Opening'], 'French: Advance');

      final searched = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        search: 'French Advance',
        sortBy: LocalChessGameSortField.opening,
        sortDirection: LocalChessGameSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(searched, isNotNull);
      expect(searched!.totalCount, 1);

      await db.execute(
        "UPDATE local_chess_games SET headers_json = "
        "json_remove(headers_json, '\$.Opening') WHERE database_id = ?",
        <Object?>[pgnFile.path],
      );
      await db.execute(
        'DELETE FROM local_chess_migrations WHERE name = ?',
        const <Object?>['local_chess_opening_name_backfill_v1'],
      );
      await createLocalChessResqliteDatabaseSchema(db);
      final repaired = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(
        repaired!.games.single.game.metadata['Opening'],
        'French: Advance',
      );
    },
  );

  test(
    'rejects stale persisted PGN rows when the file fingerprint changes',
    () async {
      final pgnFile = File('${temp.path}/stale.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pgnFile.writeAsString('[Event "Changed"]\n\n1. c4 c5 *\n');

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNull);
    },
  );

  test(
    'restores cached PGN rows and tree when only file timestamp changes',
    () async {
      final pgnFile = File('${temp.path}/timestamp-drift.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final beforeRows = await db.select(
        '''
        SELECT content_fingerprint, position_count
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      final beforeFingerprint =
          beforeRows.single['content_fingerprint']?.toString() ?? '';
      expect(beforeFingerprint, isNotEmpty);
      expect(beforeRows.single['position_count'], greaterThan(0));

      await pgnFile.setLastModified(
        pgnFile.lastModifiedSync().add(const Duration(seconds: 7)),
      );
      final changedStat = await pgnFile.stat();

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNotNull);
      expect(restored!.games, hasLength(2));
      expect(restored.openingTreeIndex, isNotNull);
      expect(restored.openingTreeIndex!.downloadedGameCount, 2);
      final afterRows = await db.select(
        '''
        SELECT modified_at_ms, content_fingerprint, position_count
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(
        afterRows.single['modified_at_ms'],
        changedStat.modified.millisecondsSinceEpoch,
      );
      expect(afterRows.single['content_fingerprint'], beforeFingerprint);
      expect(
        afterRows.single['position_count'],
        beforeRows.single['position_count'],
      );
    },
  );

  test(
    'direct unchanged queued import preserves rebuilt opening tree cache',
    () async {
      final pgnFile = File('${temp.path}/reimport-preserve-tree.pgn');
      await pgnFile.writeAsString(_bulkPgn(4));
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        cachedFileNodeGamePreviewLimit: 2,
      );
      final firstImport = await repo.importSingleFileSource(path: pgnFile.path);
      expect(firstImport, isNotNull);
      final rebuilt = await repo.rebuildOpeningTreeFromCachedGames(
        databasePath: pgnFile.path,
      );
      expect(rebuilt, isNotNull);
      expect(rebuilt!.index.positionCount, greaterThan(0));
      final beforeRows = await db.select(
        '''
        SELECT position_count, tree_max_ply
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      final beforeNodeCount = await _count(db, 'local_chess_tree_nodes');
      final beforeMoveCount = await _count(db, 'local_chess_tree_moves');
      expect(beforeRows.single['position_count'], greaterThan(0));
      expect(beforeNodeCount, greaterThan(0));
      expect(beforeMoveCount, greaterThan(0));

      await pgnFile.setLastModified(
        pgnFile.lastModifiedSync().add(const Duration(seconds: 9)),
      );
      final progress = <LocalChessScanProgress>[];

      final secondImport = await repo.importSingleFileSource(
        path: pgnFile.path,
        onProgress: progress.add,
      );

      expect(secondImport, isNotNull);
      expect(
        progress.map((event) => event.message),
        contains('Using existing local cache...'),
      );
      final afterRows = await db.select(
        '''
        SELECT position_count, tree_max_ply
        FROM local_chess_databases
        WHERE id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(
        afterRows.single['position_count'],
        beforeRows.single['position_count'],
      );
      expect(
        afterRows.single['tree_max_ply'],
        beforeRows.single['tree_max_ply'],
      );
      expect(await _count(db, 'local_chess_tree_nodes'), beforeNodeCount);
      expect(await _count(db, 'local_chess_tree_moves'), beforeMoveCount);
      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );
      expect(restored, isNotNull);
      expect(restored!.openingTreeIndex, isNotNull);
      expect(restored.openingTreeIndex!.downloadedGameCount, 4);
    },
  );

  test(
    'rejects incomplete persisted game rows after interrupted writes',
    () async {
      final pgnFile = File('${temp.path}/partial-cache.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      await db.execute(
        '''
      DELETE FROM local_chess_games
      WHERE database_id = ? AND index_in_file = ?
      ''',
        <Object?>[pgnFile.path, 1],
      );

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNull);
    },
  );

  test('drops incomplete persisted tree rows so rebuild can restart', () async {
    final pgnFile = File('${temp.path}/partial-tree-cache.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);
    await db.execute(
      '''
      DELETE FROM local_chess_tree_nodes
      WHERE database_id = ? AND node_id <> 0
      ''',
      <Object?>[pgnFile.path],
    );

    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );

    expect(restored, isNotNull);
    expect(restored!.games, hasLength(2));
    expect(restored.openingTreeIndex, isNull);
  });

  test('returns null for an uncached single source', () async {
    final pgnFile = File('${temp.path}/uncached.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final repo = LocalChessDatabaseRepository(database: () async => db);

    final restored = await repo.loadFreshSource(<String>[pgnFile.path]);

    expect(restored, isNull);
  });

  test('cached folder source skips empty non-chess subdirectories', () async {
    final root = Directory('${temp.path}/workspace');
    await root.create();
    final docs = Directory('${root.path}/docs');
    await docs.create();
    await File('${docs.path}/notes.txt').writeAsString('not chess');
    final pgnFile = File('${root.path}/lines.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[root.path]);
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistSource(source);

    final restored = await repo.loadFreshSource(<String>[root.path]);

    expect(restored, isNotNull);
    expect(restored!.root.gameCount, 2);
    expect(restored.root.folders, isEmpty);
    expect(restored.root.files.single.path, pgnFile.path);
  });

  test(
    'restores cached PGN rows when opening tree nodes are missing',
    () async {
      final pgnFile = File('${temp.path}/corrupt-cache.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      await db.execute('DELETE FROM local_chess_tree_nodes');

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNotNull);
      expect(restored!.games, hasLength(2));
      expect(restored.openingTreeIndex, isNull);
    },
  );

  test('persists local-only board annotations by game id', () async {
    final pgnFile = File('${temp.path}/annotated.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);
    final databaseRow =
        (await db.select('SELECT * FROM local_chess_databases LIMIT 1')).single;
    final now = DateTime.utc(2026, 6, 26);

    await repo.saveLocalGameAnalysis(
      LocalChessGameAnalysis(
        gameId: fileNode.games.first.id,
        databaseId: databaseRow['id'] as String,
        analysisState: const <String, dynamic>{'pane': 'tree'},
        variationComments: const <String, String>{'0:0': 'critical'},
        moveNags: const <String, List<int>>{
          '0:0': <int>[1, 14],
        },
        lastViewedPosition: 3,
        notes: 'Remember this line',
        isFavorite: true,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final restored = await repo.localGameAnalysis(fileNode.games.first.id);

    expect(restored, isNotNull);
    expect(restored!.analysisState, {'pane': 'tree'});
    expect(restored.variationComments, {'0:0': 'critical'});
    expect(restored.moveNags, {
      '0:0': <int>[1, 14],
    });
    expect(restored.lastViewedPosition, 3);
    expect(restored.notes, 'Remember this line');
    expect(restored.isFavorite, isTrue);
  });

  test(
    'deleteCachedSource purges games tree analysis and local metadata',
    () async {
      final pgnFile = File('${temp.path}/purge.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);
      final databaseRow =
          (await db.select(
            'SELECT * FROM local_chess_databases LIMIT 1',
          )).single;
      final now = DateTime.utc(2026, 6, 28);
      await repo.saveLocalGameAnalysis(
        LocalChessGameAnalysis(
          gameId: fileNode.games.first.id,
          databaseId: databaseRow['id'] as String,
          analysisState: const <String, dynamic>{'pane': 'local'},
          variationComments: const <String, String>{},
          moveNags: const <String, List<int>>{},
          lastViewedPosition: 2,
          notes: 'delete me with the database',
          isFavorite: true,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
      expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(1));
      expect(await _count(db, 'local_chess_tree_moves'), greaterThan(1));
      expect(await _count(db, 'local_chess_position_games'), greaterThan(1));
      expect(await _count(db, 'local_chess_game_analysis'), 1);
      expect(await _count(db, 'local_chess_players'), greaterThan(1));
      expect(await _count(db, 'local_chess_events'), greaterThan(1));
      expect(await _count(db, 'local_chess_sites'), greaterThan(1));

      final removed = await repo.deleteCachedSource(pgnFile.path);

      expect(removed, 1);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 0);
      expect(await _count(db, 'local_chess_players'), 1);
      expect(await _count(db, 'local_chess_events'), 1);
      expect(await _count(db, 'local_chess_sites'), 1);
      expect(
        await repo.loadFreshFileNode(pgnFile.path, rootPath: temp.path),
        isNull,
      );
    },
  );

  test(
    'deleteCachedSource retries transient sqlite busy while marking deleted',
    () async {
      final pgnFile = File('${temp.path}/retry-mark-delete.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      var databaseCalls = 0;
      final retryingRepo = LocalChessDatabaseRepository(
        database: () async {
          databaseCalls += 1;
          if (databaseCalls == 1) {
            throw StateError(
              'ResqliteQueryException: database is locked\nSQLite code: 5',
            );
          }
          return db;
        },
      );

      final removed = await retryingRepo.deleteCachedSource(pgnFile.path);

      expect(removed, 1);
      expect(databaseCalls, greaterThanOrEqualTo(2));
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
    },
  );

  test(
    'deleteCachedSource retries transient sqlite busy while purging cache',
    () async {
      final pgnFile = File('${temp.path}/retry-purge-delete.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      var databaseCalls = 0;
      final retryingRepo = LocalChessDatabaseRepository(
        database: () async {
          databaseCalls += 1;
          if (databaseCalls == 2) {
            throw StateError(
              'ResqliteQueryException: database is locked\nSQLite code: 5',
            );
          }
          return db;
        },
      );

      final removed = await retryingRepo.deleteCachedSource(pgnFile.path);

      expect(removed, 1);
      expect(databaseCalls, greaterThanOrEqualTo(3));
      expect(await retryingRepo.deletedCacheCount(), 0);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
    },
  );

  test('markCachedSourceDeleted hides cache before physical purge', () async {
    final pgnFile = File('${temp.path}/marked-delete.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    final marked = await repo.markCachedSourceDeleted(pgnFile.path);

    expect(marked, 1);
    expect(await repo.deletedCacheCount(), 1);
    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 2);
    expect(
      await repo.loadFreshFileNode(pgnFile.path, rootPath: temp.path),
      isNull,
    );
    expect(
      await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      ),
      isNull,
    );

    final purged = await repo.purgeDeletedCaches(batchSize: 1);

    expect(purged, 1);
    expect(await repo.deletedCacheCount(), 0);
    expect(await _count(db, 'local_chess_databases'), 0);
    expect(await _count(db, 'local_chess_games'), 0);
    expect(await _count(db, 'local_chess_tree_nodes'), 0);
    expect(await _count(db, 'local_chess_tree_moves'), 0);
    expect(await _count(db, 'local_chess_position_games'), 0);
  });

  test('markCachedSourceDeleted waits for the local write queue', () async {
    final pgnFile = File('${temp.path}/queued-mark-delete.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    final queueEntered = Completer<void>();
    final releaseQueue = Completer<void>();
    final held = LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
      queueEntered.complete();
      await releaseQueue.future;
    });
    await queueEntered.future.timeout(const Duration(seconds: 5));

    var completed = false;
    final marked = repo.markCachedSourceDeleted(pgnFile.path).then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(completed, isFalse);
    releaseQueue.complete();
    expect(await marked.timeout(const Duration(seconds: 5)), 1);
    await held.timeout(const Duration(seconds: 5));
    expect(await repo.deletedCacheCount(), 1);
  });

  test('marked deleted cache stays hidden without startup purge', () async {
    final pgnFile = File('${temp.path}/restart-hidden-delete.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    expect(await repo.markCachedSourceDeleted(pgnFile.path), 1);

    final restartedRepo = LocalChessDatabaseRepository(
      database: () async => db,
    );

    expect(await restartedRepo.deletedCacheCount(), 1);
    expect(await _count(db, 'local_chess_databases'), 1);
    expect(
      await restartedRepo.loadFreshFileNode(pgnFile.path, rootPath: temp.path),
      isNull,
    );
    expect(
      await restartedRepo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      ),
      isNull,
    );
  });

  test(
    'purgeDeletedCaches reports progress while deleting chunked tree cache',
    () async {
      final databasePath = '${temp.path}/chunked-delete.pgn';
      await _seedChunkedDeleteCache(db, databasePath);
      final repo = LocalChessDatabaseRepository(database: () async => db);

      final marked = await repo.markCachedSourceDeleted(databasePath);

      expect(marked, 1);
      final progress = <LocalChessScanProgress>[];
      final purged = await repo.purgeDeletedCaches(
        batchSize: 11,
        onProgress: progress.add,
      );

      expect(purged, 1);
      expect(progress, isNotEmpty);
      expect(progress.first.message, 'Preparing delete...');
      expect(progress.last.percent, 100);
      expect(progress.last.message, 'Delete complete.');
      expect(
        progress.map((item) => item.message),
        contains('Deleting tree moves...'),
      );
      expect(progress.length, greaterThan(4));
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 0);
    },
  );

  test(
    'purgeDeletedCaches can skip orphan metadata for foreground delete',
    () async {
      final pgnFile = File('${temp.path}/foreground-delete.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
      expect(await _count(db, 'local_chess_players'), greaterThan(1));
      expect(await repo.markCachedSourceDeleted(pgnFile.path), 1);

      final purged = await repo.purgeDeletedCaches(
        sourcePath: pgnFile.path,
        batchSize: 1,
        cleanupOrphanMetadata: false,
        checkpoint: false,
      );

      expect(purged, 1);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_game_analysis'), 0);
      expect(await _count(db, 'local_chess_players'), greaterThan(1));
    },
  );

  test('purgeDeletedCaches can purge only one deleted source', () async {
    final firstPgn = File('${temp.path}/first-delete.pgn');
    final secondPgn = File('${temp.path}/second-delete.pgn');
    await firstPgn.writeAsString(_samplePgn);
    await secondPgn.writeAsString(_metadataPgn);
    final repo = LocalChessDatabaseRepository(database: () async => db);

    for (final file in <File>[firstPgn, secondPgn]) {
      final source = await scanLocalChessPaths(<String>[file.path]);
      await repo.persistFileNode(
        source.root.singlePlayableDatabaseInSubtree!,
        sourceLabel: source.label,
      );
      expect(await repo.markCachedSourceDeleted(file.path), 1);
    }

    expect(await repo.deletedCacheCount(), 2);

    final purged = await repo.purgeDeletedCaches(
      sourcePath: firstPgn.path,
      batchSize: 1,
    );

    expect(purged, 1);
    expect(await repo.deletedCacheCount(), 1);
    expect(
      await db.select(
        'SELECT path FROM local_chess_databases ORDER BY path ASC',
      ),
      <Map<String, Object?>>[
        <String, Object?>{'path': secondPgn.path},
      ],
    );
    expect(
      await db.select('SELECT DISTINCT database_id FROM local_chess_games'),
      <Map<String, Object?>>[
        <String, Object?>{'database_id': secondPgn.path},
      ],
    );
  });

  test('marked cache is ignored until fresh reimport replaces it', () async {
    final pgnFile = File('${temp.path}/reimport.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final repo = LocalChessDatabaseRepository(database: () async => db);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    await repo.persistFileNode(
      source.root.singlePlayableDatabaseInSubtree!,
      sourceLabel: source.label,
    );

    expect(await repo.markCachedSourceDeleted(pgnFile.path), 1);
    expect(
      await repo.loadFreshFileNode(pgnFile.path, rootPath: temp.path),
      isNull,
    );

    await pgnFile.writeAsString(_metadataPgn);
    final freshSource = await scanLocalChessPaths(<String>[pgnFile.path]);
    await repo.persistFileNode(
      freshSource.root.singlePlayableDatabaseInSubtree!,
      sourceLabel: freshSource.label,
    );

    final databaseRows = await db.select(
      '''
        SELECT deleted_at_ms, game_count
        FROM local_chess_databases
        WHERE path = ?
        ''',
      <Object?>[pgnFile.path],
    );
    expect(databaseRows, hasLength(1));
    expect(databaseRows.single['deleted_at_ms'], isNull);
    expect(databaseRows.single['game_count'], 1);
    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );
    expect(restored, isNotNull);
    expect(restored!.games.single.game.metadata['Event'], 'Metadata');
  });

  test('deleteCachedSource purges cached files under a folder only', () async {
    final folder = Directory('${temp.path}/folder');
    await folder.create();
    final nested = Directory('${folder.path}/nested');
    await nested.create();
    final insideOne = File('${folder.path}/one.pgn');
    final insideTwo = File('${nested.path}/two.pgn');
    final outside = File('${temp.path}/outside.pgn');
    await insideOne.writeAsString(_samplePgn);
    await insideTwo.writeAsString(_metadataPgn);
    await outside.writeAsString(_legacyPgn);
    final repo = LocalChessDatabaseRepository(database: () async => db);

    for (final file in <File>[insideOne, insideTwo, outside]) {
      final source = await scanLocalChessPaths(<String>[file.path]);
      await repo.persistFileNode(
        source.root.singlePlayableDatabaseInSubtree!,
        sourceLabel: source.label,
      );
    }

    expect(await _count(db, 'local_chess_databases'), 3);

    final removed = await repo.deleteCachedSource(folder.path);

    expect(removed, 2);
    final remaining = await db.select(
      'SELECT path FROM local_chess_databases ORDER BY path ASC',
    );
    expect(remaining.map((row) => row['path']), <String>[outside.path]);
    expect(
      await repo.loadFreshFileNode(insideOne.path, rootPath: temp.path),
      isNull,
    );
    expect(
      await repo.loadFreshFileNode(insideTwo.path, rootPath: temp.path),
      isNull,
    );
    expect(
      await repo.loadFreshFileNode(outside.path, rootPath: temp.path),
      isNotNull,
    );
  });

  test(
    'resultStatsForDatabases counts distinct games across sources so Combined '
    'partitions the union and sums the per-source counts',
    () async {
      final repo = LocalChessDatabaseRepository(database: () async => db);
      const aliases = <String>['Alice, A'];

      // Lichess-style source: two of Alice's games (win as white, loss as
      // black), each with its own PGN fingerprint.
      await _seedStatsDatabase(
        db,
        databaseId: 'srcLichess',
        player: 'Alice, A',
        games: const <_StatsGame>[
          _StatsGame(hash: 'h-1', opponent: 'Bob', result: '1-0'),
          _StatsGame(
            hash: 'h-2',
            opponent: 'Cara',
            result: '0-1',
            aliasIsWhite: false,
          ),
        ],
      );
      // Chess.com-style source: one game duplicated from lichess (same
      // fingerprint h-2) plus one genuinely new draw.
      await _seedStatsDatabase(
        db,
        databaseId: 'srcChessCom',
        player: 'Alice, A',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'h-2',
            opponent: 'Cara',
            result: '0-1',
            aliasIsWhite: false,
          ),
          _StatsGame(hash: 'h-3', opponent: 'Dan', result: '1/2-1/2'),
        ],
      );
      // A disjoint OTB source with a single new game.
      await _seedStatsDatabase(
        db,
        databaseId: 'srcOtb',
        player: 'Alice, A',
        games: const <_StatsGame>[
          _StatsGame(hash: 'h-4', opponent: 'Eve', result: '1-0'),
        ],
      );

      final lichess = await repo.localDatabaseResultStats(
        databasePath: 'srcLichess',
        playerAliases: aliases,
      );
      final chesscom = await repo.localDatabaseResultStats(
        databasePath: 'srcChessCom',
        playerAliases: aliases,
      );
      final otb = await repo.localDatabaseResultStats(
        databasePath: 'srcOtb',
        playerAliases: aliases,
      );

      expect(lichess.gameCount, 2);
      expect(chesscom.gameCount, 2);
      expect(otb.gameCount, 1);

      // Combined over lichess+chesscom deduplicates the shared game h-2, so it
      // is exactly the union: h-1, h-2, h-3 = 3, not 2 + 2 = 4.
      final combined = await repo.resultStatsForDatabases(
        databasePaths: const <String>['srcLichess', 'srcChessCom'],
        playerAliases: aliases,
      );
      expect(combined.gameCount, 3);
      expect(combined.winCount, 2); // h-1 (white win) + h-2 (black win)
      expect(combined.drawCount, 1); // h-3

      // Disjoint sources add exactly: lichess + otb share nothing.
      final disjoint = await repo.resultStatsForDatabases(
        databasePaths: const <String>['srcLichess', 'srcOtb'],
        playerAliases: aliases,
      );
      expect(disjoint.gameCount, lichess.gameCount + otb.gameCount);
    },
  );

  test(
    'resultStatsForDatabases uses FIDE id before names when available',
    () async {
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await _seedStatsDatabase(
        db,
        databaseId: 'srcFide',
        player: 'Durarbayli,Vasif',
        playerFideId: '13402935',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'fide-1',
            opponent: 'Nakamura,Hi',
            opponentFideId: '2016192',
            result: '1-0',
          ),
          _StatsGame(
            hash: 'fide-2',
            opponent: 'Nakamura,Hi',
            opponentFideId: '2016192',
            result: '0-1',
            aliasIsWhite: false,
          ),
        ],
      );

      final stats = await repo.localDatabaseResultStats(
        databasePath: 'srcFide',
        playerAliases: const <String>['GM Vasif Durarbayli'],
        playerFideId: '13402935',
      );

      expect(stats.gameCount, 2);
      expect(stats.winCount, 2);
      expect(stats.lossCount, 0);
    },
  );

  test(
    'resultStatsForDatabases includes no-FIDE source rows by alias fallback',
    () async {
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await _seedStatsDatabase(
        db,
        databaseId: 'srcFide',
        player: 'Durarbayli,Vasif',
        playerFideId: '13402935',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'mixed-fide-1',
            opponent: 'Nakamura,Hi',
            opponentFideId: '2016192',
            result: '1-0',
          ),
          _StatsGame(
            hash: 'mixed-fide-2',
            opponent: 'Nakamura,Hi',
            opponentFideId: '2016192',
            result: '0-1',
            aliasIsWhite: false,
          ),
        ],
      );
      await _seedStatsDatabase(
        db,
        databaseId: 'srcChessCom',
        player: 'Vasif_Durarbayli',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'mixed-no-fide-1',
            opponent: 'Carlsen, Magnus',
            result: '1/2-1/2',
          ),
          _StatsGame(
            hash: 'mixed-no-fide-2',
            opponent: 'Carlsen, Magnus',
            result: '0-1',
            aliasIsWhite: false,
          ),
        ],
      );
      await _seedStatsDatabase(
        db,
        databaseId: 'srcWrongFide',
        player: 'Vasif Durarbayli',
        playerFideId: '999999',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'mixed-wrong-fide-1',
            opponent: 'Firouzja, Alireza',
            result: '1-0',
          ),
        ],
      );
      await _seedStatsDatabase(
        db,
        databaseId: 'srcWrongNoFide',
        player: 'Completely Different',
        games: const <_StatsGame>[
          _StatsGame(
            hash: 'mixed-wrong-no-fide-1',
            opponent: 'Firouzja, Alireza',
            result: '1-0',
          ),
        ],
      );

      final stats = await repo.resultStatsForDatabases(
        databasePaths: const <String>[
          'srcFide',
          'srcChessCom',
          'srcWrongFide',
          'srcWrongNoFide',
        ],
        playerAliases: const <String>['Vasif Durarbayli'],
        playerFideId: '13402935',
      );

      expect(stats.gameCount, 4);
      expect(stats.winCount, 3);
      expect(stats.drawCount, 1);
      expect(stats.lossCount, 0);
    },
  );
}

Future<void> _createPreTimeControlResqliteCache(
  resqlite.Database db, {
  required String databaseId,
}) async {
  await db.execute('''
    CREATE TABLE local_chess_migrations (
      name TEXT PRIMARY KEY,
      completed_at_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    '''
    INSERT INTO local_chess_migrations(name, completed_at_ms)
    VALUES (?, ?)
    ''',
    const <Object?>[
      'local_chess_resqlite_cache_generation_20260628_safe_streaming_v1',
      1,
    ],
  );
  await db.execute('''
    CREATE TABLE local_chess_databases (
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
  ''');
  await db.execute(
    '''
    INSERT INTO local_chess_databases(
      id, path, label, extension, size_bytes, game_count,
      imported_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <Object?>[databaseId, databaseId, 'Hikaru chess.com', '.pgn', 1, 1, 1, 1],
  );
  await db.execute('''
    CREATE TABLE local_chess_games (
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
      source_byte_end INTEGER
    )
  ''');
  await db.execute(
    '''
    INSERT INTO local_chess_games(
      id, database_id, time_control, raw_pgn, headers_json, source_path,
      source_relative_path, file_name, index_in_file, file_game_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <Object?>[
      'legacy-hikaru-bullet',
      databaseId,
      '60',
      '[Event "Live Chess"]\n[Site "https://www.chess.com/game/live/1"]',
      jsonEncode(<String, Object?>{
        'Event': 'Live Chess',
        'Site': 'https://www.chess.com/game/live/1',
      }),
      databaseId,
      p.basename(databaseId),
      p.basename(databaseId),
      0,
      1,
    ],
  );
}

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
  return rows.single['count'] as int;
}

class _StatsGame {
  const _StatsGame({
    required this.hash,
    required this.opponent,
    required this.result,
    this.opponentFideId,
    this.aliasIsWhite = true,
  });

  final String hash;
  final String opponent;
  final String result;
  final String? opponentFideId;
  final bool aliasIsWhite;
}

/// Seeds one local database (`databaseId`) with games between [player] and an
/// opponent, tagging each row with a caller-supplied `pgn_hash` so tests can
/// exercise cross-source deduplication directly.
Future<void> _seedStatsDatabase(
  resqlite.Database db, {
  required String databaseId,
  required String player,
  String? playerFideId,
  required List<_StatsGame> games,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.execute(
    'INSERT OR REPLACE INTO local_chess_databases'
    '(id, path, label, extension, size_bytes, imported_at_ms, updated_at_ms) '
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    <Object?>[databaseId, databaseId, databaseId, 'pgn', 0, now, now],
  );

  Future<int> playerId(String name) async {
    await db.execute(
      'INSERT OR IGNORE INTO local_chess_players(name) VALUES (?)',
      <Object?>[name],
    );
    final rows = await db.select(
      'SELECT id FROM local_chess_players WHERE name = ?',
      <Object?>[name],
    );
    return rows.single['id'] as int;
  }

  for (var i = 0; i < games.length; i++) {
    final game = games[i];
    final me = await playerId(player);
    final opponent = await playerId(game.opponent);
    final whiteId = game.aliasIsWhite ? me : opponent;
    final blackId = game.aliasIsWhite ? opponent : me;
    final headersJson = jsonEncode(<String, Object?>{
      if (game.aliasIsWhite && playerFideId != null)
        'WhiteFideId': playerFideId,
      if (!game.aliasIsWhite && playerFideId != null)
        'BlackFideId': playerFideId,
      if (game.aliasIsWhite && game.opponentFideId != null)
        'BlackFideId': game.opponentFideId,
      if (!game.aliasIsWhite && game.opponentFideId != null)
        'WhiteFideId': game.opponentFideId,
    });
    await db.execute(
      'INSERT INTO local_chess_games'
      '(id, database_id, white_id, black_id, result, raw_pgn, pgn_hash, '
      'headers_json, source_path, source_relative_path, file_name, index_in_file, '
      'file_game_count) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        '$databaseId-$i',
        databaseId,
        whiteId,
        blackId,
        game.result,
        '[Event "seed"]',
        game.hash,
        headersJson,
        databaseId,
        '',
        'seed.pgn',
        i,
        games.length,
      ],
    );
  }
}

String _bulkPgn(int count) {
  return List<String>.generate(count, (index) {
    final day = (index + 1).toString().padLeft(2, '0');
    final result = index.isEven ? '1-0' : '0-1';
    return '''
[Event "Bulk $index"]
[Site "Local"]
[Date "2026.06.$day"]
[Round "${index + 1}"]
[White "White $index"]
[Black "Black $index"]
[WhiteElo "${2500 + index}"]
[BlackElo "${2400 + index}"]
[ECO "C20"]
[Result "$result"]

1. e4 e5 2. Nf3 Nc6 $result
''';
  }).join('\n\n');
}

String _repeatingKnightPgn({required int fullMoves}) {
  final moves = StringBuffer();
  for (var move = 1; move <= fullMoves; move++) {
    final whiteSan = move.isOdd ? 'Nf3' : 'Ng1';
    final blackSan = move.isOdd ? 'Nf6' : 'Ng8';
    moves.write('$move. $whiteSan $blackSan ');
  }
  return '''
[Event "Depth Limit"]
[Site "Local"]
[Date "2026.06.28"]
[Round "1"]
[White "Depth"]
[Black "Limit"]
[Result "*"]

${moves.toString().trim()} *
''';
}

Future<void> _seedChunkedDeleteCache(
  resqlite.Database db,
  String databasePath,
) async {
  const gameCount = 23;
  const nodeCount = 95;
  const positionCount = 80;
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.execute(
    '''
    INSERT INTO local_chess_databases(
      id, path, label, extension, size_bytes, modified_at_ms, file_count,
      game_count, position_count, tree_max_ply, imported_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <Object?>[
      databasePath,
      databasePath,
      'Chunked delete',
      '.pgn',
      1,
      now,
      1,
      gameCount,
      positionCount,
      50,
      now,
      now,
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_games(
      id, database_id, event_id, site_id, white_id, black_id, result,
      ply_count, fen, moves, raw_pgn, headers_json, source_path,
      source_relative_path, file_name, index_in_file, file_game_count,
      has_moves
    ) VALUES (?, ?, 0, 0, 0, 0, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
    ''',
    <List<Object?>>[
      for (var i = 0; i < gameCount; i++)
        <Object?>[
          'delete_game_$i',
          databasePath,
          i.isEven ? '1-0' : '0-1',
          Chess.initial.fen,
          jsonEncode(<String>['e2e4', 'e7e5']),
          '[Event "Delete $i"]\n\n1. e4 e5 ${i.isEven ? '1-0' : '0-1'}',
          jsonEncode(<String, Object?>{'Event': 'Delete $i'}),
          databasePath,
          p.basename(databasePath),
          p.basename(databasePath),
          i,
          gameCount,
        ],
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_tree_nodes(database_id, node_id, fen_key, ply)
    VALUES (?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < nodeCount; i++)
        <Object?>[databasePath, i, 'delete_fen_$i', i],
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_tree_moves(
      database_id, node_id, uci, child_node_id, white, black, draws, total
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < nodeCount - 1; i++)
        <Object?>[databasePath, i, 'e2e4', i + 1, 1, 0, 0, 1],
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_position_games(
      database_id, fen_key, fen, game_id, ply, next_uci
    ) VALUES (?, ?, ?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < positionCount; i++)
        <Object?>[
          databasePath,
          'position_fen_$i',
          Chess.initial.fen,
          'delete_game_${i % gameCount}',
          i,
          'e2e4',
        ],
    ],
  );
  await db.execute(
    '''
    INSERT INTO local_chess_game_analysis(
      game_id, database_id, analysis_state, variation_comments, move_nags,
      last_viewed_position, notes, is_favorite, created_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <Object?>[
      'delete_game_0',
      databasePath,
      '{}',
      '{}',
      '{}',
      1,
      'delete with cache',
      1,
      now,
      now,
    ],
  );
}

Future<void> _seedGeneratedCacheRows(
  resqlite.Database db,
  String databasePath, {
  required List<String> gameIds,
}) async {
  const nodeCount = 95;
  const positionCount = 80;
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.executeBatch(
    '''
    INSERT INTO local_chess_tree_nodes(database_id, node_id, fen_key, ply)
    VALUES (?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < nodeCount; i++)
        <Object?>[databasePath, i, 'generated_fen_$i', i],
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_tree_moves(
      database_id, node_id, uci, child_node_id, white, black, draws, total
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < nodeCount - 1; i++)
        <Object?>[databasePath, i, 'e2e4', i + 1, 1, 0, 0, 1],
    ],
  );
  await db.executeBatch(
    '''
    INSERT INTO local_chess_position_games(
      database_id, fen_key, fen, game_id, ply, next_uci
    ) VALUES (?, ?, ?, ?, ?, ?)
    ''',
    <List<Object?>>[
      for (var i = 0; i < positionCount; i++)
        <Object?>[
          databasePath,
          'generated_position_fen_$i',
          Chess.initial.fen,
          gameIds[i % gameIds.length],
          i,
          'e2e4',
        ],
    ],
  );
  await db.execute(
    '''
    INSERT INTO local_chess_game_analysis(
      game_id, database_id, analysis_state, variation_comments, move_nags,
      last_viewed_position, notes, is_favorite, created_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    <Object?>[
      gameIds.first,
      databasePath,
      '{}',
      '{}',
      '{}',
      1,
      'delete generated cache',
      1,
      now,
      now,
    ],
  );
  await db.execute(
    '''
    UPDATE local_chess_databases
    SET position_count = ?,
        tree_max_ply = ?,
        updated_at_ms = ?
    WHERE id = ?
    ''',
    <Object?>[positionCount, 50, now, databasePath],
  );
}

Future<void> _seedLegacyLocalChessCache(
  sqflite.Database legacyDb,
  File pgnFile,
) async {
  final stat = await pgnFile.stat();
  final now = DateTime.now().millisecondsSinceEpoch;
  final rawPgn = _legacyPgn.trim();
  const gameId = 'local_legacy_game';
  final initialFenKey = _legacyTwoFieldFenKey(Chess.initial.fen);
  final afterE4FenKey = _legacyTwoFieldFenKey(
    Chess.initial.play(NormalMove.fromUci('e2e4')).fen,
  );
  final afterE5FenKey = _legacyTwoFieldFenKey(
    Chess.initial
        .play(NormalMove.fromUci('e2e4'))
        .play(NormalMove.fromUci('e7e5'))
        .fen,
  );
  final headers = <String, Object?>{
    'Event': 'Legacy cache',
    'Site': 'Istanbul',
    'Date': '2026.06.26',
    'Round': '1',
    'White': 'Legacy White',
    'Black': 'Legacy Black',
    'WhiteTitle': 'GM',
    'BlackTitle': 'IM',
    'WhiteFed': 'TUR',
    'BlackFed': 'USA',
    'Result': '1-0',
  };

  await legacyDb.insert('local_chess_databases', <String, Object?>{
    'id': pgnFile.path,
    'path': pgnFile.path,
    'label': 'Legacy',
    'extension': '.pgn',
    'size_bytes': stat.size,
    'modified_at_ms': stat.modified.millisecondsSinceEpoch,
    'file_count': 1,
    'game_count': 1,
    'position_count': 2,
    'tree_snapshot': null,
    'imported_at_ms': now,
    'updated_at_ms': now,
  });
  await legacyDb.insert('local_chess_players', <String, Object?>{
    'id': 1,
    'name': 'Legacy White',
    'elo': 2600,
  });
  await legacyDb.insert('local_chess_players', <String, Object?>{
    'id': 2,
    'name': 'Legacy Black',
    'elo': 2500,
  });
  await legacyDb.insert('local_chess_events', <String, Object?>{
    'id': 1,
    'name': 'Legacy cache',
  });
  await legacyDb.insert('local_chess_sites', <String, Object?>{
    'id': 1,
    'name': 'Istanbul',
  });
  await legacyDb.insert('local_chess_games', <String, Object?>{
    'id': gameId,
    'database_id': pgnFile.path,
    'event_id': 1,
    'site_id': 1,
    'date': '2026.06.26',
    'utc_time': null,
    'round': '1',
    'white_id': 1,
    'white_elo': 2600,
    'black_id': 2,
    'black_elo': 2500,
    'white_material': 39,
    'black_material': 39,
    'result': '1-0',
    'time_control': null,
    'eco': 'C20',
    'ply_count': 2,
    'fen': Chess.initial.fen,
    'moves': jsonEncode(<String>['e2e4', 'e7e5']),
    'pawn_home': 65535,
    'raw_pgn': rawPgn,
    'headers_json': jsonEncode(headers),
    'source_path': pgnFile.path,
    'source_relative_path': pgnFile.uri.pathSegments.last,
    'file_name': pgnFile.uri.pathSegments.last,
    'index_in_file': 0,
    'file_game_count': 1,
    'has_moves': 1,
  });
  await legacyDb.insert('local_chess_tree_nodes', <String, Object?>{
    'database_id': pgnFile.path,
    'node_id': 0,
    'fen_key': initialFenKey,
    'ply': 0,
  });
  await legacyDb.insert('local_chess_tree_nodes', <String, Object?>{
    'database_id': pgnFile.path,
    'node_id': 1,
    'fen_key': afterE4FenKey,
    'ply': 1,
  });
  await legacyDb.insert('local_chess_tree_nodes', <String, Object?>{
    'database_id': pgnFile.path,
    'node_id': 2,
    'fen_key': afterE5FenKey,
    'ply': 2,
  });
  await legacyDb.insert('local_chess_tree_moves', <String, Object?>{
    'database_id': pgnFile.path,
    'node_id': 0,
    'uci': 'e2e4',
    'child_node_id': 1,
    'white': 1,
    'black': 0,
    'draws': 0,
    'total': 1,
    'last_played_ms': DateTime.utc(2026, 6, 26).millisecondsSinceEpoch,
    'sample_game_id': gameId,
  });
  await legacyDb.insert('local_chess_tree_moves', <String, Object?>{
    'database_id': pgnFile.path,
    'node_id': 1,
    'uci': 'e7e5',
    'child_node_id': 2,
    'white': 1,
    'black': 0,
    'draws': 0,
    'total': 1,
    'last_played_ms': DateTime.utc(2026, 6, 26).millisecondsSinceEpoch,
    'sample_game_id': gameId,
  });
  await legacyDb.insert('local_chess_position_games', <String, Object?>{
    'database_id': pgnFile.path,
    'fen_key': initialFenKey,
    'fen': Chess.initial.fen,
    'game_id': gameId,
    'ply': 0,
  });
}

String _legacyTwoFieldFenKey(String fen) {
  return fen.trim().split(RegExp(r'\s+')).take(2).join(' ');
}

Future<void> _seedPagedLegacyLocalChessGames(
  sqflite.Database legacyDb,
  File pgnFile, {
  required int count,
}) async {
  final stat = await pgnFile.stat();
  final now = DateTime.now().millisecondsSinceEpoch;
  final fileName = p.basename(pgnFile.path);
  await legacyDb.insert('local_chess_databases', <String, Object?>{
    'id': pgnFile.path,
    'path': pgnFile.path,
    'label': 'Paged Legacy',
    'extension': '.pgn',
    'size_bytes': stat.size,
    'modified_at_ms': stat.modified.millisecondsSinceEpoch,
    'file_count': 1,
    'game_count': count,
    'position_count': 0,
    'tree_snapshot': null,
    'imported_at_ms': now,
    'updated_at_ms': now,
  });
  await legacyDb.insert('local_chess_players', <String, Object?>{
    'id': 1,
    'name': 'Paged White',
    'elo': 2600,
  });
  await legacyDb.insert('local_chess_players', <String, Object?>{
    'id': 2,
    'name': 'Paged Black',
    'elo': 2500,
  });
  await legacyDb.insert('local_chess_events', <String, Object?>{
    'id': 1,
    'name': 'Paged migration',
  });
  await legacyDb.insert('local_chess_sites', <String, Object?>{
    'id': 1,
    'name': 'Local',
  });

  final batch = legacyDb.batch();
  for (var index = 0; index < count; index++) {
    final result = index.isEven ? '1-0' : '0-1';
    final rawPgn = '''
[Event "Paged migration"]
[Site "Local"]
[Date "2026.06.26"]
[Round "${index + 1}"]
[White "Paged White"]
[Black "Paged Black"]
[Result "$result"]

1. e4 e5 $result
''';
    batch.insert('local_chess_games', <String, Object?>{
      'id': 'paged_legacy_$index',
      'database_id': pgnFile.path,
      'event_id': 1,
      'site_id': 1,
      'date': '2026.06.26',
      'utc_time': null,
      'round': '${index + 1}',
      'white_id': 1,
      'white_elo': 2600,
      'black_id': 2,
      'black_elo': 2500,
      'white_material': 39,
      'black_material': 39,
      'result': result,
      'time_control': null,
      'eco': 'C20',
      'ply_count': 2,
      'fen': Chess.initial.fen,
      'moves': jsonEncode(<String>['e2e4', 'e7e5']),
      'pawn_home': 65535,
      'raw_pgn': rawPgn.trim(),
      'headers_json': jsonEncode(<String, Object?>{
        'Event': 'Paged migration',
        'Site': 'Local',
        'Round': '${index + 1}',
        'White': 'Paged White',
        'Black': 'Paged Black',
        'Result': result,
      }),
      'source_path': pgnFile.path,
      'source_relative_path': fileName,
      'file_name': fileName,
      'index_in_file': index,
      'file_game_count': count,
      'has_moves': 1,
    });
  }
  await batch.commit(noResult: true);
}

const _samplePgn = '''
[Event "Fast tree"]
[Site "Local"]
[Date "2024.01.03"]
[Round "1"]
[White "Hou, Yifan"]
[Black "Gukesh, D"]
[WhiteTitle "GM"]
[BlackTitle "GM"]
[WhiteFed "CHN"]
[BlackFed "IND"]
[WhiteFideId "8602980"]
[BlackFideId "46616543"]
[WhiteElo "2650"]
[BlackElo "2760"]
[ECO "D06"]
[Result "1/2-1/2"]

1. d4 d5 2. c4 e5 3. Nf3 Nc6 1/2-1/2

[Event "Training"]
[Site "Budapest"]
[Date "2024.05.05"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[WhiteElo "2675"]
[BlackElo "2750"]
[ECO "B90"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 0-1
''';

const _filterPgn = '''
[Event "Rapid Local"]
[Site "Budapest"]
[Date "2024.03.01"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[WhiteFideId "1503014"]
[BlackFideId "2016192"]
[WhiteElo "2830"]
[BlackElo "2802"]
[TimeControl "900+0"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0

[Event "Online Blitz"]
[Site "https://lichess.org/abc123"]
[Date "2025.04.02"]
[Round "2"]
[White "Gukesh, D"]
[Black "Carlsen, Magnus"]
[WhiteFideId "46616543"]
[BlackFideId "1503014"]
[WhiteElo "2760"]
[BlackElo "2830"]
[TimeControl "300+0"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 0-1

[Event "Classical Local"]
[Site "Wijk aan Zee"]
[Date "2024.05.03"]
[Round "3"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[WhiteElo "2675"]
[BlackElo "2750"]
[TimeControl "40/7200:20/3600:900+30"]
[Result "1/2-1/2"]

1. d4 d5 2. c4 e6 1/2-1/2
''';

const _metadataPgn = '''
[Event "Metadata"]
[Site "Oslo"]
[Date "2025.02.03"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[WhiteTitle "GM"]
[BlackTitle "IM"]
[WhiteCountry "NOR"]
[BlackTeamCountry "USA"]
[WhiteFideId "1503014"]
[BlackFideId "2016192"]
[WhiteElo "2830"]
[BlackElo "2802"]
[ECO "D06"]
[CustomHeader "Preserved"]
[Result "1-0"]

1. d4 d5 2. c4 e6 1-0
''';

const _legacyPgn = '''
[Event "Legacy cache"]
[Site "Istanbul"]
[Date "2026.06.26"]
[Round "1"]
[White "Legacy White"]
[Black "Legacy Black"]
[WhiteTitle "GM"]
[BlackTitle "IM"]
[WhiteFed "TUR"]
[BlackFed "USA"]
[WhiteElo "2600"]
[BlackElo "2500"]
[ECO "C20"]
[Result "1-0"]

1. e4 e5 1-0
''';
