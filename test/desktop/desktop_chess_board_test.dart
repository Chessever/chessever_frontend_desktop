import 'package:chessground/chessground.dart' as cg;
import 'package:chessground/src/widgets/board_painter.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';

const _boardSize = 240.0;

void main() {
  testWidgets('secondary click cancels an active piece drag', (tester) async {
    final moves = <Move>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: DesktopChessBoard(
              size: _boardSize,
              fen: kInitialFEN,
              orientation: Side.white,
              playerSide: cg.PlayerSide.white,
              sideToMove: Side.white,
              validMoves: makeLegalMoves(Chess.initial),
              onMove: (move, {viaDragAndDrop}) => moves.add(move),
            ),
          ),
        ),
      ),
    );

    final e2 = _squareOffset(tester, Square.e2);
    final e4 = _squareOffset(tester, Square.e4);
    final drag = await tester.startGesture(
      e2,
      pointer: 1,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    await drag.moveBy(const Offset(0, -4));
    await tester.pump();
    expect(_highlights(tester).interactionNotifier.selected, Square.e2);
    expect(_dragPainters(tester), hasLength(1));

    await drag.updateWithCustomEvent(
      PointerMoveEvent(
        pointer: 1,
        kind: PointerDeviceKind.mouse,
        position: e2.translate(0, -4),
        buttons: kPrimaryButton | kSecondaryButton,
      ),
    );
    await tester.pump();

    await drag.moveTo(e4);
    await drag.up();
    await tester.pump();

    expect(moves, isEmpty);
    final board = tester.widget<cg.Chessboard>(find.byType(cg.Chessboard));
    expect(
      board.controller.pieces[Square.e2],
      const Piece(color: Side.white, role: Role.pawn),
    );
    expect(_highlights(tester).interactionNotifier.selected, isNull);
    expect(_dragPainters(tester), isEmpty);
  });
}

HighlightsPainter _highlights(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<HighlightsPainter>()
        .single;

Iterable<DragPiecePainter> _dragPainters(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<DragPiecePainter>();

Offset _squareOffset(WidgetTester tester, Square square) {
  final rect = tester.getRect(find.byKey(const ValueKey('board-container')));
  final squareSize = rect.width / 8;
  return Offset(
    rect.left + (square.file * squareSize) + squareSize / 2,
    rect.top + ((7 - square.rank) * squareSize) + squareSize / 2,
  );
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew();
    state = const AsyncValue.data(settings);
    return settings;
  }
}
