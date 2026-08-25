import 'package:flutter_test/flutter_test.dart';

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
    expect(
      sourceGameCountForScreenModel(
        displayMode: GameDisplayMode.all,
        primaryProviderGameCount: 72,
        processedInputGameCount: 100,
      ),
      72,
    );
  });

  test('filtered mode source coverage follows its filtered input', () {
    expect(
      sourceGameCountForScreenModel(
        displayMode: GameDisplayMode.hideFinishedGames,
        primaryProviderGameCount: 72,
        processedInputGameCount: 31,
      ),
      31,
    );
  });
}
