import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/repository/local_storage/local_eval/local_eval_cache.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';

/// Evaluation of the position after the move a reader drew as an arrow.
///
/// White perspective, like the eval bar: [evaluation] in pawns, [mate] in
/// moves to mate (negative when Black mates), `mate == 0` for a move that
/// mates on the board.
@immutable
class ArrowMoveEval {
  const ArrowMoveEval({required this.evaluation, this.mate});

  final double evaluation;
  final int? mate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArrowMoveEval &&
          other.evaluation == evaluation &&
          other.mate == mate;

  @override
  int get hashCode => Object.hash(evaluation, mate);
}

/// A right-drawn arrow that is a legal move in the shown position.
@immutable
class ArrowMoveCandidate {
  const ArrowMoveCandidate({
    required this.orig,
    required this.dest,
    required this.move,
    required this.fenAfter,
  });

  final Square orig;
  final Square dest;

  /// The move the arrow stands for, castling normalised to king-takes-rook.
  /// A pawn reaching the last rank promotes to a queen.
  final NormalMove move;

  /// FEN of the position after [move].
  final String fenAfter;
}

/// The move an arrow from [orig] to [dest] plays in [position], or null when
/// it is not legal there. Castling may be drawn to the king's destination
/// or onto the rook.
NormalMove? arrowLegalMove(Position position, Square orig, Square dest) {
  if (orig == dest) return null;
  final piece = position.board.pieceAt(orig);
  if (piece == null || piece.color != position.turn) return null;
  final promotes =
      piece.role == Role.pawn &&
      (dest.rank == Rank.first || dest.rank == Rank.eighth);
  final move = NormalMove(
    from: orig,
    to: dest,
    promotion: promotes ? Role.queen : null,
  );
  if (!position.isLegal(move)) return null;
  final normalized = position.normalizeMove(move);
  return normalized is NormalMove ? normalized : move;
}

/// Legal arrow moves among [arrows] (orig/dest pairs) in [fen], in drawing
/// order, without duplicates.
List<ArrowMoveCandidate> arrowMoveCandidates(
  String fen,
  Iterable<(Square, Square)> arrows,
) {
  final Position position;
  try {
    position = Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return const <ArrowMoveCandidate>[];
  }
  if (position.isGameOver) return const <ArrowMoveCandidate>[];
  final seen = <(Square, Square)>{};
  final out = <ArrowMoveCandidate>[];
  for (final (orig, dest) in arrows) {
    if (!seen.add((orig, dest))) continue;
    final move = arrowLegalMove(position, orig, dest);
    if (move == null) continue;
    out.add(
      ArrowMoveCandidate(
        orig: orig,
        dest: dest,
        move: move,
        fenAfter: position.play(move).fen,
      ),
    );
  }
  return out;
}

/// Whether [uci] (an engine move, `e1g1` castling) plays [move] in
/// [position]. Under-promotions do not match a drawn arrow, which promotes
/// to a queen.
bool uciPlaysArrowMove(Position position, String uci, NormalMove move) {
  final parsed = Move.parse(uci);
  if (parsed is! NormalMove) return false;
  final normalized = position.normalizeMove(parsed);
  if (normalized is! NormalMove) return false;
  return normalized.from == move.from &&
      normalized.to == move.to &&
      (parsed.promotion ?? Role.queen) == (move.promotion ?? Role.queen);
}

/// Eval of a position that is already over: mate is `#`, every draw 0.00.
ArrowMoveEval? terminalArrowMoveEval(String fen) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    if (!position.isGameOver) return null;
    if (position.isCheckmate) {
      final whiteMated = position.turn == Side.white;
      return ArrowMoveEval(evaluation: whiteMated ? -10 : 10, mate: 0);
    }
    return const ArrowMoveEval(evaluation: 0);
  } catch (_) {
    return null;
  }
}

/// The label drawn on the arrow: `+0.8`, `−1.4`, `0.0`, `#3`, `#−2`, or
/// `#` for a move that mates on the board.
String formatArrowMoveEval(ArrowMoveEval eval) {
  const minus = '−';
  final mate = eval.mate;
  if (mate != null) {
    if (mate == 0) return '#';
    return mate > 0 ? '#$mate' : '#$minus${-mate}';
  }
  final rounded = (eval.evaluation * 10).round() / 10;
  if (rounded == 0) return '0.0';
  final text = rounded.abs().toStringAsFixed(1);
  return rounded > 0 ? '+$text' : '$minus$text';
}

/// White-perspective eval of the best line in [eval], or null when it has
/// no usable line.
ArrowMoveEval? arrowMoveEvalFromPvs(List<Pv> pvs, String fen) {
  final pv = pvs.where((pv) => pv.moves.trim().isNotEmpty).firstOrNull;
  if (pv == null) return null;
  var sign = 1;
  if (!pv.whitePerspective) {
    final parts = fen.split(' ');
    sign = parts.length > 1 && parts[1] == 'b' ? -1 : 1;
  }
  final mate = pv.isMate ? pv.mate : null;
  if (mate != null) {
    return ArrowMoveEval(
      evaluation: mate * sign > 0 ? 10 : -10,
      mate: mate * sign,
    );
  }
  return ArrowMoveEval(evaluation: pv.cp * sign / 100.0);
}

/// Depth of the short local search for an arrow move nobody has evaluated.
const int kArrowMoveEvalLocalDepth = 16;

/// Evaluation of the position after an arrow move ([fenAfter]) for moves
/// the live engine lines do not cover: the local eval cache, then the
/// ChessEver eval service, then a short low-priority local search. The
/// local search runs behind the visible board's own analysis, so it waits
/// rather than slowing it down. Null when nothing has evaluated it.
final arrowMoveEvalProvider = FutureProvider.autoDispose
    .family<ArrowMoveEval?, String>((ref, fenAfter) async {
      final terminal = terminalArrowMoveEval(fenAfter);
      if (terminal != null) return terminal;

      var disposed = false;
      final ownerId = StockfishSingleton.generateOwnerId(
        'arrowMoveEval',
        identityHashCode(ref),
      );
      ref.onDispose(() {
        disposed = true;
        unawaited(StockfishSingleton().cancelEvaluationsForOwner(ownerId));
      });

      try {
        final cached = await ref.read(localEvalCacheProvider).fetch(fenAfter);
        final fromCache =
            cached == null ? null : arrowMoveEvalFromPvs(cached.pvs, fenAfter);
        if (fromCache != null) return fromCache;
      } catch (_) {}
      if (disposed) return null;

      try {
        final cloud = await ref
            .read(gamebaseRepositoryProvider)
            .getEvalByFen(fenAfter)
            .timeout(const Duration(seconds: 2), onTimeout: () => null);
        final fromCloud =
            cloud == null ? null : arrowMoveEvalFromPvs(cloud.pvs, fenAfter);
        if (fromCloud != null) return fromCloud;
      } catch (_) {}
      if (disposed) return null;

      try {
        final local = await StockfishSingleton().evaluatePosition(
          fenAfter,
          depth: kArrowMoveEvalLocalDepth,
          multiPV: 1,
          ownerId: ownerId,
          isRequestCurrent: () => !disposed,
        );
        if (disposed || local.isCancelled) return null;
        return arrowMoveEvalFromPvs(local.pvs, fenAfter);
      } catch (_) {
        return null;
      }
    });
