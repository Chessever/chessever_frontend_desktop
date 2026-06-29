import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

void main() {
  test(
    'hikaru scan probe',
    () async {
      final path =
          Platform.environment['CHESSEVER_HIKARU_SCAN_PATH'] ??
          '/Users/berkay/Downloads/hikaru_chesscom.pgn';
      final maxGames = int.parse(
        Platform.environment['CHESSEVER_HIKARU_SCAN_MAX_GAMES'] ?? '200000',
      );
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'File not found: $path');

      final stat = await file.stat();
      // ignore: avoid_print
      print('Scanning $path');
      // ignore: avoid_print
      print('size=${stat.size} maxGames=$maxGames');

      var progressEvents = 0;
      LocalChessScanProgress? lastProgress;
      final sw = Stopwatch()..start();
      final source = await scanLocalChessPathsWithProgress(
        <String>[path],
        maxGames: maxGames,
        onProgress: (progress) {
          progressEvents++;
          lastProgress = progress;
        },
      );
      sw.stop();

      final database = selectedLocalChessDatabaseFile(source.root);
      // ignore: avoid_print
      print('elapsedMs=${sw.elapsedMilliseconds}');
      // ignore: avoid_print
      print('progressEvents=$progressEvents');
      // ignore: avoid_print
      print('lastProgress=${lastProgress?.percent} ${lastProgress?.message}');
      // ignore: avoid_print
      print('sourceGames=${source.root.gameCount}');
      expect(database, isNotNull);
      final fileNode = database!;
      // ignore: avoid_print
      print('status=${fileNode.status}');
      // ignore: avoid_print
      print('games=${fileNode.games.length}');
      // ignore: avoid_print
      print(
        'fileGameCount=${fileNode.games.isEmpty ? null : fileNode.games.first.fileGameCount}',
      );
      // ignore: avoid_print
      print('message=${fileNode.message}');
      // ignore: avoid_print
      print('offsetGames=${fileNode.pgnOffsetIndex?.totalGames}');
      final index = fileNode.openingTreeIndex;
      // ignore: avoid_print
      print('treeGames=${index?.downloadedGameCount}');
      // ignore: avoid_print
      print('positions=${index?.positionCount}');
      // ignore: avoid_print
      print('maxPly=${index?.maxPly}');
      if (Platform.environment['CHESSEVER_HIKARU_PERSIST_PROBE'] == '1') {
        final dbFile = File(
          '${Directory.systemTemp.path}/local_chess_probe.db',
        );
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('${dbFile.path}$suffix');
          if (file.existsSync()) file.deleteSync();
        }
        final db = await resqlite.Database.open(dbFile.path);
        addTearDown(db.close);
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final persistSw = Stopwatch()..start();
        await repo.persistFileNode(fileNode, sourceLabel: source.label);
        persistSw.stop();
        // ignore: avoid_print
        print('persistElapsedMs=${persistSw.elapsedMilliseconds}');
        final restoredSw = Stopwatch()..start();
        final restored = await repo.loadFreshFileNode(
          fileNode.path,
          rootPath: source.rootPath,
        );
        restoredSw.stop();
        // ignore: avoid_print
        print('restoreElapsedMs=${restoredSw.elapsedMilliseconds}');
        // ignore: avoid_print
        print('restoredGames=${restored?.gameCount}');
        final rebuildPersistSw = Stopwatch()..start();
        final rebuildPersisted = await repo.persistOpeningTreeIndex(
          databasePath: fileNode.path,
          index: fileNode.openingTreeIndex!,
        );
        rebuildPersistSw.stop();
        // ignore: avoid_print
        print(
          'rebuildPersisted=$rebuildPersisted '
          'rebuildPersistElapsedMs=${rebuildPersistSw.elapsedMilliseconds}',
        );
        final rebuildRestoreSw = Stopwatch()..start();
        final rebuildRestored = await repo.loadFreshFileNode(
          fileNode.path,
          rootPath: source.rootPath,
        );
        rebuildRestoreSw.stop();
        // ignore: avoid_print
        print(
          'rebuildRestoreElapsedMs=${rebuildRestoreSw.elapsedMilliseconds} '
          'rebuildRestoredPositions=${rebuildRestored?.openingTreeIndex?.positionCount}',
        );
      }
    },
    skip:
        Platform.environment['CHESSEVER_HIKARU_SCAN_PROBE'] == '1'
            ? false
            : 'Opt-in local performance probe.',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'hikaru import worker probe',
    () async {
      final path =
          Platform.environment['CHESSEVER_HIKARU_SCAN_PATH'] ??
          '/Users/berkay/Downloads/hikaru_chesscom.pgn';
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'File not found: $path');

      final stat = await file.stat();
      // ignore: avoid_print
      print('Importing $path');
      // ignore: avoid_print
      print('size=${stat.size}');

      final dbPath =
          Platform.environment['CHESSEVER_HIKARU_IMPORT_DB_PATH'] ??
          '${Directory.systemTemp.path}/local_chess_import_probe.db';
      final dbFile = File(dbPath);
      if (Platform.environment['CHESSEVER_HIKARU_IMPORT_DB_PATH'] == null) {
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('${dbFile.path}$suffix');
          if (file.existsSync()) file.deleteSync();
        }
      }
      final db = await resqlite.Database.open(dbFile.path);
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);
      final repo = LocalChessDatabaseRepository(database: () async => db);

      var progressEvents = 0;
      LocalChessScanProgress? lastProgress;
      final sw = Stopwatch()..start();
      final source = await repo.importSingleFileSource(
        path: path,
        sourceLabel: 'Hikaru probe',
        onProgress: (progress) {
          progressEvents++;
          lastProgress = progress;
        },
      );
      sw.stop();

      final database = source?.root.singlePlayableDatabaseInSubtree;
      // ignore: avoid_print
      print('elapsedMs=${sw.elapsedMilliseconds}');
      // ignore: avoid_print
      print('progressEvents=$progressEvents');
      // ignore: avoid_print
      print('lastProgress=${lastProgress?.percent} ${lastProgress?.message}');
      // ignore: avoid_print
      print('sourceGames=${source?.root.gameCount}');
      expect(database, isNotNull);
      // ignore: avoid_print
      print('status=${database!.status}');
      // ignore: avoid_print
      print('previewGames=${database.games.length}');
      // ignore: avoid_print
      print('gameCount=${database.gameCount}');
      // ignore: avoid_print
      print('message=${database.message}');
      final rows = await db.select(
        'SELECT game_count, position_count, tree_max_ply FROM local_chess_databases WHERE id = ?',
        <Object?>[path],
      );
      // ignore: avoid_print
      print('databaseRows=$rows');
      expect(rows, hasLength(1));
    },
    skip:
        Platform.environment['CHESSEVER_HIKARU_IMPORT_PROBE'] == '1'
            ? false
            : 'Opt-in local import performance probe.',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'hikaru tree rebuild probe',
    () async {
      final path =
          Platform.environment['CHESSEVER_HIKARU_SCAN_PATH'] ??
          '/Users/berkay/Downloads/hikaru_chesscom.pgn';
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'File not found: $path');

      final stat = await file.stat();
      // ignore: avoid_print
      print('Importing and rebuilding $path');
      // ignore: avoid_print
      print('size=${stat.size}');

      final dbFile = File(
        '${Directory.systemTemp.path}/local_chess_tree_probe.db',
      );
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${dbFile.path}$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      final db = await resqlite.Database.open(dbFile.path);
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);
      final repo = LocalChessDatabaseRepository(database: () async => db);

      final importSw = Stopwatch()..start();
      final source = await repo.importSingleFileSource(
        path: path,
        sourceLabel: 'Hikaru tree probe',
      );
      importSw.stop();
      final database = source?.root.singlePlayableDatabaseInSubtree;
      expect(database, isNotNull);
      // ignore: avoid_print
      print(
        'importElapsedMs=${importSw.elapsedMilliseconds} '
        'gameCount=${database!.gameCount}',
      );

      var progressEvents = 0;
      LocalChessScanProgress? lastProgress;
      final rebuildSw = Stopwatch()..start();
      final result = await repo.rebuildOpeningTreeFromCachedGames(
        databasePath: path,
        onProgress: (progress) {
          progressEvents++;
          lastProgress = progress;
          if (progressEvents % 50 == 0 || progress.fraction >= 1) {
            // ignore: avoid_print
            print(
              'treeProgress event=$progressEvents '
              'percent=${progress.percent} message=${progress.message}',
            );
          }
        },
      );
      rebuildSw.stop();
      // ignore: avoid_print
      print('rebuildElapsedMs=${rebuildSw.elapsedMilliseconds}');
      // ignore: avoid_print
      print('progressEvents=$progressEvents');
      // ignore: avoid_print
      print('lastProgress=${lastProgress?.percent} ${lastProgress?.message}');
      // ignore: avoid_print
      print(
        'resultPositions=${result?.index.persistedPositionCount} '
        'resultGames=${result?.index.persistedGameCount} '
        'maxPly=${result?.index.maxPly} '
        'skipped=${result?.skippedGames}',
      );
      expect(result?.index.isUsable, isTrue);
      final rows = await db.select(
        'SELECT game_count, position_count, tree_max_ply FROM local_chess_databases WHERE id = ?',
        <Object?>[path],
      );
      // ignore: avoid_print
      print('databaseRows=$rows');
      expect(rows, hasLength(1));
      expect(rows.single['position_count'], isNonZero);
    },
    skip:
        Platform.environment['CHESSEVER_HIKARU_TREE_PROBE'] == '1'
            ? false
            : 'Opt-in local tree rebuild performance probe.',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'hikaru delete probe',
    () async {
      final path =
          Platform.environment['CHESSEVER_HIKARU_SCAN_PATH'] ??
          '/Users/berkay/Downloads/hikaru_chesscom.pgn';
      final dbPath =
          Platform.environment['CHESSEVER_HIKARU_DELETE_DB_PATH'] ??
          '${Directory.systemTemp.path}/local_chess_tree_probe.db';
      final batchSize = int.parse(
        Platform.environment['CHESSEVER_HIKARU_DELETE_BATCH_SIZE'] ?? '4096',
      );
      final cleanupOrphanMetadata =
          Platform.environment['CHESSEVER_HIKARU_DELETE_CLEANUP_METADATA'] ==
          '1';
      final checkpoint =
          Platform.environment['CHESSEVER_HIKARU_DELETE_CHECKPOINT'] == '1';
      final dbFile = File(dbPath);
      expect(dbFile.existsSync(), isTrue, reason: 'DB not found: $dbPath');

      final db = await resqlite.Database.open(dbPath);
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        purgeDatabase: () async {
          final purgeDb = await resqlite.Database.open(dbPath);
          await purgeDb.execute('PRAGMA foreign_keys=ON');
          await purgeDb.execute('PRAGMA journal_mode=WAL');
          await purgeDb.execute('PRAGMA synchronous=NORMAL');
          await purgeDb.execute('PRAGMA busy_timeout=5000');
          return purgeDb;
        },
      );

      Future<int> count(String table) async {
        final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
        return rows.single['count'] as int;
      }

      // ignore: avoid_print
      print('Deleting $path from $dbPath batchSize=$batchSize');
      final beforeDatabases = await count('local_chess_databases');
      final beforeGames = await count('local_chess_games');
      final beforeNodes = await count('local_chess_tree_nodes');
      final beforeMoves = await count('local_chess_tree_moves');
      final beforePositions = await count('local_chess_position_games');
      // ignore: avoid_print
      print(
        'before databases=$beforeDatabases games=$beforeGames '
        'nodes=$beforeNodes moves=$beforeMoves positions=$beforePositions',
      );

      final marked = await repo.markCachedSourceDeleted(path);
      // ignore: avoid_print
      print('marked=$marked');
      final sw = Stopwatch()..start();
      var progressEvents = 0;
      var lastPercent = -1;
      final purged = await repo.purgeDeletedCaches(
        sourcePath: path,
        batchSize: batchSize,
        cleanupOrphanMetadata: cleanupOrphanMetadata,
        checkpoint: checkpoint,
        onProgress: (progress) {
          progressEvents++;
          if (progress.percent != lastPercent &&
              (progress.percent % 10 == 0 || progress.percent >= 98)) {
            lastPercent = progress.percent;
            // ignore: avoid_print
            print(
              'deleteProgress event=$progressEvents '
              'percent=${progress.percent} message=${progress.message}',
            );
          }
        },
      );
      sw.stop();
      // ignore: avoid_print
      print(
        'purged=$purged elapsedMs=${sw.elapsedMilliseconds} '
        'progressEvents=$progressEvents',
      );
      // ignore: avoid_print
      final afterDatabases = await count('local_chess_databases');
      final afterGames = await count('local_chess_games');
      final afterNodes = await count('local_chess_tree_nodes');
      final afterMoves = await count('local_chess_tree_moves');
      final afterPositions = await count('local_chess_position_games');
      // ignore: avoid_print
      print(
        'after databases=$afterDatabases games=$afterGames '
        'nodes=$afterNodes moves=$afterMoves positions=$afterPositions',
      );
      expect(marked, 1);
      expect(purged, 1);
      final sourceRows = await db.select(
        'SELECT COUNT(*) AS count FROM local_chess_databases WHERE path = ?',
        <Object?>[path],
      );
      final sourceGames = await db.select(
        'SELECT COUNT(*) AS count FROM local_chess_games WHERE database_id = ?',
        <Object?>[path],
      );
      expect(sourceRows.single['count'], 0);
      expect(sourceGames.single['count'], 0);
    },
    skip:
        Platform.environment['CHESSEVER_HIKARU_DELETE_PROBE'] == '1'
            ? false
            : 'Opt-in local delete performance probe.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
