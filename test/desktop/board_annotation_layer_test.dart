import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/widgets/board_annotation_layer.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _boardSize = 240.0;
const _defaultTabId = 'tournaments-default';
const _boardKey = ValueKey<String>('annotation-board');

void main() {
  testWidgets('plain secondary drag draws a green arrow', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(_squareOffset(tester, Square.e2));
    await tester.pump();
    await gesture.moveTo(_squareOffset(tester, Square.e4));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final shapes =
        container.read(boardAnnotationsProvider(_defaultTabId)).shapes;
    expect(shapes, hasLength(1));
    final arrow = shapes.single as cg.Arrow;
    expect(arrow.orig, Square.e2);
    expect(arrow.dest, Square.e4);
    expect(arrow.color, AnnotationColor.green.color);
  });

  testWidgets('plain secondary tap stays available for the context menu', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);

    await tester.tapAt(
      _squareOffset(tester, Square.e2),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    expect(
      container.read(boardAnnotationsProvider(_defaultTabId)).shapes,
      isEmpty,
    );
  });

  testWidgets('modifier secondary tap toggles a colored circle', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.tapAt(
        _squareOffset(tester, Square.e2),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    final shapes =
        container.read(boardAnnotationsProvider(_defaultTabId)).shapes;
    expect(shapes, hasLength(1));
    final circle = shapes.single as cg.Circle;
    expect(circle.orig, Square.e2);
    expect(circle.color, AnnotationColor.yellow.color);
  });
}

Future<void> _pumpBoard(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.square(
              key: _boardKey,
              dimension: _boardSize,
              child: BoardAnnotationLayer(
                tabId: _defaultTabId,
                size: _boardSize,
                orientation: Side.white,
                child: ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Offset _squareOffset(WidgetTester tester, Square square) {
  final topLeft = tester.getTopLeft(find.byKey(_boardKey));
  final squareSize = _boardSize / 8;
  return topLeft +
      Offset(
        (square.file * squareSize) + squareSize / 2,
        ((7 - square.rank) * squareSize) + squareSize / 2,
      );
}
