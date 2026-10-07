import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/adaptive_games_table.dart';

void main() {
  Widget table({
    required ValueNotifier<double> width,
    required ScrollController controller,
    required VoidCallback onCellBuild,
    ScrollController? horizontalController,
    double? minTableWidth,
  }) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<double>(
        valueListenable: width,
        builder:
            (_, value, child) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: value, height: 400, child: child),
            ),
        child: AdaptiveGamesTable<int>(
          scrollController: controller,
          horizontalScrollController: horizontalController,
          minTableWidth: minTableWidth,
          rows: List<int>.generate(40, (i) => i),
          columns: [
            for (final id in ['a', 'b', 'c'])
              AdaptiveColumn<int>(
                id: id,
                label: id.toUpperCase(),
                cellBuilder: (_, row) {
                  onCellBuild();
                  return Text('r$row-$id');
                },
              ),
          ],
        ),
      ),
    ),
  );

  testWidgets('resizing re-lays out rows without rebuilding them', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final width = ValueNotifier<double>(900);
    var cellBuilds = 0;
    await tester.pumpWidget(
      table(
        width: width,
        controller: controller,
        onCellBuild: () => cellBuilds++,
      ),
    );
    expect(cellBuilds, greaterThan(0));
    cellBuilds = 0;

    for (final next in [920.0, 960.0, 1000.0, 1100.0]) {
      width.value = next;
      await tester.pump();
    }
    expect(cellBuilds, 0);
    expect(tester.getSize(find.byType(AdaptiveGamesTable<int>)).width, 1100);
  });

  testWidgets('the fallback horizontal controller survives resizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final width = ValueNotifier<double>(600);
    await tester.pumpWidget(
      table(
        width: width,
        controller: controller,
        onCellBuild: () {},
        minTableWidth: 1200,
      ),
    );
    final horizontal =
        tester
            .widget<SingleChildScrollView>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is SingleChildScrollView &&
                    widget.scrollDirection == Axis.horizontal,
              ),
            )
            .controller!;
    horizontal.jumpTo(200);
    await tester.pump();

    width.value = 640;
    await tester.pump();
    final after =
        tester
            .widget<SingleChildScrollView>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is SingleChildScrollView &&
                    widget.scrollDirection == Axis.horizontal,
              ),
            )
            .controller!;
    expect(after, same(horizontal));
    expect(after.offset, 200);
  });
}
