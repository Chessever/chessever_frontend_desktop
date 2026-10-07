import 'package:chessever/desktop/services/position_game_notation.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'batch worker caps full games and preserves every hover position',
    () async {
      final line = [
        for (var i = 0; i < 30; i++) ...['g1f3', 'g8f6', 'f3g1', 'f6g8'],
      ];
      final batch = await preparePositionGameNotations(Chess.initial.fen, [
        line,
        ['e2e4', 'c7c5', 'g1f3'],
      ]);
      expect(batch, hasLength(2));
      final notation = batch.first;
      expect(notation.tokens, hasLength(40));
      expect(notation.positions, hasLength(41));
      expect(notation.tokens.take(4), ['1.Nf3', 'Nf6', '2.Ng1', 'Ng8']);
      for (var i = 0; i < notation.tokens.length; i++) {
        final replay = computeMovePreviewReplay(
          startingFen: Chess.initial.fen,
          movesUpToHover: line.take(i + 1).toList(),
        );
        expect(notation.positions[i], replay.preFen);
        expect(notation.positions[i + 1], replay.fen);
      }
      // Navigation retains the complete game. Formatting only depends on the
      // displayed prefix, so extending the tail cannot invalidate its cache.
      expect(notation.matches(Chess.initial.fen, line), isTrue);
      expect(
        notation.matches(Chess.initial.fen, line.take(40).toList()),
        isTrue,
      );
      expect(
        notation.matches(Chess.initial.fen, ['e2e4', ...line.skip(1)]),
        isFalse,
      );
      expect(batch.last.tokens, ['1.e4', 'c5', '2.Nf3']);
    },
  );

  test(
    'black first, invalid moves, and invalid FEN keep coherent previews',
    () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 8';
      final notation = PositionGameNotation.fromLine(fen, [
        'c7c5',
        'g1f3',
        'not-a-move',
        'd7d6',
      ]);
      expect(notation.tokens, ['8…c5', '9.Nf3']);
      expect(notation.positions, hasLength(3));
      expect(notation.positions.first, fen);

      final invalid = PositionGameNotation.fromLine('invalid', ['e2e4']);
      expect(invalid.tokens, isEmpty);
      expect(invalid.positions, ['invalid']);
      expect(positionGameSanTokens(Chess.initial.fen, ['e2e5']), isEmpty);
    },
  );
}
