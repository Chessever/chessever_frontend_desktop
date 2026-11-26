import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/arrow_move_eval.dart';
import 'package:chessever/desktop/state/board_eval.dart';

/// Small engine readings on the reader's own arrows: every arrow that is a
/// legal move in the shown position carries the evaluation of the position
/// after that move, set on the shaft just behind the head.
///
/// A move the live engine lines already cover reads its score from them
/// and follows the search as it deepens; any other move is looked up once
/// ([arrowMoveEvalProvider]). A label appears only once there is a number.
class ArrowMoveEvalLabels extends ConsumerWidget {
  const ArrowMoveEvalLabels({
    super.key,
    required this.fen,
    required this.arrows,
    required this.boardSize,
    required this.orientation,
    required this.liveLinesFen,
  });

  /// Position on the board.
  final String fen;

  /// Arrows the reader (or the game's annotator) drew on [fen].
  final List<cg.Arrow> arrows;

  final double boardSize;
  final Side orientation;

  /// Position whose live engine lines may be read, when it is [fen]. Null
  /// while the engine is busy with something else (a threat probe).
  final String? liveLinesFen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = arrowMoveCandidates(fen, [
      for (final arrow in arrows) (arrow.orig, arrow.dest),
    ]);
    if (candidates.isEmpty) return const SizedBox.shrink();

    final linesFen = liveLinesFen;
    final livePvs =
        linesFen == null || linesFen != fen
            ? const <BoardPv>[]
            : ref.watch(boardEvalProvider(linesFen).select((s) => s.pvs));
    final position = Chess.fromSetup(Setup.parseFen(fen));

    final colorOf = <(Square, Square), Color>{
      for (final arrow in arrows.reversed)
        (arrow.orig, arrow.dest): arrow.color,
    };

    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final candidate in candidates)
            _ArrowMoveEvalLabel(
              key: ValueKey<String>(
                '${candidate.orig.name}${candidate.dest.name}',
              ),
              candidate: candidate,
              liveEval: _liveEvalFor(position, candidate, livePvs),
              color:
                  colorOf[(candidate.orig, candidate.dest)] ??
                  const Color(0xFF15781B),
              anchor: arrowMoveEvalLabelAnchor(
                orig: candidate.orig,
                dest: candidate.dest,
                boardSize: boardSize,
                orientation: orientation,
              ),
              squareSize: boardSize / 8,
            ),
        ],
      ),
    );
  }

  static ArrowMoveEval? _liveEvalFor(
    Position position,
    ArrowMoveCandidate candidate,
    List<BoardPv> pvs,
  ) {
    for (final pv in pvs) {
      final first = pv.moves.trim().split(RegExp(r'\s+')).first;
      if (first.isEmpty) continue;
      if (!uciPlaysArrowMove(position, first, candidate.move)) continue;
      return ArrowMoveEval(evaluation: pv.evaluation, mate: pv.mate);
    }
    return null;
  }
}

/// Where the label sits: on the shaft, its centre just behind the arrowhead.
Offset arrowMoveEvalLabelAnchor({
  required Square orig,
  required Square dest,
  required double boardSize,
  required Side orientation,
}) {
  final square = boardSize / 8;
  Offset centerOf(Square s) {
    final x = orientation == Side.black ? 7 - s.file : s.file;
    final y = orientation == Side.black ? s.rank : 7 - s.rank;
    return Offset((x + 0.5) * square, (y + 0.5) * square);
  }

  final from = centerOf(orig);
  final to = centerOf(dest);
  final delta = to - from;
  final length = delta.distance;
  // The head is a third of a square long; the label sits one notch behind
  // its base, but never past the shaft's midpoint on a one-square arrow.
  final back = math.min(square * 0.58, length * 0.5);
  return to - delta / length * back;
}

class _ArrowMoveEvalLabel extends ConsumerWidget {
  const _ArrowMoveEvalLabel({
    super.key,
    required this.candidate,
    required this.liveEval,
    required this.color,
    required this.anchor,
    required this.squareSize,
  });

  final ArrowMoveCandidate candidate;
  final ArrowMoveEval? liveEval;
  final Color color;
  final Offset anchor;
  final double squareSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eval =
        liveEval ??
        ref.watch(arrowMoveEvalProvider(candidate.fenAfter)).valueOrNull;
    if (eval == null) return const SizedBox.shrink();

    final fill = color.withValues(alpha: 1);
    final ink =
        fill.computeLuminance() > 0.35
            ? const Color(0xFF16130C)
            : const Color(0xFFFFFFFF);
    final edge = Color.lerp(fill, const Color(0xFF000000), 0.28)!;
    final fontSize = (squareSize * 0.21).clamp(9.5, 15.0);

    return Positioned(
      left: anchor.dx,
      top: anchor.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(fontSize * 0.34),
            border: Border.all(color: edge, width: 1),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: fontSize * 0.42,
              vertical: fontSize * 0.2,
            ),
            child: Text(
              formatArrowMoveEval(eval),
              maxLines: 1,
              softWrap: false,
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
              ),
              strutStyle: StrutStyle(
                fontSize: fontSize,
                height: 1,
                forceStrutHeight: true,
              ),
              style: TextStyle(
                color: ink,
                fontSize: fontSize,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
