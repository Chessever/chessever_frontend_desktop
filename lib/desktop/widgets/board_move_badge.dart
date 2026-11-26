import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:chessever/desktop/widgets/motion_translate.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';

/// The square a move's badge sits on in [after], the position the move
/// made: where the moved piece landed. A castle written king-to-rook
/// (`e1h1`) leaves its target square empty, so it anchors to the king's new
/// square instead, as the watching board does.
Square? boardMoveBadgeSquare(Position after, Move? move) {
  if (move == null) return null;
  if (move is NormalMove) {
    if (after.board.pieceAt(move.to) != null) return move.to;
    return after.board.kingOf(after.turn.opposite) ?? move.to;
  }
  final squares = move.squares.toList();
  return squares.isEmpty ? null : squares.last;
}

/// A move's mark on the board: a small disc pinned to the top-right corner
/// of [square], popping in when it appears. Place it in a [Stack] the size
/// of the board.
class BoardMoveBadge extends StatelessWidget {
  const BoardMoveBadge({
    super.key,
    required this.boardSize,
    required this.square,
    required this.flipped,
    required this.color,
    required this.child,
    this.sizeFactor = 0.42,
    this.selfContainedChild = false,
  });

  /// The report's class icon for [type], as the report draws it on the
  /// board.
  factory BoardMoveBadge.annotation({
    Key? key,
    required double boardSize,
    required Square square,
    required bool flipped,
    required LichessMoveAnnotationType type,
  }) => BoardMoveBadge(
    key: key,
    boardSize: boardSize,
    square: square,
    flipped: flipped,
    color: moveAnnotationColor(type),
    sizeFactor: 0.40,
    selfContainedChild: true,
    child: SvgPicture.asset(moveAnnotationIconAsset(type), fit: BoxFit.contain),
  );

  final double boardSize;
  final Square square;
  final bool flipped;
  final Color color;
  final Widget child;
  final double sizeFactor;

  /// True when [child] already paints its own filled disc edge-to-edge
  /// (classification badge SVGs). Those must not get a second coloured circle.
  final bool selfContainedChild;

  @override
  Widget build(BuildContext context) {
    final squareSize = boardSize / 8;
    final effectiveFile = flipped ? 7 - square.file : square.file;
    final effectiveRank = flipped ? square.rank : 7 - square.rank;
    final left = effectiveFile * squareSize;
    final top = effectiveRank * squareSize;
    final badgeSize = squareSize * sizeFactor;
    final badgeLeft = (left + squareSize - badgeSize / 2).clamp(
      0.0,
      boardSize - badgeSize,
    );
    final badgeTop = (top - badgeSize / 2 + squareSize * 0.04).clamp(
      0.0,
      boardSize - badgeSize,
    );

    return Positioned(
      left: badgeLeft,
      top: badgeTop,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1.0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          builder: (context, scale, c) => MotionScale(scale: scale, child: c),
          child: Container(
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(
              color: selfContainedChild ? Colors.transparent : color,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x73000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
              border: Border.all(color: const Color(0x2EFFFFFF), width: 0.5),
            ),
            padding:
                selfContainedChild
                    ? EdgeInsets.zero
                    : EdgeInsets.all(badgeSize * 0.16),
            child: RepaintBoundary(child: child),
          ),
        ),
      ),
    );
  }
}
