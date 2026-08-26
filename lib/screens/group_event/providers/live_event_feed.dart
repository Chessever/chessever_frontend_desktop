import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/sorting_all_event_provider.dart';
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
/// Live-first is an optional preference that the feed queries answer, so
/// hydration must leave the personalized order it was given intact — turning
/// the preference off refetches, and anything reordered here would fight that
/// result. Promotion and rank belong to [orderEventsByLiveCohort].
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

/// Puts the live cohort first, strongest event first inside it.
///
/// Both inputs are query results: [events] is the ranked page the feed asked
/// Supabase for, and [cohortIds] is `get_for_you_group_broadcasts` restricted
/// to the `live` status. [cohortIds] decides *membership* only — which rows
/// are live — while the promoted block is ordered by
/// [compareGroupEventsByRating], so the strongest live event is always on top.
///
/// Membership and rank come from different places on purpose. The cohort is a
/// union of the ranked `live` slice and the realtime live-id stream, and that
/// second source arrives in whatever order the stream produced, so honouring
/// arrival order would drop an unranked event above a stronger one. Ranking on
/// `maxAvgElo` — a column that came back on these same query rows — makes the
/// order well-defined no matter which source found the event.
///
/// Ordering happens once, here in the data layer, and the ordered list is what
/// the provider publishes — the widget layer renders it verbatim and never
/// re-sorts at paint time. Turning the preference off re-runs the query with
/// no cohort, so the canonical ranking comes back from the server rather than
/// from a remembered client-side copy.
///
/// Events not present in [events] are ignored; callers merge cohort rows into
/// the page first so a live event the feed has not paged in yet can still be
/// placed.
List<GroupEventCardModel> orderEventsByLiveCohort({
  required List<GroupEventCardModel> events,
  required Iterable<String> cohortIds,
}) {
  final cohort = <String>{
    for (final id in cohortIds)
      if (id.trim().isNotEmpty) id.trim(),
  };
  if (cohort.isEmpty) return events;

  final promoted = <GroupEventCardModel>[];
  final rest = <GroupEventCardModel>[];
  for (final event in events) {
    if (cohort.contains(event.id)) {
      promoted.add(event);
    } else {
      rest.add(event);
    }
  }
  if (promoted.isEmpty) return events;

  promoted.sort(compareGroupEventsByRating);
  return <GroupEventCardModel>[...promoted, ...rest];
}
