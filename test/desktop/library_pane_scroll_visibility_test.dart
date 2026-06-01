import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression test for the library list scroll behavior. The previous helper
// always animated the selected row to the top of the viewport using inflated
// per-row extents, which pushed the selected row off-screen after a few arrow
// presses. The current helper must (a) leave scroll untouched when the row
// is already visible, and (b) bring the row into view with the minimum scroll
// needed when it has fallen out.

void main() {
  Future<ScrollController> pumpFixedList(
    WidgetTester tester, {
    required int itemCount,
    required double rowExtent,
    double viewportHeight = 400,
  }) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              width: 300,
              child: ListView.builder(
                controller: controller,
                itemExtent: rowExtent,
                itemCount: itemCount,
                itemBuilder: (context, index) => Container(
                  color: Colors.grey,
                  child: Text('row $index'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> settle(WidgetTester tester) async {
    // The helper animates over 120 ms; advance well past that.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'does not move the viewport when the selected row is already visible',
    (tester) async {
      const rowExtent = 44.0;
      final controller = await pumpFixedList(
        tester,
        itemCount: 200,
        rowExtent: rowExtent,
      );

      // Step from index 0 down — first ~8 rows fit a 400 px viewport, so the
      // helper should leave scroll at 0.
      for (var i = 0; i < 8; i++) {
        debugScrollLibraryListToIndex(controller, i, rowExtent);
        await settle(tester);
        expect(
          controller.position.pixels,
          0.0,
          reason: 'row $i is in view; scroll should not move',
        );
      }
    },
  );

  testWidgets(
    'scrolls only enough to reveal the selected row going down',
    (tester) async {
      const rowExtent = 44.0;
      const viewport = 400.0;
      final controller = await pumpFixedList(
        tester,
        itemCount: 200,
        rowExtent: rowExtent,
        viewportHeight: viewport,
      );

      // Walk down through rows; selected row must always sit inside the
      // current viewport after the helper resolves.
      for (var i = 0; i < 80; i++) {
        debugScrollLibraryListToIndex(controller, i, rowExtent);
        await settle(tester);
        final pixels = controller.position.pixels;
        final rowTop = i * rowExtent;
        final rowBottom = rowTop + rowExtent;
        expect(
          rowTop >= pixels - 0.5 && rowBottom <= pixels + viewport + 0.5,
          isTrue,
          reason:
              'row $i (top=$rowTop bottom=$rowBottom) fell outside viewport '
              '[$pixels, ${pixels + viewport}]',
        );
      }
    },
  );

  testWidgets(
    'scrolls only enough to reveal the selected row going up',
    (tester) async {
      const rowExtent = 44.0;
      const viewport = 400.0;
      final controller = await pumpFixedList(
        tester,
        itemCount: 200,
        rowExtent: rowExtent,
        viewportHeight: viewport,
      );

      // Jump to the end, then walk back up.
      debugScrollLibraryListToIndex(controller, 199, rowExtent);
      await settle(tester);

      for (var i = 199; i >= 0; i--) {
        debugScrollLibraryListToIndex(controller, i, rowExtent);
        await settle(tester);
        final pixels = controller.position.pixels;
        final rowTop = i * rowExtent;
        final rowBottom = rowTop + rowExtent;
        expect(
          rowTop >= pixels - 0.5 && rowBottom <= pixels + viewport + 0.5,
          isTrue,
          reason:
              'row $i (top=$rowTop bottom=$rowBottom) fell outside viewport '
              '[$pixels, ${pixels + viewport}] while walking up',
        );
      }
    },
  );

  testWidgets('row extent constants stay in lockstep with the lists', (
    tester,
  ) async {
    // The lists in library_pane.dart pin row heights to these constants via
    // ListView.itemExtent / SizedBox. If anyone tweaks one without the other
    // the scroll math drifts and selected rows fall off screen again.
    expect(debugLibrarySavedRowExtent, 44.0);
    expect(debugLibraryTwicRowExtent, 44.0);
    expect(debugLibraryLocalRowExtent, 40.0);
  });
}
