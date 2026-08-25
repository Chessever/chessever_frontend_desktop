import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a promoted live event always retains a resolved games snapshot', () {
    var cache = mergeForYouTopGameSnapshots(
      current: const <String, ForYouEventGamesSnapshot>{},
      incoming: <String, ForYouEventGamesSnapshot>{
        'live-event': _snapshot('live-event'),
      },
      replace: false,
    );

    // The initial page request can finish after live hydration and performs
    // the same replace-style cache write used by _fetchPage(isInitial: true).
    cache = mergeForYouTopGameSnapshots(
      current: cache,
      incoming: <String, ForYouEventGamesSnapshot>{
        'page-event': _snapshot('page-event'),
      },
      replace: true,
    );

    final feed = mergeAndPromoteLiveEvents(
      current: [_event('page-event', TourEventCategory.ongoing)],
      additions: [_event('live-event', TourEventCategory.upcoming)],
      liveIds: const ['live-event'],
    );
    final unresolved = feed
        .where((event) => !cache.containsKey(event.id))
        .map((event) => event.id)
        .toList(growable: false);

    expect(
      unresolved,
      isEmpty,
      reason:
          'an event without a cache entry renders loading skeletons forever',
    );
  });
}

ForYouEventGamesSnapshot _snapshot(String eventId) {
  return ForYouEventGamesSnapshot(
    eventId: eventId,
    tourId: 'tour-$eventId',
    visibleGames: const [],
    pinnedIds: const [],
  );
}

GroupEventCardModel _event(String id, TourEventCategory category) {
  return GroupEventCardModel(
    id: id,
    title: id,
    dates: '',
    maxAvgElo: 2500,
    timeUntilStart: '',
    tourEventCategory: category,
    timeControl: 'Blitz',
    startDate: DateTime.utc(2026, 8, 25),
    endDate: DateTime.utc(2026, 8, 26),
  );
}
