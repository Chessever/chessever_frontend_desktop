import 'dart:async';

import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:flutter_test/flutter_test.dart';

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
  group('initial tournament game loading', () {
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
