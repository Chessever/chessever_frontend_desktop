import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_opening_metadata.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  test('recognizes the deepest known ECO for the current board line', () {
    final match = recognizedEcoForBoardLine(
      startingFen: Chess.initial.fen,
      movesUci: const <String>[
        'e2e4',
        'e7e5',
        'g1f3',
        'b8c6',
        'd2d4',
        'e5d4',
        'f3d4',
        'g8f6',
        'd4c6',
        'd7c6',
        'd1f3',
        'f6e4',
      ],
    );

    expect(match?.eco, 'C45');
  });

  test('adds recognized ECO only when current metadata has no real ECO', () {
    expect(
      metadataWithRecognizedBoardEco(
        metadata: const <String, dynamic>{'Event': '?', 'ECO': '?'},
        startingFen: Chess.initial.fen,
        movesUci: const <String>[
          'e2e4',
          'e7e5',
          'g1f3',
          'b8c6',
          'd2d4',
          'e5d4',
          'f3d4',
        ],
      )['ECO'],
      'C45',
    );
    expect(
      metadataWithRecognizedBoardEco(
        metadata: const <String, dynamic>{'ECO': 'B90'},
        startingFen: Chess.initial.fen,
        movesUci: const <String>['e2e4', 'e7e5'],
      )['ECO'],
      'B90',
    );
  });

  test('saved ECO uses the exported game mainline rather than a UI cursor', () {
    final game = ChessGame.fromPgn(
      'game',
      '1. e4 e5 2. Nf3 Nc6 3. d4 exd4 4. Nxd4 Nf6 5. Nxc6 dxc6 6. Qf3 Nxe4 *',
    );

    final metadata = metadataWithRecognizedBoardEco(
      metadata: game.metadata,
      startingFen: game.startingFen,
      movesUci: boardEcoMainlineUcis(game),
    );

    expect(metadata['ECO'], 'C45');
  });

  test('does not invent ECO for an unrecognized or custom-start position', () {
    expect(
      metadataWithRecognizedBoardEco(
        metadata: const <String, dynamic>{},
        startingFen: Chess.initial.fen,
        movesUci: const <String>['a2a3'],
      ).containsKey('ECO'),
      isFalse,
    );
    expect(
      recognizedEcoForBoardLine(
        startingFen: '8/8/8/8/8/8/8/K6k w - - 0 1',
        movesUci: const <String>[],
      ),
      isNull,
    );
  });
}
