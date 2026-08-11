import 'package:chessever/desktop/screens/desktop_calendar_event_detail_screen.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'event detail switches through its sequence in place without wrapping',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final events = [
        _event('First event', 'first'),
        _event('Middle event', 'middle'),
        _event('Last event', 'last'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return DesktopCalendarEventDetailScreen(
                event: events[1],
                eventSequence: events,
                initialEventIndex: 1,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final previous = find.byKey(
        const ValueKey('calendar-event-previous-button'),
      );
      final next = find.byKey(const ValueKey('calendar-event-next-button'));
      expect(previous, findsOneWidget);
      expect(next, findsOneWidget);
      expect(find.text('Middle event'), findsWidgets);

      await tester.tap(previous);
      await tester.pumpAndSettle();
      expect(find.text('First event'), findsWidgets);
      expect(find.text('Middle event'), findsNothing);
      expect(find.byType(DesktopCalendarEventDetailScreen), findsOneWidget);

      await tester.tap(previous);
      await tester.pumpAndSettle();
      expect(find.text('First event'), findsWidgets);

      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('Middle event'), findsWidgets);

      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('Last event'), findsWidgets);

      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('Last event'), findsWidgets);
      expect(find.byType(DesktopCalendarEventDetailScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
    },
  );

  testWidgets('Left and Right Arrow switch events without wrapping', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final events = [
      _event('First event', 'first'),
      _event('Middle event', 'middle'),
      _event('Last event', 'last'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return DesktopCalendarEventDetailScreen(
              event: events[1],
              eventSequence: events,
              initialEventIndex: 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('First event'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('First event'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Middle event'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Last event'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Last event'), findsWidgets);
  });

  testWidgets('navigation buttons sit in the centered viewport margins', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final events = [
      _event('First event', 'first'),
      _event('Middle event', 'middle'),
      _event('Last event', 'last'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return DesktopCalendarEventDetailScreen(
              event: events[1],
              eventSequence: events,
              initialEventIndex: 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final previousCenter = tester.getCenter(
      find.byKey(const ValueKey('calendar-event-previous-button')),
    );
    final nextCenter = tester.getCenter(
      find.byKey(const ValueKey('calendar-event-next-button')),
    );

    expect(previousCenter.dx, lessThan(80));
    expect(nextCenter.dx, greaterThan(1320));
    expect(previousCenter.dy, closeTo(450, 2));
    expect(nextCenter.dy, closeTo(450, 2));
  });

  testWidgets('a key repeat does not switch a second event', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final events = [
      _event('First event', 'first'),
      _event('Middle event', 'middle'),
      _event('Third event', 'third'),
      _event('Last event', 'last'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return DesktopCalendarEventDetailScreen(
              event: events[1],
              eventSequence: events,
              initialEventIndex: 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('Third event'), findsWidgets);
    expect(find.text('Last event'), findsNothing);
  });
}

CalendarEvent _event(String name, String id) {
  return CalendarEvent(
    name: name,
    createdAt: DateTime.utc(2026),
    fideEventId: id,
    startDate: DateTime.utc(2026, 8, 10),
    endDate: DateTime.utc(2026, 8, 12),
    location: 'Test City',
    countryCode: 'USA',
  );
}
