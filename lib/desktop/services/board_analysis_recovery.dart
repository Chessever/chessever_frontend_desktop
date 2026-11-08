import 'package:chessground/chessground.dart' as cg;
import 'package:collection/collection.dart';

import '../../screens/chessboard/analysis/chess_game.dart';
import '../../screens/chessboard/utils/chessever_annotation.dart';
import '../state/board_annotations.dart';
import 'engine/game_analysis_report.dart';

/// Volatile, tab/game-owned recovery, never a persisted game or save baseline.
/// Trees are immutable by convention, like BoardUndoSnapshot's tree references.
class BoardAnalysisRecovery {
  BoardAnalysisRecovery({
    required this.game,
    required this.annotations,
    required Map<int, List<int>> userNags,
    required List<String> selectedPath,
    required List<String> clearedPath,
    this.broadcastPgn,
    this.report,
  }) : userNags = Map.unmodifiable({
         for (final entry in userNags.entries)
           entry.key: List<int>.unmodifiable(entry.value),
       }),
       selectedPath = List.unmodifiable(selectedPath),
       clearedPath = List.unmodifiable(clearedPath);

  final ChessGame game;
  final BoardAnnotations annotations;
  final Map<int, List<int>> userNags;
  final List<String> selectedPath;
  final List<String> clearedPath;
  final String? broadcastPgn;
  final GameAnalysisReport? report;

  BoardAnalysisRecovery followBroadcast({
    required ChessGame game,
    required Map<int, List<int>> userNags,
    required String broadcastPgn,
  }) => BoardAnalysisRecovery(
    game: game,
    annotations: annotations,
    userNags: userNags,
    selectedPath: selectedPath,
    clearedPath: clearedPath,
    broadcastPgn: broadcastPgn,
    // A report for an older move fingerprint is not made current by recovery.
    report: report,
  );

  List<String> restorePath(List<String> currentPath) =>
      const ListEquality<String>().equals(currentPath, clearedPath)
          ? selectedPath
          : currentPath;
}

/// Add back cleared analysis without replacing today's mainline or metadata.
/// A matching full UCI prefix (not numeric variation index/FEN alone) proves
/// ownership of each recovered annotation. Later edits win conflicting fields;
/// distinct comments/branches/positional symbols are retained from both trees.
ChessGame restoreClearedBoardAnalysis({
  required ChessGame checkpoint,
  required ChessGame current,
}) {
  if (checkpoint.startingFen != current.startingFen) return current;
  final mainline = _restoreLine(checkpoint.mainline, current.mainline);
  return current.copyWith(
    mainline: mainline,
    rootComments: _comments(checkpoint.rootComments, current.rootComments),
    detachedRootAnalysis: _restoreVariations(
      checkpoint.detachedRootAnalysis,
      current.detachedRootAnalysis,
    ),
    overrideDetachedRootAnalysis: true,
  );
}

ChessLine _restoreLine(ChessLine old, ChessLine now, {bool private = false}) {
  final result = List<ChessMove>.of(now);
  var matched = 0;
  for (var i = 0; i < old.length && i < now.length; i++) {
    if (old[i].uci != now[i].uci) break;
    matched++;
    var oldVariations = old[i].variations ?? const <ChessLine>[];
    // A predicted continuation may have become the actual live mainline.
    // Fold its annotations into that continuation, not a duplicate branch.
    if (i + 1 < result.length) {
      final matching = oldVariations.where(
        (line) => line.isNotEmpty && line.first.uci == result[i + 1].uci,
      );
      for (final line in matching) {
        final suffix = _restoreLine(line, result.sublist(i + 1));
        result.replaceRange(i + 1, result.length, suffix);
      }
      oldVariations =
          oldVariations
              .where(
                (line) => line.isEmpty || line.first.uci != result[i + 1].uci,
              )
              .toList();
    }
    final move = result[i];
    result[i] = ChessMove(
      num: move.num,
      fen: move.fen,
      san: move.san,
      uci: move.uci,
      turn: move.turn,
      clockTime: move.clockTime ?? old[i].clockTime,
      eval: move.eval ?? old[i].eval,
      comments: _moveComments(old[i].comments, move.comments),
      startingComments: _moveComments(
        old[i].startingComments,
        move.startingComments,
      ),
      nags:
          old[i].nags == null && (move.nags?.isEmpty ?? true)
              ? null
              : restoreBoardAnalysisNags(old[i].nags, move.nags),
      variations: _restoreVariations(oldVariations, move.variations),
    );
  }
  // Only a private variation may recover a cleared tail. Never append an old
  // canonical mainline after a takeback/correction or resurrect displaced feed.
  if (private && matched == now.length && old.length > matched) {
    result.addAll(old.skip(matched));
  } else if (private && matched > 0 && old.length > matched) {
    final anchor = result[matched - 1];
    result[matched - 1] = anchor.copyWith(
      variations: _restoreVariations([old.sublist(matched)], anchor.variations),
      overrideVariations: true,
    );
  }
  return result;
}

List<ChessLine>? _restoreVariations(
  List<ChessLine>? old,
  List<ChessLine>? now,
) {
  final result = <ChessLine>[...?now];
  for (final line in old ?? const <ChessLine>[]) {
    if (line.isEmpty) continue;
    final index = result.indexWhere(
      (other) => other.isNotEmpty && other.first.uci == line.first.uci,
    );
    if (index < 0) {
      result.add(line);
    } else {
      result[index] = _restoreLine(line, result[index], private: true);
    }
  }
  return result.isEmpty ? null : result;
}

List<String> _comments(List<String>? old, List<String>? now) =>
    List<String>.unmodifiable({...?now, ...?old});

List<String>? _moveComments(List<String>? old, List<String>? now) =>
    old == null && (now?.isEmpty ?? true) ? null : _comments(old, now);

/// User-quality verdicts replace old quality, but not independent positional
/// symbols. The overlay remains separate from the tree so toggling still works.
List<int> restoreBoardAnalysisNags(List<int>? old, List<int>? now) {
  bool quality(int nag) =>
      (nag >= 1 && nag <= 7) ||
      isChesseverClassificationNag(nag) ||
      nag == kChesseverUserQualityOverrideNag;
  final latest = now ?? const <int>[];
  final hasNewQuality = latest.any(quality);
  return List.unmodifiable({
    ...latest,
    for (final nag in old ?? const <int>[])
      if (!hasNewQuality || !quality(nag)) nag,
  });
}

Map<int, List<int>> restoreBoardAnalysisUserNags({
  required BoardAnalysisRecovery checkpoint,
  required ChessGame current,
  required Map<int, List<int>> userNags,
}) {
  final result = <int, List<int>>{...userNags};
  if (checkpoint.game.startingFen != current.startingFen) return result;
  for (
    var i = 0;
    i < checkpoint.game.mainline.length && i < current.mainline.length;
    i++
  ) {
    if (checkpoint.game.mainline[i].uci != current.mainline[i].uci) break;
    final nags = restoreBoardAnalysisNags(checkpoint.userNags[i], userNags[i]);
    if (nags.isNotEmpty) result[i] = nags;
  }
  return result;
}

BoardAnnotations restoreBoardAnalysisShapes(
  BoardAnnotations checkpoint,
  BoardAnnotations current,
) => BoardAnnotations(
  shapes: Set<cg.Shape>.unmodifiable({...checkpoint.shapes, ...current.shapes}),
  positionShapes: Map.unmodifiable({
    for (final key in {
      ...checkpoint.positionShapes.keys,
      ...current.positionShapes.keys,
    })
      key: Set<cg.Shape>.unmodifiable({
        ...?checkpoint.positionShapes[key],
        ...?current.positionShapes[key],
      }),
  }),
);
