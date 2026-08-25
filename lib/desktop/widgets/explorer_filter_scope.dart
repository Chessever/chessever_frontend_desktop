import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

GamebaseFilters sanitizeBuildTreeExplorerFilters(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  final opponentId = _buildTreeOpponentId(filters, scopedPlayer);
  final opponent = _playerById(filters.selectedPlayers, opponentId);
  final selectedPlayers = <GamebasePlayer>[
    scopedPlayer,
    for (final player in filters.selectedPlayers)
      if (player.id != scopedPlayer.id && player.id != opponentId) player,
    if (opponent != null) opponent,
  ];
  return filters.copyWith(
    playerIds: <String>[scopedPlayer.id, if (opponentId != null) opponentId],
    // Combined Player trees include source-specific identities for the same
    // person (for example a Chess.com handle plus the ChessEver full name).
    // Keep those aliases when a filter changes; dropping them makes the local
    // tree appear to switch sources because only one account remains matched.
    selectedPlayers: selectedPlayers,
  );
}

GamebasePlayer? buildTreeOpponentFilter(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  return _playerById(
    filters.selectedPlayers,
    _buildTreeOpponentId(filters, scopedPlayer),
  );
}

GamebaseFilters setBuildTreeOpponentFilter(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
  GamebasePlayer opponent,
) {
  final scoped = sanitizeBuildTreeExplorerFilters(filters, scopedPlayer);
  final previousOpponentId = _buildTreeOpponentId(scoped, scopedPlayer);
  return scoped.copyWith(
    playerIds: <String>[scopedPlayer.id, opponent.id],
    selectedPlayers: <GamebasePlayer>[
      scopedPlayer,
      for (final player in scoped.selectedPlayers)
        if (player.id != scopedPlayer.id &&
            player.id != previousOpponentId &&
            player.id != opponent.id)
          player,
      opponent,
    ],
  );
}

GamebaseFilters clearBuildTreeOpponentFilter(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  final scoped = sanitizeBuildTreeExplorerFilters(filters, scopedPlayer);
  final opponentId = _buildTreeOpponentId(scoped, scopedPlayer);
  return scoped.copyWith(
    playerIds: <String>[scopedPlayer.id],
    selectedPlayers: <GamebasePlayer>[
      scopedPlayer,
      for (final player in scoped.selectedPlayers)
        if (player.id != scopedPlayer.id && player.id != opponentId) player,
    ],
  );
}

GamebaseFilters clearBuildTreeExplorerFilters(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  final scoped = clearBuildTreeOpponentFilter(filters, scopedPlayer);
  return GamebaseFilters(
    playerIds: scoped.playerIds,
    selectedPlayers: scoped.selectedPlayers,
  );
}

int explorerActiveFilterCount(
  GamebaseFilters filters,
  GamebasePlayer? scopedPlayer,
) {
  var count = 0;
  if (filters.timeControls.isNotEmpty) count += 1;
  if (filters.minRating != null || filters.maxRating != null) count += 1;
  if (filters.playerColor != null) count += 1;
  if (filters.gameResult != null) count += 1;
  if (filters.isOnline != null) count += 1;
  if (filters.yearFrom != null || filters.yearTo != null) count += 1;
  if (scopedPlayer == null) {
    if (filters.playerIds.isNotEmpty) count += 1;
  } else if (_buildTreeOpponentId(filters, scopedPlayer) != null) {
    count += 1;
  }
  return count;
}

String? _buildTreeOpponentId(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  for (final id in filters.playerIds) {
    final normalized = id.trim();
    if (normalized.isNotEmpty && normalized != scopedPlayer.id) {
      return normalized;
    }
  }
  return null;
}

GamebasePlayer? _playerById(List<GamebasePlayer> players, String? playerId) {
  if (playerId == null) return null;
  for (final player in players) {
    if (player.id == playerId) return player;
  }
  return null;
}
