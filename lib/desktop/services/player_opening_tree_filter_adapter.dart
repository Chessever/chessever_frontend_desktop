import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

String? playerOpeningTreeOpponentId(
  GamebaseFilters filters, {
  String? subjectPlayerId,
}) {
  final subjectId = subjectPlayerId?.trim() ?? filters.requestPlayerId?.trim();
  for (final id in filters.playerIds) {
    final normalized = id.trim();
    if (normalized.isNotEmpty && normalized != subjectId) return normalized;
  }
  return null;
}

PlayerOpeningTreeFilterCriteria playerOpeningTreeCriteriaFromFilters(
  GamebaseFilters filters, {
  String? subjectPlayerId,
}) {
  final subjectId = subjectPlayerId?.trim() ?? filters.requestPlayerId?.trim();
  final opponentId = playerOpeningTreeOpponentId(
    filters,
    subjectPlayerId: subjectId,
  );
  final opponentPlayers = <GamebasePlayer>[
    for (final player in filters.selectedPlayers)
      if (player.id == opponentId) player,
  ];
  final subjectPlayers = <GamebasePlayer>[
    for (final player in filters.selectedPlayers)
      if (player.id != opponentId) player,
  ];

  return PlayerOpeningTreeFilterCriteria(
    playerId: subjectId,
    playerIds: <String>[if (subjectId?.isNotEmpty == true) subjectId!],
    playerFideIds: _fideIds(subjectPlayers),
    playerNames: _names(subjectPlayers),
    opponentIds: <String>[if (opponentId != null) opponentId],
    opponentFideIds: _fideIds(opponentPlayers),
    opponentNames: _names(opponentPlayers),
    timeControl: filters.requestTimeControl,
    minRating: filters.minRating,
    maxRating: filters.maxRating,
    color: filters.requestColor,
    result: filters.requestResult,
    isOnline: filters.isOnline,
    yearFrom: filters.yearFrom,
    yearTo: filters.yearTo,
  );
}

List<String> _fideIds(List<GamebasePlayer> players) {
  return <String>[
    for (final player in players)
      if (player.fideId.trim().isNotEmpty) player.fideId.trim(),
  ];
}

List<String> _names(List<GamebasePlayer> players) {
  return <String>[
    for (final player in players)
      if (player.name.trim().isNotEmpty) player.name.trim(),
  ];
}
