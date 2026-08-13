enum DesktopCalendarMode { live, major, fide }

enum DesktopCalendarSource { broadcast, fide }

enum DesktopCalendarStatus { live, ongoing, upcoming, past }

class DesktopCalendarListing {
  const DesktopCalendarListing({
    required this.id,
    required this.title,
    required this.source,
    required this.status,
    this.isMajorEvent = false,
    this.isLiveNow = false,
    this.startDate,
    this.endDate,
    this.timeControls = const [],
    this.location,
    this.countryCode,
    this.topPlayers = const [],
    this.searchTerms = const [],
    this.broadcastId,
    this.fideEventId,
    this.websiteUrl,
    this.imageUrl,
    this.description,
    this.maxAvgElo = 0,
    this.sectionCount = 1,
  });

  final String id;
  final String title;
  final DesktopCalendarSource source;
  final DesktopCalendarStatus status;
  final bool isMajorEvent;
  final bool isLiveNow;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<String> timeControls;
  final String? location;
  final String? countryCode;
  final List<String> topPlayers;
  final List<String> searchTerms;
  final String? broadcastId;
  final String? fideEventId;
  final String? websiteUrl;
  final String? imageUrl;
  final String? description;
  final int maxAvgElo;
  final int sectionCount;

  DesktopCalendarListing withLiveNow(bool value) {
    if (value == isLiveNow) return this;
    return DesktopCalendarListing(
      id: id,
      title: title,
      source: source,
      status: status,
      isMajorEvent: isMajorEvent,
      isLiveNow: value,
      startDate: startDate,
      endDate: endDate,
      timeControls: timeControls,
      location: location,
      countryCode: countryCode,
      topPlayers: topPlayers,
      searchTerms: searchTerms,
      broadcastId: broadcastId,
      fideEventId: fideEventId,
      websiteUrl: websiteUrl,
      imageUrl: imageUrl,
      description: description,
      maxAvgElo: maxAvgElo,
      sectionCount: sectionCount,
    );
  }
}

String desktopCalendarStableFideId({
  required String? fideEventId,
  required String title,
  required DateTime? startDate,
}) {
  final trimmedFideId = fideEventId?.trim() ?? '';
  if (trimmedFideId.isNotEmpty) {
    return 'calendar:fide:$trimmedFideId';
  }

  final normalizedTitle = title
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final date =
      startDate == null
          ? 'undated'
          : '${startDate.year.toString().padLeft(4, '0')}-'
              '${startDate.month.toString().padLeft(2, '0')}-'
              '${startDate.day.toString().padLeft(2, '0')}';
  final safeTitle =
      normalizedTitle.isEmpty
          ? 'chess-event-${_stableCalendarHash(title.trim().toLowerCase())}'
          : normalizedTitle;
  return 'calendar:fide-fallback:$safeTitle:$date';
}

String _stableCalendarHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

List<DesktopCalendarListing> filterDesktopCalendarMode(
  Iterable<DesktopCalendarListing> listings,
  DesktopCalendarMode mode,
) {
  return listings
      .where((listing) {
        return switch (mode) {
          DesktopCalendarMode.live =>
            listing.source == DesktopCalendarSource.broadcast &&
                (listing.status == DesktopCalendarStatus.live ||
                    listing.status == DesktopCalendarStatus.ongoing),
          DesktopCalendarMode.major =>
            listing.source == DesktopCalendarSource.fide &&
                listing.isMajorEvent,
          DesktopCalendarMode.fide =>
            listing.source == DesktopCalendarSource.fide,
        };
      })
      .toList(growable: false);
}

bool desktopCalendarOverlapsMonth(
  DesktopCalendarListing listing,
  int year,
  int month,
) {
  final monthStart = DateTime.utc(year, month);
  final monthEnd = DateTime.utc(
    year,
    month + 1,
  ).subtract(const Duration(microseconds: 1));
  return _desktopCalendarOverlapsRange(listing, monthStart, monthEnd);
}

bool desktopCalendarOverlapsDay(DesktopCalendarListing listing, DateTime day) {
  final dayStart = DateTime.utc(day.year, day.month, day.day);
  final dayEnd = dayStart
      .add(const Duration(days: 1))
      .subtract(const Duration(microseconds: 1));
  return _desktopCalendarOverlapsRange(listing, dayStart, dayEnd);
}

List<DesktopCalendarListing> filterDesktopCalendarListings(
  Iterable<DesktopCalendarListing> listings, {
  required DesktopCalendarMode mode,
  required int year,
  required int month,
  String query = '',
  String? timeControl,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final normalizedTimeControl = timeControl?.trim().toLowerCase() ?? '';

  return filterDesktopCalendarMode(listings, mode)
      .where((listing) {
        if (mode != DesktopCalendarMode.live &&
            !desktopCalendarOverlapsMonth(listing, year, month)) {
          return false;
        }

        if (normalizedTimeControl.isNotEmpty &&
            !listing.timeControls.any(
              (value) => value.trim().toLowerCase() == normalizedTimeControl,
            )) {
          return false;
        }

        if (normalizedQuery.isEmpty) return true;
        final haystack =
            <String>[
              listing.title,
              if (listing.location != null) listing.location!,
              if (listing.countryCode != null) listing.countryCode!,
              ...listing.topPlayers,
              ...listing.searchTerms,
            ].join(' ').toLowerCase();
        return haystack.contains(normalizedQuery);
      })
      .toList(growable: false);
}

bool _desktopCalendarOverlapsRange(
  DesktopCalendarListing listing,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final start = listing.startDate ?? listing.endDate;
  final end = listing.endDate ?? listing.startDate;
  if (start == null || end == null) return false;
  final dateStart = _desktopCalendarDateOnly(start);
  final dateEnd = _desktopCalendarDateOnly(end);
  return !dateEnd.isBefore(_desktopCalendarDateOnly(rangeStart)) &&
      !dateStart.isAfter(_desktopCalendarDateOnly(rangeEnd));
}

class DesktopCalendarDayGroup {
  const DesktopCalendarDayGroup({required this.date, required this.listings});

  final DateTime date;
  final List<DesktopCalendarListing> listings;
}

class DesktopCalendarAgenda {
  const DesktopCalendarAgenda({
    required this.upcoming,
    required this.earlier,
    required this.startedBeforeMonth,
  });

  final List<DesktopCalendarDayGroup> upcoming;
  final List<DesktopCalendarDayGroup> earlier;
  final List<DesktopCalendarListing> startedBeforeMonth;
}

DesktopCalendarAgenda buildDesktopCalendarAgenda(
  Iterable<DesktopCalendarListing> listings, {
  required int year,
  required int month,
  required DateTime now,
}) {
  final monthStart = DateTime.utc(year, month);
  final monthLastDay = DateTime.utc(year, month + 1, 0);
  final today = _desktopCalendarDateOnly(now);
  final selectedMonth = year * 12 + month;
  final currentMonth = today.year * 12 + today.month;
  final anchor =
      selectedMonth == currentMonth
          ? today
          : selectedMonth > currentMonth
          ? monthStart
          : monthLastDay;

  final startedBefore = <DesktopCalendarListing>[];
  final byDate = <DateTime, List<DesktopCalendarListing>>{};
  for (final listing in listings) {
    if (!desktopCalendarOverlapsMonth(listing, year, month)) continue;
    final start = listing.startDate ?? listing.endDate;
    if (start == null) continue;
    final date = _desktopCalendarDateOnly(start);
    if (date.isBefore(monthStart)) {
      startedBefore.add(listing);
      continue;
    }
    byDate.putIfAbsent(date, () => <DesktopCalendarListing>[]).add(listing);
  }

  final groups =
      byDate.entries.map((entry) {
        final events = [...entry.value]..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        return DesktopCalendarDayGroup(
          date: entry.key,
          listings: List.unmodifiable(events),
        );
      }).toList();
  final upcoming =
      groups.where((group) => !group.date.isBefore(anchor)).toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  final earlier =
      groups.where((group) => group.date.isBefore(anchor)).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
  startedBefore.sort((a, b) {
    final aDate = a.startDate ?? a.endDate;
    final bDate = b.startDate ?? b.endDate;
    if (aDate == null && bDate == null) return 0;
    if (aDate == null) return 1;
    if (bDate == null) return -1;
    return _desktopCalendarDateOnly(
      bDate,
    ).compareTo(_desktopCalendarDateOnly(aDate));
  });

  return DesktopCalendarAgenda(
    upcoming: List.unmodifiable(upcoming),
    earlier: List.unmodifiable(earlier),
    startedBeforeMonth: List.unmodifiable(startedBefore),
  );
}

List<DesktopCalendarListing> buildDesktopCalendarNavigationSequence(
  Iterable<DesktopCalendarListing> listings, {
  required DesktopCalendarMode mode,
  required int year,
  required int month,
  required int? selectedDay,
  required DateTime now,
}) {
  final visible = listings.toList(growable: false);
  if (mode == DesktopCalendarMode.live) return visible;
  if (selectedDay != null) {
    final date = DateTime(year, month, selectedDay);
    return visible
        .where((listing) => desktopCalendarOverlapsDay(listing, date))
        .toList(growable: false);
  }

  final agenda = buildDesktopCalendarAgenda(
    visible,
    year: year,
    month: month,
    now: now,
  );
  return [
    for (final group in agenda.upcoming) ...group.listings,
    for (final group in agenda.earlier) ...group.listings,
    ...agenda.startedBeforeMonth,
  ];
}

DateTime _desktopCalendarDateOnly(DateTime value) {
  return DateTime.utc(value.year, value.month, value.day);
}
