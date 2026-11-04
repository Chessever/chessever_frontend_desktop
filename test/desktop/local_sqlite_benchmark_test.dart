import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/web/shims/local_sqlite.dart' as localsql;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Opt-in end-to-end benchmark of the local chess cache hot paths, through
/// the repository's public API only (so the same file runs against any
/// driver).
///
///   CHESSEVER_SQLITE_BENCH=1 \
///   CHESSEVER_SQLITE_BENCH_PGN=/path/to/games.pgn \
///   CHESSEVER_SQLITE_BENCH_REPEAT=8 \
///   flutter test test/desktop/local_sqlite_benchmark_test.dart
///
/// Each phase reports wall time and the longest gap of a 4 ms heartbeat timer
/// on the calling (UI) isolate: a long gap is a frame the app would drop.
/// Prints one `BENCH {json}` line.
void main() {
  test(
    'local cache hot paths',
    () async {
      final source = File(Platform.environment['CHESSEVER_SQLITE_BENCH_PGN']!);
      final repeat = int.parse(
        Platform.environment['CHESSEVER_SQLITE_BENCH_REPEAT'] ?? '8',
      );
      final dir = await Directory.systemTemp.createTemp('local_sqlite_bench_');
      addTearDown(() => dir.delete(recursive: true));

      // Unique copies of the source games: only the Event header differs.
      final text = source.readAsStringSync();
      final pgnPath = p.join(dir.path, 'bench.pgn');
      final sink = File(pgnPath).openWrite();
      for (var i = 0; i < repeat; i++) {
        sink.write(
          text.replaceAllMapped(
            RegExp(r'^\[Event "([^"]*)"\]', multiLine: true),
            (m) => '[Event "${m[1]} #$i"]',
          ),
        );
        sink.write('\n\n');
      }
      await sink.close();

      final dbPath = p.join(dir.path, 'chessever_local_chess.db');
      final db = await localsql.Database.open(dbPath);
      for (final pragma in const <String>[
        'PRAGMA foreign_keys=ON',
        'PRAGMA journal_mode=WAL',
        'PRAGMA synchronous=NORMAL',
        'PRAGMA temp_store=MEMORY',
        'PRAGMA busy_timeout=20000',
        'PRAGMA cache_size=-65536',
      ]) {
        await db.execute(pragma);
      }
      await createLocalChessCacheDatabaseSchema(db);
      final repo = LocalChessDatabaseRepository(
        database: () async => db,
        databaseFilePath: () async => dbPath,
        purgeDatabase: () async {
          final purge = await localsql.Database.open(dbPath);
          await purge.execute('PRAGMA foreign_keys=ON');
          await purge.execute('PRAGMA synchronous=NORMAL');
          await purge.execute('PRAGMA busy_timeout=20000');
          return purge;
        },
      );

      final results = <String, Object?>{};
      Future<T> phase<T>(String name, Future<T> Function() body) async {
        var maxGap = 0;
        var last = DateTime.now().microsecondsSinceEpoch;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 4), (_) {
          final now = DateTime.now().microsecondsSinceEpoch;
          final gap = now - last;
          if (gap > maxGap) maxGap = gap;
          last = now;
        });
        final sw = Stopwatch()..start();
        try {
          return await body();
        } finally {
          sw.stop();
          heartbeat.cancel();
          results[name] = <String, Object?>{
            'ms': sw.elapsedMilliseconds,
            'maxGapMs': (maxGap / 1000).round(),
          };
        }
      }

      final imported = await phase(
        'import',
        () => repo.importSingleFileSource(path: pgnPath),
      );
      final games = imported?.root.gameCount ?? 0;
      results['games'] = games;
      expect(games, greaterThan(0));

      final tree = await phase(
        'treeBuild',
        () => repo.rebuildOpeningTreeFromPgnFile(databasePath: pgnPath),
      );
      expect(tree, isNotNull);

      final sample =
          (await db.select(
            'SELECT white_id FROM local_chess_games GROUP BY white_id '
            'ORDER BY COUNT(*) DESC LIMIT 1',
          )).single['white_id'];
      final player =
          (await db.select(
                'SELECT name FROM local_chess_players WHERE id = ?',
                <Object?>[sample],
              )).single['name']!
              as String;

      await phase('libraryPages', () async {
        for (var page = 0; page < 20; page++) {
          final result = await repo.localDatabaseGamesPage(
            databasePath: pgnPath,
            pageNumber: page,
            pageSize: 200,
          );
          expect(result?.games, isNotEmpty);
        }
      });
      await phase('librarySortedPages', () async {
        for (var page = 0; page < 10; page++) {
          await repo.localDatabaseGamesPage(
            databasePath: pgnPath,
            sortBy: LocalChessGameSortField.whiteElo,
            sortDirection: LocalChessGameSortDirection.desc,
            pageNumber: page,
            pageSize: 200,
          );
        }
      });
      await phase('librarySearch', () async {
        for (var page = 0; page < 5; page++) {
          await repo.localDatabaseGamesPage(
            databasePath: pgnPath,
            search: player.split(',').first,
            pageNumber: page,
            pageSize: 200,
          );
        }
      });

      const fens = <String>[
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
      ];
      await phase('explorerMoves', () async {
        for (var round = 0; round < 5; round++) {
          for (final fen in fens) {
            await repo.localMoveAggregatesForFen(
              databasePath: pgnPath,
              fen: fen,
            );
          }
        }
      });
      await phase('explorerMovesFiltered', () async {
        for (var round = 0; round < 3; round++) {
          for (final fen in fens) {
            await repo.localMoveAggregatesForFen(
              databasePath: pgnPath,
              fen: fen,
              filters: const PlayerOpeningTreeFilterCriteria(minRating: 2600),
            );
          }
        }
      });
      await phase('positionGames', () async {
        for (final fen in fens) {
          for (var page = 0; page < 3; page++) {
            await repo.localPositionGamesResponse(
              databasePath: pgnPath,
              fen: fen,
              sortBy: GamebaseSortField.date,
              sortDirection: GamebaseSortDirection.desc,
              pageNumber: page,
              pageSize: 50,
            );
          }
        }
      });
      await phase('positionGamesFiltered', () async {
        for (final fen in fens) {
          await repo.localPositionGamesResponse(
            databasePath: pgnPath,
            fen: fen,
            filters: const PlayerOpeningTreeFilterCriteria(minRating: 2600),
            sortBy: GamebaseSortField.date,
            sortDirection: GamebaseSortDirection.desc,
            pageNumber: 0,
            pageSize: 50,
          );
        }
      });
      await phase('resultStatsDirect', () async {
        for (var i = 0; i < 10; i++) {
          await repo.localDatabaseResultStats(
            databasePath: pgnPath,
            playerAliases: <String>[player],
            preferDirectDatabase: true,
          );
        }
      });
      await phase('deleteAndPurge', () => repo.deleteCachedSource(pgnPath));

      await db.close();
      // ignore: avoid_print
      print('BENCH ${jsonEncode(results)}');
    },
    skip:
        Platform.environment['CHESSEVER_SQLITE_BENCH'] == '1'
            ? false
            : 'Opt-in local cache benchmark.',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
