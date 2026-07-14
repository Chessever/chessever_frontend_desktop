import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/adaptive_games_table.dart';

void main() {
  Widget wrap({required Widget? footer, required ScrollController controller}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 700,
            height: 400,
            child: AdaptiveGamesTable<int>(
              scrollController: controller,
              rows: const [0, 1],
              footer: footer,
              columns: [
                AdaptiveColumn<int>(
                  id: 'a',
                  label: 'A',
                  cellBuilder: (_, row) => Text('r$row-a'),
                ),
                AdaptiveColumn<int>(
                  id: 'b',
                  label: 'B',
                  cellBuilder: (_, row) => Text('r$row-b'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('wide footer does not inflate column 0 width', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(footer: null, controller: controller));
    final dxWithoutFooter = tester.getTopLeft(find.text('r0-b')).dx;

    await tester.pumpWidget(
      wrap(
        footer: const SizedBox(width: 400, height: 12),
        controller: controller,
      ),
    );
    final dxWithFooter = tester.getTopLeft(find.text('r0-b')).dx;

    // Regression: the footer used to live inside column 0, so its intrinsic
    // width (here 400) became the column width and shifted every other
    // column. The footer must not move the second column at all.
    expect(dxWithFooter, dxWithoutFooter);
  });

  testWidgets('footer swap keeps columns stable and footer stays tappable', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    var taps = 0;
    await tester.pumpWidget(
      wrap(
        footer: Center(
          child: GestureDetector(
            onTap: () => taps++,
            child: const Text('Load more'),
          ),
        ),
        controller: controller,
      ),
    );
    final dxWithButton = tester.getTopLeft(find.text('r0-b')).dx;

    await tester.tap(find.text('Load more'));
    expect(taps, 1);

    // Simulate pagination flipping the footer to a narrow spinner stand-in.
    await tester.pumpWidget(
      wrap(
        footer: const Center(child: SizedBox(width: 16, height: 16)),
        controller: controller,
      ),
    );
    final dxWithSpinner = tester.getTopLeft(find.text('r0-b')).dx;

    expect(dxWithSpinner, dxWithButton);
  });

  testWidgets('header divider resizes a column and double-click resets it', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 400,
            child: AdaptiveGamesTable<int>(
              enableColumnResizing: true,
              scrollController: controller,
              rows: const [0],
              columns: [
                AdaptiveColumn<int>(
                  id: 'a',
                  label: 'A',
                  cellBuilder: (_, row) => Text('r$row-a'),
                ),
                AdaptiveColumn<int>(
                  id: 'b',
                  label: 'B',
                  cellBuilder: (_, row) => Text('r$row-b'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    const handleKey = ValueKey<String>('adaptive-column-resizer-a');
    final handle = find.byKey(handleKey);
    expect(handle, findsOneWidget);
    final initialSecondColumnX = tester.getTopLeft(find.text('r0-b')).dx;

    await tester.drag(handle, const Offset(100, 0));
    await tester.pumpAndSettle();
    final resizedSecondColumnX = tester.getTopLeft(find.text('r0-b')).dx;
    expect(resizedSecondColumnX, closeTo(initialSecondColumnX + 100, 1));

    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('r0-b')).dx,
      closeTo(initialSecondColumnX, 1),
    );
  });
}
