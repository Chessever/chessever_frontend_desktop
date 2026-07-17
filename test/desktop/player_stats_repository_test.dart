import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_pgn_catalog.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';

void main() {
  late resqlite.Database db;
  late Directory temp;
  late String databasePath;
  late String databaseId;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-player-stats-');
    db = await resqlite.Database.open('${temp.path}/local_chess.db');
    await createLocalChessResqliteDatabaseSchema(db);
    // Insert games directly without seeding the database/event/site parent
    // rows — this test exercises the aggregation SQL, not referential integrity.
    await db.execute('PRAGMA foreign_keys=OFF');
    databasePath = p.join(temp.path, 'combined.pgn');
    final normalizedDatabasePath = p.normalize(databasePath);
    databaseId =
        Platform.isWindows
            ? normalizedDatabasePath.toLowerCase()
            : normalizedDatabasePath;
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<int> upsertPlayer(String name, int? elo) async {
    await db.execute(
      'INSERT OR IGNORE INTO $localChessPlayersTable(name, elo) VALUES(?, ?)',
      [name, elo],
    );
    final rows = await db.select(
      'SELECT id FROM $localChessPlayersTable WHERE name = ?',
      [name],
    );
    return (rows.first['id'] as num).toInt();
  }

  var gameSeq = 0;
  Future<void> insertGame({
    required String white,
    required String black,
    required String result,
    required String eco,
    required String date,
    String? whiteFideId,
    String? blackFideId,
    int? whiteElo,
    int? blackElo,
    int ply = 40,
    String tcc = 'Classical',
    String? opening,
    String? site,
  }) async {
    final whiteId = await upsertPlayer(white, whiteElo);
    final blackId = await upsertPlayer(black, blackElo);
    final headers = jsonEncode(<String, Object?>{
      'White': white,
      'Black': black,
      'Result': result,
      'ECO': eco,
      'Date': date,
      if (whiteFideId != null) 'WhiteFideId': whiteFideId,
      if (blackFideId != null) 'BlackFideId': blackFideId,
      if (opening != null) 'Opening': opening,
      if (site != null) 'Site': site,
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
        whiteElo,
        blackElo,
        result,
        eco,
        date,
        ply,
        tcc,
        headers,
        '',
        databasePath,
        'combined.pgn',
        'combined.pgn',
        0,
        1,
      ],
    );
  }

  test('computes W/D/L, color splits, openings and rating series', () async {
    const player = 'Durarbayli, Vasif';
    // Player wins as White (C42).
    await insertGame(
      white: player,
      black: 'Opponent, A',
      result: '1-0',
      eco: 'C42',
      date: '2024.01.01',
      whiteElo: 2600,
      blackElo: 2500,
      opening: 'Petrov Defense',
    );
    // Player wins as Black (B90).
    await insertGame(
      white: 'Opponent, B',
      black: player,
      result: '0-1',
      eco: 'B90',
      date: '2024.02.01',
      whiteElo: 2400,
      blackElo: 2610,
      opening: 'Sicilian Najdorf',
    );
    // Player draws as White (C42).
    await insertGame(
      white: player,
      black: 'Opponent, A',
      result: '1/2-1/2',
      eco: 'C42',
      date: '2024.03.01',
      whiteElo: 2620,
      blackElo: 2550,
      opening: 'Petrov Defense',
    );
    // Player loses as Black (B90).
    await insertGame(
      white: 'Opponent, C',
      black: player,
      result: '1-0',
      eco: 'B90',
      date: '2024.04.01',
      whiteElo: 2700,
      blackElo: 2615,
      opening: 'Sicilian Najdorf',
    );

    final repository = PlayerStatsRepository(database: () async => db);
    final stats = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const [player],
    );

    expect(stats.games, 4);
    expect(stats.overall.wins, 2);
    expect(stats.overall.draws, 1);
    expect(stats.overall.losses, 1);

    expect(stats.asWhite.wins, 1);
    expect(stats.asWhite.draws, 1);
    expect(stats.asWhite.losses, 0);

    expect(stats.asBlack.wins, 1);
    expect(stats.asBlack.draws, 0);
    expect(stats.asBlack.losses, 1);

    // Two ECOs, each played twice.
    expect(stats.openings.length, 2);
    final c42 = stats.openings.firstWhere((o) => o.eco == 'C42');
    expect(c42.name, 'Petrov Defense');
    expect(c42.tally.wins, 1);
    expect(c42.tally.draws, 1);
    final b90 = stats.openings.firstWhere((o) => o.eco == 'B90');
    expect(b90.tally.wins, 1);
    expect(b90.tally.losses, 1);

    // Player rating per game, ordered by date.
    expect(stats.ratingSeries.map((s) => s.rating).toList(), [
      2600,
      2610,
      2620,
      2615,
    ]);
    expect(stats.peakRating, 2620);
    expect(stats.latestRating, 2615);

    // Opponents: three distinct, "Opponent, A" played twice.
    final opponentA = stats.opponents.firstWhere(
      (o) => o.name == 'Opponent, A',
    );
    expect(opponentA.tally.games, 2);
  });

  test(
    'first Combined stats load does not fan out heavyweight reads',
    () async {
      var activeSelects = 0;
      var peakActiveSelects = 0;
      final repository = PlayerStatsRepository(
        database: () async => db,
        select: (database, sql, parameters) async {
          activeSelects++;
          if (activeSelects > peakActiveSelects) {
            peakActiveSelects = activeSelects;
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
          activeSelects--;
          return const <Map<String, Object?>>[];
        },
      );

      await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Combined Player'],
        playerFideId: '1234567',
        preferredRatingTimeControl: 'classical',
      );

      expect(
        peakActiveSelects,
        1,
        reason:
            'Parallel full-database aggregates saturate resqlite reader '
            'workers and cause first-open frame drops.',
      );
    },
  );

  test(
    'rating query transfers at most one point per day to the UI isolate',
    () async {
      final whiteId = await upsertPlayer('Frame Test Player', 2800);
      final blackId = await upsertPlayer('Frame Test Opponent', 2700);
      final headers = jsonEncode(const <String, Object?>{
        'White': 'Frame Test Player',
        'Black': 'Frame Test Opponent',
        'WhiteFideId': '7654321',
        'Result': '1-0',
        'Date': '2025.01.01',
      });
      const gameCount = 2000;
      await db.executeBatch(
        '''
        INSERT INTO $localChessGamesTable
          (id, database_id, white_id, black_id, white_elo, black_elo, result,
           eco, date, ply_count, time_control_category, headers_json, raw_pgn,
           source_path, source_relative_path, file_name, index_in_file,
           file_game_count)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''',
        <List<Object?>>[
          for (var i = 0; i < gameCount; i++)
            <Object?>[
              'frame-$i',
              databaseId,
              whiteId,
              blackId,
              2800 + (i % 10),
              2700,
              '1-0',
              'C42',
              '2025.01.01',
              40,
              'blitz',
              headers,
              '',
              databasePath,
              'combined.pgn',
              'combined.pgn',
              i,
              gameCount,
            ],
        ],
      );

      var preferredRatingRows = -1;
      var scopedRatingRows = -1;
      final repository = PlayerStatsRepository(
        database: () async => db,
        select: (database, sql, parameters) async {
          final rows = await database.select(sql, parameters);
          if (sql.contains('rating_scope')) {
            preferredRatingRows = rows.length;
          } else if (sql.contains('rating_daily AS')) {
            scopedRatingRows = rows.length;
          }
          return rows;
        },
      );

      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Frame Test Player'],
        playerFideId: '7654321',
        preferredRatingTimeControl: 'blitz',
      );

      expect(stats.games, gameCount);
      expect(stats.ratingSeries, hasLength(1));
      expect(stats.ratingSeries.single.rating, 2809);
      final scopedStats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Frame Test Player'],
        playerFideId: '7654321',
        timeControlCategory: 'blitz',
      );
      expect(scopedStats.games, gameCount);
      expect(scopedStats.ratingSeries, hasLength(1));
      expect(scopedStats.ratingSeries.single.rating, 2809);
      expect(
        preferredRatingRows,
        1,
        reason:
            'The preferred-ladder rating query must aggregate each calendar '
            'day before rows cross into the Flutter isolate.',
      );
      expect(
        scopedRatingRows,
        1,
        reason:
            'The scoped rating query must aggregate each calendar day before '
            'rows cross into the Flutter isolate.',
      );
    },
  );

  test('disposed source stats stop before dispatching another query', () async {
    final cancellationToken = OperationCancellationToken();
    var selectCount = 0;
    final repository = PlayerStatsRepository(
      database: () async => db,
      select: (_, _, _) async {
        selectCount++;
        cancellationToken.cancel();
        return const <Map<String, Object?>>[];
      },
    );

    await expectLater(
      repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Canceled Player'],
        playerFideId: '1234567',
        cancellationToken: cancellationToken,
      ),
      throwsA(isA<OperationCanceledException>()),
    );
    expect(
      selectCount,
      1,
      reason:
          'Switching source must not leave the obsolete ten-query stats loop '
          'competing with the newly selected source.',
    );
  });

  test('source switch never overlaps old and new stats reads', () async {
    final oldToken = OperationCancellationToken();
    final firstReadStarted = Completer<void>();
    final releaseFirstRead = Completer<void>();
    var selectCount = 0;
    var activeSelects = 0;
    var peakActiveSelects = 0;
    final repository = PlayerStatsRepository(
      database: () async => db,
      select: (_, _, _) async {
        selectCount++;
        activeSelects++;
        if (activeSelects > peakActiveSelects) {
          peakActiveSelects = activeSelects;
        }
        try {
          if (selectCount == 1) {
            firstReadStarted.complete();
            await releaseFirstRead.future;
          }
          return const <Map<String, Object?>>[];
        } finally {
          activeSelects--;
        }
      },
    );

    final oldRequest = repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const ['Old Source Player'],
      playerFideId: '1111111',
      cancellationToken: oldToken,
    );
    await firstReadStarted.future;
    oldToken.cancel();
    final oldExpectation = expectLater(
      oldRequest,
      throwsA(isA<OperationCanceledException>()),
    );
    final newRequest = repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const ['New Source Player'],
      playerFideId: '2222222',
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      selectCount,
      1,
      reason:
          'The new source must wait for resqlite\'s already-dispatched old '
          'read instead of occupying a second reader isolate.',
    );

    releaseFirstRead.complete();
    await oldExpectation;
    await newRequest;
    expect(peakActiveSelects, 1);
  });

  test('returns empty snapshot when the database has no games', () async {
    final repository = PlayerStatsRepository(database: () async => db);
    final stats = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const ['Durarbayli, Vasif'],
    );
    expect(stats.isEmpty, isTrue);
    expect(stats.games, 0);
  });

  test(
    'rating series prefers classical for Combined/ChessEver defaults',
    () async {
      const player = 'Durarbayli, Vasif';
      // More blitz rated games — still prefer classical when preferred.
      await insertGame(
        white: player,
        black: 'Classical Opponent 1',
        result: '1-0',
        eco: 'C42',
        date: '2024.01.01',
        whiteElo: 2600,
        blackElo: 2500,
        tcc: 'classical',
      );
      await insertGame(
        white: 'Classical Opponent 2',
        black: player,
        result: '0-1',
        eco: 'C43',
        date: '2024.02.01',
        whiteElo: 2510,
        blackElo: 2610,
        tcc: 'classical',
      );
      await insertGame(
        white: player,
        black: 'Blitz Opponent 1',
        result: '1-0',
        eco: 'B90',
        date: '2024.03.01',
        whiteElo: 2900,
        blackElo: 2800,
        tcc: 'blitz',
      );
      await insertGame(
        white: player,
        black: 'Blitz Opponent 2',
        result: '1-0',
        eco: 'B90',
        date: '2024.03.15',
        whiteElo: 2910,
        blackElo: 2800,
        tcc: 'blitz',
      );
      await insertGame(
        white: player,
        black: 'Blitz Opponent 3',
        result: '0-1',
        eco: 'B90',
        date: '2024.04.01',
        whiteElo: 2890,
        blackElo: 2750,
        tcc: 'blitz',
      );
      await insertGame(
        white: player,
        black: 'Unknown Opponent',
        result: '1-0',
        eco: 'D30',
        date: '2024.05.01',
        whiteElo: 2400,
        blackElo: 2300,
        tcc: 'Unknown',
      );

      final repository = PlayerStatsRepository(database: () async => db);
      final classicalPreferred = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
        preferredRatingTimeControl: 'classical',
      );
      expect(classicalPreferred.games, 6);
      expect(classicalPreferred.ratingTimeControlCategory, 'classical');
      expect(classicalPreferred.ratingSeries.map((s) => s.rating), [
        2600,
        2610,
      ]);

      final blitzPreferred = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
        preferredRatingTimeControl: 'blitz',
      );
      expect(blitzPreferred.ratingTimeControlCategory, 'blitz');
      expect(blitzPreferred.ratingSeries.map((s) => s.rating), [
        2900,
        2910,
        2890,
      ]);
    },
  );

  test('timeControlCategory scopes whole dashboard including rating', () async {
    const player = 'Durarbayli, Vasif';
    await insertGame(
      white: player,
      black: 'Classical Opp',
      result: '1-0',
      eco: 'C42',
      date: '2024.01.01',
      whiteElo: 2600,
      blackElo: 2500,
      tcc: 'classical',
    );
    await insertGame(
      white: player,
      black: 'Blitz Opp',
      result: '0-1',
      eco: 'B90',
      date: '2024.02.01',
      whiteElo: 2800,
      blackElo: 2700,
      tcc: 'blitz',
    );
    await insertGame(
      white: 'Opp',
      black: player,
      result: '1-0',
      eco: 'B90',
      date: '2024.03.01',
      whiteElo: 2650,
      blackElo: 2810,
      tcc: 'blitz',
    );

    final repository = PlayerStatsRepository(database: () async => db);
    final blitzOnly = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const [player],
      timeControlCategory: 'blitz',
    );
    expect(blitzOnly.games, 2);
    expect(blitzOnly.overall.wins, 0);
    expect(blitzOnly.overall.losses, 2);
    expect(blitzOnly.ratingSeries.map((s) => s.rating), [2800, 2810]);
    expect(blitzOnly.ratingTimeControlCategory, 'blitz');

    final classicalOnly = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const [player],
      timeControlCategory: 'classical',
    );
    expect(classicalOnly.games, 1);
    expect(classicalOnly.overall.wins, 1);
    expect(classicalOnly.ratingSeries.map((s) => s.rating), [2600]);
  });

  test(
    'rating series keeps older rated history when dominant bucket starts late',
    () async {
      const player = 'Durarbayli, Vasif';
      await insertGame(
        white: player,
        black: 'Older Opponent 1',
        result: '1-0',
        eco: 'C42',
        date: '2018.01.01',
        whiteElo: 2400,
        blackElo: 2300,
        tcc: 'Unknown',
      );
      await insertGame(
        white: 'Older Opponent 2',
        black: player,
        result: '1/2-1/2',
        eco: 'D30',
        date: '2019.01.01',
        whiteElo: 2350,
        blackElo: 2450,
        tcc: '',
      );
      await insertGame(
        white: player,
        black: 'Blitz Opponent 1',
        result: '1-0',
        eco: 'B90',
        date: '2022.01.01',
        whiteElo: 2600,
        blackElo: 2500,
        tcc: 'blitz',
      );
      await insertGame(
        white: 'Blitz Opponent 2',
        black: player,
        result: '0-1',
        eco: 'B91',
        date: '2022.02.01',
        whiteElo: 2510,
        blackElo: 2610,
        tcc: 'blitz',
      );
      await insertGame(
        white: player,
        black: 'Blitz Opponent 3',
        result: '1-0',
        eco: 'B92',
        date: '2022.03.01',
        whiteElo: 2620,
        blackElo: 2520,
        tcc: 'blitz',
      );

      final repository = PlayerStatsRepository(database: () async => db);
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
      );

      expect(stats.ratingTimeControlCategory, isNull);
      expect(stats.ratingSeries.map((s) => s.rating), [
        2400,
        2450,
        2600,
        2610,
        2620,
      ]);
      expect(stats.peakRating, 2620);
      expect(stats.latestRating, 2620);
    },
  );

  test(
    'computes a player PGN directly without opening the SQLite cache',
    () async {
      await File(databasePath).writeAsString('$_pgnWin\n\n$_pgnLoss');
      PlayerPgnCatalog.instance.clear();
      final firstCatalog = await PlayerPgnCatalog.instance.load(databasePath);
      final secondCatalog = await PlayerPgnCatalog.instance.load(databasePath);
      expect(identical(firstCatalog, secondCatalog), isTrue);

      var databaseOpened = false;
      final repository = PlayerStatsRepository(
        database: () async {
          databaseOpened = true;
          return db;
        },
      );
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['DrNykterstein'],
      );

      expect(databaseOpened, isFalse);
      expect(stats.games, 2);
      expect(stats.overall.wins, 1);
      expect(stats.overall.losses, 1);
      expect(stats.isEmpty, isFalse);
      expect(stats.lengthBuckets.first.count, 2);
    },
  );

  test(
    'ChessEver games without a TimeControl tag count as classical',
    () async {
      await File(databasePath).writeAsString('''
[Event "Titled Swiss"]
[Site "Baku, Azerbaijan"]
[Date "2025.03.01"]
[Round "1"]
[White "Durarbayli,Vasif"]
[Black "Opponent, One"]
[WhiteFideId "13402935"]
[BlackFideId "10000001"]
[WhiteElo "2605"]
[BlackElo "2500"]
[ECO "B90"]
[Result "1-0"]

1. e4 c5 2. Nf3 d6 1-0
''');

      final repository = PlayerStatsRepository(database: () async => db);
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Vasif Durarbayli'],
        playerFideId: '13402935',
        timeControlCategory: 'classical',
        unclassifiedTimeControlCategory: 'classical',
      );

      expect(stats.games, 1);
      expect(stats.overall.wins, 1);
      expect(stats.overall.draws, 0);
      expect(stats.timeControls.single.category, 'classical');
      expect(stats.timeControls.single.count, 1);

      // Existing players can already have this game cached with a null
      // category and a geographic Site. Source provenance must classify it
      // without requiring the user to re-download the ChessEver source.
      await db.execute(
        'UPDATE $localChessGamesTable '
        'SET time_control_category = NULL WHERE database_id = ?',
        [databaseId],
      );
      final repaired = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['Vasif Durarbayli'],
        playerFideId: '13402935',
        timeControlCategory: 'classical',
        unclassifiedTimeControlCategory: 'classical',
      );
      expect(repaired.games, 1);
      expect(repaired.timeControls.single.category, 'classical');
    },
  );

  test('matches the player via dominant name when aliases differ', () async {
    // PGN stores "Durarbayli, Vasif"; the alias arrives word-order-flipped and
    // title-prefixed. The dominant-name fallback must still attribute games.
    const stored = 'Durarbayli, Vasif';
    await insertGame(
      white: stored,
      black: 'Carlsen, Magnus',
      result: '1-0',
      eco: 'C42',
      date: '2024.01.01',
    );
    await insertGame(
      white: 'Firouzja, Alireza',
      black: stored,
      result: '1-0',
      eco: 'B90',
      date: '2024.02.01',
    );

    final repository = PlayerStatsRepository(database: () async => db);
    final stats = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const ['GM Vasif Durarbayli'],
    );

    expect(stats.games, 2);
    expect(stats.overall.wins, 1); // won as White
    expect(stats.overall.losses, 1); // lost as Black
  });

  test(
    'uses FIDE id instead of names when PGN player names are inconsistent',
    () async {
      // The same player appears under two compact ChessEver name variants. A
      // repeated opponent is the dominant name in the database, so name fallback
      // alone would attribute both games to the opponent.
      await insertGame(
        white: 'Durarbayli,Vasif',
        black: 'Nakamura,Hi',
        whiteFideId: '13402935',
        blackFideId: '2016192',
        result: '1-0',
        eco: 'C42',
        date: '2026.03.31',
      );
      await insertGame(
        white: 'Nakamura,Hi',
        black: 'Durarbayli,V',
        whiteFideId: '2016192',
        blackFideId: '13402935',
        result: '0-1',
        eco: 'B90',
        date: '2026.04.01',
      );

      final repository = PlayerStatsRepository(database: () async => db);
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['GM Vasif Durarbayli'],
        playerFideId: '13402935',
      );

      expect(stats.games, 2);
      expect(stats.overall.wins, 2);
      expect(stats.overall.losses, 0);
    },
  );

  test('uses aliases for source games that do not carry FIDE ids', () async {
    await insertGame(
      white: 'Durarbayli,Vasif',
      black: 'Nakamura,Hi',
      whiteFideId: '13402935',
      blackFideId: '2016192',
      result: '1-0',
      eco: 'C42',
      date: '2026.03.31',
    );
    await insertGame(
      white: 'Nakamura,Hi',
      black: 'Durarbayli,V',
      whiteFideId: '2016192',
      blackFideId: '13402935',
      result: '0-1',
      eco: 'B90',
      date: '2026.04.01',
    );
    await insertGame(
      white: 'Vasif_Durarbayli',
      black: 'Carlsen, Magnus',
      result: '1/2-1/2',
      eco: 'C65',
      date: '2026.04.02',
    );
    await insertGame(
      white: 'Carlsen, Magnus',
      black: 'VasifDurarbayli',
      result: '0-1',
      eco: 'C67',
      date: '2026.04.03',
    );
    await insertGame(
      white: 'Vasif Durarbayli',
      black: 'Firouzja, Alireza',
      whiteFideId: '999999',
      result: '1-0',
      eco: 'D30',
      date: '2026.04.04',
    );

    final repository = PlayerStatsRepository(database: () async => db);
    final stats = await repository.computePlayerStats(
      databasePath: databasePath,
      aliases: const ['Vasif Durarbayli'],
      playerFideId: '13402935',
    );

    expect(stats.games, 4);
    expect(stats.overall.wins, 3);
    expect(stats.overall.draws, 1);
    expect(stats.overall.losses, 0);
    expect(stats.years.single.games, 4);
  });

  test(
    'year series carries W/D/L, time controls and sources for hover',
    () async {
      const player = 'Year Chart Player';
      await insertGame(
        white: player,
        black: 'Opp A',
        result: '1-0',
        eco: 'C01',
        date: '2022.05.01',
        tcc: 'Blitz',
        site: 'https://lichess.org/abc',
      );
      await insertGame(
        white: 'Opp B',
        black: player,
        result: '1-0',
        eco: 'C02',
        date: '2022.06.01',
        tcc: 'Rapid',
        site: 'https://www.chess.com/game/live/1',
      );
      await insertGame(
        white: player,
        black: 'Opp C',
        result: '1/2-1/2',
        eco: 'C03',
        date: '2023.01.15',
        tcc: 'Blitz',
        site: 'https://lichess.org/def',
      );
      await insertGame(
        white: player,
        black: 'Opp D',
        result: '0-1',
        eco: 'C04',
        date: '2023.08.20',
        tcc: 'Classical',
        site: 'https://lichess.org/ghi',
      );

      final repository = PlayerStatsRepository(database: () async => db);
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const [player],
      );

      expect(stats.years.map((y) => y.year).toList(), [2022, 2023]);

      final y2022 = stats.years.firstWhere((y) => y.year == 2022);
      expect(y2022.games, 2);
      expect(y2022.tally.wins, 1);
      expect(y2022.tally.losses, 1);
      expect(y2022.tally.draws, 0);
      expect(
        {for (final t in y2022.timeControls) t.category: t.count},
        {'Blitz': 1, 'Rapid': 1},
      );
      expect(
        {for (final s in y2022.sources) s.label: s.count},
        {'Lichess': 1, 'Chess.com': 1},
      );

      final y2023 = stats.years.firstWhere((y) => y.year == 2023);
      expect(y2023.games, 2);
      expect(y2023.tally.wins, 0);
      expect(y2023.tally.draws, 1);
      expect(y2023.tally.losses, 1);
      expect(
        {for (final t in y2023.timeControls) t.category: t.count},
        {'Blitz': 1, 'Classical': 1},
      );
      expect({for (final s in y2023.sources) s.label: s.count}, {'Lichess': 2});

      // Shipped chart mapping must surface the same breakdowns.
      final series = playerYearChartSeries(stats.years);
      expect(series.map((p) => p.year), [2022, 2023]);
      expect(series[0].wins, 1);
      expect(series[0].losses, 1);
      expect(series[0].sources.map((s) => s.label).toSet(), {
        'Lichess',
        'Chess.com',
      });
      expect(series[1].timeControls.map((t) => t.category).toSet(), {
        'Blitz',
        'Classical',
      });
    },
  );
}

const String _pgnWin = '''
[Event "Lichess import 1"]
[Site "https://lichess.org/import-one"]
[Date "2026.06.01"]
[Round "1"]
[White "DrNykterstein"]
[Black "Opponent One"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

const String _pgnLoss = '''
[Event "Lichess import 2"]
[Site "https://lichess.org/import-two"]
[Date "2026.06.02"]
[Round "1"]
[White "Opponent Two"]
[Black "DrNykterstein"]
[Result "1-0"]

1. d4 d5 2. c4 e6 1-0
''';
