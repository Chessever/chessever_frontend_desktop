import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_metrics.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders inside raw desktop overlays without a Material ancestor',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: const [
            DefaultMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder:
                      (_) => DesktopSearchField(
                        controller: controller,
                        hintText: 'Search username',
                        onChanged: (_) {},
                      ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'hikaru');
      expect(controller.text, 'hikaru');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Games toolbar controls share one 36px height', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var filtersPressed = 0;
    var clearPressed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: Row(
              children: [
                Expanded(
                  child: DesktopSearchField(
                    key: const ValueKey<String>('toolbar-search'),
                    controller: controller,
                    onChanged: (_) {},
                  ),
                ),
                const SizedBox(width: 8),
                DesktopGameFilterButton(
                  key: const ValueKey<String>('toolbar-filters'),
                  filter: GameFilter(
                    result: GameResultFilter.whiteWins,
                    maxYear: DateTime.now().year,
                  ),
                  onPress: () => filtersPressed++,
                ),
                const SizedBox(width: 8),
                ClearDesktopGameFiltersButton(
                  key: const ValueKey<String>('toolbar-clear'),
                  onPress: () => clearPressed++,
                ),
                const SizedBox(width: 8),
                const DesktopToolbarCountPill(
                  key: ValueKey<String>('toolbar-count'),
                  label: '200 / 649 loaded',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    for (final key in const <String>[
      'toolbar-search',
      'toolbar-filters',
      'toolbar-clear',
      'toolbar-count',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey<String>(key))).height,
        desktopToolbarControlHeight,
        reason: key,
      );
    }

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('toolbar-count')),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('toolbar-filters')));
    await tester.tap(find.byKey(const ValueKey<String>('toolbar-clear')));
    expect(filtersPressed, 1);
    expect(clearPressed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
