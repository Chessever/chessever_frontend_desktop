import 'dart:async';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/local_storage/group_broadcast/group_broadcast_local_storage.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/group_event_screen.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _EmptyFavoriteEventsNotifier extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => const <FavoriteEvent>[];
}

class _BroadcastRepository implements GroupBroadcastRepository {
  _BroadcastRepository(this.catalog);

  final List<GroupBroadcast> catalog;

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
    'Current hydration preserves source order for display-only live first',
    () async {
      final sourceBroadcasts = <GroupBroadcast>[
        _broadcast(id: 'source-a', name: 'Source A', maxAvgElo: 2700),
        _broadcast(id: 'live-b', name: 'Live B', maxAvgElo: 2650),
        _broadcast(id: 'source-c', name: 'Source C', maxAvgElo: 2600),
      ];
      final liveD = _broadcast(id: 'live-d', name: 'Live D', maxAvgElo: 2550);
      final liveUpdates = StreamController<List<String>>.broadcast();
      addTearDown(liveUpdates.close);
      final container = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(
            _BroadcastRepository(<GroupBroadcast>[liveD]),
          ),
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
      final provider = groupEventScreenByCategoryProvider(
        GroupEventCategory.current,
      );
      final subscription = container
          .listen<AsyncValue<List<GroupEventCardModel>>>(
            provider,
            (_, __) {},
            fireImmediately: true,
          );
      addTearDown(subscription.close);

      await _waitFor(() => container.read(provider).valueOrNull?.length == 3);
      final source = container.read(provider).requireValue;
      final sourceIds = source.map((event) => event.id).toList(growable: false);

      liveUpdates.add(const <String>['live-b', 'live-d']);
      await _waitFor(() => container.read(provider).valueOrNull?.length == 4);

      final hydrated = container.read(provider).requireValue;
      expect(hydrated.map((event) => event.id), <String>[
        ...sourceIds,
        'live-d',
      ]);
      expect(
        hydrated
            .where((event) => const {'live-b', 'live-d'}.contains(event.id))
            .every(
              (event) => event.tourEventCategory == TourEventCategory.live,
            ),
        isTrue,
      );
      expect(
        orderTournamentEventsForDisplay(
          hydrated,
          liveFirst: true,
        ).map((event) => event.id),
        <String>[
          'live-b',
          'live-d',
          ...sourceIds.where((id) => id != 'live-b'),
        ],
      );
      expect(
        orderTournamentEventsForDisplay(
          hydrated,
          liveFirst: false,
        ).map((event) => event.id),
        <String>[...sourceIds, 'live-d'],
      );
    },
  );
}
