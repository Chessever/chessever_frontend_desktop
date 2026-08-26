import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether the event feeds should query and rank live events first.
///
/// Lives in the data layer because the feed providers are the ones that turn
/// it into a query; the desktop "Live first" control mirrors its own persisted
/// preference into this provider rather than the providers reaching upwards
/// into desktop state. Flipping it re-runs the feed queries — the order the
/// user sees is always an order the server returned.
final liveFirstOrderingProvider = StateProvider<bool>((ref) => false);

/// Live IDs that are not already represented in [knownIds].
Set<String> missingLiveEventIds({
  required Iterable<String> knownIds,
  required Iterable<String> liveIds,
}) {
  final known = <String>{
    for (final id in knownIds)
      if (id.trim().isNotEmpty) id.trim(),
  };
  return {
    for (final id in liveIds)
      if (id.trim().isNotEmpty && !known.contains(id.trim())) id.trim(),
  };
}

/// Appends broadcasts whose ids are not already in [current], preserving the
/// established order of existing rows.
List<GroupBroadcast> appendUnknownBroadcasts({
  required List<GroupBroadcast> current,
  required Iterable<GroupBroadcast> incoming,
}) {
  if (incoming.isEmpty) return current;

  final knownIds = current.map((broadcast) => broadcast.id).toSet();
  final additions = <GroupBroadcast>[];
  for (final broadcast in incoming) {
    if (broadcast.id.isEmpty || !knownIds.add(broadcast.id)) continue;
    additions.add(broadcast);
  }
  if (additions.isEmpty) return current;
  return [...current, ...additions];
}

bool liveEventFeedUnchanged(
  List<GroupEventCardModel> current,
  List<GroupEventCardModel> next,
) {
  if (identical(current, next)) return true;
  if (current.length != next.length) return false;
  for (var i = 0; i < current.length; i++) {
    if (current[i].id != next[i].id) return false;
    if (current[i].tourEventCategory != next[i].tourEventCategory) {
      return false;
    }
  }
  return true;
}

/// Inserts [additions] that aren't already in [current] and refreshes live
/// categories from [liveIds] without changing the provider-owned source order.
///
/// Live-first is an optional presentation preference. Hydration must therefore
/// preserve the normal personalized order so disabling that preference can
/// immediately restore it. The display projection decides whether to promote
/// the live cohort.
List<GroupEventCardModel> mergeLiveEventsPreservingSourceOrder({
  required List<GroupEventCardModel> current,
  List<GroupEventCardModel> additions = const [],
  required Iterable<String> liveIds,
}) {
  final liveIdList = <String>[
    for (final id in liveIds)
      if (id.trim().isNotEmpty) id.trim(),
  ];

  final seen = <String>{};
  final merged = <GroupEventCardModel>[];

  void add(GroupEventCardModel event) {
    if (event.id.isEmpty || !seen.add(event.id)) return;
    merged.add(event.withLiveIds(liveIdList));
  }

  for (final event in current) {
    add(event);
  }
  for (final event in additions) {
    add(event);
  }

  return merged;
}

/// Ranks the server's live cohort ahead of the rest of a fetched page.
///
/// Both inputs are query results: [events] is the ranked page the feed asked
/// Supabase for, and [cohortIds] is `get_for_you_group_broadcasts` restricted
/// to the `live` status, in the server's own ranking. Ordering happens once,
/// here in the data layer, and the ordered list is what the provider
/// publishes — the widget layer renders it verbatim and never re-sorts at
/// paint time. Turning the preference off simply re-runs the query without a
/// cohort, so the canonical ranking comes back from the server rather than
/// from a remembered client-side copy.
///
/// Events not present in [events] are ignored; callers merge cohort rows into
/// the page first so a live event the feed has not paged in yet can still be
/// placed.
List<GroupEventCardModel> orderEventsByLiveCohort({
  required List<GroupEventCardModel> events,
  required Iterable<String> cohortIds,
}) {
  final rankById = <String, int>{};
  for (final id in cohortIds) {
    final trimmed = id.trim();
    if (trimmed.isEmpty || rankById.containsKey(trimmed)) continue;
    rankById[trimmed] = rankById.length;
  }
  if (rankById.isEmpty) return events;

  final promoted = <GroupEventCardModel>[];
  final rest = <GroupEventCardModel>[];
  for (final event in events) {
    if (rankById.containsKey(event.id)) {
      promoted.add(event);
    } else {
      rest.add(event);
    }
  }
  if (promoted.isEmpty) return events;

  promoted.sort((a, b) => rankById[a.id]!.compareTo(rankById[b.id]!));
  return <GroupEventCardModel>[...promoted, ...rest];
}
