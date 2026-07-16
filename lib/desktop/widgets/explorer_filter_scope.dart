import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

GamebaseFilters sanitizeBuildTreeExplorerFilters(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  final selectedPlayers = <GamebasePlayer>[
    scopedPlayer,
    for (final player in filters.selectedPlayers)
      if (player.id != scopedPlayer.id) player,
  ];
  return GamebaseFilters(
    timeControls: filters.timeControls,
    playerIds: <String>[scopedPlayer.id],
    // Combined Player trees include source-specific identities for the same
    // person (for example a Chess.com handle plus the ChessEver full name).
    // Keep those aliases when a filter changes; dropping them makes the local
    // tree appear to switch sources because only one account remains matched.
    selectedPlayers: selectedPlayers,
    playerColor: filters.playerColor,
    isOnline: filters.isOnline,
    sortBy: filters.sortBy,
    sortDirection: filters.sortDirection,
  );
}
