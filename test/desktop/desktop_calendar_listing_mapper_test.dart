import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_listing_mapper.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> calendarJson({
    String name = 'FIDE World Cup',
    String? fideEventId = '5080',
    bool? isMajorEvent,
    bool? isMajorUpcomingEvent,
  }) {
    return <String, dynamic>{
      'name': name,
      'start_date': '2026-08-01',
      'end_date': '2026-08-12',
      'created_at': '2026-01-01T00:00:00Z',
      'location': 'Baku',
      'country_code': 'AZE',
      'time_control': 'Classical / Rapid',
      'website_url': 'https://example.test/event',
      'description': 'World championship event',
      'players': <dynamic>[
        <String, dynamic>{'name': 'Player Low', 'rating': 2400},
        <String, dynamic>{'name': 'Player High', 'rating': 2750},
        <String, dynamic>{'name': 'Player Third', 'rating': 2650},
        <String, dynamic>{'name': 'Player Fourth', 'rating': 2550},
        <String, dynamic>{'name': 'Player Fifth', 'rating': 2450},
        'String Player',
      ],
      'fide_event_id': fideEventId,
      if (isMajorEvent != null) 'is_major_event': isMajorEvent,
      if (isMajorUpcomingEvent != null)
        'is_major_upcoming_event': isMajorUpcomingEvent,
    };
  }

  group('CalendarEvent public schema', () {
    test('parses optional major flags when the backend supplies them', () {
      final event = CalendarEvent.fromJson(
        calendarJson(isMajorEvent: false, isMajorUpcomingEvent: true),
      );

      expect(event.isMajorEvent, isFalse);
      expect(event.isMajorUpcomingEvent, isTrue);
      expect(event.toJson()['is_major_event'], isFalse);
      expect(event.toJson()['is_major_upcoming_event'], isTrue);
    });

    test('defaults missing major columns to false for older rows', () {
      final event = CalendarEvent.fromJson(calendarJson());

      expect(event.isMajorEvent, isFalse);
      expect(event.isMajorUpcomingEvent, isFalse);
    });
  });

  group('calendar listing mapping', () {
    test('maps a FIDE row without discarding parity metadata', () {
      final event = CalendarEvent.fromJson(
        calendarJson(name: 'FIDE World Cup *', isMajorUpcomingEvent: true),
      );

      final listing = desktopCalendarListingFromCalendarEvent(
        event,
        now: DateTime.utc(2026, 8, 2),
      );

      expect(listing.id, 'calendar:fide:5080');
      expect(listing.title, 'FIDE World Cup');
      expect(listing.source, DesktopCalendarSource.fide);
      expect(listing.status, DesktopCalendarStatus.upcoming);
      expect(listing.isMajorEvent, isTrue);
      expect(listing.fideEventId, '5080');
      expect(listing.location, 'Baku');
      expect(listing.countryCode, 'AZE');
      expect(listing.websiteUrl, 'https://example.test/event');
      expect(listing.timeControls, ['Classical', 'Rapid']);
      expect(listing.topPlayers, [
        'Player High',
        'Player Third',
        'Player Fourth',
        'Player Fifth',
      ]);
      expect(listing.searchTerms, containsAll(['Baku', 'AZE']));
    });

    test('maps a current group broadcast to a cyan-live-ready listing', () {
      final broadcast = GroupBroadcast(
        id: 'broadcast-id',
        createdAt: DateTime.utc(2026),
        name: 'Current Broadcast',
        search: const ['World', 'Cup'],
        maxAvgElo: 2710,
        dateStart: DateTime.utc(2026, 8, 1),
        dateEnd: DateTime.utc(2026, 8, 10),
        timeControl: 'blitz',
      );

      final listing = desktopCalendarListingFromGroupBroadcast(
        broadcast,
        isCurrent: true,
        isLiveNow: true,
        now: DateTime.utc(2026, 8, 2),
      );

      expect(listing.id, 'broadcast:broadcast-id');
      expect(listing.broadcastId, 'broadcast-id');
      expect(listing.source, DesktopCalendarSource.broadcast);
      expect(listing.status, DesktopCalendarStatus.ongoing);
      expect(listing.isLiveNow, isTrue);
      expect(listing.timeControls, ['Blitz']);
      expect(listing.maxAvgElo, 2710);
      expect(listing.searchTerms, ['World', 'Cup']);
    });

    test(
      'reconciles duplicate FIDE rows and preserves supplemental metadata',
      () {
        final canonical = desktopCalendarListingFromCalendarEvent(
          CalendarEvent.fromJson(
            calendarJson(name: 'FIDE World Cup', isMajorEvent: false)
              ..['description'] = null,
          ),
          now: DateTime.utc(2026, 8, 2),
        );
        final supplement = desktopCalendarListingFromCalendarEvent(
          CalendarEvent.fromJson(
            calendarJson(name: 'FIDE World Cup *', isMajorEvent: true)
              ..['website_url'] = null,
          ),
          now: DateTime.utc(2026, 8, 2),
        );

        final reconciled = reconcileDesktopCalendarListings([
          supplement,
          canonical,
        ]);

        expect(reconciled, hasLength(1));
        expect(reconciled.single.id, 'calendar:fide:5080');
        expect(reconciled.single.title, 'FIDE World Cup');
        expect(reconciled.single.isMajorEvent, isTrue);
        expect(reconciled.single.description, 'World championship event');
        expect(reconciled.single.websiteUrl, 'https://example.test/event');
      },
    );

    test('reconciliation bridges optional IDs and unions section dates', () {
      final anonymous = desktopCalendarListingFromCalendarEvent(
        CalendarEvent.fromJson(
          calendarJson(fideEventId: null)
            ..['start_date'] = '2026-08-01'
            ..['end_date'] = '2026-08-03',
        ),
        now: DateTime.utc(2026, 8, 2),
      );
      final authoritative = desktopCalendarListingFromCalendarEvent(
        CalendarEvent.fromJson(
          calendarJson(fideEventId: '5080')
            ..['start_date'] = '2026-08-10'
            ..['end_date'] = '2026-08-20',
        ),
        now: DateTime.utc(2026, 8, 2),
      );

      final reconciled = reconcileDesktopCalendarListings([
        anonymous,
        authoritative,
      ]);

      expect(reconciled, hasLength(1));
      expect(reconciled.single.id, 'calendar:fide:5080');
      expect(reconciled.single.startDate, DateTime(2026, 8, 1));
      expect(reconciled.single.endDate, DateTime(2026, 8, 20));
    });

    test('conflicting authoritative FIDE IDs remain separate', () {
      DesktopCalendarListing mapped(String fideId, int startDay) {
        return desktopCalendarListingFromCalendarEvent(
          CalendarEvent(
            name: 'Shared Open',
            location: 'Baku',
            fideEventId: fideId,
            startDate: DateTime(2026, 8, startDay),
            endDate: DateTime(2026, 8, startDay + 2),
            createdAt: DateTime(2026),
          ),
          now: DateTime(2026, 8, 1),
        );
      }

      final reconciled = reconcileDesktopCalendarListings([
        mapped('A', 1),
        mapped('B', 20),
      ]);

      expect(reconciled, hasLength(2));
      expect(reconciled.map((listing) => listing.fideEventId), {'A', 'B'});
    });
  });
}
