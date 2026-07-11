import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Separates the games rendered by a For You preview strip from the complete
/// event context carried into the board rail when one of those games opens.
class DesktopForYouGameContext {
  const DesktopForYouGameContext({
    required this.stripGames,
    required this.boardGames,
  });

  final List<GamesTourModel> stripGames;
  final List<GamesTourModel> boardGames;
}

DesktopForYouGameContext buildDesktopForYouGameContext({
  required List<GamesTourModel> snapshotGames,
  required List<GamesTourModel> fullVisibleGames,
  required List<GamesTourModel> fullEventGames,
}) {
  final stripGames = _buildStripGames(
    snapshotGames: snapshotGames,
    fullVisibleGames: fullVisibleGames,
  );
  final boardGames =
      fullEventGames.isNotEmpty
          ? fullEventGames
          : fullVisibleGames.isNotEmpty
          ? fullVisibleGames
          : snapshotGames;

  return DesktopForYouGameContext(
    stripGames: List<GamesTourModel>.unmodifiable(stripGames),
    boardGames: List<GamesTourModel>.unmodifiable(boardGames),
  );
}

List<GamesTourModel> _buildStripGames({
  required List<GamesTourModel> snapshotGames,
  required List<GamesTourModel> fullVisibleGames,
}) {
  if (fullVisibleGames.isEmpty) return snapshotGames;

  final previewRoundIds = <String>{
    for (final game in snapshotGames)
      if (game.roundId.trim().isNotEmpty) game.roundId,
  };
  final scoped =
      previewRoundIds.isEmpty
          ? fullVisibleGames
          : fullVisibleGames
              .where((game) => previewRoundIds.contains(game.roundId))
              .toList(growable: false);
  if (scoped.isEmpty) return snapshotGames;

  // Preserve the feed snapshot's priority/pin ordering, then append any
  // remaining boards in stable board-number order.
  final snapshotOrder = <String, int>{
    for (var i = 0; i < snapshotGames.length; i++) snapshotGames[i].gameId: i,
  };
  final overflowRank = snapshotOrder.length;
  return scoped.toList(growable: false)..sort((a, b) {
    final ai = snapshotOrder[a.gameId] ?? overflowRank;
    final bi = snapshotOrder[b.gameId] ?? overflowRank;
    if (ai != bi) return ai.compareTo(bi);
    final ab = a.boardNr;
    final bb = b.boardNr;
    if (ab != null && bb != null && ab != bb) return ab.compareTo(bb);
    if (ab != null && bb == null) return -1;
    if (ab == null && bb != null) return 1;
    return a.gameId.compareTo(b.gameId);
  });
}
