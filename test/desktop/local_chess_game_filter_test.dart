import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

void main() {
  group('localChessGameFilterFromOverview', () {
    test('maps W/D/L, colour, ECO, year, and time control facets', () {
      final wins = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.wins,
          sourcePath: '/db/combined.pgn',
        ),
      );
      expect(wins.playerOutcome, LocalPlayerOutcomeFilter.win);
      expect(wins.base.hasActiveFilters, isFalse);
      // Overview W/D/L must still light the Filters badge (combined count).
      expect(wins.hasActiveFilters, isTrue);
      expect(wins.activeFilterCount, 1);

      final asWhite = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.asWhite,
        ),
      );
      expect(asWhite.base.color, GameColorFilter.white);

      final eco = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.eco,
          ecoCode: 'b90',
        ),
      );
      expect(eco.base.eco.code, 'B90');

      final year = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.year,
          year: 2022,
        ),
      );
      expect(year.base.minYear, 2022);
      expect(year.base.maxYear, 2022);

      final tc = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.timeControl,
          timeControlCategory: 'Blitz',
        ),
      );
      expect(tc.base.timeControl, GameTimeControlFilter.blitz);
    });
  });

  group('localDatabaseGamesPage structured filters', () {
    late resqlite.Database db;
    late Directory temp;
    late String databasePath;
    late String databaseId;
    late PlayerStatsRepositoryHarness harness;

    setUpAll(() {
      sqfliteFfiInit();
      sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever-local-filter-');
      db = await resqlite.Database.open('${temp.path}/local_chess.db');
      await createLocalChessResqliteDatabaseSchema(db);
      await db.execute('PRAGMA foreign_keys=OFF');
      databasePath = p.join(temp.path, 'player.pgn');
      databaseId = p.normalize(databasePath);
      harness = PlayerStatsRepositoryHarness(
        db: db,
        databaseId: databaseId,
        databasePath: databasePath,
      );
      await harness.ensureDatabaseRow();
    });

    tearDown(() async {
      await db.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test(
      'narrows by player outcome, colour, time control, year and ECO',
      () async {
        const player = 'Filter, Local';
        // 2022 white win blitz B90
        await harness.insertGame(
          white: player,
          black: 'Opp A',
          result: '1-0',
          eco: 'B90',
          date: '2022.05.01',
          tcc: 'Blitz',
          whiteFideId: '111',
        );
        // 2022 black loss rapid C42
        await harness.insertGame(
          white: 'Opp B',
          black: player,
          result: '1-0',
          eco: 'C42',
          date: '2022.06.01',
          tcc: 'Rapid',
          blackFideId: '111',
        );
        // 2023 white draw classical B90
        await harness.insertGame(
          white: player,
          black: 'Opp C',
          result: '1/2-1/2',
          eco: 'B90',
          date: '2023.01.15',
          tcc: 'Classical',
          whiteFideId: '111',
        );
        // 2023 black win blitz C42
        await harness.insertGame(
          white: 'Opp D',
          black: player,
          result: '0-1',
          eco: 'C42',
          date: '2023.08.20',
          tcc: 'Blitz',
          blackFideId: '111',
        );

        final repo = LocalChessDatabaseRepository(database: () async => db);

        Future<int> count(LocalChessGameFilter filter) async {
          final page = await repo.localDatabaseGamesPage(
            databasePath: databasePath,
            filter: filter,
            playerFideId: '111',
            playerAliases: const [player],
            pageNumber: 0,
            pageSize: 50,
          );
          return page?.totalCount ?? -1;
        }

        expect(await count(LocalChessGameFilter()), 4);

        expect(
          await count(
            LocalChessGameFilter(
              playerOutcome: LocalPlayerOutcomeFilter.win,
            ),
          ),
          2,
        ); // white 1-0 + black 0-1

        expect(
          await count(
            LocalChessGameFilter(
              playerOutcome: LocalPlayerOutcomeFilter.loss,
            ),
          ),
          1,
        );

        expect(
          await count(
            LocalChessGameFilter(
              base: GameFilter(
                color: GameColorFilter.white,
                maxYear: DateTime.now().year,
              ),
            ),
          ),
          2,
        );

        expect(
          await count(
            LocalChessGameFilter(
              base: GameFilter(
                timeControl: GameTimeControlFilter.blitz,
                maxYear: DateTime.now().year,
              ),
            ),
          ),
          2,
        );

        expect(
          await count(
            LocalChessGameFilter(
              base: GameFilter(minYear: 2023, maxYear: 2023),
            ),
          ),
          2,
        );

        expect(
          await count(
            LocalChessGameFilter(
              base: GameFilter(
                eco: GameEcoFilter.forCode('B90'),
                maxYear: DateTime.now().year,
              ),
            ),
          ),
          2,
        );

        // Combined overview-style: wins as white in B90
        expect(
          await count(
            LocalChessGameFilter(
              playerOutcome: LocalPlayerOutcomeFilter.win,
              base: GameFilter(
                color: GameColorFilter.white,
                eco: GameEcoFilter.forCode('B90'),
                maxYear: DateTime.now().year,
              ),
            ),
          ),
          1,
        );
      },
    );
  });

  group('UI structure keys', () {
    test('filter control keys are present in shipped sources', () {
      final filesView = File(
        'lib/desktop/widgets/library/local_chess_files_view.dart',
      ).readAsStringSync();
      expect(filesView, contains('local-chess-files-filter-button'));
      expect(filesView, contains('showDesktopGameFilterDialog'));
      expect(filesView, contains('LocalChessGameFilter'));

      final library = File('lib/desktop/panes/library_pane.dart').readAsStringSync();
      expect(library, contains('library-mini-preview-filter-button'));
      expect(library, contains('showDesktopGameFilterDialog'));

      final workspace =
          File('lib/desktop/panes/player_workspace_pane.dart').readAsStringSync();
      expect(workspace, contains('onOverviewFilter'));
      expect(workspace, contains('localChessGameFilterFromOverview'));
      expect(workspace, contains('initialFilter'));
    });
  });
}

/// Minimal insert helper mirroring player_stats_repository_test fixtures.
class PlayerStatsRepositoryHarness {
  PlayerStatsRepositoryHarness({
    required this.db,
    required this.databaseId,
    required this.databasePath,
  });

  final resqlite.Database db;
  final String databaseId;
  final String databasePath;
  var gameSeq = 0;

  Future<void> ensureDatabaseRow() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      '''
      INSERT OR IGNORE INTO $localChessDatabasesTable
        (id, path, label, extension, size_bytes, modified_at_ms, file_count,
         game_count, position_count, tree_max_ply, imported_at_ms, updated_at_ms)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        databaseId,
        databasePath,
        'player.pgn',
        '.pgn',
        1,
        now,
        1,
        0,
        0,
        50,
        now,
        now,
      ],
    );
  }

  Future<int> upsertPlayer(String name) async {
    await db.execute(
      'INSERT OR IGNORE INTO $localChessPlayersTable(name, elo) VALUES(?, NULL)',
      [name],
    );
    final rows = await db.select(
      'SELECT id FROM $localChessPlayersTable WHERE name = ?',
      [name],
    );
    return (rows.first['id'] as num).toInt();
  }

  Future<void> insertGame({
    required String white,
    required String black,
    required String result,
    required String eco,
    required String date,
    String tcc = 'Classical',
    String? whiteFideId,
    String? blackFideId,
  }) async {
    final whiteId = await upsertPlayer(white);
    final blackId = await upsertPlayer(black);
    final headers = jsonEncode(<String, Object?>{
      'White': white,
      'Black': black,
      'Result': result,
      'ECO': eco,
      'Date': date,
      if (whiteFideId != null) 'WhiteFideId': whiteFideId,
      if (blackFideId != null) 'BlackFideId': blackFideId,
    });
    await db.execute(
      '''
      INSERT INTO $localChessGamesTable
        (id, database_id, white_id, black_id, white_elo, black_elo, result,
         eco, date, ply_count, time_control_category, headers_json, raw_pgn,
         source_path, source_relative_path, file_name, index_in_file,
         file_game_count)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ''',
      [
        'g${gameSeq++}',
        databaseId,
        whiteId,
        blackId,
        null,
        null,
        result,
        eco,
        date,
        40,
        tcc,
        headers,
        '',
        databasePath,
        'player.pgn',
        'player.pgn',
        gameSeq,
        1,
      ],
    );
  }
}
