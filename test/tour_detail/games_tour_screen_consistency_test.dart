import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';

void main() {
  test('new screen computation invalidates every older completion', () {
    final epoch = GamesScreenRecomputeEpoch();

    final staleGeneration = epoch.begin();
    final freshGeneration = epoch.begin();

    expect(epoch.isCurrent(staleGeneration), isFalse);
    expect(epoch.isCurrent(freshGeneration), isTrue);

    epoch.invalidate();

    expect(epoch.isCurrent(freshGeneration), isFalse);
  });

  test('All mode source coverage stays scoped to the primary provider', () {
    const primaryProviderGames = <String>[
      'selected-stage-board-a',
      'selected-stage-board-b',
    ];
    const processedGames = <String>[
      ...primaryProviderGames,
      'sibling-stage-board',
    ];

    expect(
      sourceGameCountForScreenModel(
        displayMode: GameDisplayMode.all,
        primaryProviderGameCount: primaryProviderGames.length,
        processedInputGameCount: processedGames.length,
      ),
      primaryProviderGames.length,
    );
  });

  test('filtered mode source coverage follows its filtered input', () {
    const primaryProviderGames = <String>[
      'finished-board',
      'live-board-a',
      'live-board-b',
    ];
    const visibleLiveGames = <String>['live-board-a', 'live-board-b'];

    expect(
      sourceGameCountForScreenModel(
        displayMode: GameDisplayMode.hideFinishedGames,
        primaryProviderGameCount: primaryProviderGames.length,
        processedInputGameCount: visibleLiveGames.length,
      ),
      visibleLiveGames.length,
    );
  });

  test('live snapshot identity changes with round and board assignments', () {
    final previousRound = <Games>[
      _sourceGame(id: 'game-a', roundId: 'previous-round', boardNr: 1),
      _sourceGame(id: 'game-b', roundId: 'previous-round', boardNr: 2),
    ];
    final currentRound = <Games>[
      _sourceGame(id: 'game-a', roundId: 'current-round', boardNr: 2),
      _sourceGame(id: 'game-b', roundId: 'current-round', boardNr: 1),
    ];

    expect(currentRound.length, previousRound.length);
    expect(
      tournamentGamesSourceFingerprint(currentRound),
      isNot(tournamentGamesSourceFingerprint(previousRound)),
    );
  });

  test(
    'live snapshot identity does not depend on repository arrival order',
    () {
      final games = <Games>[
        _sourceGame(id: 'game-a', roundId: 'current-round', boardNr: 1),
        _sourceGame(id: 'game-b', roundId: 'current-round', boardNr: 2),
      ];

      expect(
        tournamentGamesSourceFingerprint(games.reversed),
        tournamentGamesSourceFingerprint(games),
      );
    },
  );
}

Games _sourceGame({
  required String id,
  required String roundId,
  required int boardNr,
}) {
  return Games(
    id: id,
    roundId: roundId,
    roundSlug: roundId,
    tourId: 'dynamic-tournament',
    tourSlug: 'dynamic-tournament',
    status: '*',
    boardNr: boardNr,
  );
}
