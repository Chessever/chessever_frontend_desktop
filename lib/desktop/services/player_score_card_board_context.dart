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
  T? selectedGame,
  bool Function(T game, T selectedGame)? isSameGame,
  int contextRadius = 30,
}) {
  final source = displayedGames.isNotEmpty ? displayedGames : resolvedGames;
  if (selectedGame == null || isSameGame == null) return source;
  return _selectedContextWindow(
    selectedGame: selectedGame,
    games: source,
    isSameGame: isSameGame,
    contextRadius: contextRadius,
  );
}

List<T> _selectedContextWindow<T>({
  required T selectedGame,
  required List<T> games,
  required bool Function(T game, T selectedGame) isSameGame,
  required int contextRadius,
}) {
  if (games.isEmpty) return <T>[selectedGame];
  final selectedIndex = games.indexWhere(
    (game) => isSameGame(game, selectedGame),
  );
  if (selectedIndex < 0) return <T>[selectedGame];

  final radius = contextRadius < 0 ? 0 : contextRadius;
  final start = selectedIndex - radius < 0 ? 0 : selectedIndex - radius;
  final end =
      selectedIndex + radius + 1 > games.length
          ? games.length
          : selectedIndex + radius + 1;
  return games.sublist(start, end);
}
