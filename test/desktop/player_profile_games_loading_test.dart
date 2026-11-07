import 'dart:async';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models_extra.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _playerKey = PlayerProfileKey(
  playerName: 'Profile Player',
  source: PlayerProfileDataSource.twic,
);

void main() {
  late _SearchRepository repository;
  late ProviderContainer container;

  setUp(() {
    repository = _SearchRepository();
    container = ProviderContainer(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(repository),
        twicPlayerIdProvider(_playerKey).overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
  });

  test(
    'profile with no matching archive games loads without an error',
    () async {
      final state = await _waitForLoadedGames(container);

      expect(state.error, isNull);
      expect(state.allGames, isEmpty);
      expect(state.filteredGames, isEmpty);
      expect(state.totalCount, 0);
      expect(state.hasMorePages, isFalse);

      await container
          .read(playerProfileGamesKeyProvider(_playerKey).notifier)
          .refresh();

      final refreshed = container.read(
        playerProfileGamesKeyProvider(_playerKey),
      );
      expect(refreshed.error, isNull);
      expect(refreshed.allGames, isEmpty);
      expect(refreshed.isLoading, isFalse);
    },
  );

  test('a search with no matches clears previously loaded games', () async {
    repository.results = [
      _searchGame('older', '2026-01-01'),
      _searchGame('newer', '2026-02-01'),
    ];
    final initial = await _waitForLoadedGames(container);

    expect(initial.error, isNull);
    expect(initial.allGames.map((game) => game.gameId), ['newer', 'older']);
    expect(initial.totalCount, 2);

    repository.results = const [];
    container
        .read(playerProfileGamesKeyProvider(_playerKey).notifier)
        .setSearchQuery('event:no-matches');
    final empty = await _waitForLoadedGames(container);

    expect(empty.error, isNull);
    expect(empty.allGames, isEmpty);
    expect(empty.totalCount, 0);
    expect(empty.hasMorePages, isFalse);
    expect(empty.searchQuery, 'event:no-matches');
  });
}

Future<PlayerProfileGamesState> _waitForLoadedGames(
  ProviderContainer container,
) {
  final loaded = Completer<PlayerProfileGamesState>();
  final subscription = container.listen(
    playerProfileGamesKeyProvider(_playerKey),
    (_, state) {
      if (!state.isLoading && !loaded.isCompleted) loaded.complete(state);
    },
    fireImmediately: true,
  );
  addTearDown(subscription.close);
  return loaded.future;
}

GamebaseSearchResult _searchGame(String id, String date) =>
    GamebaseSearchResult(
      resource: 'game',
      id: id,
      score: 1,
      label: 'Profile Player - Opponent',
      preview: {
        'white': _playerKey.playerName,
        'black': 'Opponent',
        'result': '1-0',
        'date': date,
      },
    );

class _SearchRepository extends Fake implements GamebaseRepository {
  List<GamebaseSearchResult> results = const [];

  @override
  Future<GamebaseGlobalSearchResponse> globalSearch({
    required String query,
    List<String>? resources,
    int pageNumber = 1,
    int pageSize = 20,
    String? result,
    String? color,
    String? timeControl,
    int? yearFrom,
    int? yearTo,
    int? ratingFrom,
    int? ratingTo,
    bool? isOnline,
  }) async => GamebaseGlobalSearchResponse(
    status: 'success',
    results: results,
    metadata: GamebasePaginationMetadata(
      pageNumber: pageNumber,
      pageSize: pageSize,
      totalCount: results.length,
      hasMoreValue: false,
    ),
  );
}
