import 'package:chessever/desktop/panes/calendar_pane.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_calendar_directory_view.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/calendar/calendar_event_detail_screen.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  Future<void> setDesktopViewport(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  Widget harness(_FakeCalendarDataSource source) {
    return ProviderScope(
      overrides: [
        desktopCalendarDirectoryDataSourceProvider.overrideWithValue(source),
        selectedYearProvider.overrideWith((ref) => 2026),
        selectedMonthProvider.overrideWith((ref) => 8),
        liveGroupBroadcastIdsProvider.overrideWith(
          (ref) => Stream.value(const ['live-broadcast']),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return const Scaffold(body: CalendarPane());
          },
        ),
      ),
    );
  }

  testWidgets(
    'real pane switches among Major, FIDE, and Follow Live datasets',
    (tester) async {
      await setDesktopViewport(tester);
      final source = _FakeCalendarDataSource();
      await tester.pumpWidget(harness(source));
      await tester.pumpAndSettle();

      expect(find.text('Baku Major'), findsOneWidget);
      expect(find.text('Oslo Open'), findsNothing);
      expect(
        find.byKey(const Key('desktop-calendar-compact-month')),
        findsOneWidget,
      );

      await tester.tap(find.text('Full FIDE Calendar'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Baku Major'), findsOneWidget);
      expect(find.text('Oslo Open'), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-calendar-compact-month')),
        findsOneWidget,
      );

      await tester.tap(find.text('Follow Live'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Current Broadcast'), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-calendar-live-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('desktop-calendar-compact-month')),
        findsOneWidget,
      );
      expect(find.text('LIVE'), findsOneWidget);
    },
  );

  testWidgets(
    'real pane search filters active mode and Enter opens FIDE detail',
    (tester) async {
      await setDesktopViewport(tester);
      final source = _FakeCalendarDataSource();
      await tester.pumpWidget(harness(source));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(DesktopSearchField),
          matching: find.byType(TextField),
        ),
        'Baku',
      );
      await tester.pump();
      expect(find.text('Baku Major'), findsOneWidget);
      expect(find.text('Oslo Open'), findsNothing);

      final rowFinder = find.byWidgetPredicate(
        (widget) =>
            widget is DesktopCalendarEventRow &&
            widget.listing.title == 'Baku Major',
      );
      expect(rowFinder, findsOneWidget);
      expect(
        tester.widget<DesktopCalendarEventRow>(rowFinder).selected,
        isFalse,
      );

      await tester.tap(rowFinder);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<DesktopCalendarEventRow>(rowFinder).selected,
        isTrue,
      );
      expect(find.byType(CalendarEventDetailScreen), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(CalendarEventDetailScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('calendar-event-previous-button')),
        findsOneWidget,
      );
      final next = find.byKey(const ValueKey('calendar-event-next-button'));
      expect(next, findsOneWidget);

      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('Baku Major'), findsWidgets);
      expect(find.text('Oslo Open'), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
    },
  );

  testWidgets('FIDE detail arrows follow the rendered Calendar event order', (
    tester,
  ) async {
    await setDesktopViewport(tester);
    await tester.pumpWidget(harness(_FakeCalendarDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Full FIDE Calendar'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<DesktopCalendarEventRow>(
          find.byType(DesktopCalendarEventRow),
        )
        .toList(growable: false);
    expect(rows, hasLength(2));
    final firstTitle = rows[0].listing.title;
    final secondTitle = rows[1].listing.title;

    await tester.tap(find.byType(DesktopCalendarEventRow).at(0));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final previous = find.byKey(
      const ValueKey('calendar-event-previous-button'),
    );
    final next = find.byKey(const ValueKey('calendar-event-next-button'));
    expect(previous, findsOneWidget);
    expect(next, findsOneWidget);
    expect(find.text(firstTitle), findsWidgets);

    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text(firstTitle), findsNothing);
    expect(find.text(secondTitle), findsWidgets);
    expect(find.byType(CalendarEventDetailScreen), findsOneWidget);

    await tester.tap(previous);
    await tester.pumpAndSettle();
    expect(find.text(firstTitle), findsWidgets);
    expect(find.text(secondTitle), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('wide short pane keeps the final calendar week visible', (
    tester,
  ) async {
    await setDesktopViewport(tester, size: const Size(1400, 720));
    await tester.pumpWidget(harness(_FakeCalendarDataSource()));
    await tester.pumpAndSettle();

    expect(find.text('31'), findsOneWidget);
    expect(tester.getBottomRight(find.text('31')).dy, lessThanOrEqualTo(720));
  });

  testWidgets('broadcast activation opens a Desktop tournament-detail tab', (
    tester,
  ) async {
    await setDesktopViewport(tester);
    await tester.pumpWidget(harness(_FakeCalendarDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Follow Live'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final row = find.text('Current Broadcast');
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 400));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalendarPane)),
    );
    final tabs = container.read(desktopTabsProvider);
    expect(tabs.active?.kind, TabKind.tournamentDetail);
    expect(
      container.read(tournamentByTabIdProvider)[tabs.activeId]?.id,
      'live-broadcast',
    );
  });
}

class _FakeCalendarDataSource implements DesktopCalendarDirectoryDataSource {
  final List<CalendarEvent> _calendarEvents = [
    CalendarEvent(
      name: 'Baku Major',
      startDate: DateTime.utc(2026, 8, 5),
      endDate: DateTime.utc(2026, 8, 12),
      location: 'Baku',
      timeControl: 'Classical',
      createdAt: DateTime.utc(2026),
      countryCode: 'AZE',
      fideEventId: 'baku-major',
      isMajorEvent: true,
    ),
    CalendarEvent(
      name: 'Oslo Open',
      startDate: DateTime.utc(2026, 8, 18),
      endDate: DateTime.utc(2026, 8, 24),
      location: 'Oslo',
      timeControl: 'Rapid',
      createdAt: DateTime.utc(2026),
      countryCode: 'NOR',
      fideEventId: 'oslo-open',
    ),
  ];

  @override
  Future<List<CalendarEvent>> fetchCalendarMonth({
    required int year,
    required int month,
  }) async {
    return _calendarEvents;
  }

  @override
  Future<List<GroupBroadcast>> fetchCurrentBroadcasts() async {
    return [
      GroupBroadcast(
        id: 'live-broadcast',
        createdAt: DateTime.utc(2026),
        name: 'Current Broadcast',
        search: const ['Current Broadcast'],
        maxAvgElo: 2750,
        dateStart: DateTime.utc(2026, 8, 1),
        dateEnd: DateTime.utc(2026, 8, 10),
        timeControl: 'Blitz',
      ),
    ];
  }
}
