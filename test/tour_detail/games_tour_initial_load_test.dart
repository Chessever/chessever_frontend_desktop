import 'dart:async';

import 'package:chessever/repository/local_storage/tournament/games/games_local_storage.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Games _game(String id) {
  return Games(
    id: id,
    roundId: 'round',
    roundSlug: 'round',
    tourId: 'tour',
    tourSlug: 'tour',
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      Supabase.instance.client;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder-anon-key',
      );
    }
  });

  group('initial tournament game loading', () {
    test(
      'mounted notifier replaces an arbitrary partial cache with fresh games',
      () async {
        final freshGames = Completer<List<Games>>();
        final cachedPublished = Completer<void>();
        final freshPublished = Completer<void>();
        late _StaleCacheGamesLocalStorage storage;
        final container = ProviderContainer(
          overrides: [
            shouldStreamProvider.overrideWith((ref) => false),
            gamesLocalStorage.overrideWith((ref) {
              storage = _StaleCacheGamesLocalStorage(
                ref,
                cachedGames: List<Games>.generate(
                  72,
                  (index) => _game('cached-$index'),
                ),
                freshGames: freshGames,
              );
              return storage;
            }),
          ],
        );
        final subscription = container.listen(gamesTourProvider('tour'), (
          _,
          next,
        ) {
          final count = next.valueOrNull?.length;
          if (count == 72 && !cachedPublished.isCompleted) {
            cachedPublished.complete();
          }
          if (count == 630 && !freshPublished.isCompleted) {
            freshPublished.complete();
          }
        }, fireImmediately: true);
        addTearDown(() {
          subscription.close();
          container.dispose();
        });

        await cachedPublished.future.timeout(const Duration(seconds: 2));

        expect(storage.freshFetches, 1);
        freshGames.complete(
          List<Games>.generate(630, (index) => _game('fresh-$index')),
        );
        await freshPublished.future.timeout(const Duration(seconds: 2));

        expect(
          container.read(gamesTourProvider('tour')).valueOrNull,
          hasLength(630),
        );
      },
    );

    test('publishes cached games without waiting for the network', () async {
      var freshFetches = 0;

      final games = await loadInitialTournamentGames(
        readCachedGames: () async => [_game('cached')],
        fetchFreshGames: () async {
          freshFetches++;
          return [_game('fresh')];
        },
      );

      expect(games.single.id, 'cached');
      expect(freshFetches, 0);
    });

    test('fetches fresh games when no cache exists', () async {
      final games = await loadInitialTournamentGames(
        readCachedGames: () async => const [],
        fetchFreshGames: () async => [_game('fresh')],
      );

      expect(games.single.id, 'fresh');
    });

    test('forced refresh bypasses cached games', () async {
      var cacheReads = 0;

      final games = await loadInitialTournamentGames(
        readCachedGames: () async {
          cacheReads++;
          return [_game('cached')];
        },
        fetchFreshGames: () async => [_game('fresh')],
        useCache: false,
      );

      expect(games.single.id, 'fresh');
      expect(cacheReads, 0);
    });

    test(
      'refreshes a cache that ends exactly on a response-page boundary',
      () async {
        var freshFetches = 0;
        final cached = List<Games>.generate(
          3,
          (index) => _game('cached-$index'),
        );

        final games = await loadInitialTournamentGames(
          readCachedGames: () async => cached,
          fetchFreshGames: () async {
            freshFetches += 1;
            return List<Games>.generate(4, (index) => _game('fresh-$index'));
          },
          suspectPageSize: 3,
        );

        expect(games, hasLength(4));
        expect(games.last.id, 'fresh-3');
        expect(freshFetches, 1);
      },
    );

    test(
      'keeps a page-boundary cache when its healing refresh fails',
      () async {
        final cached = List<Games>.generate(
          3,
          (index) => _game('cached-$index'),
        );

        final games = await loadInitialTournamentGames(
          readCachedGames: () async => cached,
          fetchFreshGames: () async => throw StateError('offline'),
          suspectPageSize: 3,
        );

        expect(games, same(cached));
      },
    );

    test('real cache wrapper preserves repository fetch failures', () async {
      final container = ProviderContainer(
        overrides: [
          gameRepositoryProvider.overrideWithValue(_ThrowingGameRepository()),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(gamesLocalStorage)
            .fetchAndSaveGames('failing-tour', forceRefresh: true),
        throwsA(isA<StateError>()),
      );
    });

    test('stops waiting when the tournament feed does not respond', () async {
      final pending = Completer<List<Games>>();

      await expectLater(
        loadInitialTournamentGames(
          readCachedGames: () async => const [],
          fetchFreshGames: () => pending.future,
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

class _ThrowingGameRepository extends GameRepository {
  @override
  Future<List<Games>> getGamesByTourId(
    String tourId, {
    int? limit,
    int offset = 0,
  }) async {
    throw StateError('offline');
  }
}

class _StaleCacheGamesLocalStorage extends GamesLocalStorage {
  _StaleCacheGamesLocalStorage(
    super.ref, {
    required this.cachedGames,
    required this.freshGames,
  });

  final List<Games> cachedGames;
  final Completer<List<Games>> freshGames;
  int freshFetches = 0;

  @override
  Future<List<Games>> getCachedGames(String tourId) async => cachedGames;

  @override
  Future<List<Games>> fetchAndSaveGames(
    String tourId, {
    bool forceRefresh = false,
  }) {
    freshFetches += 1;
    return freshGames.future;
  }
}
