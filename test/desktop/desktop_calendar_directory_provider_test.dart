import 'dart:async';

import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CalendarEvent calendarEvent(String name, {bool major = false}) {
    return CalendarEvent(
      name: name,
      startDate: DateTime.utc(2026, 8, 1),
      endDate: DateTime.utc(2026, 8, 8),
      createdAt: DateTime.utc(2026),
      fideEventId: name,
      isMajorEvent: major,
    );
  }

  GroupBroadcast broadcast(String id) {
    return GroupBroadcast(
      id: id,
      createdAt: DateTime.utc(2026),
      name: id,
      search: const [],
      dateStart: DateTime.utc(2026, 8, 1),
      dateEnd: DateTime.utc(2026, 8, 8),
    );
  }

  Future<bool> validateCodePointNamesAfter({
    required String afterName,
    required Set<String> candidateNames,
  }) async => candidateNames.every((name) => name.compareTo(afterName) > 0);

  test('pagination continues until a short page without truncating', () async {
    final cursors = <int?>[];
    final result = await fetchAllDesktopCalendarPages<int>(
      ({required limit, int? after}) async {
        cursors.add(after);
        if (after == null) return [1, 2];
        if (after == 2) return [3, 4];
        return [5];
      },
      pageSize: 2,
      identityOf: (value) => value,
      compareCursor: (previous, next) => previous.compareTo(next),
    );

    expect(result, [1, 2, 3, 4, 5]);
    expect(cursors, [null, 2, 4]);
  });

  test('pagination rejects duplicate boundary rows by identity', () async {
    final result = await fetchAllDesktopCalendarPages<int>(
      ({required limit, int? after}) async {
        if (after == null) return [1, 2];
        if (after == 2) return [2, 3];
        return [4];
      },
      pageSize: 2,
      identityOf: (value) => value,
      compareCursor: (previous, next) => previous.compareTo(next),
    );

    expect(result, [1, 2, 3, 4]);
  });

  test('pagination does not skip rows removed before the boundary', () async {
    final rows = [1, 2, 3, 4, 5];
    var firstPage = true;
    final result = await fetchAllDesktopCalendarPages<int>(
      ({required limit, int? after}) async {
        final page =
            rows
                .where((value) => after == null || value > after)
                .take(limit)
                .toList();
        if (firstPage) {
          firstPage = false;
          rows.removeAt(0);
        }
        return page;
      },
      pageSize: 2,
      identityOf: (value) => value,
      compareCursor: (previous, next) => previous.compareTo(next),
    );

    expect(result, [1, 2, 3, 4, 5]);
  });

  test('calendar pagination keeps equal-name authoritative rows', () async {
    final rows = [
      CalendarEvent(
        name: 'Shared Open',
        createdAt: DateTime.utc(2026),
        fideEventId: 'A',
      ),
      CalendarEvent(
        name: 'Shared Open',
        createdAt: DateTime.utc(2026),
        fideEventId: 'B',
      ),
      CalendarEvent(
        name: 'Zulu Open',
        createdAt: DateTime.utc(2026),
        fideEventId: 'Z',
      ),
    ];

    final result = await fetchAllDesktopCalendarNamePages<CalendarEvent>(
      ({required limit, String? afterName}) async {
        return rows
            .where(
              (row) => afterName == null || row.name.compareTo(afterName) > 0,
            )
            .take(limit)
            .toList();
      },
      ({required name, required limit}) async =>
          rows.where((row) => row.name == name).take(limit).toList(),
      pageSize: 1,
      validateNamesAfter: validateCodePointNamesAfter,
      nameOf: (event) => event.name,
      identityOf: (event) => event.fideEventId!,
    );

    expect(result.map((event) => event.fideEventId), ['A', 'B', 'Z']);
  });

  test('calendar pagination accepts database-collated name order', () async {
    final rows = [
      CalendarEvent(
        name: 'apple Open',
        createdAt: DateTime.utc(2026),
        fideEventId: 'A',
      ),
      CalendarEvent(
        name: 'Zulu Open',
        createdAt: DateTime.utc(2026),
        fideEventId: 'Z',
      ),
    ];

    final result = await fetchAllDesktopCalendarNamePages<CalendarEvent>(
      ({required limit, String? afterName}) async => rows.take(limit).toList(),
      ({required name, required limit}) async =>
          rows.where((row) => row.name == name).take(limit).toList(),
      pageSize: 3,
      validateNamesAfter: validateCodePointNamesAfter,
      nameOf: (event) => event.name,
      identityOf: (event) => event.fideEventId!,
    );

    expect(result.map((event) => event.fideEventId), ['A', 'Z']);
  });

  test('broadcast pagination accepts a database-collated first page', () async {
    final result = await fetchAllDesktopCalendarPages<String>(
      ({required limit, String? after}) async => ['apple-id', 'Zulu-id'],
      pageSize: 3,
      identityOf: (value) => value,
      compareCursor: (previous, next) => previous.compareTo(next),
      validateAfter: ({required after, required candidates}) async => true,
    );

    expect(result, ['apple-id', 'Zulu-id']);
  });

  test(
    'broadcast pagination validates continuation in database order',
    () async {
      final pages = <String?, List<String>>{
        null: ['apple-id'],
        'apple-id': ['Zulu-id'],
        'Zulu-id': const [],
      };
      final databaseOrder = {'apple-id': 0, 'Zulu-id': 1};

      final result = await fetchAllDesktopCalendarPages<String>(
        ({required limit, String? after}) async => pages[after]!,
        pageSize: 1,
        identityOf: (value) => value,
        compareCursor: (previous, next) => previous.compareTo(next),
        validateAfter:
            ({required after, required candidates}) async => candidates.every(
              (candidate) => databaseOrder[candidate]! > databaseOrder[after]!,
            ),
      );

      expect(result, ['apple-id', 'Zulu-id']);
    },
  );

  test('generic pagination still rejects an unordered page', () async {
    await expectLater(
      fetchAllDesktopCalendarPages<int>(
        ({required limit, int? after}) async => [2, 1],
        pageSize: 3,
        identityOf: (value) => value,
        compareCursor: (previous, next) => previous.compareTo(next),
      ),
      throwsStateError,
    );
  });

  test('database pagination rejects a previously visited boundary', () async {
    final pages = <String?, List<String>>{
      null: ['X', 'A'],
      'A': ['Y', 'B'],
      'B': ['A'],
    };

    await expectLater(
      fetchAllDesktopCalendarPages<String>(
        ({required limit, String? after}) async => pages[after] ?? const [],
        pageSize: 2,
        identityOf: (value) => value,
        compareCursor: (previous, next) => previous.compareTo(next),
        validateAfter: ({required after, required candidates}) async => true,
      ),
      throwsStateError,
    );
  });

  test('calendar pagination rejects a backward short name page', () async {
    final rows = {
      'initial': [calendarEvent('B'), calendarEvent('C')],
      'C': [calendarEvent('A')],
    };

    await expectLater(
      fetchAllDesktopCalendarNamePages<CalendarEvent>(
        ({required limit, String? afterName}) async =>
            (rows[afterName ?? 'initial'] ?? const []).take(limit).toList(),
        ({required name, required limit}) async =>
            [calendarEvent(name)].take(limit).toList(),
        pageSize: 2,
        validateNamesAfter: validateCodePointNamesAfter,
        nameOf: (event) => event.name,
        identityOf: (event) => event.fideEventId!,
      ),
      throwsStateError,
    );
  });

  test('calendar pagination rejects a cycle on a short name page', () async {
    final rows = {
      'initial': [calendarEvent('A'), calendarEvent('B')],
      'B': [calendarEvent('C'), calendarEvent('D')],
      'D': [calendarEvent('B')],
    };

    await expectLater(
      fetchAllDesktopCalendarNamePages<CalendarEvent>(
        ({required limit, String? afterName}) async =>
            (rows[afterName ?? 'initial'] ?? const []).take(limit).toList(),
        ({required name, required limit}) async =>
            [calendarEvent(name)].take(limit).toList(),
        pageSize: 2,
        validateNamesAfter: validateCodePointNamesAfter,
        nameOf: (event) => event.name,
        identityOf: (event) => event.fideEventId!,
      ),
      throwsStateError,
    );
  });

  test('pagination rejects a backward cursor on a short page', () async {
    await expectLater(
      fetchAllDesktopCalendarPages<int>(
        ({required limit, int? after}) async {
          if (after == null) return [1, 2];
          return [1];
        },
        pageSize: 2,
        identityOf: (value) => value,
        compareCursor: (previous, next) => previous.compareTo(next),
      ),
      throwsStateError,
    );
  });

  test('pagination rejects a multi-page cursor cycle', () async {
    await expectLater(
      fetchAllDesktopCalendarPages<int>(
        ({required limit, int? after}) async {
          if (after == null) return [1];
          if (after == 1) return [2];
          return [1];
        },
        pageSize: 1,
        identityOf: (value) => value,
        compareCursor: (previous, next) => previous.compareTo(next),
      ),
      throwsStateError,
    );
  });

  test('Major and FIDE loads do not query current broadcasts', () async {
    final source =
        _FakeCalendarDataSource()
          ..calendarRows = [
            calendarEvent('ordinary'),
            calendarEvent('major', major: true),
          ];
    final controller = DesktopCalendarDirectoryController(
      dataSource: source,
      now: () => DateTime.utc(2026, 8, 2),
    );
    addTearDown(controller.dispose);

    await controller.load(
      mode: DesktopCalendarMode.major,
      year: 2026,
      month: 8,
    );

    expect(source.calendarCalls, 1);
    expect(source.liveCalls, 0);
    expect(controller.state.value!.listings.map((event) => event.title), [
      'major',
    ]);
  });

  test('Follow Live queries only current broadcasts', () async {
    final source = _FakeCalendarDataSource()..liveRows = [broadcast('live')];
    final controller = DesktopCalendarDirectoryController(
      dataSource: source,
      now: () => DateTime.utc(2026, 8, 2),
    );
    addTearDown(controller.dispose);

    await controller.load(mode: DesktopCalendarMode.live, year: 2026, month: 8);

    expect(source.calendarCalls, 0);
    expect(source.liveCalls, 1);
    expect(
      controller.state.value!.listings.single.status,
      DesktopCalendarStatus.ongoing,
    );
  });

  test('a stale month response cannot repaint the newer month', () async {
    final source = _ControlledCalendarDataSource();
    final controller = DesktopCalendarDirectoryController(
      dataSource: source,
      now: () => DateTime.utc(2026, 8, 2),
    );
    addTearDown(controller.dispose);

    final august = controller.load(
      mode: DesktopCalendarMode.fide,
      year: 2026,
      month: 8,
    );
    final september = controller.load(
      mode: DesktopCalendarMode.fide,
      year: 2026,
      month: 9,
    );

    source.requests[9]!.complete([calendarEvent('september')]);
    await september;
    expect(controller.state.value!.month, 9);
    expect(controller.state.value!.listings.single.title, 'september');

    source.requests[8]!.complete([calendarEvent('august')]);
    await august;
    expect(controller.state.value!.month, 9);
    expect(controller.state.value!.listings.single.title, 'september');
  });

  test('quiet Live refresh preserves visible data while loading', () async {
    final source = _ControlledCalendarDataSource();
    final controller = DesktopCalendarDirectoryController(
      dataSource: source,
      now: () => DateTime.utc(2026, 8, 2),
    );
    addTearDown(controller.dispose);

    final initial = controller.load(
      mode: DesktopCalendarMode.live,
      year: 2026,
      month: 8,
    );
    source.liveRequests.removeAt(0).complete([broadcast('first')]);
    await initial;

    final refresh = controller.load(
      mode: DesktopCalendarMode.live,
      year: 2026,
      month: 8,
      quiet: true,
    );
    expect(controller.state.value!.listings.single.title, 'first');
    source.liveRequests.removeAt(0).complete([broadcast('second')]);
    await refresh;
    expect(controller.state.value!.listings.single.title, 'second');
  });
}

class _FakeCalendarDataSource implements DesktopCalendarDirectoryDataSource {
  List<CalendarEvent> calendarRows = const [];
  List<GroupBroadcast> liveRows = const [];
  int calendarCalls = 0;
  int liveCalls = 0;

  @override
  Future<List<CalendarEvent>> fetchCalendarMonth({
    required int year,
    required int month,
  }) async {
    calendarCalls++;
    return calendarRows;
  }

  @override
  Future<List<GroupBroadcast>> fetchCurrentBroadcasts() async {
    liveCalls++;
    return liveRows;
  }
}

class _ControlledCalendarDataSource
    implements DesktopCalendarDirectoryDataSource {
  final Map<int, Completer<List<CalendarEvent>>> requests = {};
  final List<Completer<List<GroupBroadcast>>> liveRequests = [];

  @override
  Future<List<CalendarEvent>> fetchCalendarMonth({
    required int year,
    required int month,
  }) {
    final completer = Completer<List<CalendarEvent>>();
    requests[month] = completer;
    return completer.future;
  }

  @override
  Future<List<GroupBroadcast>> fetchCurrentBroadcasts() {
    final completer = Completer<List<GroupBroadcast>>();
    liveRequests.add(completer);
    return completer.future;
  }
}
