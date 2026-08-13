import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_endgame_board_overlay.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  testWidgets('fallen king keeps the same square footprint as board pieces', (
    tester,
  ) async {
    const boardSize = 208.0;
    const squareSize = boardSize / 8;

    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: DesktopEndgameBoard(
            size: boardSize,
            fen: '4R3/3q2pk/8/6Bp/5P1P/1r2N1K1/8/8 w - - 0 1',
            orientation: Side.white,
            status: GameStatus.blackWins,
            settings: BoardSettingsNew(),
          ),
        ),
      ),
    );

    final fallenKingFinder = find.byType(Image);
    expect(fallenKingFinder, findsOneWidget);
    final fallenKing = tester.widget<Image>(fallenKingFinder);

    expect(fallenKing.width, squareSize);
    expect(fallenKing.height, squareSize);
  });
}
