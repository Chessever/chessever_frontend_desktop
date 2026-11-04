import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DesktopCalendarDetail {
  const DesktopCalendarDetail({required this.events, required this.index});
  final List<CalendarEvent> events;
  final int index;
  CalendarEvent get event => events[index];
}

final desktopCalendarDetailByTabIdProvider =
    StateProvider<Map<String, DesktopCalendarDetail>>((_) => {});

String desktopCalendarEventPath(CalendarEvent event) {
  final slug = event.name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final fide = event.fideEventId?.trim();
  final key =
      fide != null && fide.isNotEmpty
          ? 'fide-${Uri.encodeComponent(fide)}'
          : 'date-${event.startDate?.toIso8601String().split('T').first ?? 'undated'}';
  return '/calendar/${slug.isEmpty ? 'chess-event' : slug}/$key';
}

typedef DesktopCalendarEventLoader = Future<CalendarEvent?> Function(Uri uri);
final desktopCalendarWebEventLoaderProvider =
    Provider<DesktopCalendarEventLoader>(
      (_) => (uri) async {
        final segments = uri.pathSegments;
        if (segments.length < 3 || segments.first != 'calendar') return null;
        final key = segments[2];
        final query = Supabase.instance.client.from('calendar_events').select();
        if (key.startsWith('fide-')) {
          final id = key.substring(5);
          if (id.isEmpty || id.length > 100) return null;
          final rows = await query.eq('fide_event_id', id).limit(1);
          return rows.isEmpty ? null : CalendarEvent.fromJson(rows.first);
        }
        if (!key.startsWith('date-')) return null;
        final date = DateTime.tryParse(key.substring(5));
        if (date == null) return null;
        final rows = await query
            .gte('start_date', date.toIso8601String())
            .lt(
              'start_date',
              date.add(const Duration(days: 1)).toIso8601String(),
            )
            .limit(100);
        for (final row in rows) {
          final event = CalendarEvent.fromJson(row);
          if (Uri.parse(desktopCalendarEventPath(event)).pathSegments[1] ==
              segments[1]) {
            return event;
          }
        }
        return null;
      },
    );
