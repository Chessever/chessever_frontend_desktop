import 'package:chessever/desktop/widgets/desktop_search_field.dart';
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
}
