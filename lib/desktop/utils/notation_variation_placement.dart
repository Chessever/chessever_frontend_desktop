import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

typedef NotationVariationPlacement =
    ({int ownerIndex, int variationIndex, ChessLine line});

/// Branches displayed after [moveIndex], without changing their tree owner.
///
/// Imported alternatives to the next move live on the preceding position;
/// same-turn alternatives (including first-move RAVs) live on the move itself.
/// Both must follow the principal move they replace, at every nesting depth.
Iterable<NotationVariationPlacement> notationVariationsAfterMove(
  ChessLine line,
  int moveIndex,
) sync* {
  final move = line[moveIndex];
  final own = move.variations ?? const <ChessLine>[];
  for (var v = 0; v < own.length; v++) {
    final branch = own[v];
    if (branch.isNotEmpty && branch.first.turn == move.turn) {
      yield (ownerIndex: moveIndex, variationIndex: v, line: branch);
    }
  }
  if (moveIndex > 0) {
    final previous = line[moveIndex - 1];
    final deferred = previous.variations ?? const <ChessLine>[];
    for (var v = 0; v < deferred.length; v++) {
      final branch = deferred[v];
      if (branch.isNotEmpty && branch.first.turn != previous.turn) {
        yield (ownerIndex: moveIndex - 1, variationIndex: v, line: branch);
      }
    }
  }
  // A tail may have only optional continuations, with no principal reply.
  // Keep those reachable instead of deferring them past the end of the line.
  if (moveIndex == line.length - 1) {
    for (var v = 0; v < own.length; v++) {
      final branch = own[v];
      if (branch.isNotEmpty && branch.first.turn != move.turn) {
        yield (ownerIndex: moveIndex, variationIndex: v, line: branch);
      }
    }
  }
}
