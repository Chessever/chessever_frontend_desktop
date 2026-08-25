import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';

void main() {
  test(
    'empty Live result is ready when the tournament has completed games',
    () {
      const providerGameIds = <String>['completed-game'];
      const modeledGameIds = <String>[];
      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.hideFinishedGames,
          isSearchMode: false,
          providerGameCount: providerGameIds.length,
          modelGameCount: modeledGameIds.length,
          providerGamesFingerprint: Object.hashAll(providerGameIds),
          modelGamesFingerprint: Object.hashAll(modeledGameIds),
        ),
        isTrue,
      );
    },
  );

  test('empty All snapshot waits for raw games to be modeled', () {
    const providerGameIds = <String>['current-game'];
    const modeledGameIds = <String>[];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: providerGameIds.length,
        modelGameCount: modeledGameIds.length,
        providerGamesFingerprint: Object.hashAll(providerGameIds),
        modelGamesFingerprint: Object.hashAll(modeledGameIds),
      ),
      isFalse,
    );
  });

  test('partial All snapshot waits for the complete provider model', () {
    const providerGameIds = <String>['board-a', 'board-b', 'board-c'];
    const modeledGameIds = <String>['board-b'];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: providerGameIds.length,
        modelGameCount: modeledGameIds.length,
        providerGamesFingerprint: Object.hashAll(providerGameIds),
        modelGamesFingerprint: Object.hashAll(modeledGameIds),
      ),
      isFalse,
    );
  });

  test(
    'complete source coverage is ready when malformed models are skipped',
    () {
      const sourceGameIds = <String>['renderable-game', 'malformed-game'];
      final sourceFingerprint = Object.hashAll(sourceGameIds);
      final model = GamesScreenModel(
        gamesTourModels: const [],
        pinnedGamedIs: const [],
        sourceGameCount: sourceGameIds.length,
        sourceGamesFingerprint: sourceFingerprint,
      );

      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.all,
          isSearchMode: false,
          providerGameCount: sourceGameIds.length,
          modelGameCount: model.sourceGameCount,
          providerGamesFingerprint: sourceFingerprint,
          modelGamesFingerprint: model.sourceGamesFingerprint,
        ),
        isTrue,
      );
    },
  );

  test('same-size All snapshot waits for the current live-round identity', () {
    const previousRoundGameIds = <String>['previous-round-board'];
    const currentRoundGameIds = <String>['current-round-board'];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: currentRoundGameIds.length,
        modelGameCount: previousRoundGameIds.length,
        providerGamesFingerprint: Object.hashAll(currentRoundGameIds),
        modelGamesFingerprint: Object.hashAll(previousRoundGameIds),
      ),
      isFalse,
    );
  });

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
