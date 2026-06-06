import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

/// Color scope to use for the current player when building a player tree.
enum PlayerBuildTreePreparationSide { white, black, both }

extension PlayerBuildTreePreparationSideX on PlayerBuildTreePreparationSide {
  String get label {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return 'Prepare against White';
      case PlayerBuildTreePreparationSide.black:
        return 'Prepare against Black';
      case PlayerBuildTreePreparationSide.both:
        return 'Prepare against both';
    }
  }

  String get description {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return 'Use games where this player played White';
      case PlayerBuildTreePreparationSide.black:
        return 'Use games where this player played Black';
      case PlayerBuildTreePreparationSide.both:
        return 'Use this player’s games from both colors';
    }
  }

  /// Explorer color filter for the current player.
  ///
  /// The prompt text is direct: preparing against White uses current-player-as-
  /// White games, preparing against Black uses current-player-as-Black games,
  /// and both colors intentionally clears the color scope.
  GamebasePlayerColor? get targetPlayerColor {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return GamebasePlayerColor.white;
      case PlayerBuildTreePreparationSide.black:
        return GamebasePlayerColor.black;
      case PlayerBuildTreePreparationSide.both:
        return null;
    }
  }
}

GamebaseFilters buildPlayerProfileTreeFilters({
  required GamebaseFilters baseFilters,
  required String playerId,
  required GamebasePlayer player,
  required PlayerBuildTreePreparationSide preparationSide,
}) {
  return baseFilters.copyWith(
    playerIds: [playerId],
    selectedPlayers: [player],
    playerColor: preparationSide.targetPlayerColor,
  );
}
