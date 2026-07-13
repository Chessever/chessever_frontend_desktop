import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'clearing an imported quality NAG preserves prose and unrelated metadata',
    () {
      final move = ChessMove(
        num: 1,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        san: 'e4',
        uci: 'e2e4',
        turn: ChessColor.white,
        nags: const <int>[2, 18, 146],
        comments: const <String>[
          'Keep this prose [%c_effect b4;square;b4;type;Mistake;persistent;true] after it.',
          '[%clk 0:01:20][%c_effect c3;square;c3;type;Inaccuracy;persistent;true][%c_effect d4;square;d4;type;Book;persistent;true]',
        ],
      );

      final cleared = clearImportedMoveQualityAnnotation(move);

      expect(cleared.nags, const <int>[18, 146]);
      expect(cleared.comments, const <String>[
        'Keep this prose after it.',
        '[%clk 0:01:20][%c_effect c3;square;c3;type;Inaccuracy;persistent;true][%c_effect d4;square;d4;type;Book;persistent;true]',
      ]);
    },
  );
}
