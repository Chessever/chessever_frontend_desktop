import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/library/twic_filter_dialog.dart';
import 'package:chessever/screens/library/widgets/library_gamebase_filter_dialog.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/widgets/game_filter/eco_filter_dropdown.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _expectNoFlutterExceptions(WidgetTester tester) {
  final errors = <Object>[];
  for (;;) {
    final error = tester.takeException();
    if (error == null) break;
    errors.add(error);
  }
  expect(errors, isEmpty, reason: 'Flutter exceptions: $errors');
}

void main() {
  testWidgets(
    'showTwicFilterDialog builds Opening and Year without a Material overlay wrapper',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return TextButton(
                onPressed: () {
                  unawaited(
                    showTwicFilterDialog(
                      context: context,
                      currentFilter: GamebaseFilter(),
                    ),
                  );
                },
                child: const Text('Open TWIC filters'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Open TWIC filters'));
      await tester.pumpAndSettle();

      expect(find.text('OPENING'), findsOneWidget);
      // Header plus the still-built (SizeTransition) list option.
      expect(find.text('All Openings'), findsAtLeastNWidgets(1));
      expect(find.text('YEAR'), findsOneWidget);
      expect(find.text('1800 – ${DateTime.now().year}'), findsOneWidget);
      expect(find.text('RATING'), findsOneWidget);
      expect(find.byType(RangeSlider), findsNWidgets(2));
      expect(find.byType(EcoFilterDropdown), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
      _expectNoFlutterExceptions(tester);
    },
  );

  testWidgets(
    'Reset stays enabled when an already-applied ECO filter is reopened',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return TextButton(
                onPressed: () {
                  unawaited(
                    showTwicFilterDialog(
                      context: context,
                      currentFilter: GamebaseFilter(
                        eco: GameEcoFilter.forCode('A49'),
                      ),
                    ),
                  );
                },
                child: const Text('Open TWIC filters'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Open TWIC filters'));
      await tester.pumpAndSettle();

      expect(find.text('A49'), findsOneWidget);
      expect(find.text("King's Indian: Fianchetto"), findsOneWidget);

      final reset = tester.widget<DesktopDialogButton>(
        find.widgetWithText(DesktopDialogButton, 'Reset'),
      );
      expect(reset.onPress, isNotNull);

      reset.onPress!();
      await tester.pump();

      expect(find.text('All Openings'), findsAtLeastNWidgets(1));
      expect(find.text('A49'), findsNothing);
      expect(
        tester
            .widget<DesktopDialogButton>(
              find.widgetWithText(DesktopDialogButton, 'Reset'),
            )
            .onPress,
        isNull,
      );
      _expectNoFlutterExceptions(tester);
    },
  );

  testWidgets(
    'EcoFilterDropdown Search TextField mounts in an overlay without Material',
    (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(800, 1200)),
          child: Theme(
            data: ThemeData.dark(),
            child: Localizations(
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
                      builder: (context) {
                        ResponsiveHelper.init(context);
                        return Align(
                          alignment: Alignment.topCenter,
                          child: EcoFilterDropdown(
                            value: GameEcoFilter.all,
                            onChanged: (_) {},
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('All Openings'), findsAtLeastNWidgets(1));
      _expectNoFlutterExceptions(tester);

      await tester.tap(find.text('All Openings').first);
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'sicilian');
      await tester.pump();
      expect(find.widgetWithText(TextField, 'sicilian'), findsOneWidget);
      _expectNoFlutterExceptions(tester);
    },
  );
}
