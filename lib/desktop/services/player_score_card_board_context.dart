/// Helpers for preserving the intended left-rail context when a game is opened
/// from a desktop player score card.
///
/// The score-card view may resolve a full tournament/source list first and then
/// filter it down to the selected player's rows for display. Board tabs opened
/// from that displayed list should carry the displayed player-scoped rows, not
/// the broader tournament source.
List<T> selectPlayerScoreCardBoardRailGames<T>({
  required List<T> displayedGames,
  required List<T> resolvedGames,
}) {
  return displayedGames.isNotEmpty ? displayedGames : resolvedGames;
}
