import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_rounds_id_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test(
    'For You keeps stars first, promotes pins and restores order on unpin',
    () async {
      final feed = _Feed([
        _broadcast('strong', 2900),
        _broadcast('live', 2800),
        _broadcast('charlotte', 2700),
        _broadcast('star', 2600, pinDay: 21),
        _broadcast('older', 2500, pinDay: 19),
      ]);
      final container = _container(feed);
      await _loaded(container);
      expect(_ids(container), ['star', 'older', 'strong', 'live', 'charlotte']);

      final notifier = container.read(forYouEventsProvider.notifier);
      feed.rows[2] = _broadcast('charlotte', 2700, pinDay: 20);
      await notifier.refresh();
      expect(_ids(container), ['star', 'charlotte', 'older', 'strong', 'live']);

      await notifier.setLiveFirst(true);
      expect(_ids(container), ['live', 'star', 'charlotte', 'older', 'strong']);
      await notifier.setLiveFirst(false);

      feed.rows[2] = _broadcast('charlotte', 2700);
      feed.rows[4] = _broadcast('older', 2500);
      await notifier.refresh();
      expect(_ids(container), ['star', 'strong', 'live', 'charlotte', 'older']);
    },
  );

  test(
    'a pin found on a later page is promoted without duplicating it',
    () async {
      final feed = _Feed([
        for (var i = 0; i < 24; i++)
          _broadcast('e$i', 2800 - i * 10, pinDay: i == 23 ? 21 : null),
      ]);
      final container = _container(feed);
      await _loaded(container);
      final first = _ids(container);
      expect(first, hasLength(20));
      await container.read(forYouEventsProvider.notifier).loadMore();
      expect(_ids(container), ['e23', ...first, 'e20', 'e21', 'e22']);
    },
  );
}

ProviderContainer _container(_Feed feed) {
  final container = ProviderContainer(
    overrides: [
      groupBroadcastRepositoryProvider.overrideWithValue(feed),
      gameRepositoryProvider.overrideWithValue(_Boards()),
      favoriteEventsProvider.overrideWith(_Stars.new),
      favoritePlayersProviderNew.overrideWith(_Players.new),
      liveGroupBroadcastIdsProvider.overrideWith(
        (ref) => Stream.value(['live']),
      ),
      liveRoundsIdProvider.overrideWith((ref) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _loaded(ProviderContainer container) async {
  final sub = container.listen(forYouEventsProvider, (_, __) {});
  addTearDown(sub.close);
  for (
    var i = 0;
    i < 200 && container.read(forYouEventsProvider).isLoading;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(container.read(forYouEventsProvider).isLoading, isFalse);
  expect(container.read(forYouEventsProvider).error, isNull);
}

List<String> _ids(ProviderContainer container) =>
    container
        .read(forYouEventsProvider)
        .events
        .map((event) => event.id)
        .toList();

GroupBroadcast _broadcast(String id, int elo, {int? pinDay}) {
  final now = DateTime.now();
  return GroupBroadcast(
    id: id,
    name: id,
    search: const [],
    createdAt: now,
    dateStart: now.subtract(const Duration(hours: 1)),
    dateEnd: now.add(const Duration(hours: 8)),
    maxAvgElo: elo,
    pinnedAt: pinDay == null ? null : DateTime.utc(2026, 11, pinDay),
  );
}

class _Stars extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => [
    FavoriteEvent(
      id: 'favorite',
      userId: 'test-user',
      eventId: 'star',
      eventName: 'star',
      metadata: const {},
      createdAt: DateTime.utc(2026, 11, 21),
      updatedAt: DateTime.utc(2026, 11, 21),
    ),
  ];
}

class _Players extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => [];
}

class _Feed implements GroupBroadcastRepository {
  _Feed(this.rows);
  final List<GroupBroadcast> rows;

  @override
  Future<List<GroupBroadcast>> getForYouGroupBroadcasts({
    int limit = 20,
    int offset = 0,
    List<String>? timeControlFilters,
    int? minElo,
    int? maxElo,
    List<String>? statusFilters,
  }) async => rows.skip(offset).take(limit).toList();

  @override
  Future<List<GroupBroadcast>> getLiveFirstGroupBroadcasts({
    int limit = 60,
    List<String>? timeControlFilters,
    int? minElo,
    int? maxElo,
  }) async => rows.where((event) => event.id == 'live').toList();

  @override
  Future<List<GroupBroadcast>> getGroupBroadcastsByIdsOrNames(
    List<String> ids,
  ) async => rows.where((event) => ids.contains(event.id)).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Boards implements GameRepository {
  @override
  Future<Map<String, List<Games>>> getForYouTopGamesByEventIds({
    required List<String> eventIds,
    int boardsPerEvent = 4,
  }) async => {for (final id in eventIds) id: []};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
