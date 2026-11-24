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
  testWidgets('rapid replay keeps each piece on its own animation path', (
    tester,
  ) async {
    Position position = Chess.initial;
    Move? lastMove;

    Future<void> pumpBoard() => tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: DesktopChessBoard(
              size: _boardSize,
              fen: position.fen,
              orientation: Side.white,
              playerSide: cg.PlayerSide.both,
              sideToMove: position.turn,
              validMoves: makeLegalMoves(position),
              lastMove: lastMove,
              onMove: (_, {viaDragAndDrop}) {},
            ),
          ),
        ),
      ),
    );

    await pumpBoard();
    for (final san in ['Nf3', 'd5', 'Rg1']) {
      lastMove = position.parseSan(san)!;
      position = position.play(lastMove);
      await pumpBoard();
      await tester.pump(const Duration(milliseconds: 32));
    }

    final knightOrigin =
        _translations(tester).translationOrigins!.value[Square.f3]!;

    // The white rook is sliding into g1, the white knight's original square.
    // A black move must continue both animations from their own positions.
    lastMove = position.parseSan('Nf6')!;
    position = position.play(lastMove);
    await pumpBoard();

    final board = tester.widget<cg.Chessboard>(find.byType(cg.Chessboard));
    expect(board.controller.pieces, cg.readFen(position.fen));
    final painter = _translations(tester);
    expect(painter.translatingPieces[Square.f3]?.piece, Piece.whiteKnight);
    final newOrigin = painter.translationOrigins!.value[Square.f3]!;
    expect(newOrigin.dx, inExclusiveRange(Square.f3.file, knightOrigin.dx));
    expect(newOrigin.dy, inExclusiveRange(knightOrigin.dy, Square.f3.rank));
    await tester.pumpAndSettle();
    expect(_translations(tester).translatingPieces, isEmpty);
  });

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

TranslatingPiecesPainter _translations(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<TranslatingPiecesPainter>()
        .single;

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
