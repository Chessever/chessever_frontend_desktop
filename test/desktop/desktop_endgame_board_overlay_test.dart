import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_endgame_board_overlay.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  testWidgets(
    'finished previews do not start animation tickers on scroll mount',
    (tester) async {
      for (final status in [GameStatus.blackWins, GameStatus.draw]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: DesktopEndgameBoard(
                key: ValueKey(status),
                size: 208,
                fen: '4R3/3q2pk/8/6Bp/5P1P/1r2N1K1/8/8 w - - 0 1',
                orientation: Side.white,
                status: status,
                settings: const BoardSettingsNew(),
              ),
            ),
          ),
        );
        expect(tester.binding.transientCallbackCount, 0);
        if (status == GameStatus.draw) {
          expect(find.text('🕊️'), findsNWidgets(2));
        }
      }
    },
  );
  // Regression for the browser report where losing kings vanished from
  // finished mini-boards: the king used to be stripped from the FEN and
  // redrawn by a separate Image overlay, so a failed overlay paint left an
  // empty red square. It must now stay in the position and be tilted by the
  // board's own cached piece painter.
  const fen = '4R3/3q2pk/8/6Bp/5P1P/1r2N1K1/8/8 w - - 0 1';
  const cornerFen = 'k7/8/8/8/8/8/8/7K w - - 0 1';
  for (final (positionFen, status, loserSquare) in [
    (fen, GameStatus.whiteWins, Square.h7),
    (fen, GameStatus.blackWins, Square.g3),
    (cornerFen, GameStatus.whiteWins, Square.a8),
    (cornerFen, GameStatus.blackWins, Square.h1),
  ]) {
    for (final orientation in Side.values) {
      testWidgets('losing king stays painted once and tilted: '
          '$positionFen ${status.name} ${orientation.name}', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: DesktopEndgameBoard(
                size: 208,
                fen: positionFen,
                orientation: orientation,
                status: status,
                settings: const BoardSettingsNew(),
              ),
            ),
          ),
        );

        final board = tester.widget<cg.StaticChessboard>(
          find.byType(cg.StaticChessboard),
        );
        final kings = <Square, Side>{
          for (final (square, piece) in Setup.parseFen(board.fen).board.pieces)
            if (piece.role == Role.king) square: piece.color,
        };
        final loserColor =
            status == GameStatus.whiteWins ? Side.black : Side.white;
        expect(board.fen, positionFen, reason: 'canonical FEN, both kings');
        expect(kings.length, 2);
        expect(kings[loserSquare], loserColor);
        expect(board.pieceRotations, {loserSquare: closeTo(-0.785398, 1e-6)});
        expect(board.squareHighlights.keys, [loserSquare]);
        expect(
          board.squareHighlights[loserSquare]!.details.solidColor,
          const Color(0xCCF53236),
        );
        // No separate king sprite that could fail to paint on its own.
        expect(find.byType(Image), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
      });
    }
  }

  testWidgets('draws and ongoing games keep upright kings', (tester) async {
    for (final status in [GameStatus.draw, GameStatus.ongoing]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: DesktopEndgameBoard(
              key: ValueKey(status),
              size: 208,
              fen: fen,
              orientation: Side.white,
              status: status,
              settings: const BoardSettingsNew(),
            ),
          ),
        ),
      );
      final board = tester.widget<cg.StaticChessboard>(
        find.byType(cg.StaticChessboard),
      );
      expect(board.fen, fen);
      expect(board.pieceRotations, isEmpty);
      expect(board.squareHighlights, isEmpty);
    }
  });
}
