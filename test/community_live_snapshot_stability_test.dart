import 'dart:async';

import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_event_feed.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_rounds_id_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _EmptyFavoriteEventsNotifier extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => const <FavoriteEvent>[];
}

class _NewEventFavoriteEventsNotifier extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async {
    final now = DateTime.now();
    return <FavoriteEvent>[
      FavoriteEvent(
        id: 'favorite-row',
        userId: 'user-1',
        eventId: 'new-starred-event',
        eventName: 'New starred event',
        metadata: const <String, dynamic>{},
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }
}

class _EmptyFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const <FavoritePlayer>[];
}

class _SequencedBroadcastRepository implements GroupBroadcastRepository {
  _SequencedBroadcastRepository(this.snapshots, {this.catalog = const []});

  final List<List<GroupBroadcast>> snapshots;
  final List<GroupBroadcast> catalog;
  int calls = 0;
  final List<List<String>> byIdRequests = <List<String>>[];

  /// What the server returns for the ranked `live` slice, and how many times
  /// it was actually asked. Live first is only query-driven if the count moves
  /// when the preference flips.
  List<GroupBroadcast> rankedLive = const <GroupBroadcast>[];
  int liveFirstQueryCount = 0;

  @override
  Future<List<GroupBroadcast>> getLiveFirstGroupBroadcasts({
    int limit = 60,
    List<String>? timeControlFilters,
    int? minElo,
    int? maxElo,
  }) async {
    liveFirstQueryCount += 1;
    return rankedLive;
  }

  @override
  Future<List<GroupBroadcast>> getForYouGroupBroadcasts({
    int limit = 20,
    int offset = 0,
    List<String>? timeControlFilters,
    int? minElo,
    int? maxElo,
    List<String>? statusFilters,
  }) async {
    final index = calls.clamp(0, snapshots.length - 1);
    calls += 1;
    return snapshots[index];
  }

  @override
  Future<List<GroupBroadcast>> getGroupBroadcastsByIdsOrNames(
    List<String> identifiers,
  ) async {
    byIdRequests.add(List<String>.from(identifiers));
    final wanted = identifiers.map((id) => id.trim()).toSet();
    return catalog
        .where(
          (broadcast) =>
              wanted.contains(broadcast.id) || wanted.contains(broadcast.name),
        )
        .toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyGameRepository implements GameRepository {
  @override
  Future<Map<String, List<Games>>> getForYouTopGamesByEventIds({
    required List<String> eventIds,
    int boardsPerEvent = 4,
  }) async => <String, List<Games>>{
    for (final eventId in eventIds) eventId: const <Games>[],
  };

  @override
  Future<Map<String, List<int>>> getForYouFavoritePlayerFideIdsByEventIds({
    required List<String> eventIds,
    required List<int> favoriteFideIds,
  }) async => <String, List<int>>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    'For You Live first is a refetch, and turning it off is another',
    () async {
      final offPageLive = _broadcast(
        id: 'titled-tuesday',
        name: 'Titled Tuesday',
        maxAvgElo: 2400,
      );
      final broadcasts = _SequencedBroadcastRepository(
        <List<GroupBroadcast>>[
          <GroupBroadcast>[
            _broadcast(
              id: 'starred-open',
              name: 'Starred Open',
              maxAvgElo: 2700,
            ),
            _broadcast(id: 'club-open', name: 'Club Open', maxAvgElo: 2600),
          ],
        ],
        catalog: <GroupBroadcast>[offPageLive],
      );
      // The live event the user wants ranks 2400 — well below the paged window.
      // Only a query can surface it; there is nothing on screen to reorder.
      broadcasts.rankedLive = <GroupBroadcast>[offPageLive];

      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
          favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
          favoritePlayersProviderNew.overrideWith(
            _EmptyFavoritePlayersNotifier.new,
          ),
          liveGroupBroadcastIdsProvider.overrideWith(
            (ref) => Stream<List<String>>.value(const <String>[]),
          ),
          liveRoundsIdProvider.overrideWith(
            (ref) => const Stream<List<String>>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<ForYouState>(
        forYouEventsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      List<String> feedIds() => container
          .read(forYouEventsProvider)
          .events
          .map((event) => event.id)
          .toList(growable: false);

      await _waitFor(() => feedIds().length == 2);
      expect(feedIds(), <String>['starred-open', 'club-open']);
      expect(
        broadcasts.liveFirstQueryCount,
        0,
        reason: 'the ranking query must not run while Live first is off',
      );

      container.read(liveFirstOrderingProvider.notifier).state = true;
      await _waitFor(
        () => feedIds().isNotEmpty && feedIds().first == 'titled-tuesday',
      );
      expect(broadcasts.liveFirstQueryCount, greaterThan(0));
      expect(feedIds(), <String>[
        'titled-tuesday',
        'starred-open',
        'club-open',
      ]);

      container.read(liveFirstOrderingProvider.notifier).state = false;
      await _waitFor(
        () => feedIds().isNotEmpty && feedIds().first == 'starred-open',
      );
      // Off refetches too, so the canonical ranking is the server's answer
      // rather than a remembered client-side copy.
      expect(feedIds(), <String>['starred-open', 'club-open']);
    },
  );

  test(
    'refresh does not swap Titled Tuesday siblings as mutable rankings change',
    () async {
      final broadcasts = _SequencedBroadcastRepository(<List<GroupBroadcast>>[
        <GroupBroadcast>[
          _broadcast(
            id: 'titled-tuesday-1',
            name: 'Titled Tuesday #1',
            maxAvgElo: 2800,
          ),
          _broadcast(
            id: 'titled-tuesday-2',
            name: 'Titled Tuesday #2',
            maxAvgElo: 2700,
          ),
        ],
        <GroupBroadcast>[
          _broadcast(
            id: 'titled-tuesday-2',
            name: 'Titled Tuesday #2',
            maxAvgElo: 2810,
          ),
          _broadcast(
            id: 'titled-tuesday-1',
            name: 'Titled Tuesday #1',
            maxAvgElo: 2790,
          ),
        ],
      ]);
      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
          favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
          favoritePlayersProviderNew.overrideWith(
            _EmptyFavoritePlayersNotifier.new,
          ),
          liveGroupBroadcastIdsProvider.overrideWith(
            (ref) => Stream<List<String>>.value(const <String>[
              'titled-tuesday-1',
              'titled-tuesday-2',
            ]),
          ),
          liveRoundsIdProvider.overrideWith(
            (ref) => const Stream<List<String>>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<ForYouState>(
        forYouEventsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _waitFor(
        () =>
            broadcasts.calls >= 1 &&
            container.read(forYouEventsProvider).events.length == 2,
      );
      expect(
        container.read(forYouEventsProvider).events.map((event) => event.id),
        <String>['titled-tuesday-1', 'titled-tuesday-2'],
      );

      await container.read(forYouEventsProvider.notifier).refresh();

      expect(
        container.read(forYouEventsProvider).events.map((event) => event.id),
        <String>['titled-tuesday-1', 'titled-tuesday-2'],
      );
    },
  );

  test('a genuinely new starred event enters personalized ranking', () async {
    final initial = <GroupBroadcast>[
      _broadcast(id: 'regular-a', name: 'Regular A', maxAvgElo: 2900),
      _broadcast(id: 'regular-b', name: 'Regular B', maxAvgElo: 2800),
    ];
    final broadcasts = _SequencedBroadcastRepository(<List<GroupBroadcast>>[
      initial,
      <GroupBroadcast>[
        ...initial,
        _broadcast(
          id: 'new-starred-event',
          name: 'New starred event',
          maxAvgElo: 2200,
        ),
      ],
    ]);
    final container = ProviderContainer(
      overrides: [
        groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
        gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
        favoriteEventsProvider.overrideWith(
          _NewEventFavoriteEventsNotifier.new,
        ),
        favoritePlayersProviderNew.overrideWith(
          _EmptyFavoritePlayersNotifier.new,
        ),
        liveGroupBroadcastIdsProvider.overrideWith(
          (ref) => Stream<List<String>>.value(const <String>[]),
        ),
        liveRoundsIdProvider.overrideWith(
          (ref) => const Stream<List<String>>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen<ForYouState>(
      forYouEventsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _waitFor(
      () =>
          broadcasts.calls >= 1 &&
          container.read(forYouEventsProvider).events.length == 2,
    );
    await container.read(favoriteEventsProvider.future);
    await container.read(forYouEventsProvider.notifier).refresh();

    expect(
      container.read(forYouEventsProvider).events.map((event) => event.id),
      <String>['new-starred-event', 'regular-a', 'regular-b'],
    );
  });

  test(
    'a newly live event is appended without replacing personalized order',
    () async {
      final titledTuesday = _broadcast(
        id: 'titled-tuesday',
        name: 'Titled Tuesday',
        maxAvgElo: 2650,
      );
      final liveUpdates = StreamController<List<String>>.broadcast();
      addTearDown(liveUpdates.close);
      final broadcasts = _SequencedBroadcastRepository(
        <List<GroupBroadcast>>[
          <GroupBroadcast>[
            _broadcast(
              id: 'starred-open',
              name: 'Starred Open',
              maxAvgElo: 2750,
            ),
            _broadcast(id: 'club-open', name: 'Club Open', maxAvgElo: 2400),
          ],
        ],
        catalog: <GroupBroadcast>[titledTuesday],
      );
      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
          favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
          favoritePlayersProviderNew.overrideWith(
            _EmptyFavoritePlayersNotifier.new,
          ),
          liveGroupBroadcastIdsProvider.overrideWith((ref) async* {
            yield const <String>[];
            yield* liveUpdates.stream;
          }),
          liveRoundsIdProvider.overrideWith(
            (ref) => const Stream<List<String>>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<ForYouState>(
        forYouEventsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _waitFor(
        () =>
            broadcasts.calls >= 1 &&
            container.read(forYouEventsProvider).events.length == 2,
      );
      expect(
        container.read(forYouEventsProvider).events.map((event) => event.id),
        <String>['starred-open', 'club-open'],
      );

      liveUpdates.add(const <String>['titled-tuesday']);

      await _waitFor(
        () =>
            container.read(forYouEventsProvider).events.length == 3 &&
            container.read(forYouEventsProvider).events.last.id ==
                'titled-tuesday',
      );
      expect(
        container.read(forYouEventsProvider).events.map((event) => event.id),
        <String>['starred-open', 'club-open', 'titled-tuesday'],
      );
      expect(
        container.read(forYouEventsProvider).events.last.tourEventCategory,
        TourEventCategory.live,
      );
    },
  );

  test('an already-loaded live event keeps its source position', () async {
    final titledTuesday = _broadcast(
      id: 'titled-tuesday',
      name: 'Titled Tuesday',
      maxAvgElo: 2400,
    );
    final liveUpdates = StreamController<List<String>>.broadcast();
    addTearDown(liveUpdates.close);
    final broadcasts = _SequencedBroadcastRepository(
      <List<GroupBroadcast>>[
        <GroupBroadcast>[
          _broadcast(id: 'starred-open', name: 'Starred Open', maxAvgElo: 2750),
          titledTuesday,
        ],
      ],
      catalog: <GroupBroadcast>[titledTuesday],
    );
    final container = ProviderContainer(
      overrides: [
        groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
        gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
        favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
        favoritePlayersProviderNew.overrideWith(
          _EmptyFavoritePlayersNotifier.new,
        ),
        liveGroupBroadcastIdsProvider.overrideWith((ref) async* {
          yield const <String>[];
          yield* liveUpdates.stream;
        }),
        liveRoundsIdProvider.overrideWith(
          (ref) => const Stream<List<String>>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen<ForYouState>(
      forYouEventsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _waitFor(
      () => container.read(forYouEventsProvider).events.length == 2,
    );
    expect(
      container.read(forYouEventsProvider).events.map((event) => event.id),
      <String>['starred-open', 'titled-tuesday'],
    );

    liveUpdates.add(const <String>['titled-tuesday']);

    await _waitFor(() {
      final events = container.read(forYouEventsProvider).events;
      return events.length == 2 &&
          events[1].tourEventCategory == TourEventCategory.live;
    });
    expect(
      container.read(forYouEventsProvider).events.map((event) => event.id),
      <String>['starred-open', 'titled-tuesday'],
    );
    expect(
      container.read(forYouEventsProvider).events[1].tourEventCategory,
      TourEventCategory.live,
    );
  });

  test(
    'refresh keeps an off-page live event and its resolved games snapshot',
    () async {
      final titledTuesday = _broadcast(
        id: 'titled-tuesday',
        name: 'Titled Tuesday',
        maxAvgElo: 2650,
      );
      final page = <GroupBroadcast>[
        _broadcast(id: 'starred-open', name: 'Starred Open', maxAvgElo: 2750),
        _broadcast(id: 'club-open', name: 'Club Open', maxAvgElo: 2400),
      ];
      final liveUpdates = StreamController<List<String>>.broadcast();
      addTearDown(liveUpdates.close);
      final broadcasts = _SequencedBroadcastRepository(
        <List<GroupBroadcast>>[page, page],
        catalog: <GroupBroadcast>[titledTuesday],
      );
      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(broadcasts),
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
          favoriteEventsProvider.overrideWith(_EmptyFavoriteEventsNotifier.new),
          favoritePlayersProviderNew.overrideWith(
            _EmptyFavoritePlayersNotifier.new,
          ),
          liveGroupBroadcastIdsProvider.overrideWith((ref) async* {
            yield const <String>[];
            yield* liveUpdates.stream;
          }),
          liveRoundsIdProvider.overrideWith(
            (ref) => const Stream<List<String>>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<ForYouState>(
        forYouEventsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _waitFor(
        () => container.read(forYouEventsProvider).events.length == 2,
      );
      liveUpdates.add(const <String>['titled-tuesday']);
      await _waitFor(
        () => container.read(forYouEventsProvider).events.length == 3,
      );

      await container.read(forYouEventsProvider.notifier).refresh();

      expect(
        container.read(forYouEventsProvider).events.map((event) => event.id),
        <String>['starred-open', 'club-open', 'titled-tuesday'],
      );
      expect(
        container.read(forYouEventSnapshotProvider('titled-tuesday')).isLoading,
        isFalse,
        reason:
            'a retained event without a cache entry renders skeletons forever',
      );
      expect(
        container
            .read(forYouTopGamesSnapshotCacheProvider)
            .containsKey('titled-tuesday'),
        isTrue,
      );
    },
  );

  test('round reconciliation updates fields without dropping siblings', () {
    final startsAt = DateTime.utc(2026, 7, 14, 18);
    final missingCounts = <String, int>{};
    const previous = <GamesAppBarModel>[
      GamesAppBarModel(
        id: 'round-5',
        name: 'Round 5',
        startsAt: null,
        roundStatus: RoundStatus.ongoing,
        sourceRoundIds: <String>['round-5'],
      ),
      GamesAppBarModel(
        id: 'round-6',
        name: 'Round 6',
        startsAt: null,
        roundStatus: RoundStatus.upcoming,
        sourceRoundIds: <String>['round-6'],
      ),
    ];
    final merged = mergePublishedRoundModels(
      previous: previous,
      incoming: <GamesAppBarModel>[
        GamesAppBarModel(
          id: 'round-6',
          name: 'Round 6 (Live)',
          startsAt: startsAt,
          roundStatus: RoundStatus.upcoming,
          sourceRoundIds: const <String>['round-6'],
        ),
      ],
      liveRoundIds: const <String>['round-6'],
      missingSnapshotCounts: missingCounts,
    );

    expect(
      merged.map((round) => round.id),
      containsAll(<String>['round-5', 'round-6']),
    );
    final round6 = merged.singleWhere((round) => round.id == 'round-6');
    expect(round6.name, 'Round 6 (Live)');
    expect(round6.startsAt, startsAt);
    expect(round6.roundStatus, RoundStatus.live);
  });

  test('initial round reconciliation remains mutable for app-bar sorting', () {
    const round = GamesAppBarModel(
      id: 'round-1',
      name: 'Round 1',
      startsAt: null,
      roundStatus: RoundStatus.ongoing,
      sourceRoundIds: <String>['round-1'],
    );
    final merged = mergePublishedRoundModels(
      previous: const <GamesAppBarModel>[],
      incoming: const <GamesAppBarModel>[round],
    );

    expect(() {
      merged.clear();
      merged.add(round);
    }, returnsNormally);
    expect(merged.single.id, 'round-1');
  });

  test(
    'round cache retains live rows and prunes only after bounded misses',
    () {
      final startsAt = DateTime.now().add(const Duration(hours: 2));
      final missingCounts = <String, int>{};
      var known = mergePublishedRoundModels(
        previous: const <GamesAppBarModel>[],
        incoming: <GamesAppBarModel>[
          GamesAppBarModel(
            id: 'round-8',
            name: 'Round 8',
            startsAt: startsAt,
            roundStatus: RoundStatus.upcoming,
            sourceRoundIds: const <String>['round-8'],
          ),
        ],
        liveRoundIds: const <String>['round-8'],
        missingSnapshotCounts: missingCounts,
        missingSnapshotTolerance: 2,
      );
      expect(known.single.roundStatus, RoundStatus.live);

      known = mergePublishedRoundModels(
        previous: known,
        incoming: const <GamesAppBarModel>[],
        liveRoundIds: const <String>['round-8'],
        missingSnapshotCounts: missingCounts,
        missingSnapshotTolerance: 2,
      );
      expect(known.single.roundStatus, RoundStatus.live);

      for (var miss = 1; miss <= 2; miss++) {
        known = mergePublishedRoundModels(
          previous: known,
          incoming: const <GamesAppBarModel>[],
          missingSnapshotCounts: missingCounts,
          missingSnapshotTolerance: 2,
        );
        expect(known.map((round) => round.id), contains('round-8'));
      }

      known = mergePublishedRoundModels(
        previous: known,
        incoming: const <GamesAppBarModel>[],
        missingSnapshotCounts: missingCounts,
        missingSnapshotTolerance: 2,
      );
      expect(known, isEmpty);
      expect(missingCounts, isEmpty);
    },
  );
}
