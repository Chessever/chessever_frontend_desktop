import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
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
    databaseId = p.normalize(databasePath);
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
    int? whiteElo,
    int? blackElo,
    int ply = 40,
    String tcc = 'Classical',
    String? opening,
  }) async {
    final whiteId = await upsertPlayer(white, whiteElo);
    final blackId = await upsertPlayer(black, blackElo);
    final headers = jsonEncode(<String, Object?>{
      'White': white,
      'Black': black,
      'Result': result,
      'ECO': eco,
      'Date': date,
      if (opening != null) 'Opening': opening,
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
    'hydrates missing local cache from the player PGN before computing stats',
    () async {
      await File(databasePath).writeAsString('$_pgnWin\n\n$_pgnLoss');

      final repository = PlayerStatsRepository(database: () async => db);
      final stats = await repository.computePlayerStats(
        databasePath: databasePath,
        aliases: const ['DrNykterstein'],
      );

      expect(stats.games, 2);
      expect(stats.overall.wins, 1);
      expect(stats.overall.losses, 1);
      expect(stats.isEmpty, isFalse);
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
