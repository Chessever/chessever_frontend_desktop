import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

GamebaseFilters sanitizeBuildTreeExplorerFilters(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  return GamebaseFilters(
    timeControls: filters.timeControls,
    playerIds: <String>[scopedPlayer.id],
    selectedPlayers: <GamebasePlayer>[scopedPlayer],
    playerColor: filters.playerColor,
    isOnline: filters.isOnline,
    sortBy: filters.sortBy,
    sortDirection: filters.sortDirection,
  );
}
