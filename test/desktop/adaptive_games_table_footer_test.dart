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
}
