import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';

/// Returns the zero-based mainline annotation key for [pointer].
///
/// Lichess annotation payloads and notation tokens are keyed by the mainline
/// half-move index: `0` is the first move, `1` is the reply, and so on.
/// Variation pointers deliberately return null because those annotations only
/// describe the original mainline.
int? mainlineAnnotationIndexForPointer(ChessMovePointer pointer) {
  if (pointer.length != 1) return null;
  final index = pointer.first;
  return index >= 0 ? index : null;
}

class MainlineNagPromotionMigration {
  const MainlineNagPromotionMigration({
    required this.game,
    required this.userNags,
  });

  final ChessGame game;
  final Map<int, List<int>> userNags;
}

/// Moves user-applied root-mainline NAGs onto the move nodes that will be
/// demoted when [variationHeadPointer] is promoted.
///
/// Desktop user NAGs are keyed by root mainline ply. After a promotion, those
/// same integer keys would point at the newly-promoted sideline, making the old
/// mainline's `!`/`?` glyphs appear on the wrong moves. Before promotion, fold
/// the affected keys into the old mainline move nodes and remove only those
/// keys from the overlay map; the navigator then carries the annotated move
/// nodes into the demoted variation.
MainlineNagPromotionMigration migrateMainlineNagsForVariationPromotion({
  required ChessGame game,
  required ChessMovePointer variationHeadPointer,
  required Map<int, List<int>> userNags,
}) {
  if (userNags.isEmpty || variationHeadPointer.length < 3) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final variationIndexPosition = variationHeadPointer.length - 2;
  if (!variationIndexPosition.isOdd) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final parentPointer = variationHeadPointer.sublist(0, variationIndexPosition);

  // `userNags` is keyed only by the root mainline. Nested variation promotion
  // already carries NAGs on ChessMove nodes, so there is no overlay to migrate.
  if (parentPointer.length != 1) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final moveIndex = parentPointer.single;
  if (moveIndex < 0 || moveIndex >= game.mainline.length) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final variationIndex = variationHeadPointer[variationIndexPosition];
  final junctionMove = game.mainline[moveIndex];
  final variations = junctionMove.variations;
  if (variations == null || variationIndex >= variations.length) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final promotedLine = variations[variationIndex];
  final promotesSamePly =
      promotedLine.isNotEmpty &&
      promotedLine.first.num == junctionMove.num &&
      promotedLine.first.turn == junctionMove.turn;
  final firstDemotedIndex = promotesSamePly ? moveIndex : moveIndex + 1;
  if (firstDemotedIndex >= game.mainline.length) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final affectedKeys = userNags.keys
      .where((key) => key >= firstDemotedIndex && key < game.mainline.length)
      .toSet();
  if (affectedKeys.isEmpty) {
    return MainlineNagPromotionMigration(game: game, userNags: userNags);
  }

  final nextMainline = List<ChessMove>.of(game.mainline);
  for (final key in affectedKeys) {
    final nags = userNags[key];
    if (nags == null || nags.isEmpty) continue;
    nextMainline[key] = _withMergedNags(nextMainline[key], nags);
  }

  final nextUserNags = Map<int, List<int>>.unmodifiable({
    for (final entry in userNags.entries)
      if (!affectedKeys.contains(entry.key))
        entry.key: List<int>.unmodifiable(entry.value),
  });

  return MainlineNagPromotionMigration(
    game: game.copyWith(mainline: nextMainline),
    userNags: nextUserNags,
  );
}

ChessMove _withMergedNags(ChessMove move, Iterable<int> extraNags) {
  final merged = <int>[];
  final seen = <int>{};
  for (final nag in move.nags ?? const <int>[]) {
    if (seen.add(nag)) merged.add(nag);
  }
  for (final nag in extraNags) {
    if (seen.add(nag)) merged.add(nag);
  }
  return move.copyWith(nags: List<int>.unmodifiable(merged));
}
