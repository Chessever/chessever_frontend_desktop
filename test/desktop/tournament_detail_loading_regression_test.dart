import 'dart:async';

import 'package:chessever/repository/local_storage/tournament/games/games_local_storage.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/round/round.dart';
import 'package:chessever/repository/supabase/round/round_repository.dart';
import 'package:chessever/repository/supabase/settings/settings.dart';
import 'package:chessever/repository/supabase/settings/settings_repository.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';

import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '21-stage tournament detail uses bounded metadata loading and exits spinner',
    () async {
      final now = DateTime.utc(2026, 7, 16, 12);
      final primary = _tour(
        id: 'stage-primary',
        name: 'Titled Tuesday | Stage 2',
        startsAt: now.subtract(const Duration(hours: 4)),
      );
      final sibling = _tour(
        id: 'stage-sibling',
        name: 'Titled Tuesday | Stage 1',
        startsAt: now.subtract(const Duration(days: 1)),
      );
      final primaryRound = _round(
        id: 'primary-round',
        tourId: primary.id,
        startsAt: now.subtract(const Duration(hours: 4)),
      );
      final siblingRound = _round(
        id: 'sibling-round',
        tourId: sibling.id,
        startsAt: now.subtract(const Duration(days: 1)),
      );
      final extraTours = <Tour>[
        for (var index = 3; index <= 21; index++)
          _tour(
            id: 'stage-$index',
            name: 'Titled Tuesday | Stage $index',
            startsAt: now.subtract(Duration(days: index)),
          ),
      ];
      final allTours = <Tour>[primary, sibling, ...extraTours];
      final roundsByTourId = <String, List<Round>>{
        primary.id: <Round>[primaryRound],
        sibling.id: <Round>[siblingRound],
        for (final tour in extraTours)
          tour.id: <Round>[
            _round(
              id: '${tour.id}-round',
              tourId: tour.id,
              startsAt: tour.dates.first,
            ),
          ],
      };
      final roundRepository = _BlockingSiblingRoundRepository(
        primaryTourId: primary.id,
        roundsByTourId: roundsByTourId,
      );

      final container = ProviderContainer(
        overrides: <Override>[
          tourRepositoryProvider.overrideWithValue(
            _TournamentDetailTourRepository(allTours),
          ),
          roundRepositoryProvider.overrideWithValue(roundRepository),
          gameRepositoryProvider.overrideWithValue(
            _TournamentDetailGameRepository(primary.id),
          ),
          settingsRepositoryProvider.overrideWithValue(
            _SilentSettingsRepository(),
          ),
          gamesLocalStorage.overrideWith(
            (ref) => _FixtureGamesLocalStorage(ref, <String, List<Games>>{
              for (final tour in allTours)
                tour.id: <Games>[
                  _game(
                    id: '${tour.id}-game',
                    tourId: tour.id,
                    roundId: roundsByTourId[tour.id]!.single.id,
                  ),
                ],
            }),
          ),
          shouldStreamProvider.overrideWith((ref) => false),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(selectedBroadcastModelProvider.notifier)
          .state = GroupBroadcast(
        id: 'titled-tuesday',
        createdAt: now,
        name: 'Titled Tuesday',
        search: const <String>[],
      );
      final subscription = container.listen(
        gamesAppBarProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final groupedSubscription = container.listen(
        gamesTourGroupedProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(groupedSubscription.close);

      await _pumpEventQueue();
      await _waitUntil(() {
        final grouped = container.read(gamesTourGroupedProvider);
        return !grouped.isLoading &&
            grouped.filteredRounds.isNotEmpty &&
            grouped.allGames.isNotEmpty;
      });

      expect(
        roundRepository.siblingSingleFetchStarted,
        isFalse,
        reason:
            'the app bar must not enter a serial sibling-stage request after '
            'the selected stage is ready',
      );
      final appBarState = container.read(gamesAppBarProvider);
      expect(
        appBarState.isLoading,
        isFalse,
        reason:
            'TournamentGamesView shows its indefinite spinner while this '
            'provider remains loading. A ready selected stage must not wait '
            'for an unrelated sibling-stage request.',
      );
      expect(
        appBarState.hasError,
        isFalse,
        reason: '${appBarState.error}\n${appBarState.stackTrace}',
      );
      expect(
        appBarState.valueOrNull?.gamesAppBarModels.map((round) => round.id),
        contains('knockout-stage-${primary.id}'),
      );
      expect(appBarState.valueOrNull?.gamesAppBarModels, hasLength(21));

      final grouped = container.read(gamesTourGroupedProvider);
      expect(
        grouped.isLoading,
        isFalse,
        reason:
            'this is the exact loading flag consumed by TournamentGamesView',
      );
      expect(grouped.filteredRounds, isNotEmpty);
      expect(grouped.allGames, isNotEmpty);

      expect(
        roundRepository.bulkFetches,
        lessThanOrEqualTo(2),
        reason:
            'the initial request plus one coalesced catch-up is the maximum',
      );
      expect(
        roundRepository.maxConcurrentBulkFetches,
        1,
        reason: 'multi-stage metadata loads must never overlap',
      );

      final stableRoundIds = appBarState.valueOrNull!.gamesAppBarModels
          .map((round) => round.id)
          .toList(growable: false);
      roundRepository.failBulkFetches = true;
      await container.read(gamesAppBarProvider.notifier).refresh();

      final afterFailedRefresh = container.read(gamesAppBarProvider);
      expect(afterFailedRefresh.isLoading, isFalse);
      expect(afterFailedRefresh.hasError, isFalse);
      expect(
        afterFailedRefresh.valueOrNull?.gamesAppBarModels.map(
          (round) => round.id,
        ),
        orderedEquals(stableRoundIds),
        reason:
            'a failed metadata refresh must retain the rendered tournament '
            'instead of returning to an indefinite spinner',
      );
    },
  );

  test(
    'stalled optional selection lookup falls back and exits games spinner',
    () async {
      final now = DateTime.utc(2026, 7, 24, 12);
      final tour = _tour(
        id: 'stalled-selection-tour',
        name: 'Dole Open',
        startsAt: now.subtract(const Duration(hours: 4)),
      );
      final round = _round(
        id: 'stalled-selection-round',
        tourId: tour.id,
        startsAt: tour.dates.first,
      );
      final roundRepository = _BlockingSiblingRoundRepository(
        primaryTourId: tour.id,
        roundsByTourId: <String, List<Round>>{
          tour.id: <Round>[round],
        },
      );
      final gameRepository = _StalledSelectionGameRepository();

      final container = ProviderContainer(
        overrides: <Override>[
          tourRepositoryProvider.overrideWithValue(
            _TournamentDetailTourRepository(<Tour>[tour]),
          ),
          roundRepositoryProvider.overrideWithValue(roundRepository),
          gameRepositoryProvider.overrideWithValue(gameRepository),
          settingsRepositoryProvider.overrideWithValue(
            _SilentSettingsRepository(),
          ),
          gamesLocalStorage.overrideWith(
            (ref) => _FixtureGamesLocalStorage(ref, <String, List<Games>>{
              tour.id: <Games>[
                _game(id: 'stalled-game', tourId: tour.id, roundId: round.id),
              ],
            }),
          ),
          shouldStreamProvider.overrideWith((ref) => false),
          tourDetailSelectionLookupTimeoutProvider.overrideWith(
            (ref) => const Duration(milliseconds: 20),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(selectedBroadcastModelProvider.notifier)
          .state = GroupBroadcast(
        id: 'titled-tuesday',
        createdAt: now,
        name: 'Dole Open',
        search: const <String>[],
      );
      final subscription = container.listen(
        gamesTourGroupedProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _waitUntil(() {
        final grouped = container.read(gamesTourGroupedProvider);
        return !grouped.isLoading && grouped.allGames.isNotEmpty;
      });

      expect(gameRepository.selectionLookupStarted, isTrue);
      final grouped = container.read(gamesTourGroupedProvider);
      expect(grouped.isLoading, isFalse);
      expect(
        grouped.allGames.map((game) => game.gameId),
        contains('stalled-game'),
      );
    },
  );
}

Future<void> _pumpEventQueue() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

Tour _tour({
  required String id,
  required String name,
  required DateTime startsAt,
}) {
  return Tour(
    id: id,
    name: name,
    slug: id,
    info: const TourInfo(format: 'Knockout', tc: '3+1'),
    createdAt: startsAt.subtract(const Duration(hours: 1)),
    url: 'https://example.com/$id',
    tier: 1,
    dates: <DateTime>[startsAt, startsAt.add(const Duration(hours: 6))],
    players: const <TournamentPlayer>[],
    groupBroadcastId: 'titled-tuesday',
  );
}

Round _round({
  required String id,
  required String tourId,
  required DateTime startsAt,
}) {
  return Round(
    id: id,
    slug: 'game-1',
    tourId: tourId,
    tourSlug: tourId,
    name: 'Game 1',
    createdAt: startsAt,
    startsAt: startsAt,
    url: 'https://example.com/$tourId/$id',
  );
}

Games _game({
  required String id,
  required String tourId,
  required String roundId,
}) {
  return Games(
    id: id,
    roundId: roundId,
    roundSlug: 'game-1',
    tourId: tourId,
    tourSlug: tourId,
    status: '*',
    boardNr: 1,
    lastMove: 'e2e4',
    players: <Player>[
      Player(
        name: 'White $id',
        title: 'GM',
        rating: 2700,
        fideId: 1,
        fed: 'USA',
        clock: 300,
        team: '',
      ),
      Player(
        name: 'Black $id',
        title: 'GM',
        rating: 2700,
        fideId: 2,
        fed: 'NOR',
        clock: 300,
        team: '',
      ),
    ],
  );
}

class _TournamentDetailTourRepository implements TourRepository {
  _TournamentDetailTourRepository(this.tours);

  final List<Tour> tours;

  @override
  Future<List<Tour>> getTourByGroupId(String groupId) async => tours;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TournamentDetailGameRepository implements GameRepository {
  _TournamentDetailGameRepository(this.primaryTourId);

  final String primaryTourId;

  @override
  Future<String?> getMostRelevantTourId({required List<String> tourIds}) async {
    return primaryTourId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StalledSelectionGameRepository implements GameRepository {
  final Completer<String?> _selectionLookup = Completer<String?>();
  bool selectionLookupStarted = false;

  @override
  Future<String?> getMostRelevantTourId({required List<String> tourIds}) {
    selectionLookupStarted = true;
    return _selectionLookup.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockingSiblingRoundRepository implements RoundRepository {
  _BlockingSiblingRoundRepository({
    required this.primaryTourId,
    required this.roundsByTourId,
  });

  final String primaryTourId;
  final Map<String, List<Round>> roundsByTourId;
  final Completer<List<Round>> _blockedSibling = Completer<List<Round>>();

  bool siblingSingleFetchStarted = false;
  int bulkFetches = 0;
  int _activeBulkFetches = 0;
  int maxConcurrentBulkFetches = 0;
  bool failBulkFetches = false;

  @override
  Future<List<Round>> getRoundsByTourId(String tourId) {
    if (tourId == primaryTourId) {
      return Future<List<Round>>.value(roundsByTourId[tourId] ?? const []);
    }
    siblingSingleFetchStarted = true;
    return _blockedSibling.future;
  }

  @override
  Future<Map<String, List<Round>>> getRoundsByTourIds(
    List<String> tourIds,
  ) async {
    bulkFetches++;
    _activeBulkFetches++;
    if (_activeBulkFetches > maxConcurrentBulkFetches) {
      maxConcurrentBulkFetches = _activeBulkFetches;
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (failBulkFetches) {
        throw StateError('transient bulk round metadata failure');
      }
      return <String, List<Round>>{
        for (final tourId in tourIds)
          tourId: roundsByTourId[tourId] ?? const <Round>[],
      };
    } finally {
      _activeBulkFetches--;
    }
  }

  @override
  Future<Map<String, DateTime>> getLatestPlayedRoundTimesByTourIds(
    List<String> tourIds, {
    DateTime? now,
  }) async => const <String, DateTime>{};

  @override
  Future<Round?> getLatestRoundByLastMove(String tourId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureGamesLocalStorage extends GamesLocalStorage {
  _FixtureGamesLocalStorage(super.ref, this.gamesByTourId);

  final Map<String, List<Games>> gamesByTourId;

  @override
  Future<List<Games>> fetchAndSaveGames(
    String tourId, {
    bool forceRefresh = false,
  }) async => gamesByTourId[tourId] ?? const <Games>[];
}

class _SilentSettingsRepository implements SettingsRepository {
  @override
  Future<Settings?> getSettings() async => null;

  @override
  Stream<Settings?> subscribeToSettings() => const Stream<Settings?>.empty();

  @override
  Stream<List<String>> subscribeToLiveGroupBroadcastIds() =>
      const Stream<List<String>>.empty();

  @override
  Stream<List<String>> subscribeToLiveRoundIds() =>
      const Stream<List<String>>.empty();

  @override
  Stream<List<String>> subscribeToLiveTourIds() =>
      const Stream<List<String>>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
