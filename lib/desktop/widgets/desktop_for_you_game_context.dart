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
  final previewGames = selectDesktopForYouPreviewRoundGames(snapshotGames);
  final stripGames = _buildStripGames(
    snapshotGames: previewGames,
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

/// Keeps ordinary event previews on the leading/current round selected by the
/// For You snapshot. A true two-player match may backfill up to three recent
/// games because each round normally contains only one board.
List<GamesTourModel> selectDesktopForYouPreviewRoundGames(
  List<GamesTourModel> orderedGames,
) {
  if (orderedGames.isEmpty) return const <GamesTourModel>[];

  final currentRoundKey = _previewRoundKey(orderedGames.first);
  if (currentRoundKey.isEmpty) {
    return List<GamesTourModel>.unmodifiable(orderedGames);
  }

  final currentRoundGames = orderedGames
      .where((game) => _previewRoundKey(game) == currentRoundKey)
      .toList(growable: false);
  if (!_isHeadToHeadMatch(orderedGames)) {
    return List<GamesTourModel>.unmodifiable(currentRoundGames);
  }

  return List<GamesTourModel>.unmodifiable(orderedGames.take(3));
}

/// Labels a game backfilled from an earlier match round. Ordinary event
/// previews never reach this path because they are scoped to the current
/// round before rendering.
String? desktopForYouBackfillRoundLabel({
  required GamesTourModel game,
  required GamesTourModel currentGame,
}) {
  final currentRoundKey = _previewRoundKey(currentGame);
  final gameRoundKey = _previewRoundKey(game);
  if (currentRoundKey.isEmpty ||
      gameRoundKey.isEmpty ||
      currentRoundKey == gameRoundKey) {
    return null;
  }

  final source =
      (game.roundSlug ?? '').trim().isNotEmpty
          ? game.roundSlug!.trim()
          : gameRoundKey;
  final roundNumbers = RegExp(
    r'\d+',
  ).allMatches(source).toList(growable: false);
  return roundNumbers.isEmpty ? 'Previous' : 'R${roundNumbers.last.group(0)}';
}

String _previewRoundKey(GamesTourModel game) {
  final roundId = game.roundId.trim();
  if (roundId.isNotEmpty) return roundId;
  return (game.roundSlug ?? '').trim();
}

bool _isHeadToHeadMatch(List<GamesTourModel> games) {
  final gamesPerRound = <String, int>{};
  final competitors = <String>{};
  for (final game in games) {
    final roundKey = _previewRoundKey(game);
    if (roundKey.isEmpty) return false;
    gamesPerRound.update(roundKey, (count) => count + 1, ifAbsent: () => 1);
    competitors
      ..add(_playerIdentity(game.whitePlayer))
      ..add(_playerIdentity(game.blackPlayer));
  }

  competitors.removeWhere((identity) => identity.isEmpty);
  return gamesPerRound.length > 1 &&
      gamesPerRound.values.every((count) => count == 1) &&
      competitors.length == 2;
}

String _playerIdentity(PlayerCard player) {
  final fideId = player.fideId;
  if (fideId != null && fideId > 0) return 'fide:$fideId';
  return player.name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
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
