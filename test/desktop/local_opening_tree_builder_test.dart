import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
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

    test('incremental builder can spill position refs outside its index', () {
      final refs = <LocalOpeningTreePositionGameRef>[];
      final builder = LocalOpeningTreeIncrementalBuilder(
        treeId: 'local:spilled-refs',
        databaseId: 'local-db',
        includePositionGameRefs: false,
        includeGameRows: false,
        onPositionGameRef: refs.add,
      );
      builder.addGames(<LocalOpeningTreeGameInput>[
        _input('a', _spanishPgn, 0),
        _input('b', _sicilianPgn, 1),
      ]);

      final result = builder.finishAndRelease();
      final rootRefs = refs
          .where((ref) => ref.ply == 0)
          .toList(growable: false);

      expect(result.index.isUsable, isTrue);
      expect(result.index.gamesByFen, isEmpty);
      expect(result.index.gameRowsById, isEmpty);
      expect(rootRefs.map((ref) => ref.gameId), <String>['a', 'b']);
      expect(rootRefs.map((ref) => ref.nextUci), everyElement('e2e4'));
      expect(refs.where((ref) => ref.gameId == 'a').last.nextUci, isNull);
    });

    test(
      'games index compaction preserves local PGN source metadata',
      () async {
        final gamesIndex = await buildPlayerOpeningGamesIndexBatchAsync(
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'persisted-local',
              'pgn': _spanishPgn,
              'sourcePath': '/tmp/lines.pgn',
              'sourceRelativePath': 'lines.pgn',
              'fileName': 'lines.pgn',
              'indexInFile': 4,
              'fileGameCount': 9,
              'headers': const <String, String>{'WhiteTitle': 'GM'},
              'metadata': const <String, String>{'WhiteFed': 'NOR'},
            },
          ],
        );

        final row = gamesIndex.gameRowsById['persisted-local'];

        expect(row, isNotNull);
        expect(row!['pgn'], contains('[Event "Fast tree"]'));
        expect(row['sourcePath'], '/tmp/lines.pgn');
        expect(row['sourceRelativePath'], 'lines.pgn');
        expect(row['fileName'], 'lines.pgn');
        expect(row['indexInFile'], 4);
        expect(row['fileGameCount'], 9);
        expect(row['headers'], containsPair('WhiteTitle', 'GM'));
        expect(row['metadata'], containsPair('WhiteFed', 'NOR'));
      },
    );

    test('builder tokenizes mainline PGN without building a full PGN AST', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('annotated', _annotatedMainlinePgn, 0),
        ],
      );
      final row = index.gameRowsById['annotated'];
      final afterE4 =
          ChessGame.fromPgn('annotated', _annotatedMainlinePgn).mainline[0].fen;
      final afterNc6 =
          ChessGame.fromPgn('annotated', _annotatedMainlinePgn).mainline[3].fen;

      expect(row, isNotNull);
      expect(row!['line'], <String>[
        'e2e4',
        'e7e5',
        'g1f3',
        'b8c6',
        'f1b5',
        'a7a6',
      ]);
      expect(_move(index.movesForFen(afterE4), 'e7e5').total, 1);
      expect(_move(index.movesForFen(afterNc6), 'f1b5').total, 1);
      expect(index.gameRowsById, hasLength(1));
    });

    test(
      'unknown results are counted in the draw bucket like En Croissant',
      () {
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
        expect(row!['pgn'], isNull);
        expect(row['pgnHash'], isNotEmpty);
        expect(row['result'], '*');
      },
    );

    test('merges legal transpositions with identical four-field FEN', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('a', _knightsFirstTranspositionPgn, 0),
          _input('b', _pawnsFirstTranspositionPgn, 1),
        ],
      );
      final knightsFirstFen =
          ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).mainline[3].fen;
      final pawnsFirstFen =
          ChessGame.fromPgn('b', _pawnsFirstTranspositionPgn).mainline[3].fen;
      final rootMoves = index.movesForFen(
        ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).startingFen,
      );
      final transposedKey = playerOpeningTreeFenKey(knightsFirstFen);

      expect(_move(rootMoves, 'g1f3').total, 1);
      expect(_move(rootMoves, 'c2c4').total, 1);
      expect(transposedKey.split(' '), hasLength(4));
      expect(playerOpeningTreeFenKey(pawnsFirstFen), transposedKey);
      expect(index.nodesByFenKey.containsKey(transposedKey), isTrue);
      expect(index.gamesCountForFen(knightsFirstFen), 2);
    });

    test('cached UCI lines preserve transpositions without reparsing PGN', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:cached-uci',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _cachedInput(
            'a',
            const <String>['g1f3', 'g8f6', 'c2c4', 'e7e6'],
            0,
            result: '1-0',
          ),
          _cachedInput(
            'b',
            const <String>['c2c4', 'e7e6', 'g1f3', 'g8f6'],
            1,
            result: '0-1',
          ),
        ],
      );
      final transposedFen =
          ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).mainline[3].fen;
      final initialFen =
          ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).startingFen;

      expect(index.gamesCountForFen(transposedFen), 2);
      expect(
        index.nodesByFenKey,
        contains(playerOpeningTreeFenKey(transposedFen)),
      );
      expect(_move(index.movesForFen(initialFen), 'g1f3').white, 1);
      expect(_move(index.movesForFen(initialFen), 'c2c4').black, 1);
    });

    test(
      'cached UCI transitions preserve castling en-passant and promotion',
      () {
        const castlePgn = '''
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Be2 Nf6 4. O-O Be7 5. d3 O-O *
''';
        const enPassantPgn = '''
[Result "*"]

1. e4 a6 2. e5 d5 3. exd6 *
''';
        const promotionPgn = '''
[Result "*"]
[SetUp "1"]
[FEN "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"]

1. a8=Q+ *
''';
        final promotionStart =
            ChessGame.fromPgn('promotion', promotionPgn).startingFen;
        final index = buildLocalOpeningTreeIndex(
          treeId: 'local:cached-special-moves',
          databaseId: 'local-db',
          games: <LocalOpeningTreeGameInput>[
            _cachedInput('castle', const <String>[
              'e2e4',
              'e7e5',
              'g1f3',
              'b8c6',
              'f1e2',
              'g8f6',
              'e1h1',
              'f8e7',
              'd2d3',
              'e8h8',
            ], 0),
            _cachedInput('ep', const <String>[
              'e2e4',
              'a7a6',
              'e4e5',
              'd7d5',
              'e5d6',
            ], 1),
            _cachedInput(
              'promotion',
              const <String>['a7a8q'],
              2,
              startingFen: promotionStart,
            ),
          ],
        );

        for (final game in <(String, String)>[
          ('castle', castlePgn),
          ('ep', enPassantPgn),
          ('promotion', promotionPgn),
        ]) {
          final finalFen =
              ChessGame.fromPgn(game.$1, game.$2).mainline.last.fen;
          expect(
            index.nodesByFenKey,
            contains(playerOpeningTreeFenKey(finalFen)),
            reason: '${game.$1} should match dartchess position identity',
          );
          expect(index.gamesCountForFen(finalFen), 1);
        }
      },
    );

    test('separates castling-right positions and their supporting games', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('castle-all', _allCastlingRightsPgn, 0),
          _input('castle-reduced', _reducedCastlingRightsPgn, 1),
        ],
      );
      final allRightsFen =
          ChessGame.fromPgn('castle-all', _allCastlingRightsPgn).startingFen;
      final reducedRightsFen =
          ChessGame.fromPgn(
            'castle-reduced',
            _reducedCastlingRightsPgn,
          ).startingFen;
      final allFields = allRightsFen.split(' ');
      final reducedFields = reducedRightsFen.split(' ');

      expect(allFields.take(2), reducedFields.take(2));
      expect(allFields[2], 'KQkq');
      expect(reducedFields[2], 'Qkq');
      expect(
        playerOpeningTreeFenKey(allRightsFen),
        isNot(playerOpeningTreeFenKey(reducedRightsFen)),
      );
      expect(_move(index.movesForFen(allRightsFen), 'g1f3').total, 1);
      expect(
        index.movesForFen(allRightsFen).map((move) => move.uci),
        isNot(contains('b1c3')),
      );
      expect(_move(index.movesForFen(reducedRightsFen), 'b1c3').total, 1);
      expect(
        index.movesForFen(reducedRightsFen).map((move) => move.uci),
        isNot(contains('g1f3')),
      );
      expect(_gameIdsForFen(index, allRightsFen), <String>['castle-all']);
      expect(_gameIdsForFen(index, reducedRightsFen), <String>[
        'castle-reduced',
      ]);
    });

    test('separates legal en-passant positions and their supporting games', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        games: <LocalOpeningTreeGameInput>[
          _input('ep-available', _enPassantAvailablePgn, 0),
          _input('ep-unavailable', _enPassantUnavailablePgn, 1),
        ],
      );
      final enPassantFen =
          ChessGame.fromPgn('ep-available', _enPassantAvailablePgn).startingFen;
      final noEnPassantFen =
          ChessGame.fromPgn(
            'ep-unavailable',
            _enPassantUnavailablePgn,
          ).startingFen;
      final enPassantFields = enPassantFen.split(' ');
      final noEnPassantFields = noEnPassantFen.split(' ');

      expect(enPassantFields.take(3), noEnPassantFields.take(3));
      expect(enPassantFields[3], 'd6');
      expect(noEnPassantFields[3], '-');
      expect(
        playerOpeningTreeFenKey(enPassantFen),
        isNot(playerOpeningTreeFenKey(noEnPassantFen)),
      );
      expect(_move(index.movesForFen(enPassantFen), 'e5d6').total, 1);
      expect(
        index.movesForFen(enPassantFen).map((move) => move.uci),
        isNot(contains('e5e6')),
      );
      expect(_move(index.movesForFen(noEnPassantFen), 'e5e6').total, 1);
      expect(
        index.movesForFen(noEnPassantFen).map((move) => move.uci),
        isNot(contains('e5d6')),
      );
      expect(_gameIdsForFen(index, enPassantFen), <String>['ep-available']);
      expect(_gameIdsForFen(index, noEnPassantFen), <String>['ep-unavailable']);
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
          ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).mainline[3].fen;

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

    test('memory-safe large tree omits duplicate game rows', () {
      final index = buildLocalOpeningTreeIndex(
        treeId: 'local:test',
        databaseId: 'local-db',
        includePositionGameRefs: false,
        includeGameRows: false,
        games: <LocalOpeningTreeGameInput>[
          _input('a', _knightsFirstTranspositionPgn, 0),
          _input('b', _pawnsFirstTranspositionPgn, 1),
        ],
      );
      final rootFen =
          ChessGame.fromPgn('a', _knightsFirstTranspositionPgn).startingFen;

      expect(index.downloadedGameCount, 2);
      expect(index.gameRowsById, isEmpty);
      expect(index.gamesByFen, isEmpty);
      expect(_move(index.movesForFen(rootFen), 'g1f3').total, 1);
      expect(_move(index.movesForFen(rootFen), 'c2c4').total, 1);
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

LocalOpeningTreeGameInput _cachedInput(
  String id,
  List<String> uciLine,
  int index, {
  String result = '*',
  String? startingFen,
}) {
  return LocalOpeningTreeGameInput(
    id: id,
    uciLine: uciLine,
    metadata: <String, String>{'Result': result},
    startingFen: startingFen,
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

List<String> _gameIdsForFen(PlayerOpeningTreeIndex index, String fen) {
  return index
      .gamesForFen(
        fen,
        sortBy: GamebaseSortField.id,
        sortDirection: GamebaseSortDirection.asc,
        pageNumber: 0,
        pageSize: 10,
      )
      .map((row) => row['id']! as String)
      .toList(growable: false);
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

const _annotatedMainlinePgn = '''
[Event "Annotated"]
[Site "Local"]
[Date "2024.01.04"]
[Round "4"]
[White "Annotated"]
[Black "Line"]
[Result "1-0"]

1.e4! { center [%clk 0:03:00] } 1...e5 \$1 ; line comment
( 1... c5 2. Nf3 d6 )
2.Nf3?! Nc6 3. Bb5 a6!! 1-0
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

const _allCastlingRightsPgn = '''
[Event "Castling identity"]
[Site "Local"]
[White "All rights"]
[Black "Line"]
[Result "*"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]

1. Nf3 *
''';

const _reducedCastlingRightsPgn = '''
[Event "Castling identity"]
[Site "Local"]
[White "Reduced rights"]
[Black "Line"]
[Result "*"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w Qkq - 0 1"]

1. Nc3 *
''';

const _enPassantAvailablePgn = '''
[Event "En-passant identity"]
[Site "Local"]
[White "Available"]
[Black "Line"]
[Result "*"]
[SetUp "1"]
[FEN "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"]

1. exd6 *
''';

const _enPassantUnavailablePgn = '''
[Event "En-passant identity"]
[Site "Local"]
[White "Unavailable"]
[Black "Line"]
[Result "*"]
[SetUp "1"]
[FEN "4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1"]

1. e6 *
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
