import 'dart:async';

import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/favorites/favorite_players_provider.dart';
import 'package:chessever/screens/favorites/player_games/provider/favorites_combined_games_provider.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('waits for favorite players before loading favorite games', () async {
    final favoritesCompleter = Completer<FavoritePlayersState>();
    final gameRepository = _FakeGameRepository();
    final container = ProviderContainer(
      overrides: [
        favoritePlayersNotifierProvider.overrideWith(
          () => _DelayedFavoritePlayersNotifier(favoritesCompleter.future),
        ),
        gameRepositoryProvider.overrideWithValue(gameRepository),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(
      favoritesCombinedGamesProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);

    await Future<void>.delayed(Duration.zero);

    expect(container.read(favoritesCombinedGamesProvider).isLoading, isTrue);
    expect(gameRepository.distinctDateCalls, 0);
    expect(gameRepository.gamesByDateCalls, 0);

    favoritesCompleter.complete(
      const FavoritePlayersState(
        players: [
          PlayerStandingModel(
            countryCode: 'NOR',
            name: 'Carlsen, Magnus',
            score: 2830,
            scoreChange: 0,
            matchScore: null,
            fideId: 1503014,
          ),
        ],
      ),
    );

    await _waitUntil(
      () => !container.read(favoritesCombinedGamesProvider).isLoading,
    );

    final state = container.read(favoritesCombinedGamesProvider);
    expect(gameRepository.distinctDateCalls, 1);
    expect(gameRepository.gamesByDateCalls, 1);
    expect(state.games.map((game) => game.gameId), ['game-1']);
    expect(state.hasMore, isFalse);
  });
}

class _DelayedFavoritePlayersNotifier extends FavoritePlayersNotifier {
  _DelayedFavoritePlayersNotifier(this._future);

  final Future<FavoritePlayersState> _future;

  @override
  Future<FavoritePlayersState> build() => _future;
}

class _FakeGameRepository implements GameRepository {
  int distinctDateCalls = 0;
  int gamesByDateCalls = 0;

  @override
  Future<List<DateTime>> getDistinctDatesForFavorites({
    required List<String> fideIds,
    int limit = 30,
    int offset = 0,
  }) async {
    distinctDateCalls++;
    expect(fideIds, ['1503014']);
    return [DateTime(2026, 5, 7)];
  }

  @override
  Future<List<Games>> getGamesByFideIdsAndDate({
    required List<String> fideIds,
    required DateTime date,
    String? eco,
  }) async {
    gamesByDateCalls++;
    expect(fideIds, ['1503014']);
    expect(date, DateTime(2026, 5, 7));
    return [_game()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Games _game() {
  return Games(
    id: 'game-1',
    roundId: 'round-1',
    roundSlug: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'Test Event',
    status: '*',
    lastMove: 'e4',
    dateStart: DateTime(2026, 5, 7),
    players: [
      Player(
        name: 'Carlsen, Magnus',
        title: 'GM',
        rating: 2830,
        fideId: 1503014,
        fed: 'NOR',
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Nakamura, Hikaru',
        title: 'GM',
        rating: 2800,
        fideId: 2016192,
        fed: 'USA',
        clock: 0,
        team: '',
      ),
    ],
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 50; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}
