import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';

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

/// Inserts [additions] that aren't already in [current], refreshes live
/// categories from [liveIds], and promotes events that just went live.
///
/// Newly live rows (including ones that were already on the page as upcoming /
/// ongoing) move to the front as a cohort. Events that were already live keep
/// their relative order after that cohort, and everything else keeps its
/// relative order. This is how a Titled Tuesday that starts while the home
/// feed is open can appear without a restart, without shuffling siblings whose
/// ranking merely jittered.
List<GroupEventCardModel> mergeAndPromoteLiveEvents({
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

  if (liveIdList.isEmpty) return merged;

  final previouslyLiveIds = <String>{
    for (final event in current)
      if (event.tourEventCategory == TourEventCategory.live) event.id,
  };

  final newlyLive = <GroupEventCardModel>[];
  final alreadyLive = <GroupEventCardModel>[];
  final rest = <GroupEventCardModel>[];
  for (final event in merged) {
    if (event.tourEventCategory != TourEventCategory.live) {
      rest.add(event);
      continue;
    }
    if (previouslyLiveIds.contains(event.id)) {
      alreadyLive.add(event);
    } else {
      newlyLive.add(event);
    }
  }

  return [...newlyLive, ...alreadyLive, ...rest];
}
