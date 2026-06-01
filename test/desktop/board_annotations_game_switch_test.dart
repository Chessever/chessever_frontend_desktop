import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('clear() wipes user-drawn arrows', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const tabId = 'tab-1';
    final notifier = container.read(
      boardAnnotationsProvider(tabId).notifier,
    );

    notifier.toggleArrow(Square.e2, Square.e4, AnnotationColor.green);
    notifier.toggleArrow(Square.d7, Square.d5, AnnotationColor.red);
    expect(
      container.read(boardAnnotationsProvider(tabId)).shapes.length,
      2,
      reason: 'precondition: two arrows drawn',
    );

    notifier.clear();

    expect(
      container.read(boardAnnotationsProvider(tabId)).shapes,
      isEmpty,
      reason: 'clear() must empty user-drawn shape set',
    );
  });

  test('annotation state is isolated per tabId', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(boardAnnotationsProvider('tab-A').notifier)
        .toggleArrow(Square.e2, Square.e4, AnnotationColor.green);
    container
        .read(boardAnnotationsProvider('tab-B').notifier)
        .toggleArrow(Square.g1, Square.f3, AnnotationColor.blue);

    expect(container.read(boardAnnotationsProvider('tab-A')).shapes, hasLength(1));
    expect(container.read(boardAnnotationsProvider('tab-B')).shapes, hasLength(1));

    container.read(boardAnnotationsProvider('tab-A').notifier).clear();

    expect(container.read(boardAnnotationsProvider('tab-A')).shapes, isEmpty);
    expect(
      container.read(boardAnnotationsProvider('tab-B')).shapes,
      hasLength(1),
      reason: 'clearing one tab must not touch another tab',
    );
  });

  test('restore replaces shape set wholesale', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const tabId = 'tab-restore';
    final notifier = container.read(
      boardAnnotationsProvider(tabId).notifier,
    );

    notifier.toggleArrow(Square.e2, Square.e4, AnnotationColor.green);
    notifier.restore(const <cg.Shape>{});
    expect(container.read(boardAnnotationsProvider(tabId)).shapes, isEmpty);

    final restored = <cg.Shape>{
      cg.Arrow(
        color: const Color(0xCCB72217),
        orig: Square.a1,
        dest: Square.h8,
      ),
    };
    notifier.restore(restored);
    expect(
      container.read(boardAnnotationsProvider(tabId)).shapes,
      hasLength(1),
    );
  });
}
