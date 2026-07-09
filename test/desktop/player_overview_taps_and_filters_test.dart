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
    Future<void> insertGame({
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
          'g${seq++}',
          databaseId,
          whiteId,
          blackId,
          whiteElo,
          blackElo,
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
          seq,
          1,
        ],
      );
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
