import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('missingLiveEventIds', () {
    test('returns live ids the feed has not loaded yet', () {
      expect(
        missingLiveEventIds(
          knownIds: const ['loaded-a', 'loaded-b', ''],
          liveIds: const ['loaded-a', ' titled-tuesday ', 'loaded-b'],
        ),
        {'titled-tuesday'},
      );
    });

    test('is empty when every live id is already on the page', () {
      expect(
        missingLiveEventIds(
          knownIds: const ['live-a', 'live-b'],
          liveIds: const ['live-b', 'live-a'],
        ),
        isEmpty,
      );
    });
  });

  group('appendUnknownBroadcasts', () {
    test('appends unseen broadcasts and skips duplicates', () {
      final current = [_broadcast('loaded')];
      final merged = appendUnknownBroadcasts(
        current: current,
        incoming: [
          _broadcast('loaded'),
          _broadcast('titled-tuesday'),
          _broadcast('titled-tuesday'),
        ],
      );

      expect(merged.map((broadcast) => broadcast.id), [
        'loaded',
        'titled-tuesday',
      ]);
      expect(current.map((broadcast) => broadcast.id), ['loaded']);
    });
  });

  group('mergeAndPromoteLiveEvents', () {
    test('appends a newly live event and promotes it to the front', () {
      final current = [
        _event('starred', TourEventCategory.ongoing),
        _event('high-elo', TourEventCategory.ongoing),
      ];

      final merged = mergeAndPromoteLiveEvents(
        current: current,
        additions: [_event('titled-tuesday', TourEventCategory.upcoming)],
        liveIds: const ['titled-tuesday'],
      );

      expect(merged.map((event) => event.id), [
        'titled-tuesday',
        'starred',
        'high-elo',
      ]);
      expect(merged.first.tourEventCategory, TourEventCategory.live);
      expect(current.map((event) => event.id), ['starred', 'high-elo']);
    });

    test('promotes an already-loaded event that just went live', () {
      final current = [
        _event('starred', TourEventCategory.ongoing),
        _event('titled-tuesday', TourEventCategory.upcoming),
        _event('club', TourEventCategory.ongoing),
      ];

      final merged = mergeAndPromoteLiveEvents(
        current: current,
        liveIds: const ['titled-tuesday'],
      );

      expect(merged.map((event) => event.id), [
        'titled-tuesday',
        'starred',
        'club',
      ]);
      expect(merged.first.tourEventCategory, TourEventCategory.live);
    });

    test('does not swap siblings that were already live', () {
      final current = [
        _event('titled-tuesday-1', TourEventCategory.live),
        _event('titled-tuesday-2', TourEventCategory.live),
        _event('club', TourEventCategory.ongoing),
      ];

      final merged = mergeAndPromoteLiveEvents(
        current: current,
        liveIds: const ['titled-tuesday-2', 'titled-tuesday-1'],
      );

      expect(merged.map((event) => event.id), [
        'titled-tuesday-1',
        'titled-tuesday-2',
        'club',
      ]);
    });

    test('keeps already-live events after the newly live cohort', () {
      final current = [
        _event('already-live', TourEventCategory.live),
        _event('starred', TourEventCategory.ongoing),
        _event('club', TourEventCategory.ongoing),
      ];

      final merged = mergeAndPromoteLiveEvents(
        current: current,
        additions: [_event('titled-tuesday', TourEventCategory.upcoming)],
        liveIds: const ['already-live', 'titled-tuesday'],
      );

      expect(merged.map((event) => event.id), [
        'titled-tuesday',
        'already-live',
        'starred',
        'club',
      ]);
    });
  });
}

GroupBroadcast _broadcast(String id) {
  final now = DateTime.now();
  return GroupBroadcast(
    id: id,
    createdAt: now,
    name: id,
    search: const <String>[],
    maxAvgElo: 2700,
    dateStart: now.subtract(const Duration(hours: 1)),
    dateEnd: now.add(const Duration(hours: 8)),
    timeControl: 'blitz',
  );
}

GroupEventCardModel _event(String id, TourEventCategory category) {
  return GroupEventCardModel(
    id: id,
    title: id,
    dates: '',
    maxAvgElo: 2700,
    timeUntilStart: '',
    tourEventCategory: category,
    timeControl: 'Blitz',
    endDate: DateTime.now().add(const Duration(hours: 8)),
    startDate: DateTime.now().subtract(const Duration(hours: 1)),
  );
}
