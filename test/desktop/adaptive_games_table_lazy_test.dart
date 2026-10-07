import 'package:chessever/desktop/widgets/adaptive_games_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('row construction stays bounded as the loaded set grows', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final built = <int>{};

    Widget host(int count) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 700,
            height: 240,
            child: AdaptiveGamesTable<int>(
              rows: List<int>.generate(count, (index) => index),
              scrollController: controller,
              lazyRowExtent: 40,
              lazyColumnWidths: const {'a': 150, 'b': 150},
              columns: [
                AdaptiveColumn<int>(
                  id: 'a',
                  label: 'A',
                  cellBuilder: (_, row) {
                    built.add(row);
                    return Text('row-$row');
                  },
                ),
                AdaptiveColumn<int>(
                  id: 'b',
                  label: 'B',
                  cellBuilder: (_, row) => Text('value-$row'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(25));
    final firstPageBuilt = built.length;
    expect(firstPageBuilt, lessThan(15));
    built.clear();
    await tester.pumpWidget(host(1000));
    expect(built.length, lessThanOrEqualTo(firstPageBuilt + 1));
    expect(find.text('row-900'), findsNothing);

    controller.jumpTo(900 * 40 + 28);
    await tester.pump();
    expect(find.text('row-900'), findsOneWidget);
    expect(find.text('row-0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lazy rows share widths through resize and footer changes', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Widget host(Widget? footer) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          height: 240,
          child: AdaptiveGamesTable<int>(
            rows: const [0, 1, 2],
            scrollController: controller,
            enableColumnResizing: true,
            lazyRowExtent: 40,
            lazyColumnWidths: const {'a': 150, 'b': 150},
            footer: footer,
            columns: [
              AdaptiveColumn<int>(
                id: 'a',
                label: 'A',
                cellBuilder: (_, row) => Text('row-$row'),
              ),
              AdaptiveColumn<int>(
                id: 'b',
                label: 'B',
                cellBuilder: (_, row) => Text('value-$row'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(null));
    final original = tester.getTopLeft(find.text('value-0')).dx;
    final originalHeader = tester.getTopLeft(find.text('B')).dx;
    final handle = find.byKey(
      const ValueKey<String>('adaptive-column-resizer-a'),
    );
    await tester.drag(handle, const Offset(80, 0));
    await tester.pumpAndSettle();
    // The drag recognizer may consume its slop, so assert the shared grid
    // (header and every lazily built row moved by the same amount) rather
    // than an exact pointer delta.
    final resized = tester.getTopLeft(find.text('value-0')).dx;
    expect(resized - original, greaterThan(40));
    expect(
      tester.getTopLeft(find.text('B')).dx - originalHeader,
      closeTo(resized - original, 1),
    );
    for (var row = 0; row < 3; row++) {
      expect(
        tester.getTopLeft(find.text('value-$row')).dx,
        closeTo(resized, 1),
      );
    }
    await tester.pumpWidget(host(const SizedBox(width: 600, height: 12)));
    expect(tester.getTopLeft(find.text('value-1')).dx, closeTo(resized, 1));
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('value-1')).dx, closeTo(original, 1));
    expect(tester.takeException(), isNull);
  });
}
