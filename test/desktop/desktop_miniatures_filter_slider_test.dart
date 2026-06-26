import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_miniatures_filter_controls.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets('miniatures rating filter is a draggable range slider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  unawaited(
                    showDesktopMiniaturesFilterDialog(
                      context: context,
                      currentFilter: MiniatureGamesFilter.defaultFilter,
                    ),
                  );
                },
                child: const Text('Open filters'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open filters'));
    await tester.pumpAndSettle();

    // Rating must be a slider again, not the raw Min/Max input fields.
    expect(find.byType(FSlider), findsOneWidget);
    expect(find.text('Min'), findsNothing);
    expect(find.text('Max'), findsNothing);

    // Date filters must be calendar pickers, not raw YYYY-MM-DD text fields.
    expect(find.byWidgetPredicate((w) => w is FDateField), findsNWidgets(2));
    expect(find.text('From YYYY-MM-DD'), findsNothing);
    expect(find.text('To YYYY-MM-DD'), findsNothing);

    final controller = tester.widget<FSlider>(find.byType(FSlider)).controller!;
    final extent = controller.selection.rawExtent.total;
    expect(extent, greaterThan(0));

    // Dragging the min thumb must not collapse the selection to zero.
    controller.slide(extent * 0.3, min: true);
    await tester.pump();
    expect(controller.selection.rawExtent.total, greaterThan(0));
    expect(controller.selection.rawOffset.min, greaterThan(0));
  });
}
