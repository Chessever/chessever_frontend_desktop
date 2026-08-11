import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/widgets/desktop_calendar_directory_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SizedBox(width: 1200, height: 760, child: child)),
    );
  }

  DesktopCalendarListing listing(
    String id, {
    DesktopCalendarSource source = DesktopCalendarSource.fide,
    DesktopCalendarStatus status = DesktopCalendarStatus.upcoming,
    int month = 8,
    int day = 15,
    int? endMonth,
    int? endDay,
  }) {
    return DesktopCalendarListing(
      id: id,
      title: id,
      source: source,
      status: status,
      isLiveNow: status == DesktopCalendarStatus.live,
      startDate: DateTime.utc(2026, month, day),
      endDate: DateTime.utc(2026, endMonth ?? month, endDay ?? day),
      countryCode: 'NOR',
      location: 'Oslo',
      timeControls: const ['Classical', 'Rapid'],
    );
  }

  testWidgets('mode bar exposes all three website data modes', (tester) async {
    DesktopCalendarMode? selected;
    await tester.pumpWidget(
      harness(
        DesktopCalendarModeBar(
          selected: DesktopCalendarMode.major,
          eventCount: 87,
          onSelect: (mode) => selected = mode,
        ),
      ),
    );

    expect(find.text('Follow Live'), findsOneWidget);
    expect(find.text('Major Events'), findsOneWidget);
    expect(find.text('Full FIDE Calendar'), findsOneWidget);
    expect(find.text('87 events'), findsOneWidget);

    await tester.tap(find.text('Follow Live'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(selected, DesktopCalendarMode.live);
  });

  testWidgets('Follow Live uses a list with a compact right month calendar', (
    tester,
  ) async {
    final selected = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      harness(
        DesktopCalendarDirectoryBody(
          mode: DesktopCalendarMode.live,
          year: 2026,
          month: 8,
          listings: [
            listing(
              'Live broadcast',
              source: DesktopCalendarSource.broadcast,
              status: DesktopCalendarStatus.live,
            ),
            listing(
              'Current broadcast',
              source: DesktopCalendarSource.broadcast,
              status: DesktopCalendarStatus.ongoing,
            ),
          ],
          selectedDay: null,
          selectedEventId: null,
          now: DateTime.utc(2026, 8, 15),
          onSelectDay: (_) {},
          onSelectEvent: (event) => selected.add(event.id),
          onOpenEvent: (event) => opened.add(event.id),
        ),
      ),
    );

    expect(find.byKey(const Key('desktop-calendar-live-list')), findsOneWidget);
    final listFinder = find.byKey(
      const Key('desktop-calendar-directory-list-pane'),
    );
    final calendarFinder = find.byKey(
      const Key('desktop-calendar-compact-month'),
    );
    expect(listFinder, findsOneWidget);
    expect(calendarFinder, findsOneWidget);
    expect(find.byKey(const Key('desktop-calendar-month-grid')), findsNothing);
    final listSize = tester.getSize(listFinder);
    final calendarSize = tester.getSize(calendarFinder);
    expect(calendarSize.width, inInclusiveRange(280, 310));
    expect(listSize.width, greaterThan(calendarSize.width * 1.4));
    expect(
      tester.getTopLeft(listFinder).dx,
      lessThan(tester.getTopLeft(calendarFinder).dx),
    );
    expect(find.text('1 live now'), findsOneWidget);
    expect(find.text('2 current'), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('Open broadcast'), findsNWidgets(2));
    await tester.tap(find.text('Open broadcast').first);
    await tester.pump();
    expect(selected, ['Live broadcast']);
    expect(opened, ['Live broadcast']);
  });

  testWidgets('agenda separates earlier and cross-month events', (
    tester,
  ) async {
    var previousMonths = 0;
    var nextMonths = 0;
    var todaySelections = 0;
    await tester.pumpWidget(
      harness(
        DesktopCalendarDirectoryBody(
          mode: DesktopCalendarMode.fide,
          year: 2026,
          month: 8,
          listings: [
            listing('Today', day: 15),
            listing('Earlier', day: 10),
            listing(
              'Started before',
              month: 7,
              day: 29,
              endMonth: 8,
              endDay: 3,
            ),
          ],
          selectedDay: null,
          selectedEventId: null,
          now: DateTime.utc(2026, 8, 15),
          onSelectDay: (_) {},
          onSelectEvent: (_) {},
          onOpenEvent: (_) {},
          onPreviousMonth: () => previousMonths++,
          onNextMonth: () => nextMonths++,
          onToday: () => todaySelections++,
        ),
      ),
    );

    expect(
      find.byKey(const Key('desktop-calendar-compact-month')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('desktop-calendar-month-grid')), findsNothing);
    await tester.tap(find.byKey(const Key('desktop-calendar-previous-month')));
    await tester.tap(find.byKey(const Key('desktop-calendar-next-month')));
    await tester.tap(find.byKey(const Key('desktop-calendar-today')));
    expect(previousMonths, 1);
    expect(nextMonths, 1);
    expect(todaySelections, 1);
    expect(find.text('Saturday, August 15, 2026'), findsOneWidget);
    expect(find.text('Monday, August 10, 2026'), findsOneWidget);
    expect(find.text('Earlier in August'), findsOneWidget);
    expect(find.text('Started before August'), findsOneWidget);
  });

  testWidgets('focused live row keeps its identity across reorder', (
    tester,
  ) async {
    late StateSetter rebuild;
    final first = listing(
      'Focused A',
      source: DesktopCalendarSource.broadcast,
      status: DesktopCalendarStatus.ongoing,
    );
    final second = listing(
      'Other B',
      source: DesktopCalendarSource.broadcast,
      status: DesktopCalendarStatus.ongoing,
      day: 16,
    );
    var listings = [first, second];
    String? selectedId;
    final opened = <String>[];

    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return DesktopCalendarDirectoryBody(
              mode: DesktopCalendarMode.live,
              year: 2026,
              month: 8,
              listings: listings,
              selectedDay: null,
              selectedEventId: selectedId,
              now: DateTime.utc(2026, 8, 15),
              onSelectDay: (_) {},
              onSelectEvent: (event) {
                setState(() => selectedId = event.id);
              },
              onOpenEvent: (event) => opened.add(event.id),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Focused A'));
    await tester.pump(const Duration(milliseconds: 400));
    rebuild(() => listings = [second, first]);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(opened, ['Focused A']);
  });

  testWidgets('event row double-click selects and opens exactly once', (
    tester,
  ) async {
    var selectedCount = 0;
    var openedCount = 0;
    final doubleClickListing = listing('Double Click Open', day: 10);

    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 760,
          height: 360,
          child: DesktopCalendarDirectoryBody(
            mode: DesktopCalendarMode.major,
            year: 2026,
            month: 8,
            listings: [doubleClickListing],
            selectedDay: null,
            selectedEventId: null,
            now: DateTime.utc(2026, 8, 4),
            onSelectDay: (_) {},
            onSelectEvent: (_) => selectedCount++,
            onOpenEvent: (_) => openedCount++,
          ),
        ),
      ),
    );

    final row = find.text('Double Click Open');
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 400));

    expect(selectedCount, 1);
    expect(openedCount, 1);
  });

  testWidgets('event row selects once and opens on Enter', (tester) async {
    var selections = 0;
    var opens = 0;
    await tester.pumpWidget(
      harness(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 560,
            child: DesktopCalendarEventRow(
              listing: listing('Keyboard event'),
              date: DateTime.utc(2026, 8, 15),
              selected: false,
              onSelect: () => selections++,
              onOpen: () => opens++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Keyboard event'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selections, 1);
    expect(opens, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selections, 2);
    expect(opens, 1);
  });
}
