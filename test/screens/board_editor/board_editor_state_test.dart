import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/board_editor/board_editor_state.dart';

void main() {
  group('BoardEditorNotifier position setup helpers', () {
    test(
      'secondary edit places the selected piece with the opposite color',
      () {
        final notifier = BoardEditorNotifier();
        notifier.selectPiece(const Piece(color: Side.white, role: Role.pawn));

        notifier.onEditedSquareWithOppositeColor(Square.e4);

        expect(
          notifier.state.pieces[Square.e4],
          const Piece(color: Side.black, role: Role.pawn),
        );
      },
    );

    test('last pawn move is converted into the FEN en passant target', () {
      final notifier = BoardEditorNotifier();
      notifier.setSideToMove(Side.white);

      notifier.setLastPawnMove('e5');

      expect(notifier.state.epSquare, Square.e6);
      expect(notifier.state.fullFen.split(' ')[3], 'e6');
    });

    test('en passant capture shorthand is converted into the FEN target', () {
      final notifier = BoardEditorNotifier();
      notifier.setSideToMove(Side.white);

      notifier.setLastPawnMove('ed');

      expect(notifier.state.epSquare, Square.d6);
      expect(notifier.state.fullFen.split(' ')[3], 'd6');
    });

    test('clearing last pawn move clears en passant target', () {
      final notifier = BoardEditorNotifier();
      notifier.setSideToMove(Side.white);
      notifier.setLastPawnMove('e5');

      notifier.setLastPawnMove('');

      expect(notifier.state.epSquare, isNull);
      expect(notifier.state.fullFen.split(' ')[3], '-');
    });

    test('move number rejects non-positive values', () {
      final notifier = BoardEditorNotifier();

      notifier.setFullmoves(12);
      notifier.setFullmoves(0);

      expect(notifier.state.fullmoves, 12);
      expect(notifier.state.fullFen.split(' ')[5], '12');
    });
  });
}
