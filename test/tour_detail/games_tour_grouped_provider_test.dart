import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';

void main() {
  test(
    'empty Live result is ready when the tournament has completed games',
    () {
      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.hideFinishedGames,
          isSearchMode: false,
          providerGameCount: 10,
          modelGameCount: 0,
        ),
        isTrue,
      );
    },
  );

  test('empty All snapshot waits for raw games to be modeled', () {
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: 10,
        modelGameCount: 0,
      ),
      isFalse,
    );
  });

  test('partial All snapshot waits for the complete provider model', () {
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: 630,
        modelGameCount: 72,
      ),
      isFalse,
    );
  });

  test(
    'complete source coverage is ready when malformed models are skipped',
    () {
      final model = GamesScreenModel(
        gamesTourModels: const [],
        pinnedGamedIs: const [],
        sourceGameCount: 630,
      );

      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.all,
          isSearchMode: false,
          providerGameCount: 630,
          modelGameCount: model.sourceGameCount,
        ),
        isTrue,
      );
    },
  );

  test('Live mode includes only games explicitly marked ongoing', () {
    expect(
      isGameStatusVisible(
        displayMode: GameDisplayMode.hideFinishedGames,
        gameStatus: GameStatus.ongoing,
      ),
      isTrue,
    );

    for (final status in <GameStatus>[
      GameStatus.whiteWins,
      GameStatus.blackWins,
      GameStatus.draw,
      GameStatus.unknown,
    ]) {
      expect(
        isGameStatusVisible(
          displayMode: GameDisplayMode.hideFinishedGames,
          gameStatus: status,
        ),
        isFalse,
        reason: '$status is not a live game',
      );
    }
  });
}
