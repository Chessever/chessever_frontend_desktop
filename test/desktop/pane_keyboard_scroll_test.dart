import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/pane_keyboard_scroll.dart';

Widget _harness(ScrollController controller, {bool wrap = true}) {
  final list = ListView.builder(
    controller: controller,
    itemCount: 200,
    itemBuilder:
        (_, i) => SizedBox(height: 40, child: Center(child: Text('row $i'))),
  );
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        width: 400,
        child: wrap ? PaneKeyboardScroll(child: list) : list,
      ),
    ),
  );
}

Widget _indexedHarness({
  required ScrollController hiddenController,
  required ScrollController visibleController,
}) {
  Widget list(ScrollController controller, String prefix) {
    return ListView.builder(
      controller: controller,
      itemCount: 200,
      itemBuilder:
          (_, i) => SizedBox(
            height: 40,
            child: Center(child: Text('$prefix row $i')),
          ),
    );
  }

  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        width: 400,
        child: PaneKeyboardScroll(
          child: IndexedStack(
            index: 1,
            children: [
              list(hiddenController, 'hidden'),
              list(visibleController, 'visible'),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('PageDown scrolls down by ~viewport*0.9', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(400));
    expect(controller.offset, lessThan(600));
  });

  testWidgets('PageUp scrolls up after PageDown', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    final downOffset = controller.offset;
    expect(downOffset, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();

    expect(controller.offset, lessThan(downOffset));
    expect(controller.offset, 0);
  });

  testWidgets('End jumps to max, Home returns to 0', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();

    final max = controller.position.maxScrollExtent;
    expect(controller.offset, max);
    expect(max, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
  });

  testWidgets('without PaneKeyboardScroll wrap, PageDown is a no-op', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(_harness(controller, wrap: false));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
  });

  testWidgets('PageDown skips hidden IndexedStack scrollables', (tester) async {
    final hiddenController = ScrollController();
    final visibleController = ScrollController();
    await tester.pumpWidget(
      _indexedHarness(
        hiddenController: hiddenController,
        visibleController: visibleController,
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();

    expect(hiddenController.offset, 0);
    expect(visibleController.offset, greaterThan(400));
  });

  testWidgets('arrow keys are passed through (not intercepted)', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    final before = controller.offset;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(controller.offset, before);
  });
}
