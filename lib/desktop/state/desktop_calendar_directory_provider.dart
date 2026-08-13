import 'dart:async';

import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_listing_mapper.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const desktopCalendarPageSize = 250;
const desktopCalendarMaxNameBoundaryGroupSize = 500;
const desktopCalendarLiveRefreshInterval = Duration(minutes: 2);

typedef DesktopCalendarPageFetcher<T> =
    Future<List<T>> Function({required int limit, T? after});
typedef DesktopCalendarCursorValidator<T> =
    Future<bool> Function({required T after, required Set<T> candidates});

Future<List<T>> fetchAllDesktopCalendarPages<T>(
  DesktopCalendarPageFetcher<T> fetchPage, {
  int pageSize = desktopCalendarPageSize,
  required Object Function(T value) identityOf,
  required int Function(T previous, T next) compareCursor,
  DesktopCalendarCursorValidator<T>? validateAfter,
}) async {
  assert(pageSize > 0);
  final result = <T>[];
  final seen = <Object>{};
  final visitedBoundaries = <Object>{};
  T? cursor;
  while (true) {
    final page = await fetchPage(limit: pageSize, after: cursor);
    if (validateAfter == null) {
      for (var index = 1; index < page.length; index++) {
        if (compareCursor(page[index - 1], page[index]) > 0) {
          throw StateError('Calendar keyset page is not ordered');
        }
      }
    }
    if (page.isNotEmpty && cursor != null) {
      final cursorIdentity = identityOf(cursor);
      final firstIdentity = identityOf(page.first);
      final lastIdentity = identityOf(page.last);
      if ((visitedBoundaries.contains(firstIdentity) &&
              firstIdentity != cursorIdentity) ||
          visitedBoundaries.contains(lastIdentity)) {
        throw StateError('Calendar keyset page repeated a boundary');
      }
      final advanced =
          validateAfter == null
              ? compareCursor(cursor, page.last) < 0
              : await validateAfter(
                after: cursor,
                candidates: {page.first, page.last},
              );
      if (!advanced) {
        throw StateError('Calendar keyset page did not advance');
      }
    }
    for (final value in page) {
      if (seen.add(identityOf(value))) result.add(value);
    }
    if (page.length < pageSize) break;
    if (!visitedBoundaries.add(identityOf(page.last))) {
      throw StateError('Calendar keyset page repeated a boundary');
    }
    cursor = page.last;
  }
  return result;
}

typedef DesktopCalendarNamePageFetcher<T> =
    Future<List<T>> Function({required int limit, String? afterName});
typedef DesktopCalendarNameGroupFetcher<T> =
    Future<List<T>> Function({required String name, required int limit});
typedef DesktopCalendarNameCursorValidator =
    Future<bool> Function({
      required String afterName,
      required Set<String> candidateNames,
    });

Future<List<T>> fetchAllDesktopCalendarNamePages<T>(
  DesktopCalendarNamePageFetcher<T> fetchPage,
  DesktopCalendarNameGroupFetcher<T> fetchNameGroup, {
  required DesktopCalendarNameCursorValidator validateNamesAfter,
  int pageSize = desktopCalendarPageSize,
  int maxNameGroupSize = desktopCalendarMaxNameBoundaryGroupSize,
  required String Function(T value) nameOf,
  required Object Function(T value) identityOf,
}) async {
  assert(pageSize > 0);
  assert(maxNameGroupSize > 0);
  final result = <T>[];
  final seen = <Object>{};
  final visitedBoundaryNames = <String>{};
  String? cursorName;

  void add(Iterable<T> values) {
    for (final value in values) {
      if (seen.add(identityOf(value))) result.add(value);
    }
  }

  while (true) {
    final page = await fetchPage(limit: pageSize, afterName: cursorName);
    // Supabase/Postgres owns name ordering and comparison collation. Dart's
    // String.compareTo uses Unicode code-point order, so continuation pages
    // are validated through the repository under the database's own `gt`
    // semantics. First and last cover the ordered page's range.
    if (cursorName != null && page.isNotEmpty) {
      final candidateNames = {nameOf(page.first), nameOf(page.last)};
      if (candidateNames.contains(cursorName) ||
          candidateNames.any(visitedBoundaryNames.contains) ||
          !await validateNamesAfter(
            afterName: cursorName,
            candidateNames: candidateNames,
          )) {
        throw StateError('Calendar name page did not advance');
      }
    }
    if (page.length < pageSize) {
      add(page);
      break;
    }

    final boundaryName = nameOf(page.last);
    if (!visitedBoundaryNames.add(boundaryName)) {
      throw StateError('Calendar name pagination repeated a boundary');
    }
    add(page.where((value) => nameOf(value) != boundaryName));
    final boundaryRows = await fetchNameGroup(
      name: boundaryName,
      limit: maxNameGroupSize + 1,
    );
    if (boundaryRows.isEmpty ||
        boundaryRows.any((value) => nameOf(value) != boundaryName)) {
      throw StateError('Calendar name-boundary query was inconsistent');
    }
    if (boundaryRows.length > maxNameGroupSize) {
      throw StateError('Calendar name-boundary group exceeds the safe limit');
    }
    add(boundaryRows);
    cursorName = boundaryName;
  }
  return result;
}

abstract interface class DesktopCalendarDirectoryDataSource {
  Future<List<CalendarEvent>> fetchCalendarMonth({
    required int year,
    required int month,
  });

  Future<List<GroupBroadcast>> fetchCurrentBroadcasts();
}

class RepositoryDesktopCalendarDirectoryDataSource
    implements DesktopCalendarDirectoryDataSource {
  RepositoryDesktopCalendarDirectoryDataSource({
    required this.calendarRepository,
    required this.broadcastRepository,
  });

  final CalendarEventRepository calendarRepository;
  final GroupBroadcastRepository broadcastRepository;

  @override
  Future<List<CalendarEvent>> fetchCalendarMonth({
    required int year,
    required int month,
  }) {
    return fetchAllDesktopCalendarNamePages<CalendarEvent>(
      ({required limit, String? afterName}) =>
          calendarRepository.getCalendarEventsForMonth(
            selectedYear: year,
            selectedMonth: month,
            limit: limit,
            orderBy: 'name',
            ascending: true,
            afterName: afterName,
          ),
      ({required name, required limit}) =>
          calendarRepository.getCalendarEventsForMonthByName(
            selectedYear: year,
            selectedMonth: month,
            name: name,
            limit: limit,
          ),
      validateNamesAfter:
          ({required afterName, required candidateNames}) =>
              calendarRepository.areCalendarEventNamesAfter(
                afterName: afterName,
                candidateNames: candidateNames,
              ),
      nameOf: (event) => event.name,
      identityOf:
          (event) => (
            event.fideEventId,
            event.name,
            event.startDate,
            event.endDate,
            event.location,
            event.createdAt,
          ),
    );
  }

  @override
  Future<List<GroupBroadcast>> fetchCurrentBroadcasts() {
    return fetchAllDesktopCalendarPages<GroupBroadcast>(
      ({required limit, GroupBroadcast? after}) =>
          broadcastRepository.getCurrentGroupBroadcasts(
            limit: limit,
            orderBy: 'id',
            ascending: true,
            afterId: after?.id,
          ),
      identityOf: (broadcast) => broadcast.id,
      compareCursor: (previous, next) => previous.id.compareTo(next.id),
      validateAfter:
          ({required after, required candidates}) =>
              broadcastRepository.areCurrentGroupBroadcastIdsAfter(
                afterId: after.id,
                candidateIds: {
                  for (final candidate in candidates) candidate.id,
                },
              ),
    );
  }
}

class DesktopCalendarDirectoryState {
  const DesktopCalendarDirectoryState({
    required this.mode,
    required this.year,
    required this.month,
    required this.listings,
    required this.calendarEventsById,
    required this.loadedAt,
  });

  final DesktopCalendarMode mode;
  final int year;
  final int month;
  final List<DesktopCalendarListing> listings;
  final Map<String, CalendarEvent> calendarEventsById;
  final DateTime loadedAt;
}

class DesktopCalendarDirectoryController
    extends StateNotifier<AsyncValue<DesktopCalendarDirectoryState>> {
  DesktopCalendarDirectoryController({
    required DesktopCalendarDirectoryDataSource dataSource,
    DateTime Function()? now,
    this.liveRefreshInterval = desktopCalendarLiveRefreshInterval,
  }) : _dataSource = dataSource,
       _now = now ?? DateTime.now,
       super(const AsyncValue.loading());

  final DesktopCalendarDirectoryDataSource _dataSource;
  final DateTime Function() _now;
  final Duration liveRefreshInterval;
  Timer? _liveRefreshTimer;
  int _requestGeneration = 0;

  Future<void> load({
    required DesktopCalendarMode mode,
    required int year,
    required int month,
    bool quiet = false,
  }) async {
    final generation = ++_requestGeneration;
    _scheduleLiveRefresh(mode: mode, year: year, month: month);
    if (!quiet || !state.hasValue) {
      state = const AsyncValue.loading();
    }

    try {
      final now = _now();
      final List<DesktopCalendarListing> listings;
      final Map<String, CalendarEvent> calendarEventsById;

      if (mode == DesktopCalendarMode.live) {
        final broadcasts = await _dataSource.fetchCurrentBroadcasts();
        listings = broadcasts
          .map(
            (broadcast) => desktopCalendarListingFromGroupBroadcast(
              broadcast,
              isCurrent: true,
              isLiveNow: false,
              now: now,
            ),
          )
          .toList(growable: false)..sort((a, b) {
          final rating = b.maxAvgElo.compareTo(a.maxAvgElo);
          return rating != 0
              ? rating
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
        calendarEventsById = const {};
      } else {
        final rows = await _dataSource.fetchCalendarMonth(
          year: year,
          month: month,
        );
        final mapped = rows
            .map(
              (event) =>
                  desktopCalendarListingFromCalendarEvent(event, now: now),
            )
            .toList(growable: false);
        final reconciled = reconcileDesktopCalendarListings(mapped);
        listings = filterDesktopCalendarMode(reconciled, mode)..sort((a, b) {
          final aDate = a.startDate ?? a.endDate;
          final bDate = b.startDate ?? b.endDate;
          if (aDate == null && bDate == null) {
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          if (aDate == null) return 1;
          if (bDate == null) return -1;
          final date = aDate.compareTo(bDate);
          return date != 0
              ? date
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
        calendarEventsById = _calendarEventsByStableId(rows);
      }

      if (!mounted || generation != _requestGeneration) return;
      state = AsyncValue.data(
        DesktopCalendarDirectoryState(
          mode: mode,
          year: year,
          month: month,
          listings: List.unmodifiable(listings),
          calendarEventsById: Map.unmodifiable(calendarEventsById),
          loadedAt: now,
        ),
      );
    } catch (error, stackTrace) {
      if (!mounted || generation != _requestGeneration) return;
      if (quiet && state.hasValue) {
        debugPrint('Desktop Calendar quiet refresh failed: $error');
        return;
      }
      state = AsyncValue.error(error, stackTrace);
    }
  }

  void _scheduleLiveRefresh({
    required DesktopCalendarMode mode,
    required int year,
    required int month,
  }) {
    _liveRefreshTimer?.cancel();
    if (mode != DesktopCalendarMode.live) return;
    _liveRefreshTimer = Timer(liveRefreshInterval, () {
      unawaited(load(mode: mode, year: year, month: month, quiet: true));
    });
  }

  Map<String, CalendarEvent> _calendarEventsByStableId(
    Iterable<CalendarEvent> rows,
  ) {
    final result = <String, CalendarEvent>{};
    for (final event in rows) {
      final id = desktopCalendarStableFideId(
        fideEventId: event.fideEventId,
        title: cleanDesktopCalendarEventTitle(event.name),
        startDate: event.startDate,
      );
      final existing = result[id];
      if (existing == null || (existing.isMajorEvent && !event.isMajorEvent)) {
        result[id] = event;
      }
    }
    return result;
  }

  @override
  void dispose() {
    _requestGeneration++;
    _liveRefreshTimer?.cancel();
    super.dispose();
  }
}

final desktopCalendarModeProvider = StateProvider<DesktopCalendarMode>(
  (ref) => DesktopCalendarMode.major,
);
final desktopCalendarSearchQueryProvider = StateProvider<String>((ref) => '');
final desktopCalendarTimeControlProvider = StateProvider<String?>(
  (ref) => null,
);

final desktopCalendarDirectoryDataSourceProvider =
    AutoDisposeProvider<DesktopCalendarDirectoryDataSource>((ref) {
      return RepositoryDesktopCalendarDirectoryDataSource(
        calendarRepository: ref.read(calendarEventRepositoryProvider),
        broadcastRepository: ref.read(groupBroadcastRepositoryProvider),
      );
    });

final desktopCalendarDirectoryProvider = AutoDisposeStateNotifierProvider<
  DesktopCalendarDirectoryController,
  AsyncValue<DesktopCalendarDirectoryState>
>((ref) {
  final controller = DesktopCalendarDirectoryController(
    dataSource: ref.read(desktopCalendarDirectoryDataSourceProvider),
  );

  void loadCurrent() {
    unawaited(
      controller.load(
        mode: ref.read(desktopCalendarModeProvider),
        year: ref.read(selectedYearProvider),
        month: ref.read(selectedMonthProvider),
      ),
    );
  }

  ref.listen<DesktopCalendarMode>(desktopCalendarModeProvider, (_, __) {
    loadCurrent();
  });
  ref.listen<int>(selectedYearProvider, (_, __) {
    loadCurrent();
  });
  ref.listen<int>(selectedMonthProvider, (_, __) {
    loadCurrent();
  });
  Future<void>.microtask(loadCurrent);
  return controller;
});

final desktopCalendarVisibleListingsProvider =
    Provider<AsyncValue<List<DesktopCalendarListing>>>((ref) {
      final query = ref.watch(desktopCalendarSearchQueryProvider);
      final timeControl = ref.watch(desktopCalendarTimeControlProvider);
      final liveIds =
          ref.watch(liveGroupBroadcastIdsProvider).valueOrNull?.toSet() ??
          const <String>{};
      return ref.watch(desktopCalendarDirectoryProvider).whenData((directory) {
        final filtered = filterDesktopCalendarListings(
          directory.listings,
          mode: directory.mode,
          year: directory.year,
          month: directory.month,
          query: query,
          timeControl: timeControl,
        );
        return filtered
            .map(
              (listing) =>
                  listing.source == DesktopCalendarSource.broadcast
                      ? listing.withLiveNow(
                        liveIds.contains(listing.broadcastId),
                      )
                      : listing,
            )
            .toList(growable: false);
      });
    });
