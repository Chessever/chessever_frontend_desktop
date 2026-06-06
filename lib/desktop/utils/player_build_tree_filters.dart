import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

/// Color perspective the user is preparing from when building a player tree.
enum PlayerBuildTreePreparationSide { white, black, both }

extension PlayerBuildTreePreparationSideX on PlayerBuildTreePreparationSide {
  String get label {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return 'White';
      case PlayerBuildTreePreparationSide.black:
        return 'Black';
      case PlayerBuildTreePreparationSide.both:
        return 'Both colors';
    }
  }

  String get description {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return 'Prepare with White against this player';
      case PlayerBuildTreePreparationSide.black:
        return 'Prepare with Black against this player';
      case PlayerBuildTreePreparationSide.both:
        return 'Use all games for both colors';
    }
  }

  /// Explorer color filter for the target player, not the preparing user.
  ///
  /// Preparing as White means the opponent is Black; preparing as Black means
  /// the opponent is White. Both colors intentionally clears the color scope.
  GamebasePlayerColor? get targetPlayerColor {
    switch (this) {
      case PlayerBuildTreePreparationSide.white:
        return GamebasePlayerColor.black;
      case PlayerBuildTreePreparationSide.black:
        return GamebasePlayerColor.white;
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
