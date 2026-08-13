import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';

DesktopCalendarListing desktopCalendarListingFromCalendarEvent(
  CalendarEvent event, {
  required DateTime now,
}) {
  final title = cleanDesktopCalendarEventTitle(event.name);
  final fideEventId = _trimmedOrNull(event.fideEventId);
  final location = _firstNonEmpty([event.location, event.city, event.venue]);
  final countryCode = _trimmedOrNull(event.countryCode)?.toUpperCase();
  final topPlayers = desktopCalendarTopPlayers(event.players);
  final searchTerms = _uniqueStrings([
    if (location != null) location,
    if (countryCode != null) countryCode,
    if (_trimmedOrNull(event.country) case final country?) country,
    if (_trimmedOrNull(event.city) case final city?) city,
    if (_trimmedOrNull(event.venue) case final venue?) venue,
  ]);

  return DesktopCalendarListing(
    id: desktopCalendarStableFideId(
      fideEventId: fideEventId,
      title: title,
      startDate: event.startDate,
    ),
    title: title,
    source: DesktopCalendarSource.fide,
    status: _calendarEventStatus(event, now),
    isMajorEvent: event.isMajorEvent || event.isMajorUpcomingEvent,
    startDate: event.startDate,
    endDate: event.endDate,
    timeControls: desktopCalendarTimeControls(event.timeControl),
    location: location,
    countryCode: countryCode,
    topPlayers: topPlayers,
    searchTerms: searchTerms,
    fideEventId: fideEventId,
    websiteUrl: _firstNonEmpty([event.websiteUrl, event.website]),
    imageUrl: _trimmedOrNull(event.imageUrl),
    description: _trimmedOrNull(event.description),
  );
}

DesktopCalendarListing desktopCalendarListingFromGroupBroadcast(
  GroupBroadcast broadcast, {
  required bool isCurrent,
  required bool isLiveNow,
  required DateTime now,
}) {
  return DesktopCalendarListing(
    id: 'broadcast:${broadcast.id}',
    title:
        broadcast.name.trim().isEmpty
            ? 'Chess broadcast'
            : broadcast.name.trim(),
    source: DesktopCalendarSource.broadcast,
    status: _broadcastStatus(broadcast, isCurrent: isCurrent, now: now),
    isLiveNow: isLiveNow,
    startDate: broadcast.dateStart,
    endDate: broadcast.dateEnd,
    timeControls: desktopCalendarTimeControls(broadcast.timeControl),
    searchTerms: _uniqueStrings(broadcast.search),
    broadcastId: broadcast.id,
    maxAvgElo: broadcast.maxAvgElo ?? 0,
  );
}

List<DesktopCalendarListing> reconcileDesktopCalendarListings(
  Iterable<DesktopCalendarListing> listings,
) {
  final byIdentity = <String, DesktopCalendarListing>{};
  final anonymousByFamily = <String, DesktopCalendarListing>{};

  for (final listing in listings) {
    final isAnonymousFide =
        listing.source == DesktopCalendarSource.fide &&
        listing.fideEventId == null;
    if (isAnonymousFide) {
      final family = _fideFamilyKey(listing);
      final existing = anonymousByFamily[family];
      anonymousByFamily[family] =
          existing == null
              ? listing
              : _mergeDesktopCalendarListings(
                existing,
                listing,
                identity: existing.id,
              );
      continue;
    }

    final existing = byIdentity[listing.id];
    byIdentity[listing.id] =
        existing == null
            ? listing
            : _mergeDesktopCalendarListings(
              existing,
              listing,
              identity: existing.id,
            );
  }

  final authoritativeByFamily = <String, List<String>>{};
  for (final listing in byIdentity.values) {
    if (listing.source != DesktopCalendarSource.fide ||
        listing.fideEventId == null) {
      continue;
    }
    authoritativeByFamily
        .putIfAbsent(_fideFamilyKey(listing), () => <String>[])
        .add(listing.id);
  }

  for (final entry in anonymousByFamily.entries) {
    final authoritativeIds = authoritativeByFamily[entry.key] ?? const [];
    if (authoritativeIds.length == 1) {
      final identity = authoritativeIds.single;
      byIdentity[identity] = _mergeDesktopCalendarListings(
        byIdentity[identity]!,
        entry.value,
        identity: identity,
      );
    } else {
      final existing = byIdentity[entry.value.id];
      byIdentity[entry.value.id] =
          existing == null
              ? entry.value
              : _mergeDesktopCalendarListings(
                existing,
                entry.value,
                identity: existing.id,
              );
    }
  }

  return byIdentity.values.toList(growable: false);
}

DesktopCalendarListing _mergeDesktopCalendarListings(
  DesktopCalendarListing existing,
  DesktopCalendarListing listing, {
  required String identity,
}) {
  // Match the website's canonical-row preference: when the first row is a
  // major marker and a non-marker duplicate follows, keep the non-marker's
  // primary fields while OR-ing major state and filling absent metadata.
  final canonical =
      existing.isMajorEvent && !listing.isMajorEvent ? listing : existing;
  final supplement = identical(canonical, existing) ? listing : existing;
  return DesktopCalendarListing(
    id: identity,
    title: canonical.title,
    source: canonical.source,
    status: canonical.status,
    isMajorEvent: existing.isMajorEvent || listing.isMajorEvent,
    isLiveNow: existing.isLiveNow || listing.isLiveNow,
    startDate: _earliestDate(existing.startDate, listing.startDate),
    endDate: _latestDate(existing.endDate, listing.endDate),
    timeControls: _uniqueStrings([
      ...canonical.timeControls,
      ...supplement.timeControls,
    ]),
    location: canonical.location ?? supplement.location,
    countryCode: canonical.countryCode ?? supplement.countryCode,
    topPlayers: _uniqueStrings([
      ...canonical.topPlayers,
      ...supplement.topPlayers,
    ]).take(4).toList(growable: false),
    searchTerms: _uniqueStrings([
      ...canonical.searchTerms,
      ...supplement.searchTerms,
    ]),
    broadcastId: canonical.broadcastId ?? supplement.broadcastId,
    fideEventId: canonical.fideEventId ?? supplement.fideEventId,
    websiteUrl: canonical.websiteUrl ?? supplement.websiteUrl,
    imageUrl: canonical.imageUrl ?? supplement.imageUrl,
    description: canonical.description ?? supplement.description,
    maxAvgElo:
        canonical.maxAvgElo > supplement.maxAvgElo
            ? canonical.maxAvgElo
            : supplement.maxAvgElo,
    sectionCount:
        canonical.sectionCount > supplement.sectionCount
            ? canonical.sectionCount
            : supplement.sectionCount,
  );
}

String _fideFamilyKey(DesktopCalendarListing listing) {
  final title = cleanDesktopCalendarEventTitle(listing.title).toLowerCase();
  final country = listing.countryCode?.trim().toLowerCase() ?? '';
  final location = listing.location?.trim().toLowerCase() ?? '';
  return '$title|$country|$location';
}

DateTime? _earliestDate(DateTime? first, DateTime? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first.isBefore(second) ? first : second;
}

DateTime? _latestDate(DateTime? first, DateTime? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first.isAfter(second) ? first : second;
}

String cleanDesktopCalendarEventTitle(String value) {
  final cleaned = value.trim().replaceFirst(RegExp(r'\s+\*+\s*$'), '').trim();
  return cleaned.isEmpty ? 'Chess event' : cleaned;
}

List<String> desktopCalendarTimeControls(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return const [];
  final lower = value.toLowerCase();
  final result = <String>[];
  if (lower.contains('classic') || lower.contains('standard')) {
    result.add('Classical');
  }
  if (lower.contains('rapid')) result.add('Rapid');
  if (lower.contains('blitz')) result.add('Blitz');
  if (lower.contains('bullet')) result.add('Bullet');
  if (result.isNotEmpty) return List.unmodifiable(result);
  return ['${value[0].toUpperCase()}${value.substring(1)}'];
}

List<String> desktopCalendarTopPlayers(List<dynamic>? players) {
  final parsed = <({String name, int rating})>[];
  for (final player in players ?? const <dynamic>[]) {
    if (player is String) {
      final name = _trimmedOrNull(player);
      if (name != null) parsed.add((name: name, rating: 0));
      continue;
    }
    if (player is! Map) continue;
    final name = _trimmedOrNull(player['name']?.toString());
    if (name == null) continue;
    final ratingValue = player['rating'];
    final rating =
        ratingValue is num
            ? ratingValue.toInt()
            : int.tryParse(ratingValue?.toString() ?? '') ?? 0;
    parsed.add((name: name, rating: rating));
  }
  parsed.sort((a, b) => b.rating.compareTo(a.rating));
  return parsed.take(4).map((player) => player.name).toList(growable: false);
}

DesktopCalendarStatus _calendarEventStatus(CalendarEvent event, DateTime now) {
  final end = event.endDate ?? event.startDate;
  if (end == null) return DesktopCalendarStatus.upcoming;
  return _dateOnly(end).isBefore(_dateOnly(now))
      ? DesktopCalendarStatus.past
      : DesktopCalendarStatus.upcoming;
}

DesktopCalendarStatus _broadcastStatus(
  GroupBroadcast broadcast, {
  required bool isCurrent,
  required DateTime now,
}) {
  if (isCurrent) return DesktopCalendarStatus.ongoing;
  final today = _dateOnly(now);
  final start =
      broadcast.dateStart == null ? null : _dateOnly(broadcast.dateStart!);
  final end = broadcast.dateEnd == null ? null : _dateOnly(broadcast.dateEnd!);
  if (start != null && today.isBefore(start)) {
    return DesktopCalendarStatus.upcoming;
  }
  if (end != null && today.isAfter(end)) {
    return DesktopCalendarStatus.past;
  }
  return DesktopCalendarStatus.ongoing;
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = _trimmedOrNull(value);
    if (trimmed != null) return trimmed;
  }
  return null;
}

List<String> _uniqueStrings(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    final key = trimmed.toLowerCase();
    if (seen.add(key)) result.add(trimmed);
  }
  return List.unmodifiable(result);
}
