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
    Set<cg.Shape>? persistedShapes;
    addTearDown(container.dispose);
    await _pumpBoard(
      tester,
      container,
      onShapesChanged: (shapes) => persistedShapes = shapes,
    );

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

    final annotations = container.read(boardAnnotationsProvider(_defaultTabId));
    final shapes = annotations.shapes;
    expect(shapes, hasLength(1));
    expect(annotations.shapesForPosition('start w KQkq -'), hasLength(1));
    expect(annotations.shapesForPosition('other w KQkq -'), isEmpty);
    final arrow = shapes.single as cg.Arrow;
    expect(arrow.orig, Square.e2);
    expect(arrow.dest, Square.e4);
    expect(arrow.color, AnnotationColor.green.color);
    expect(persistedShapes, isNotNull);
    expect(persistedShapes, hasLength(1));
    expect(persistedShapes!.single, isA<cg.Arrow>());
  });

  testWidgets('plain secondary tap toggles a green circle', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);

    await tester.tapAt(
      _squareOffset(tester, Square.e2),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    final shapes =
        container.read(boardAnnotationsProvider(_defaultTabId)).shapes;
    expect(shapes, hasLength(1));
    final circle = shapes.single as cg.Circle;
    expect(circle.orig, Square.e2);
    expect(circle.color, AnnotationColor.green.color);
  });

  testWidgets('shift secondary tap toggles a colored circle', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await tester.tapAt(
        _squareOffset(tester, Square.e2),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }

    final shapes =
        container.read(boardAnnotationsProvider(_defaultTabId)).shapes;
    expect(shapes, hasLength(1));
    final circle = shapes.single as cg.Circle;
    expect(circle.orig, Square.e2);
    expect(circle.color, AnnotationColor.red.color);
  });

  for (final (label, keys, expectedColor) in [
    ('Ctrl', [LogicalKeyboardKey.controlLeft], AnnotationColor.red),
    ('Cmd', [LogicalKeyboardKey.metaRight], AnnotationColor.blue),
    ('Alt', [LogicalKeyboardKey.altLeft], AnnotationColor.blue),
    (
      'Ctrl+Alt',
      [LogicalKeyboardKey.controlRight, LogicalKeyboardKey.altRight],
      AnnotationColor.yellow,
    ),
    (
      'Shift+Cmd',
      [LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.metaLeft],
      AnnotationColor.yellow,
    ),
  ]) {
    testWidgets('$label secondary drag draws a ${expectedColor.name} arrow', (
      tester,
    ) async {
      final container = ProviderContainer();
      Set<cg.Shape>? persistedShapes;
      addTearDown(container.dispose);
      await _pumpBoard(
        tester,
        container,
        onShapesChanged: (shapes) => persistedShapes = shapes,
      );

      for (final key in keys) {
        await tester.sendKeyDownEvent(key);
      }
      try {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.down(_squareOffset(tester, Square.e2));
        await gesture.moveTo(_squareOffset(tester, Square.e4));
        await gesture.up();
        await tester.pump();
      } finally {
        for (final key in keys.reversed) {
          await tester.sendKeyUpEvent(key);
        }
      }

      final shapes =
          container.read(boardAnnotationsProvider(_defaultTabId)).shapes;
      expect(shapes, hasLength(1));
      final arrow = shapes.single as cg.Arrow;
      expect(arrow.orig, Square.e2);
      expect(arrow.dest, Square.e4);
      expect(arrow.color, expectedColor.color);
      expect(persistedShapes, unorderedEquals(shapes));
    });
  }

  testWidgets('Ctrl secondary tap toggles a red circle', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpBoard(tester, container);
    final square = _squareOffset(tester, Square.e2);
    final annotations = boardAnnotationsProvider(_defaultTabId);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.tapAt(square, buttons: kSecondaryMouseButton);
      await tester.pump();
      final circle = container.read(annotations).shapes.single as cg.Circle;
      expect(circle.orig, Square.e2);
      expect(circle.color, AnnotationColor.red.color);
      await tester.tapAt(square, buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(container.read(annotations).shapes, isEmpty);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  });

  testWidgets('left click clears persistent PGN-backed shapes', (tester) async {
    final container = ProviderContainer();
    Set<cg.Shape>? persistedShapes;
    addTearDown(container.dispose);
    await _pumpBoard(
      tester,
      container,
      persistentShapes: <cg.Shape>[
        cg.Arrow(
          color: AnnotationColor.green.color,
          orig: Square.h1,
          dest: Square.h4,
        ),
      ],
      onShapesChanged: (shapes) => persistedShapes = shapes,
    );

    await tester.tapAt(_squareOffset(tester, Square.e2));
    await tester.pump();

    expect(persistedShapes, isEmpty);
  });
}

Future<void> _pumpBoard(
  WidgetTester tester,
  ProviderContainer container, {
  List<cg.Shape> persistentShapes = const <cg.Shape>[],
  ValueChanged<Set<cg.Shape>>? onShapesChanged,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
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
                positionKey: 'start w KQkq -',
                persistentShapes: persistentShapes,
                onShapesChanged: onShapesChanged,
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
