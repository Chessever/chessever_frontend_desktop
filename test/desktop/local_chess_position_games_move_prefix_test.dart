import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess, NormalMove;
import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';

// Regression coverage for the PM report: the opening-explorer games list showed
// "No Games Found" for every non-root position on a Local/Combined source, even
// though the move-statistics tree still rendered.
//
// Cause: large local databases (above the position-game-ref limit) skip the
// per-position index and serve the games list through the move-prefix fallback
// (`_localPositionGamesResponseFromMovePrefix`), which matches the board's UCI
// prefix against each game's `moves` column. The streaming importer stored an
// empty `moves` array, so the fallback matched nothing past the root (empty
// prefix) position.
const String _divergingPgn = '''
[Event "Najdorf"]
[Site "?"]
[Date "2026.01.01"]
[White "Durarbayli"]
[Black "Opp A"]
[Result "1-0"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 1-0

[Event "Closed Sicilian"]
[Site "?"]
[Date "2026.01.02"]
[White "Opp B"]
[Black "Durarbayli"]
[Result "0-1"]

1. e4 c5 2. Nc3 Nc6 3. g3 g6 0-1

[Event "Queens Pawn"]
[Site "?"]
[Date "2026.01.03"]
[White "Durarbayli"]
[Black "Opp C"]
[Result "1/2-1/2"]

1. d4 Nf6 2. c4 e6 3. Nf3 b6 1/2-1/2
''';

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS c FROM $table');
  return (rows.single['c'] as num).toInt();
}

void main() {
  late resqlite.Database db;
  late Directory temp;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-move-prefix-');
    db = await resqlite.Database.open('${temp.path}/local_chess.db');
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('PRAGMA journal_mode=WAL');
    await createLocalChessResqliteDatabaseSchema(db);
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<int?> gamesAt(
    LocalChessDatabaseRepository repo,
    String path,
    String fen,
    List<String> moves,
  ) async {
    final response = await repo.localPositionGamesResponse(
      databasePath: path,
      fen: fen,
      moves: moves,
      sortBy: GamebaseSortField.date,
      sortDirection: GamebaseSortDirection.asc,
      pageNumber: 0,
      pageSize: 25,
    );
    return response?.metadata.totalCount;
  }

  test(
    'streaming import populates moves so the move-prefix fallback filters '
    'games at non-root positions',
    () async {
      final pgnFile = File('${temp.path}/combined.pgn');
      await pgnFile.writeAsString(_divergingPgn);
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.importSingleFileSource(path: pgnFile.path);

      // The importer alone does not build the per-position index, so the games
      // list is served entirely by the move-prefix fallback here. This mirrors
      // the state of a large Combined database whose per-position refs were
      // intentionally skipped.
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(await _count(db, 'local_chess_games'), 3);

      // The moves column must carry the UCI line (previously stored as `[]`).
      final movesRows = await db.select(
        'SELECT moves, ply_count FROM local_chess_games ORDER BY date',
      );
      for (final row in movesRows) {
        final line = (jsonDecode(row['moves'] as String) as List);
        expect(line, isNotEmpty, reason: 'moves column must be populated');
        expect(row['ply_count'], line.length);
      }

      final rootFen = Chess.initial.fen;
      final afterE4c5 = Chess.initial
          .play(NormalMove.fromUci('e2e4'))
          .play(NormalMove.fromUci('c7c5'))
          .fen;
      final afterE4c5Nf3 = Chess.initial
          .play(NormalMove.fromUci('e2e4'))
          .play(NormalMove.fromUci('c7c5'))
          .play(NormalMove.fromUci('g1f3'))
          .fen;
      final afterD4 = Chess.initial.play(NormalMove.fromUci('d2d4')).fen;

      // Root: all three games pass through the initial position.
      expect(await gamesAt(repo, pgnFile.path, rootFen, const <String>[]), 3);

      // After 1.e4 c5 the two Sicilians match; the 1.d4 game must not.
      expect(
        await gamesAt(
          repo,
          pgnFile.path,
          afterE4c5,
          const <String>['e2e4', 'c7c5'],
        ),
        2,
      );

      // After 1.e4 c5 2.Nf3 only the Najdorf remains.
      expect(
        await gamesAt(
          repo,
          pgnFile.path,
          afterE4c5Nf3,
          const <String>['e2e4', 'c7c5', 'g1f3'],
        ),
        1,
      );

      // After 1.d4 only the Queen's Pawn game matches.
      expect(
        await gamesAt(
          repo,
          pgnFile.path,
          afterD4,
          const <String>['d2d4'],
        ),
        1,
      );
    },
  );
}
