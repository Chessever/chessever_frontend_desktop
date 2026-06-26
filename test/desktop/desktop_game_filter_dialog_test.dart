import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets('range sliders keep their drag extent after controlled updates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                unawaited(
                  showDesktopGameFilterDialog(
                    context: context,
                    currentFilter: GameFilter.defaultFilter(),
                  ),
                );
              },
              child: const Text('Open filters'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open filters'));
    await tester.pumpAndSettle();

    final yearSliderFinder = find.byType(FSlider).first;
    final controller = tester.widget<FSlider>(yearSliderFinder).controller!;
    final trackExtent = controller.selection.rawExtent.total;

    expect(trackExtent, greaterThan(0));

    controller.slide(trackExtent * 0.25, min: true);
    await tester.pump();

    final updatedController =
        tester.widget<FSlider>(yearSliderFinder).controller!;
    expect(updatedController.selection.rawExtent.total, greaterThan(0));
    expect(updatedController.selection.rawOffset.min, greaterThan(0));

    final firstOffset = updatedController.selection.rawOffset.min;
    updatedController.slide(trackExtent * 0.35, min: true);
    await tester.pump();

    expect(updatedController.selection.rawOffset.min, greaterThan(firstOffset));
  });
}
