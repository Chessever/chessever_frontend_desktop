import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop calendar identity', () {
    test('uses the authoritative FIDE id when present', () {
      expect(
        desktopCalendarStableFideId(
          fideEventId: ' 5080 ',
          title: 'FIDE World Junior Championships 2026',
          startDate: DateTime.utc(2026, 9, 1),
        ),
        'calendar:fide:5080',
      );
    });

    test('falls back to title and date when the FIDE id is blank', () {
      expect(
        desktopCalendarStableFideId(
          fideEventId: '  ',
          title: 'FIDE World Junior U20 Championships 2026 *',
          startDate: DateTime.utc(2026, 9, 1),
        ),
        'calendar:fide-fallback:fide-world-junior-u20-championships-2026:2026-09-01',
      );
    });

    test('keeps distinct non-Latin fallback titles distinct', () {
      final first = desktopCalendarStableFideId(
        fideEventId: null,
        title: 'Шахматный фестиваль',
        startDate: DateTime.utc(2026, 9, 1),
      );
      final second = desktopCalendarStableFideId(
        fideEventId: null,
        title: '国际象棋节',
        startDate: DateTime.utc(2026, 9, 1),
      );

      expect(first, isNot(second));
    });
  });

  group('desktop calendar modes', () {
    final listings = <DesktopCalendarListing>[
      DesktopCalendarListing(
        id: 'live-broadcast',
        title: 'Live broadcast',
        source: DesktopCalendarSource.broadcast,
        status: DesktopCalendarStatus.live,
        isMajorEvent: true,
      ),
      DesktopCalendarListing(
        id: 'upcoming-major',
        title: 'Upcoming major',
        source: DesktopCalendarSource.broadcast,
        status: DesktopCalendarStatus.upcoming,
        isMajorEvent: true,
      ),
      const DesktopCalendarListing(
        id: 'current-broadcast',
        title: 'Current broadcast without fresh moves',
        source: DesktopCalendarSource.broadcast,
        status: DesktopCalendarStatus.ongoing,
      ),
      DesktopCalendarListing(
        id: 'fide-major',
        title: 'FIDE major',
        source: DesktopCalendarSource.fide,
        status: DesktopCalendarStatus.upcoming,
        isMajorEvent: true,
      ),
      DesktopCalendarListing(
        id: 'ordinary-fide',
        title: 'Ordinary FIDE event',
        source: DesktopCalendarSource.fide,
        status: DesktopCalendarStatus.past,
      ),
    ];

    test('Follow Live includes only current broadcast listings', () {
      expect(
        filterDesktopCalendarMode(
          listings,
          DesktopCalendarMode.live,
        ).map((event) => event.id),
        ['live-broadcast', 'current-broadcast'],
      );
    });

    test('Major Events requires authoritative FIDE major metadata', () {
      expect(
        filterDesktopCalendarMode(
          listings,
          DesktopCalendarMode.major,
        ).map((event) => event.id),
        ['fide-major'],
      );
    });

    test('Full FIDE Calendar includes every FIDE listing', () {
      expect(
        filterDesktopCalendarMode(
          listings,
          DesktopCalendarMode.fide,
        ).map((event) => event.id),
        ['fide-major', 'ordinary-fide'],
      );
    });
  });

  group('desktop calendar filtering', () {
    final crossingMonth = DesktopCalendarListing(
      id: 'crossing-month',
      title: 'International Chess Festival',
      source: DesktopCalendarSource.fide,
      status: DesktopCalendarStatus.ongoing,
      isMajorEvent: true,
      startDate: DateTime.utc(2026, 7, 29),
      endDate: DateTime.utc(2026, 8, 3),
      timeControls: const ['Classical', 'Rapid'],
      location: 'Amman',
      countryCode: 'JOR',
      topPlayers: const ['Player One', 'Player Two'],
      searchTerms: const ['Jordan summer chess'],
    );
    final liveOutsideMonth = DesktopCalendarListing(
      id: 'live-outside-month',
      title: 'Current Broadcast',
      source: DesktopCalendarSource.broadcast,
      status: DesktopCalendarStatus.live,
      startDate: DateTime.utc(2026, 9, 2),
      endDate: DateTime.utc(2026, 9, 9),
      timeControls: const ['Blitz'],
    );

    test('uses inclusive event ranges for month and day overlap', () {
      expect(desktopCalendarOverlapsMonth(crossingMonth, 2026, 8), isTrue);
      expect(
        desktopCalendarOverlapsDay(crossingMonth, DateTime.utc(2026, 8, 3)),
        isTrue,
      );
      expect(
        desktopCalendarOverlapsDay(crossingMonth, DateTime.utc(2026, 8, 4)),
        isFalse,
      );
    });

    test('searches location, country, players, and source terms', () {
      for (final query in ['Amman', 'jor', 'player two', 'summer chess']) {
        expect(
          filterDesktopCalendarListings(
            [crossingMonth],
            mode: DesktopCalendarMode.fide,
            year: 2026,
            month: 8,
            query: query,
          ).map((event) => event.id),
          ['crossing-month'],
          reason: 'query: $query',
        );
      }
    });

    test('matches any normalized time control in a multi-format family', () {
      expect(
        filterDesktopCalendarListings(
          [crossingMonth],
          mode: DesktopCalendarMode.major,
          year: 2026,
          month: 8,
          timeControl: 'rapid',
        ).map((event) => event.id),
        ['crossing-month'],
      );
    });

    test('Follow Live is not scoped to the selected calendar month', () {
      expect(
        filterDesktopCalendarListings(
          [crossingMonth, liveOutsideMonth],
          mode: DesktopCalendarMode.live,
          year: 2026,
          month: 8,
        ).map((event) => event.id),
        ['live-outside-month'],
      );
    });
  });

  group('desktop calendar agenda ordering', () {
    DesktopCalendarListing event(
      String id,
      int month,
      int day, {
      int? endMonth,
      int? endDay,
    }) {
      return DesktopCalendarListing(
        id: id,
        title: id,
        source: DesktopCalendarSource.fide,
        status: DesktopCalendarStatus.upcoming,
        startDate: DateTime.utc(2026, month, day),
        endDate: DateTime.utc(2026, endMonth ?? month, endDay ?? day),
      );
    }

    test('current month shows today and future before earlier dates', () {
      final agenda = buildDesktopCalendarAgenda(
        [
          event('started-before', 7, 29, endMonth: 8, endDay: 3),
          event('earlier-10', 8, 10),
          event('today-15', 8, 15),
          event('future-20', 8, 20),
        ],
        year: 2026,
        month: 8,
        now: DateTime.utc(2026, 8, 15, 12),
      );

      expect(agenda.upcoming.map((group) => group.date.day), [15, 20]);
      expect(agenda.earlier.map((group) => group.date.day), [10]);
      expect(agenda.startedBeforeMonth.map((listing) => listing.id), [
        'started-before',
      ]);
    });

    test('future month begins at day one and remains ascending', () {
      final agenda = buildDesktopCalendarAgenda(
        [event('sep-20', 9, 20), event('sep-2', 9, 2)],
        year: 2026,
        month: 9,
        now: DateTime.utc(2026, 8, 15),
      );

      expect(agenda.upcoming.map((group) => group.date.day), [2, 20]);
      expect(agenda.earlier, isEmpty);
    });

    test('past month anchors at the final day and puts older dates below', () {
      final agenda = buildDesktopCalendarAgenda(
        [event('jul-2', 7, 2), event('jul-20', 7, 20), event('jul-31', 7, 31)],
        year: 2026,
        month: 7,
        now: DateTime.utc(2026, 8, 15),
      );

      expect(agenda.upcoming.map((group) => group.date.day), [31]);
      expect(agenda.earlier.map((group) => group.date.day), [20, 2]);
    });

    test('selected-day navigation excludes rows outside that day', () {
      final sequence = buildDesktopCalendarNavigationSequence(
        [
          event('outside', 8, 20),
          event('crossing', 8, 10, endDay: 16),
          event('selected-day', 8, 15),
        ],
        mode: DesktopCalendarMode.fide,
        year: 2026,
        month: 8,
        selectedDay: 15,
        now: DateTime.utc(2026, 8, 15),
      );

      expect(sequence.map((listing) => listing.id), [
        'crossing',
        'selected-day',
      ]);
    });
  });
}
