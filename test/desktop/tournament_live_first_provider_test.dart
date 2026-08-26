import 'dart:async';

import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/local_storage/group_broadcast/group_broadcast_local_storage.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/group_event_screen.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/group_event/providers/live_event_feed.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _EmptyFavoriteEventsNotifier extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => const <FavoriteEvent>[];
}

class _BroadcastRepository implements GroupBroadcastRepository {
  _BroadcastRepository({
    this.catalog = const <GroupBroadcast>[],
    this.rankedLive = const <GroupBroadcast>[],
  });

  final List<GroupBroadcast> catalog;

  /// What the server returns for the `live` slice, in its own ranking.
  final List<GroupBroadcast> rankedLive;

  /// How many times the ranking query actually went out. Live first is only
  /// query-driven if this climbs when the preference flips.
  int liveFirstQueryCount = 0;

  @override
  Future<List<GroupBroadcast>> getGroupBroadcastsByIdsOrNames(
    List<String> idsOrNames,
  ) async {
    final wanted = idsOrNames.toSet();
    return catalog
        .where(
          (broadcast) =>
              wanted.contains(broadcast.id) || wanted.contains(broadcast.name),
        )
        .toList(growable: false);
  }

  @override
  Future<List<GroupBroadcast>> getLiveFirstGroupBroadcasts({
    int limit = 60,
    List<String>? timeControlFilters,
    int? minElo,
    int? maxElo,
  }) async {
    liveFirstQueryCount++;
    return rankedLive;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedGroupBroadcastLocalStorage extends GroupBroadcastLocalStorage {
  _FixedGroupBroadcastLocalStorage({
    required super.ref,
    required super.category,
    required this.broadcasts,
  });

  final List<GroupBroadcast> broadcasts;

  @override
  Future<List<GroupBroadcast>> fetchGroupBroadcasts() async => broadcasts;

  @override
  Future<List<GroupBroadcast>> refresh() async => broadcasts;
}

GroupBroadcast _broadcast({
  required String id,
  required String name,
  required int maxAvgElo,
}) {
  final now = DateTime.now();
  return GroupBroadcast(
    id: id,
    createdAt: now.subtract(const Duration(hours: 2)),
    name: name,
    search: const <String>[],
    maxAvgElo: maxAvgElo,
    dateStart: now.subtract(const Duration(hours: 1)),
    dateEnd: now.add(const Duration(hours: 8)),
    timeControl: 'blitz',
  );
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for provider state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Current re-queries on toggle and restores the canonical order when off',
    () async {
      final sourceBroadcasts = <GroupBroadcast>[
        _broadcast(id: 'source-a', name: 'Source A', maxAvgElo: 2700),
        _broadcast(id: 'live-b', name: 'Live B', maxAvgElo: 2650),
        _broadcast(id: 'source-c', name: 'Source C', maxAvgElo: 2600),
      ];
      final liveD = _broadcast(id: 'live-d', name: 'Live D', maxAvgElo: 2550);
      // The server ranks `live-d` above `live-b` even though the page carries
      // `live-b` first. Live first must honour the ranking, not the page.
      final repository = _BroadcastRepository(
        catalog: <GroupBroadcast>[liveD],
        rankedLive: <GroupBroadcast>[liveD, sourceBroadcasts[1]],
      );
      final liveUpdates = StreamController<List<String>>.broadcast();
      addTearDown(liveUpdates.close);
      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(repository),
          groupBroadcastLocalStorage.overrideWith(
            (ref, category) => _FixedGroupBroadcastLocalStorage(
              ref: ref,
              category: category,
              broadcasts: sourceBroadcasts,
            ),
          ),
          favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
          liveGroupBroadcastIdsProvider.overrideWith((ref) async* {
            yield const <String>[];
            yield* liveUpdates.stream;
          }),
        ],
      );
      addTearDown(container.dispose);

      List<String> currentIds() =>
          container
              .read(
                groupEventScreenByCategoryProvider(GroupEventCategory.current),
              )
              .valueOrNull
              ?.map((event) => event.id)
              .toList(growable: false) ??
          const <String>[];

      ProviderSubscription<AsyncValue<List<GroupEventCardModel>>> listen() =>
          container.listen<AsyncValue<List<GroupEventCardModel>>>(
            groupEventScreenByCategoryProvider(GroupEventCategory.current),
            (_, __) {},
            fireImmediately: true,
          );

      var subscription = listen();
      addTearDown(() => subscription.close());

      await _waitFor(() => currentIds().length == 3);
      final canonical = currentIds();
      expect(canonical, <String>['source-a', 'live-b', 'source-c']);
      expect(
        repository.liveFirstQueryCount,
        0,
        reason: 'the ranking query must not run while Live first is off',
      );

      liveUpdates.add(const <String>['live-b', 'live-d']);
      await _waitFor(() => currentIds().length == 4);
      expect(currentIds(), <String>[...canonical, 'live-d']);

      // Flip the preference on. The controller is rebuilt, so re-subscribe the
      // way a rebuilt widget would.
      container.read(liveFirstOrderingProvider.notifier).state = true;
      subscription.close();
      subscription = listen();

      await _waitFor(
        () => currentIds().length == 4 && currentIds().first == 'live-d',
      );
      expect(
        repository.liveFirstQueryCount,
        greaterThan(0),
        reason: 'flipping Live first must issue the ranking query',
      );
      expect(currentIds(), <String>[
        'live-d',
        'live-b',
        'source-a',
        'source-c',
      ]);

      // And back off. Nothing client-side remembered the canonical order — it
      // comes back because the feed re-queries without a cohort.
      container.read(liveFirstOrderingProvider.notifier).state = false;
      subscription.close();
      subscription = listen();

      await _waitFor(
        () => currentIds().length == 4 && currentIds().first == 'source-a',
      );
      expect(currentIds(), <String>[...canonical, 'live-d']);
    },
  );

  test('hydration never decides position on its own', () {
    GroupEventCardModel event(String id, TourEventCategory category) {
      return GroupEventCardModel(
        id: id,
        title: id,
        dates: '',
        timeUntilStart: '',
        maxAvgElo: 2500,
        tourEventCategory: category,
        timeControl: 'Standard',
        endDate: null,
        startDate: null,
      );
    }

    final source = <GroupEventCardModel>[
      event('personalized-a', TourEventCategory.ongoing),
      event('live-b', TourEventCategory.live),
    ];

    final hydrated = mergeLiveEventsPreservingSourceOrder(
      current: source,
      additions: <GroupEventCardModel>[
        event('live-d', TourEventCategory.upcoming),
      ],
      liveIds: const <String>['live-b', 'live-d'],
    );

    // Hydration pulled `live-d` in and re-derived its live category, but left
    // ranking alone — that is the cohort query's job.
    expect(hydrated.map((event) => event.id), <String>[
      'personalized-a',
      'live-b',
      'live-d',
    ]);
    expect(hydrated.last.tourEventCategory, TourEventCategory.live);
    expect(source.map((event) => event.id), <String>[
      'personalized-a',
      'live-b',
    ]);
  });
}
