import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';

DesktopDialogButtonTone _tone(WidgetTester tester, String label) => tester
    .widget<DesktopDialogButton>(find.widgetWithText(DesktopDialogButton, label))
    .tone;

void main() {
  testWidgets('a plain gate offers Premium as its one primary action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DesktopDateGateDialog(title: 'Title', body: 'Body'),
        ),
      ),
    );

    expect(_tone(tester, 'Not now'), DesktopDialogButtonTone.ghost);
    expect(_tone(tester, 'See Premium'), DesktopDialogButtonTone.primary);
  });

  testWidgets(
    'an action gate draws the requested action as primary, last, with a cancel',
    (tester) async {
      var cancelled = 0;
      var premium = 0;
      var exported = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopDateGateDialog(
              title: 'Export 3 of 6 likes?',
              body: 'Body',
              dismissLabel: 'Cancel',
              onDismiss: () => cancelled++,
              onPremium: () => premium++,
              actionLabel: 'Export 3',
              onAction: () => exported++,
            ),
          ),
        ),
      );

      expect(_tone(tester, 'Cancel'), DesktopDialogButtonTone.ghost);
      expect(_tone(tester, 'See Premium'), DesktopDialogButtonTone.secondary);
      expect(_tone(tester, 'Export 3'), DesktopDialogButtonTone.primary);

      final cancelX = tester.getCenter(find.text('Cancel')).dx;
      final premiumX = tester.getCenter(find.text('See Premium')).dx;
      final exportX = tester.getCenter(find.text('Export 3')).dx;
      expect(cancelX, lessThan(premiumX));
      expect(premiumX, lessThan(exportX));

      // forui's tap feedback runs short timers; let each one finish.
      const tapFeedback = Duration(milliseconds: 300);
      await tester.tap(find.text('Export 3'));
      await tester.pump(tapFeedback);
      await tester.tap(find.text('See Premium'));
      await tester.pump(tapFeedback);
      await tester.tap(find.text('Cancel'));
      await tester.pump(tapFeedback);
      expect((exported, premium, cancelled), (1, 1, 1));
    },
  );
}
