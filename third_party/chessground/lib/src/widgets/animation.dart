import 'package:dartchess/dartchess.dart';
import 'package:flutter/painting.dart' show Offset;
import '../models.dart';

/// A Map of the pieces that are being translated on the board.
///
/// The keys are the squares the pieces are moving to, and the values are the pieces and the squares they are moving from.
typedef TranslatingPieces = Map<Square, ({Piece piece, Square from})>;

/// A Map of the pieces that are being faded out on the board.
///
/// Corresponds to the pieces that are no longer on the board after a position change.
typedef FadingPieces = Map<Square, Piece>;

/// Returns the pieces that need to be animated by comparing the old and new positions.
(TranslatingPieces, FadingPieces) preparePieceAnimations(
  Pieces oldPosition,
  Pieces newPosition, {
  Move? lastDrop,
}) {
  final Map<Square, ({Piece piece, Square from})> translatingPieces = {};
  final Map<Square, Piece> fadingPieces = {};
  final List<(Piece, Square)> newOnSquare = [];
  final List<(Piece, Square)> missingOnSquare = [];
  final Set<Square> animatedOrigins = {};
  for (final s in Square.values) {
    if ((lastDrop is NormalMove && s == lastDrop.from) || s == lastDrop?.to) {
      continue;
    }
    final oldP = oldPosition[s];
    final newP = newPosition[s];
    if (newP != null) {
      if (oldP != null) {
        if (newP != oldP) {
          missingOnSquare.add((oldP, s));
          newOnSquare.add((newP, s));
        }
      } else {
        newOnSquare.add((newP, s));
      }
    } else if (oldP != null) {
      missingOnSquare.add((oldP, s));
    }
  }
  for (final (newPiece, newPieceSquare) in newOnSquare) {
    // find the closest square that the piece was on before
    final fromSquare = _closestSquare(
      newPieceSquare,
      missingOnSquare
          .where((m) => m.$1 == newPiece && !animatedOrigins.contains(m.$2))
          .map((e) => e.$2),
    );
    if (fromSquare != null) {
      translatingPieces[newPieceSquare] = (piece: newPiece, from: fromSquare);
      animatedOrigins.add(fromSquare);
    }
  }
  for (final (missingPiece, missingPieceSquare) in missingOnSquare) {
    if (!animatedOrigins.contains(missingPieceSquare)) {
      fadingPieces[missingPieceSquare] = missingPiece;
    }
  }

  return (translatingPieces, fadingPieces);
}

/// Retargets in-flight pieces from their actual displayed positions, in
/// file/rank units, rather than snapping to the preceding move's destination.
/// Also carries unfinished moves that remain on the board into the new tween.
Map<Square, Offset> retargetPieceAnimations({
  required TranslatingPieces previous,
  required Map<Square, Offset> previousOrigins,
  required double progress,
  required TranslatingPieces next,
  required Pieces newPosition,
  Move? lastDrop,
}) {
  if (previous.isEmpty || progress >= 1) return const {};
  // Only new moves use their source squares to find an in-flight piece. A
  // carried move's original square may now be another piece's destination.
  final destinationsBySource = {
    for (final entry in next.entries) entry.value.from: entry.key,
  };
  final origins = <Square, Offset>{};
  for (final MapEntry(key: square, value: translation) in previous.entries) {
    final destination = destinationsBySource[square];
    if (destination == null) {
      if (newPosition[square] != translation.piece ||
          next.containsKey(square) ||
          square == lastDrop?.to) {
        continue;
      }
      next[square] = translation;
    }
    final from =
        previousOrigins[square] ??
        Offset(
          translation.from.file.toDouble(),
          translation.from.rank.toDouble(),
        );
    final to = Offset(square.file.toDouble(), square.rank.toDouble());
    origins[destination ?? square] = Offset.lerp(from, to, progress)!;
  }
  return origins;
}

/// Returns the closest square to the target square from a list of squares.
Square? _closestSquare(Square square, Iterable<Square> squares) {
  if (squares.isEmpty) return null;
  return squares.reduce((a, b) {
    final aDist = _distanceSq(square, a);
    final bDist = _distanceSq(square, b);
    return aDist < bDist ? a : b;
  });
}

int _distanceSq(Square pos1, Square pos2) {
  final dx = pos1.file - pos2.file;
  final dy = pos1.rank - pos2.rank;
  return dx * dx + dy * dy;
}
