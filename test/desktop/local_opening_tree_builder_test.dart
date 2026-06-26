import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';

void main() {
  group('local opening tree builder', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_local_tree_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test(
      'scanner builds a full-depth opening tree for imported PGNs',
      () async {
        final file = File('${temp.path}/lines.pgn');
        await file.writeAsString(
          '$_spanishPgn\n\n$_sicilianPgn\n\n$_queenPawnPgn',
        );

        final source = await scanLocalChessPaths(<String>[file.path]);
        final database = source.root.files.single;
        final index = database.openingTreeIndex;

        expect(index, isNotNull);
        expect(index!.downloadedGameCount, 3);
        expect(index.positionCount, greaterThan(6));

        final rootMoves = index.movesForFen(
          ChessGame.fromPgn('seed', _spanishPgn).startingFen,
        );
        expect(_move(rootMoves, 'e2e4').total, 2);
        expect(_move(rootMoves, 'e2e4').white, 1);
        expect(_move(rootMoves, 'e2e4').black, 1);
        expect(_move(rootMoves, 'd2d4').draws, 1);

        final afterE4 =
            ChessGame.fromPgn('spanish', _spanishPgn).mainline[0].fen;
        final afterE4Moves = index.movesForFen(afterE4);
        expect(_move(afterE4Moves, 'e7e5').total, 1);
        expect(_move(afterE4Moves, 'c7c5').total, 1);

        final afterNc6 =
            ChessGame.fromPgn('spanish', _spanishPgn).mainline[3].fen;
        final deepMoves = index.movesForFen(afterNc6);
        expect(_move(deepMoves, 'f1b5').total, 1);
      },
    );

    test(
      'builder exposes position games and continuations from local PGN rows',
      () async {
        final inputs = <LocalOpeningTreeGameInput>[
          _input('a', _spanishPgn, 0),
          _input('b', _sicilianPgn, 1),
          _input('c', _queenPawnPgn, 2),
        ];

        final index = buildLocalOpeningTreeIndex(
          treeId: 'local:test',
          databaseId: 'local-db',
          games: inputs,
        );
        final afterE4 =
            ChessGame.fromPgn('spanish', _spanishPgn).mainline[0].fen;

        expect(index.gamesCountForFen(afterE4), 2);
        expect(index.gamesCountForFen(afterE4, uci: 'e7e5'), 1);

        final rows = index.gamesForFen(
          afterE4,
          uci: 'e7e5',
          sortBy: GamebaseSortField.id,
          sortDirection: GamebaseSortDirection.asc,
          pageNumber: 0,
          pageSize: 10,
        );

        expect(rows, hasLength(1));
        expect(rows.single['id'], 'a');
        expect(rows.single['white'], 'Carlsen, Magnus');
        expect(
          rows.single['continuation'],
          containsAllInOrder(<String>['e7e5', 'g1f3']),
        );
      },
    );

    test('unknown results are counted in the draw bucket like En Croissant', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('unknown', _unknownResultPgn, 0),
        ],
      );
      final rootMoves = index.movesForFen(
        ChessGame.fromPgn('unknown', _unknownResultPgn).startingFen,
      );
      final row = index.gameRowsById['unknown'];

      expect(_move(rootMoves, 'e2e4').total, 1);
      expect(_move(rootMoves, 'e2e4').white, 0);
      expect(_move(rootMoves, 'e2e4').black, 0);
      expect(_move(rootMoves, 'e2e4').draws, 1);
      expect(row, isNotNull);
      expect(row!.containsKey('pgn'), isFalse);
      expect(row['result'], '*');
    });

    test('transposes positions by board and side to move', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('a', _knightsFirstTranspositionPgn, 0),
          _input('b', _pawnsFirstTranspositionPgn, 1),
        ],
      );
      final transposedFen =
          ChessGame.fromPgn(
            'a',
            _knightsFirstTranspositionPgn,
          ).mainline[3].fen;
      final rootMoves = index.movesForFen(
        ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).startingFen,
      );

      expect(_move(rootMoves, 'g1f3').total, 1);
      expect(_move(rootMoves, 'c2c4').total, 1);
      expect(index.gamesCountForFen(transposedFen), 2);
    });

    test('large-import mode replays compact lines for position games', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        includePositionGameRefs: false,
        games: <LocalOpeningTreeGameInput>[
          _input('a', _knightsFirstTranspositionPgn, 0),
          _input('b', _pawnsFirstTranspositionPgn, 1),
        ],
      );
      final transposedFen =
          ChessGame.fromPgn(
            'a',
            _knightsFirstTranspositionPgn,
          ).mainline[3].fen;

      expect(index.gamesByFen, isEmpty);
      expect(index.gamesCountForFen(transposedFen), 2);

      final rows = index.gamesForFen(
        transposedFen,
        sortBy: GamebaseSortField.id,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(rows.map((row) => row['id']), <String>['a', 'b']);
      expect(rows.first['continuation'], isEmpty);
      expect(index.gamesCountForFen(transposedFen, uci: 'a2a3'), 0);
    });

    test('builder skips illegal SAN instead of indexing prefixes', () {
      final result = buildLocalOpeningTreeIndexWithDiagnostics(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('good', _spanishPgn, 0),
          _input('bad', _illegalSanPgn, 1),
        ],
      );
      final afterE4 = ChessGame.fromPgn('spanish', _spanishPgn).mainline[0].fen;

      expect(result.skippedGames, hasLength(1));
      expect(result.skippedGames.single.id, 'bad');
      expect(
        result.skippedGames.single.message,
        contains('Could not parse move'),
      );
      expect(result.index.downloadedGameCount, 1);
      expect(result.index.gamesCountForFen(afterE4), 1);
    });

    test('scanner reports when all PGN entries cannot be indexed', () async {
      final file = File('${temp.path}/bad-tree.pgn');
      await file.writeAsString(_illegalSanPgn);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final database = source.root.files.single;

      expect(database.status, LocalChessFileStatus.parsed);
      expect(database.games, hasLength(1));
      expect(database.openingTreeIndex, isNotNull);
      expect(database.openingTreeIndex!.downloadedGameCount, 0);
      expect(
        database.message,
        contains('Opening tree skipped all 1 invalid PGN entry'),
      );
    });
  });
}

LocalOpeningTreeGameInput _input(String id, String pgn, int index) {
  return LocalOpeningTreeGameInput(
    id: id,
    rawPgn: pgn,
    sourcePath: '/tmp/lines.pgn',
    sourceRelativePath: 'lines.pgn',
    fileName: 'lines.pgn',
    indexInFile: index,
    fileGameCount: 3,
  );
}

dynamic _move(List<dynamic> moves, String uci) {
  return moves.singleWhere((move) => move.uci == uci);
}

const _spanishPgn = '''
[Event "Fast tree"]
[Site "Local"]
[Date "2024.01.01"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2780"]
[ECO "C65"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
''';

const _sicilianPgn = '''
[Event "Fast tree"]
[Site "Local"]
[Date "2024.01.02"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Kasparov, Garry"]
[Result "0-1"]
[WhiteElo "2675"]
[BlackElo "2812"]
[ECO "B50"]

1. e4 c5 2. Nf3 d6 0-1
''';

const _queenPawnPgn = '''
[Event "Fast tree"]
[Site "Local"]
[Date "2024.01.03"]
[Round "3"]
[White "Hou, Yifan"]
[Black "Gukesh, D"]
[Result "1/2-1/2"]
[WhiteElo "2650"]
[BlackElo "2760"]
[ECO "D06"]

1. d4 d5 1/2-1/2
''';

const _unknownResultPgn = '''
[Event "Unknown result"]
[Site "Local"]
[Date "2024.01.04"]
[Round "4"]
[White "Training"]
[Black "Line"]
[Result "*"]

1. e4 e5 *
''';

const _illegalSanPgn = '''
[Event "Broken tree"]
[Site "Local"]
[Date "2024.01.04"]
[Round "4"]
[White "Broken"]
[Black "Line"]
[Result "*"]

1. e4 e5 2. e5 *
''';

const _knightsFirstTranspositionPgn = '''
[Event "Transposition"]
[Site "Local"]
[Date "2024.01.05"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. Nf3 Nf6 2. c4 e6 1-0
''';

const _pawnsFirstTranspositionPgn = '''
[Event "Transposition"]
[Site "Local"]
[Date "2024.01.06"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. c4 e6 2. Nf3 Nf6 0-1
''';
