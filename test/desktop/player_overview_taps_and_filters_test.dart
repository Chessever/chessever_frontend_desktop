import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/tempo_icon.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

void main() {
  group('overview mapping', () {
    test('W/D/L and opponent/ECO facets map to shipped filter fields', () {
      final wins = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.wins,
        ),
      );
      expect(wins.playerOutcome, LocalPlayerOutcomeFilter.win);

      final eco = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.eco,
          ecoCode: 'b90',
        ),
      );
      expect(eco.base.eco.code, 'B90');

      final opp = localChessGameFilterFromOverview(
        const PlayerOverviewFilterRequest(
          facet: PlayerOverviewFilterFacet.opponent,
          opponentName: 'Carlsen, Magnus',
        ),
      );
      expect(opp.opponentName, 'Carlsen, Magnus');
    });

    test(
      'applyingDialog clears sticky timeControlCategory so dialog TC wins',
      () {
        final fromOverview = localChessGameFilterFromOverview(
          const PlayerOverviewFilterRequest(
            facet: PlayerOverviewFilterFacet.timeControl,
            timeControlCategory: 'bullet',
          ),
        );
        expect(fromOverview.timeControlCategory, 'bullet');

        final afterDialog = fromOverview.applyingDialog(
          GameFilter(
            timeControl: GameTimeControlFilter.classical,
            maxYear: DateTime.now().year,
          ),
        );
        expect(afterDialog.timeControlCategory, isNull);
        expect(afterDialog.base.timeControl, GameTimeControlFilter.classical);

        // SQL path must honor dialog classical, not leftover bullet.
        final where = StringBuffer('g.database_id = ?');
        final params = <Object?>['db'];
        appendLocalChessGameFilter(where, params, afterDialog);
        final sql = where.toString();
        expect(sql, contains('classical'));
        expect(sql, isNot(contains("= 'bullet'")));
      },
    );
  });

  group('tempo icons', () {
    test('bullet and ultra-bullet resolve to distinct assets from blitz', () {
      expect(tempoIconAssetForCategory('blitz'), PngAsset.blitzIcon);
      expect(tempoIconAssetForCategory('bullet'), PngAsset.bulletIcon);
      expect(
        tempoIconAssetForCategory('ultrabullet'),
        PngAsset.ultraBulletIcon,
      );
      expect(
        tempoIconAssetForCategory('ultra bullet'),
        PngAsset.ultraBulletIcon,
      );
      expect(PngAsset.bulletIcon, isNot(PngAsset.blitzIcon));
      expect(PngAsset.ultraBulletIcon, isNot(PngAsset.blitzIcon));
      expect(File(PngAsset.bulletIcon).existsSync(), isTrue);
      expect(File(PngAsset.ultraBulletIcon).existsSync(), isTrue);
      expect(File(PngAsset.blitzIcon).existsSync(), isTrue);
    });
  });

  group('local filter + search composition', () {
    late resqlite.Database db;
    late Directory temp;
    late String databasePath;
    late String databaseId;

    setUpAll(() {
      sqfliteFfiInit();
      sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever-filter-combo-');
      db = await resqlite.Database.open('${temp.path}/local_chess.db');
      await createLocalChessResqliteDatabaseSchema(db);
      await db.execute('PRAGMA foreign_keys=OFF');
      databasePath = p.join(temp.path, 'player.pgn');
      databaseId = p.normalize(databasePath);
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
    });

    tearDown(() async {
      await db.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

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

    var seq = 0;
    Future<String> insertGame({
      required String white,
      required String black,
      required String result,
      required String eco,
      required String date,
      String tcc = 'Classical',
      String? whiteFideId,
      String? blackFideId,
      int? whiteElo,
      int? blackElo,
      String opening = '',
      String event = 'Local Event',
      String site = 'Local Site',
      int ply = 40,
      bool isOnline = false,
      String fileName = 'player.pgn',
    }) async {
      final whiteId = await upsertPlayer(white);
      final blackId = await upsertPlayer(black);
      Future<int> upsertNamed(String table, String name) async {
        await db.execute('INSERT OR IGNORE INTO $table(name) VALUES(?)', [
          name,
        ]);
        final rows = await db.select('SELECT id FROM $table WHERE name = ?', [
          name,
        ]);
        return (rows.single['id'] as num).toInt();
      }

      final eventId = await upsertNamed(localChessEventsTable, event);
      final siteId = await upsertNamed(localChessSitesTable, site);
      final headers = jsonEncode(<String, Object?>{
        'White': white,
        'Black': black,
        'Result': result,
        'ECO': eco,
        'Date': date,
        'Event': event,
        'Site': site,
        if (opening.isNotEmpty) 'Opening': opening,
        if (whiteFideId != null) 'WhiteFideId': whiteFideId,
        if (blackFideId != null) 'BlackFideId': blackFideId,
      });
      final id = 'g${seq++}';
      await db.execute(
        '''
        INSERT INTO $localChessGamesTable
          (id, database_id, event_id, site_id, white_id, black_id,
           white_elo, black_elo, result, eco, date, ply_count,
           time_control_category, is_online, headers_json, raw_pgn,
           source_path, source_relative_path, file_name, index_in_file,
           file_game_count)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''',
        [
          id,
          databaseId,
          eventId,
          siteId,
          whiteId,
          blackId,
          whiteElo,
          blackElo,
          result,
          eco,
          date,
          ply,
          tcc,
          isOnline ? 1 : 0,
          headers,
          '',
          databasePath,
          fileName,
          fileName,
          seq,
          1,
        ],
      );
      return id;
    }

    test('combines outcome + eco + year + search on selected source', () async {
      const player = 'Filter Player';
      await insertGame(
        white: player,
        black: 'Carlsen, Magnus',
        result: '1-0',
        eco: 'B90',
        date: '2022.05.01',
        tcc: 'Blitz',
        whiteFideId: '111',
      );
      await insertGame(
        white: player,
        black: 'Carlsen, Magnus',
        result: '0-1',
        eco: 'B90',
        date: '2022.06.01',
        tcc: 'Blitz',
        whiteFideId: '111',
      );
      await insertGame(
        white: player,
        black: 'Nakamura, Hikaru',
        result: '1-0',
        eco: 'C42',
        date: '2023.01.01',
        tcc: 'Classical',
        whiteFideId: '111',
      );
      await insertGame(
        white: 'Opp',
        black: player,
        result: '0-1',
        eco: 'B90',
        date: '2022.07.01',
        tcc: 'Bullet',
        blackFideId: '111',
      );

      final repo = LocalChessDatabaseRepository(database: () async => db);

      Future<int> count(
        LocalChessGameFilter filter, {
        String search = '',
      }) async {
        final page = await repo.localDatabaseGamesPage(
          databasePath: databasePath,
          search: search,
          filter: filter,
          playerFideId: '111',
          playerAliases: const [player],
          pageNumber: 0,
          pageSize: 50,
        );
        return page?.totalCount ?? -1;
      }

      expect(await count(LocalChessGameFilter()), 4);

      // Wins only (player POV): white 1-0 vs Carlsen, white 1-0 vs Naka, black 0-1 = win
      expect(
        await count(
          LocalChessGameFilter(playerOutcome: LocalPlayerOutcomeFilter.win),
        ),
        3,
      );

      // ECO B90 + win: Carlsen win + black win vs Opp (B90)
      expect(
        await count(
          LocalChessGameFilter(
            playerOutcome: LocalPlayerOutcomeFilter.win,
            base: GameFilter(
              eco: GameEcoFilter.forCode('B90'),
              maxYear: DateTime.now().year,
            ),
          ),
        ),
        2,
      );

      // Year 2022 + search carlsen
      expect(
        await count(
          LocalChessGameFilter(base: GameFilter(minYear: 2022, maxYear: 2022)),
          search: 'carlsen',
        ),
        2,
      );

      // Opponent + blitz exact
      expect(
        await count(
          LocalChessGameFilter(
            opponentName: 'Carlsen',
            timeControlCategory: 'blitz',
          ),
        ),
        2,
      );

      // Bullet exact (not merged into blitz when exact category set)
      expect(
        await count(LocalChessGameFilter(timeControlCategory: 'bullet')),
        1,
      );

      // Clear restores
      expect(await count(LocalChessGameFilter()), 4);
    });

    test(
      'all filter/search combinations compose with every column sort and page',
      () async {
        const player = 'Filter Player';
        final games = <_QueryOracleGame>[
          const _QueryOracleGame(
            event: 'Baku Open',
            white: player,
            black: 'Carlsen, Magnus',
            result: '1-0',
            eco: 'C02',
            opening: 'French: Advance',
            date: '2022.01.01',
            timeControl: 'classical',
            whiteElo: 2600,
            blackElo: 2800,
            ply: 40,
            isOnline: false,
            playerSide: 'w',
            playerOutcome: 'win',
          ),
          const _QueryOracleGame(
            event: 'Wijk Masters',
            white: 'Nepomniachtchi, Ian',
            black: player,
            result: '1/2-1/2',
            eco: 'B20',
            opening: 'Sicilian Defense',
            date: '2022.02.02',
            timeControl: 'rapid',
            whiteElo: 2750,
            blackElo: 2610,
            ply: 60,
            isOnline: false,
            playerSide: 'b',
            playerOutcome: 'draw',
          ),
          const _QueryOracleGame(
            event: 'Speed Arena',
            white: 'Filter_Player',
            black: 'Nakamura, Hikaru',
            result: '0-1',
            eco: 'C45',
            opening: 'Scotch Game',
            date: '2023.03.03',
            timeControl: 'blitz',
            whiteElo: 2650,
            blackElo: 2900,
            ply: 30,
            isOnline: true,
            playerSide: 'w',
            playerOutcome: 'loss',
          ),
          const _QueryOracleGame(
            event: 'Bullet Cup',
            white: 'Firouzja, Alireza',
            black: 'Filter_Player',
            result: '0-1',
            eco: 'B06',
            opening: 'Modern Defense',
            date: '2024.04.04',
            timeControl: 'bullet',
            whiteElo: 2800,
            blackElo: 2700,
            ply: 22,
            isOnline: true,
            playerSide: 'b',
            playerOutcome: 'win',
          ),
          const _QueryOracleGame(
            event: 'Candidates',
            white: player,
            black: 'Gukesh D',
            result: '1/2-1/2',
            eco: 'D30',
            opening: "Queen's Gambit Declined",
            date: '2024.05.05',
            timeControl: 'classical',
            whiteElo: 2710,
            blackElo: 2750,
            ply: 80,
            isOnline: false,
            playerSide: 'w',
            playerOutcome: 'draw',
          ),
          const _QueryOracleGame(
            event: 'Rapid Open',
            white: 'Abdusattorov, Nodirbek',
            black: player,
            result: '1-0',
            eco: 'A04',
            opening: 'Réti Opening',
            date: '2025.06.06',
            timeControl: 'rapid',
            whiteElo: 2760,
            blackElo: 2720,
            ply: 50,
            isOnline: false,
            playerSide: 'b',
            playerOutcome: 'loss',
          ),
          const _QueryOracleGame(
            event: 'Online Swiss',
            white: 'Filter_Player',
            black: 'Carlsen, Magnus',
            result: '1-0',
            eco: 'B90',
            opening: 'Sicilian: Najdorf',
            date: '2025.07.07',
            timeControl: 'blitz',
            whiteElo: 2730,
            blackElo: 2850,
            ply: 70,
            isOnline: true,
            playerSide: 'w',
            playerOutcome: 'win',
          ),
          const _QueryOracleGame(
            event: 'Mystery Match',
            white: 'Opponent Eight',
            black: 'Filter_Player',
            result: '1/2-1/2',
            eco: 'A45',
            opening: 'Indian Defense',
            date: '2021.08.08',
            timeControl: 'classical',
            blackElo: 2500,
            ply: 18,
            isOnline: false,
            playerSide: 'b',
            playerOutcome: 'draw',
          ),
          const _QueryOracleGame(
            event: 'Percent % Under_score',
            white: player,
            black: 'Literal Opponent',
            result: '1-0',
            eco: 'E90',
            opening: "King's Indian: Classical",
            date: '2020.09.09',
            timeControl: 'classical',
            whiteElo: 2400,
            blackElo: 2450,
            ply: 28,
            isOnline: false,
            playerSide: 'w',
            playerOutcome: 'win',
          ),
        ];

        for (final game in games) {
          await insertGame(
            white: game.white,
            black: game.black,
            result: game.result,
            eco: game.eco,
            date: game.date,
            tcc: game.timeControl,
            whiteFideId:
                game.playerSide == 'w' && game.white == player ? '111' : null,
            blackFideId:
                game.playerSide == 'b' && game.black == player ? '111' : null,
            whiteElo: game.whiteElo,
            blackElo: game.blackElo,
            opening: game.opening,
            event: game.event,
            site:
                game.isOnline ? 'https://online.test/${game.eco}' : 'OTB Hall',
            ply: game.ply,
            isOnline: game.isOnline,
          );
        }

        final scenarios = <_QueryOracleScenario>[
          _QueryOracleScenario(
            label: 'all',
            filter: LocalChessGameFilter(),
            matches: (_) => true,
          ),
          _QueryOracleScenario(
            label: 'overview wins',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.wins,
              ),
            ),
            matches: (game) => game.playerOutcome == 'win',
          ),
          _QueryOracleScenario(
            label: 'overview draws',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.draws,
              ),
            ),
            matches: (game) => game.playerOutcome == 'draw',
          ),
          _QueryOracleScenario(
            label: 'overview losses',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.losses,
              ),
            ),
            matches: (game) => game.playerOutcome == 'loss',
          ),
          _QueryOracleScenario(
            label: 'overview as white',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.asWhite,
              ),
            ),
            matches: (game) => game.playerSide == 'w',
          ),
          _QueryOracleScenario(
            label: 'overview as black',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.asBlack,
              ),
            ),
            matches: (game) => game.playerSide == 'b',
          ),
          _QueryOracleScenario(
            label: 'overview eco',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.eco,
                ecoCode: 'B20',
              ),
            ),
            matches: (game) => game.eco == 'B20',
          ),
          _QueryOracleScenario(
            label: 'overview year',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.year,
                year: 2024,
              ),
            ),
            matches: (game) => game.date.startsWith('2024.'),
          ),
          _QueryOracleScenario(
            label: 'overview classical',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.timeControl,
                timeControlCategory: 'classical',
              ),
            ),
            matches: (game) => game.timeControl == 'classical',
          ),
          _QueryOracleScenario(
            label: 'overview opponent',
            filter: localChessGameFilterFromOverview(
              const PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.opponent,
                opponentName: 'Carlsen, Magnus',
              ),
            ),
            matches:
                (game) =>
                    game.white == 'Carlsen, Magnus' ||
                    game.black == 'Carlsen, Magnus',
          ),
          _QueryOracleScenario(
            label: 'dialog online blitz',
            filter: LocalChessGameFilter(
              base: GameFilter(
                timeControl: GameTimeControlFilter.blitz,
                online: GameOnlineFilter.online,
                maxYear: DateTime.now().year,
              ),
            ),
            matches:
                (game) =>
                    game.isOnline &&
                    (game.timeControl == 'blitz' ||
                        game.timeControl == 'bullet'),
          ),
          _QueryOracleScenario(
            label: 'stacked result year rating finish',
            filter: LocalChessGameFilter(
              base: GameFilter(
                result: GameResultFilter.whiteWins,
                finish: GameFinishFilter.byMove25,
                minYear: 2020,
                maxYear: 2025,
                minRating: 2400,
                maxRating: 2800,
              ),
            ),
            matches:
                (game) =>
                    game.result == '1-0' &&
                    game.ply <= 50 &&
                    game.year >= 2020 &&
                    game.year <= 2025 &&
                    game.averageRating >= 2400 &&
                    game.averageRating <= 2800,
          ),
          _QueryOracleScenario(
            label: 'dense combined filters and search',
            filter: LocalChessGameFilter(
              base: GameFilter(
                color: GameColorFilter.black,
                finish: GameFinishFilter.byMove15,
                online: GameOnlineFilter.online,
                eco: GameEcoFilter.forCode('B06'),
                minYear: 2024,
                maxYear: 2024,
                minRating: 2600,
                maxRating: 2800,
              ),
              playerOutcome: LocalPlayerOutcomeFilter.win,
              opponentName: 'Firouzja, Alireza',
              timeControlCategory: 'bullet',
            ),
            search: 'bullet cup',
            matches: (game) => game.event == 'Bullet Cup',
          ),
          _QueryOracleScenario(
            label: 'multi-term search',
            filter: LocalChessGameFilter(),
            search: 'carlsen 2025',
            matches: (game) => game.event == 'Online Swiss',
          ),
          _QueryOracleScenario(
            label: 'literal SQL wildcard search',
            filter: LocalChessGameFilter(),
            search: '% under_',
            matches: (game) => game.event == 'Percent % Under_score',
          ),
        ];
        final repo = LocalChessDatabaseRepository(database: () async => db);

        Future<int> countOverview(PlayerOverviewFilterRequest request) async {
          final page = await repo.localDatabaseGamesPage(
            databasePath: databasePath,
            filter: localChessGameFilterFromOverview(request),
            playerFideId: '111',
            playerAliases: const <String>[player, 'Filter_Player'],
            pageNumber: 0,
            pageSize: 50,
          );
          return page!.totalCount;
        }

        final stats = await PlayerStatsRepository(
          database: () async => db,
        ).computePlayerStats(
          databasePath: databasePath,
          aliases: const <String>[player, 'Filter_Player'],
          playerFideId: '111',
        );
        expect(
          await countOverview(
            const PlayerOverviewFilterRequest(
              facet: PlayerOverviewFilterFacet.wins,
            ),
          ),
          stats.overall.wins,
        );
        expect(
          await countOverview(
            const PlayerOverviewFilterRequest(
              facet: PlayerOverviewFilterFacet.draws,
            ),
          ),
          stats.overall.draws,
        );
        expect(
          await countOverview(
            const PlayerOverviewFilterRequest(
              facet: PlayerOverviewFilterFacet.losses,
            ),
          ),
          stats.overall.losses,
        );
        expect(
          await countOverview(
            const PlayerOverviewFilterRequest(
              facet: PlayerOverviewFilterFacet.asWhite,
            ),
          ),
          stats.asWhite.games,
        );
        expect(
          await countOverview(
            const PlayerOverviewFilterRequest(
              facet: PlayerOverviewFilterFacet.asBlack,
            ),
          ),
          stats.asBlack.games,
        );
        for (final opening in stats.openings) {
          expect(
            await countOverview(
              PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.eco,
                ecoCode: opening.eco,
              ),
            ),
            opening.tally.games,
            reason: 'Opening handoff ${opening.eco}',
          );
        }
        for (final year in stats.years) {
          expect(
            await countOverview(
              PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.year,
                year: year.year,
              ),
            ),
            year.games,
            reason: 'Year handoff ${year.year}',
          );
        }
        for (final timeControl in stats.timeControls) {
          expect(
            await countOverview(
              PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.timeControl,
                timeControlCategory: timeControl.category,
              ),
            ),
            timeControl.count,
            reason: 'Time-control handoff ${timeControl.category}',
          );
        }
        for (final opponent in stats.opponents) {
          expect(
            await countOverview(
              PlayerOverviewFilterRequest(
                facet: PlayerOverviewFilterFacet.opponent,
                opponentName: opponent.name,
              ),
            ),
            opponent.tally.games,
            reason: 'Opponent handoff ${opponent.name}',
          );
        }

        for (final scenario in scenarios) {
          final scoped = games.where(scenario.matches).toList(growable: false);
          for (final sort in LocalChessGameSortField.values) {
            for (final direction in LocalChessGameSortDirection.values) {
              final expected = _sortOracleGames(scoped, sort, direction);
              final actualEvents = <String>[];
              var pageNumber = 0;
              var total = -1;
              do {
                final page = await repo.localDatabaseGamesPage(
                  databasePath: databasePath,
                  search: scenario.search,
                  filter: scenario.filter,
                  playerFideId: '111',
                  playerAliases: const <String>[player, 'Filter_Player'],
                  sortBy: sort,
                  sortDirection: direction,
                  pageNumber: pageNumber,
                  pageSize: 2,
                );
                expect(page, isNotNull, reason: scenario.label);
                total = page!.totalCount;
                actualEvents.addAll(
                  page.games.map(
                    (game) => game.game.metadata['Event']!.toString(),
                  ),
                );
                pageNumber++;
              } while (actualEvents.length < total);

              expect(
                total,
                expected.length,
                reason: '${scenario.label} · $sort · $direction total',
              );
              expect(
                actualEvents,
                expected.map((game) => game.event),
                reason: '${scenario.label} · $sort · $direction order',
              );
            }
          }
        }
      },
    );
  });

  group('overview outcome re-scopes stats', () {
    late resqlite.Database db;
    late Directory temp;
    late String databasePath;
    late String databaseId;

    setUpAll(() {
      sqfliteFfiInit();
      sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever-outcome-');
      db = await resqlite.Database.open('${temp.path}/local_chess.db');
      await createLocalChessResqliteDatabaseSchema(db);
      await db.execute('PRAGMA foreign_keys=OFF');
      databasePath = p.join(temp.path, 'player.pgn');
      databaseId = p.normalize(databasePath);
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
    });

    tearDown(() async {
      await db.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<void> insert({
      required String white,
      required String black,
      required String result,
      required String date,
      String tcc = 'Classical',
    }) async {
      Future<int> up(String n) async {
        await db.execute(
          'INSERT OR IGNORE INTO $localChessPlayersTable(name, elo) VALUES(?, NULL)',
          [n],
        );
        final rows = await db.select(
          'SELECT id FROM $localChessPlayersTable WHERE name = ?',
          [n],
        );
        return (rows.first['id'] as num).toInt();
      }

      final wid = await up(white);
      final bid = await up(black);
      final headers = jsonEncode({
        'White': white,
        'Black': black,
        'Result': result,
        'Date': date,
      });
      await db.execute(
        '''
        INSERT INTO $localChessGamesTable
          (id, database_id, white_id, black_id, result, eco, date, ply_count,
           time_control_category, headers_json, raw_pgn, source_path,
           source_relative_path, file_name, index_in_file, file_game_count)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''',
        [
          'g${DateTime.now().microsecondsSinceEpoch}',
          databaseId,
          wid,
          bid,
          result,
          'C42',
          date,
          40,
          tcc,
          headers,
          '',
          databasePath,
          'p.pgn',
          'p.pgn',
          0,
          1,
        ],
      );
    }

    test('wins-only outcome shrinks overall tally', () async {
      const player = 'Outcome Player';
      await insert(
        white: player,
        black: 'A',
        result: '1-0',
        date: '2024.01.01',
      );
      await insert(
        white: player,
        black: 'B',
        result: '1/2-1/2',
        date: '2024.02.01',
      );
      await insert(
        white: 'C',
        black: player,
        result: '1-0',
        date: '2024.03.01',
      );

      final repo = PlayerStatsRepository(database: () async => db);
      final all = await repo.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
      );
      expect(all.games, 3);
      expect(all.overall.wins, 1);
      expect(all.overall.draws, 1);
      expect(all.overall.losses, 1);

      final winsOnly = await repo.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
        playerOutcome: PlayerStatsOutcomeFilter.win,
      );
      expect(winsOnly.games, 1);
      expect(winsOnly.overall.wins, 1);
      expect(winsOnly.overall.draws, 0);
      expect(winsOnly.overall.losses, 0);

      final asWhite = await repo.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
        playerColor: 'w',
      );
      expect(asWhite.games, 2);
    });
  });
}

class _QueryOracleGame {
  const _QueryOracleGame({
    required this.event,
    required this.white,
    required this.black,
    required this.result,
    required this.eco,
    required this.opening,
    required this.date,
    required this.timeControl,
    this.whiteElo,
    this.blackElo,
    required this.ply,
    required this.isOnline,
    required this.playerSide,
    required this.playerOutcome,
  });

  final String event;
  final String white;
  final String black;
  final String result;
  final String eco;
  final String opening;
  final String date;
  final String timeControl;
  final int? whiteElo;
  final int? blackElo;
  final int ply;
  final bool isOnline;
  final String playerSide;
  final String playerOutcome;

  int get year => int.parse(date.substring(0, 4));

  int get averageRating {
    final whiteRating = whiteElo ?? 0;
    final blackRating = blackElo ?? 0;
    if (whiteRating <= 0) return blackRating;
    if (blackRating <= 0) return whiteRating;
    return (whiteRating + blackRating) ~/ 2;
  }
}

class _QueryOracleScenario {
  const _QueryOracleScenario({
    required this.label,
    required this.filter,
    required this.matches,
    this.search = '',
  });

  final String label;
  final LocalChessGameFilter filter;
  final bool Function(_QueryOracleGame game) matches;
  final String search;
}

List<_QueryOracleGame> _sortOracleGames(
  List<_QueryOracleGame> games,
  LocalChessGameSortField field,
  LocalChessGameSortDirection direction,
) {
  final indexed = <({int index, _QueryOracleGame game})>[
    for (var index = 0; index < games.length; index++)
      (index: index, game: games[index]),
  ];
  int compareText(String? a, String? b) {
    final cleanA = a?.trim();
    final cleanB = b?.trim();
    final missingA =
        cleanA == null || cleanA.isEmpty || cleanA == '?' || cleanA == '-';
    final missingB =
        cleanB == null || cleanB.isEmpty || cleanB == '?' || cleanB == '-';
    if (missingA != missingB) return missingA ? 1 : -1;
    final compared = (cleanA ?? '').toLowerCase().compareTo(
      (cleanB ?? '').toLowerCase(),
    );
    return direction == LocalChessGameSortDirection.asc ? compared : -compared;
  }

  int compareInt(int? a, int? b) {
    if ((a == null) != (b == null)) return a == null ? 1 : -1;
    final compared = (a ?? 0).compareTo(b ?? 0);
    return direction == LocalChessGameSortDirection.asc ? compared : -compared;
  }

  indexed.sort((a, b) {
    if (field == LocalChessGameSortField.originalOrder) {
      final compared = a.index.compareTo(b.index);
      return direction == LocalChessGameSortDirection.asc
          ? compared
          : -compared;
    }
    final compared = switch (field) {
      LocalChessGameSortField.originalOrder => 0,
      LocalChessGameSortField.white => compareText(a.game.white, b.game.white),
      LocalChessGameSortField.whiteElo => compareInt(
        a.game.whiteElo,
        b.game.whiteElo,
      ),
      LocalChessGameSortField.black => compareText(a.game.black, b.game.black),
      LocalChessGameSortField.blackElo => compareInt(
        a.game.blackElo,
        b.game.blackElo,
      ),
      LocalChessGameSortField.result => compareText(
        a.game.result,
        b.game.result,
      ),
      LocalChessGameSortField.eco => compareText(a.game.eco, b.game.eco),
      LocalChessGameSortField.opening => compareText(
        a.game.opening,
        b.game.opening,
      ),
      LocalChessGameSortField.event => compareText(a.game.event, b.game.event),
      LocalChessGameSortField.date => compareText(a.game.date, b.game.date),
    };
    return compared != 0 ? compared : a.index.compareTo(b.index);
  });
  return indexed.map((entry) => entry.game).toList(growable: false);
}
