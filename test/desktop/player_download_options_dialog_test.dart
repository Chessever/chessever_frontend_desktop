import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as flutter_test;
import 'package:forui/forui.dart';

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/player_download_options_dialog.dart';

// Flutter 3.48 asserts in debug when a MergeSemantics TextField with a visible
// InputDecoration.prefix rebuilds while its route fades out. Every forui
// FTextField with text has that shape, so closing this dialog trips it with
// semantics on. These tests cover dialog behavior, not semantics.
void testWidgets(String description, WidgetTesterCallback callback) =>
    flutter_test.testWidgets(description, callback, semanticsEnabled: false);

void main() {
  Future<void> open(
    WidgetTester tester, {
    PlayerDownloadPreferences preferences = const PlayerDownloadPreferences(),
    PlayerDownloadPreferences appliedPreferences =
        const PlayerDownloadPreferences(),
    String? pgnPath,
    ValueChanged<PlayerDownloadPreferences?>? onSubmitted,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => TextButton(
                onPressed: () async {
                  final result = await showPlayerDownloadOptionsDialog(
                    context,
                    account: PlayerWorkspaceAccount(
                      source: PlayerWorkspaceSource.chesscom,
                      username: 'prep-player',
                      downloadPreferences: preferences,
                      appliedDownloadPreferences: appliedPreferences,
                      pgnPath: pgnPath,
                    ),
                  );
                  onSubmitted?.call(result);
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  FDateFieldController dateController(WidgetTester tester, [int index = 0]) =>
      tester
          .widgetList<FDateField>(
            find.byWidgetPredicate((widget) => widget is FDateField),
          )
          .elementAt(index)
          .controller!;

  bool selected(WidgetTester tester, String label) =>
      tester.widget<FCheckbox>(find.widgetWithText(FCheckbox, label)).value;

  testWidgets('defaults to all history through today with an optional start', (
    tester,
  ) async {
    PlayerDownloadPreferences? submitted;
    await open(tester, onSubmitted: (value) => submitted = value);
    expect(selected(tester, 'All time controls'), isTrue);
    expect(selected(tester, 'Blitz'), isFalse);
    expect(dateController(tester).value, isNull);
    expect(find.text('All history'), findsOneWidget);
    expect(find.text('Starting date (optional)'), findsOneWidget);
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    expect(dateController(tester, 1).value, today);
    expect(
      find.byWidgetPredicate((widget) => widget is FDateField),
      findsNWidgets(2),
    );
    await tester.tap(
      find.widgetWithText(DesktopToolbarPillButton, 'Download games'),
    );
    await tester.pumpAndSettle();
    expect(submitted!.timeControls, isEmpty);
    expect(submitted!.fromDate, isNull);
    // Today is open-ended so future syncs keep receiving new games.
    expect(submitted!.toDate, isNull);
    expect(submitted!.isFiltered, isFalse);
  });

  testWidgets('an unfiltered downloaded profile syncs instead of replacing', (
    tester,
  ) async {
    PlayerDownloadPreferences? submitted;
    await open(
      tester,
      pgnPath: 'prep-player.pgn',
      onSubmitted: (value) => submitted = value,
    );
    expect(
      find.widgetWithText(DesktopToolbarPillButton, 'Sync new games'),
      findsOneWidget,
    );
    expect(find.text('Apply and download'), findsNothing);
    await tester.tap(
      find.widgetWithText(DesktopToolbarPillButton, 'Sync new games'),
    );
    await tester.pumpAndSettle();
    expect(submitted, const PlayerDownloadPreferences());
  });

  testWidgets(
    'choosing a time control narrows All without clearing the start',
    (tester) async {
      await open(tester);
      final from = dateController(tester);
      final first = DateTime.utc(2020, 1, 1);
      from.value = first;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blitz'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'All time controls'), isFalse);
      expect(selected(tester, 'Blitz'), isTrue);
      expect(selected(tester, 'Bullet'), isFalse);
      await tester.tap(find.text('Rapid'));
      await tester.pumpAndSettle();
      expect(from.value, first);
      expect(selected(tester, 'Blitz'), isTrue);
      expect(selected(tester, 'Rapid'), isTrue);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.readOnly),
        isTrue,
      );

      from.value = DateTime.utc(2020, 2, 1);
      await tester.pumpAndSettle();
      expect(selected(tester, 'Blitz'), isTrue);
      expect(selected(tester, 'Rapid'), isTrue);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is DesktopDialogIconButton &&
              widget.tooltip == 'Clear starting date',
        ),
      );
      await tester.pumpAndSettle();
      expect(from.value, isNull);
      expect(selected(tester, 'Blitz'), isTrue);
      expect(selected(tester, 'Rapid'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('All restores the prior individual selection when unchecked', (
    tester,
  ) async {
    await open(
      tester,
      preferences: const PlayerDownloadPreferences(
        timeControls: {PlayerDownloadTimeControl.blitz},
      ),
    );
    await tester.tap(find.text('All time controls'));
    await tester.pumpAndSettle();
    expect(selected(tester, 'All time controls'), isTrue);
    await tester.tap(find.text('All time controls'));
    await tester.pumpAndSettle();
    expect(selected(tester, 'Blitz'), isTrue);
    expect(selected(tester, 'Bullet'), isFalse);
    expect(selected(tester, 'Rapid'), isFalse);
  });

  testWidgets('start picker accepts today and prevents future dates', (
    tester,
  ) async {
    await open(tester);
    final from = dateController(tester);
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    expect(from.validator(today), isNull);
    expect(from.validator(null), isNull);
    expect(from.validator(tomorrow), isNotNull);
    expect(from.validator(DateTime.utc(1899, 12, 31)), isNotNull);

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    final calendar = tester.widget<FCalendar>(find.byType(FCalendar));
    expect(calendar.end, today);
    expect(calendar.controller.selectable(today), isTrue);
    expect(calendar.controller.selectable(tomorrow), isFalse);
    // Clicking the field again closes the calendar. A tap elsewhere in the
    // dialog can land on a calendar day instead.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.byType(FCalendar), findsNothing);
    from.value = tomorrow;
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DesktopToolbarPillButton>(
            find.widgetWithText(DesktopToolbarPillButton, 'Download games'),
          )
          .onPress,
      isNull,
    );
  });

  testWidgets('saved end dates remain selectable and reset selects today', (
    tester,
  ) async {
    PlayerDownloadPreferences? submitted;
    await open(
      tester,
      preferences: PlayerDownloadPreferences(
        timeControls: const {PlayerDownloadTimeControl.blitz},
        fromDate: DateTime.utc(2020, 1, 1),
        toDate: DateTime.utc(2020, 6, 30),
      ),
      onSubmitted: (value) => submitted = value,
    );
    await tester.tap(
      find.widgetWithText(DesktopToolbarPillButton, 'Download games'),
    );
    await tester.pumpAndSettle();
    expect(submitted!.fromDate, DateTime.utc(2020, 1, 1));
    expect(submitted!.toDate, DateTime.utc(2020, 6, 30));
    expect(submitted!.timeControls, {PlayerDownloadTimeControl.blitz});

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset options'));
    await tester.pumpAndSettle();
    expect(dateController(tester).value, isNull);
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    expect(dateController(tester, 1).value, today);
    await tester.tap(find.text('Reset options'));
    await tester.pumpAndSettle();
    expect(dateController(tester, 1).value, today);
    expect(selected(tester, 'All time controls'), isTrue);
    expect(selected(tester, 'Blitz'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'end picker allows earlier dates while preserving other filters',
    (tester) async {
      PlayerDownloadPreferences? submitted;
      await open(tester, onSubmitted: (value) => submitted = value);
      final from = dateController(tester);
      final to = dateController(tester, 1);
      from.value = DateTime.utc(2020, 2, 1);
      to.value = DateTime.utc(2020, 3, 1);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blitz'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();
      final calendar = tester.widget<FCalendar>(find.byType(FCalendar));
      expect(
        calendar.controller.selectable(DateTime.utc(2020, 1, 31)),
        isFalse,
      );
      expect(calendar.controller.selectable(DateTime.utc(2020, 2, 1)), isTrue);
      final end = DateTime.utc(2020, 2, 15);
      calendar.controller.select(end);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();
      expect(find.byType(FCalendar), findsNothing);
      expect(to.value, end);
      expect(from.value, DateTime.utc(2020, 2, 1));
      expect(selected(tester, 'Blitz'), isTrue);
      await tester.tap(
        find.widgetWithText(DesktopToolbarPillButton, 'Download games'),
      );
      await tester.pumpAndSettle();
      expect(submitted!.toDate, end);
      expect(submitted!.fromDate, DateTime.utc(2020, 2, 1));
      expect(submitted!.timeControls, {PlayerDownloadTimeControl.blitz});
    },
  );
}
