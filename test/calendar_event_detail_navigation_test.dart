import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/screens/calendar/calendar_event_detail_screen.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CalendarEvent event(String name, int day) => CalendarEvent(
    name: name,
    startDate: DateTime(2026, 6, day),
    endDate: DateTime(2026, 6, day + 1),
    createdAt: DateTime(2026),
    location: 'Test City',
    timeControl: 'Standard',
  );

  testWidgets('calendar event detail arrows switch between supplied events', (
    tester,
  ) async {
    final events = [event('First Event', 1), event('Second Event', 3)];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return CalendarEventDetailScreen(
              event: events.first,
              navigationEvents: events,
              initialEventIndex: 0,
            );
          },
        ),
      ),
    );

    expect(find.text('First Event'), findsWidgets);
    expect(find.text('Second Event'), findsNothing);

    await tester.tap(find.byTooltip('Next event').first);
    await tester.pumpAndSettle();

    expect(find.text('Second Event'), findsWidgets);
    expect(find.text('First Event'), findsNothing);

    await tester.tap(find.byTooltip('Previous event').first);
    await tester.pumpAndSettle();

    expect(find.text('First Event'), findsWidgets);
    expect(find.text('Second Event'), findsNothing);
  });
}
