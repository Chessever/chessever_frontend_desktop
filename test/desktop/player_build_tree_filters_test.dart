import 'package:chessever/desktop/utils/player_build_tree_filters.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const playerId = 'player-uuid';
  const player = GamebasePlayer(
    id: playerId,
    fideId: '13401319',
    name: 'Mamedyarov, Shakhriyar',
    gender: PlayerGender.male,
    fed: 'AZE',
    title: 'GM',
    ratingClassical: 2717,
  );

  const baseFilters = GamebaseFilters(
    timeControls: [TimeControl.classical],
    minRating: 2400,
    maxRating: 2800,
    playerColor: GamebasePlayerColor.white,
    gameResult: GamebaseGameResult.draw,
    yearFrom: 2020,
    yearTo: 2026,
    isOnline: false,
  );

  test('prepare against White scopes the current player to White games', () {
    final filters = buildPlayerProfileTreeFilters(
      baseFilters: baseFilters,
      playerId: playerId,
      player: player,
      preparationSide: PlayerBuildTreePreparationSide.white,
    );

    expect(filters.playerIds, [playerId]);
    expect(filters.selectedPlayers, [player]);
    expect(filters.playerColor, GamebasePlayerColor.white);
    expect(filters.timeControls, baseFilters.timeControls);
    expect(filters.minRating, 2400);
    expect(filters.maxRating, 2800);
    expect(filters.gameResult, GamebaseGameResult.draw);
    expect(filters.yearFrom, 2020);
    expect(filters.yearTo, 2026);
    expect(filters.isOnline, isFalse);
  });

  test('prepare against Black scopes the current player to Black games', () {
    final filters = buildPlayerProfileTreeFilters(
      baseFilters: baseFilters,
      playerId: playerId,
      player: player,
      preparationSide: PlayerBuildTreePreparationSide.black,
    );

    expect(filters.playerIds, [playerId]);
    expect(filters.selectedPlayers, [player]);
    expect(filters.playerColor, GamebasePlayerColor.black);
  });

  test('preparing for both colors clears only the color scope', () {
    final filters = buildPlayerProfileTreeFilters(
      baseFilters: baseFilters,
      playerId: playerId,
      player: player,
      preparationSide: PlayerBuildTreePreparationSide.both,
    );

    expect(filters.playerIds, [playerId]);
    expect(filters.selectedPlayers, [player]);
    expect(filters.playerColor, isNull);
    expect(filters.gameResult, GamebaseGameResult.draw);
  });
}
