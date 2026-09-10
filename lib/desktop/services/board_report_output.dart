import 'package:collection/collection.dart';

import '../../screens/chessboard/analysis/chess_game.dart';
import '../../screens/chessboard/utils/chessever_annotation.dart';
import 'engine/game_analysis_report.dart';

/// Engine evidence is reusable across records; permission to export it is not.
GameAnalysisReport? eligibleBoardOutputReport({
  required ChessGame game,
  required GameAnalysisReport? report,
  required bool explicitlyVisibleForActivation,
}) {
  if (!explicitlyVisibleForActivation ||
      report == null ||
      report.moves.isEmpty ||
      report.fingerprint != gameReportFingerprint(game)) {
    return null;
  }
  return report;
}

/// Shared by the Library action and successive-save routing regressions.
/// A resolver is allowed only for an unchanged opening record, never merely
/// because a committed working snapshot is clean.
Future<ChessGame> resolveBoardLibrarySaveGame({
  required bool useOpeningSource,
  required ChessGame workingGame,
  required Future<ChessGame> Function() resolveOpeningSource,
}) async => useOpeningSource ? await resolveOpeningSource() : workingGame;

// Quality and positional symbols are independent fields. A late positional
// edit must not accidentally erase committed report quality, while an explicit
// late quality edit/clear must replace the whole verdict (including metadata).
List<int>? _rebaseNags(
  List<int>? before,
  List<int>? saved,
  List<int>? current,
) {
  if (const ListEquality<int>().equals(before, current)) return saved;
  bool quality(int nag) =>
      (nag >= 1 && nag <= 7) ||
      isChesseverClassificationNag(nag) ||
      nag == kChesseverUserQualityOverrideNag;
  final old = before ?? const <int>[];
  final now = current ?? const <int>[];
  final committed = saved ?? const <int>[];
  final verdictUnchanged = const SetEquality<int>().equals(
    old.where(quality).toSet(),
    now.where(quality).toSet(),
  );
  return [
    ...(verdictUnchanged ? committed : now).where(quality),
    for (final nag in {...committed, ...now})
      if (!quality(nag) &&
          (old.contains(nag) == now.contains(nag)
              ? committed.contains(nag)
              : now.contains(nag)))
        nag,
  ];
}

/// Promote the captured, successfully persisted snapshot, not today's report.
/// Rebase edits made during the await field-by-field onto that baseline. Only
/// matching move prefixes inherit annotations; deleted/replaced moves never
/// come back, and current variations are never replaced by an older snapshot.
ChessGame rebaseBoardAfterSavedSnapshot({
  required ChessGame before,
  required ChessGame saved,
  required ChessGame current,
}) {
  if (before.startingFen != saved.startingFen ||
      before.startingFen != current.startingFen) {
    return current;
  }
  const equality = DeepCollectionEquality();
  T pick<T>(T old, T committed, T now) =>
      equality.equals(old, now) ? committed : now;
  var matchingPrefix = true;
  final moves = <ChessMove>[];
  for (var i = 0; i < current.mainline.length; i++) {
    final now = current.mainline[i];
    matchingPrefix =
        matchingPrefix &&
        i < before.mainline.length &&
        i < saved.mainline.length &&
        before.mainline[i].uci == now.uci &&
        saved.mainline[i].uci == now.uci;
    if (!matchingPrefix) {
      moves.add(now);
      continue;
    }
    final old = before.mainline[i];
    final committed = saved.mainline[i];
    moves.add(
      ChessMove(
        num: now.num,
        fen: now.fen,
        san: now.san,
        uci: now.uci,
        turn: now.turn,
        clockTime: pick(old.clockTime, committed.clockTime, now.clockTime),
        eval: pick(old.eval, committed.eval, now.eval),
        comments: pick(old.comments, committed.comments, now.comments),
        nags: _rebaseNags(old.nags, committed.nags, now.nags),
        variations: now.variations,
      ),
    );
  }
  final metadata = Map<String, dynamic>.of(current.metadata);
  // Preserve runtime-only metadata absent from PGN (live/extension policy).
  for (final entry in saved.metadata.entries) {
    if (equality.equals(
      before.metadata[entry.key],
      current.metadata[entry.key],
    )) {
      metadata[entry.key] = entry.value;
    }
  }
  return current.copyWith(mainline: moves, metadata: metadata);
}
