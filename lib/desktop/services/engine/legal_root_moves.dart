import 'package:dartchess/dartchess.dart';

/// Counts distinct legal UCI root choices, not pieces in the source-square map.
/// Keep the library's one castling representation; count all promotion choices.
int legalStockfishRootMoveCount(String fen) {
  final position = Chess.fromSetup(Setup.parseFen(fen));
  var count = 0;
  for (final entry in position.legalMoves.entries) {
    final pawn = position.board.roleAt(entry.key) == Role.pawn;
    for (final destination in entry.value.squares) {
      final promotion =
          pawn &&
          (destination.rank == Rank.first || destination.rank == Rank.eighth);
      count += promotion ? 4 : 1;
    }
  }
  return count;
}
