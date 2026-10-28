import 'package:chessever/desktop/services/board_report_output.dart'
    show mergeUserMainlineNags;
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

bool shouldConfirmBoardAnalysisDiscard({
  required bool dirtySinceLoad,
  required String currentPgn,
  required String? lastAppliedPgn,
  String? lastSavedAnalysisPgn,
}) {
  final saved = lastSavedAnalysisPgn?.trim();
  if (saved != null && saved.isNotEmpty) {
    if (currentPgn.trim() == saved) return false;
    try {
      return _savedAnalysisContent(currentPgn) != _savedAnalysisContent(saved);
    } catch (_) {
      // Malformed/unreadable snapshots must retain the conservative warning.
      return true;
    }
  }
  if (!dirtySinceLoad) return false;
  final current = currentPgn.trim();
  final applied = lastAppliedPgn?.trim();
  if (applied == null || applied.isEmpty) return current.isNotEmpty;
  return current != applied;
}

/// The board as the user sees it: the retained tree plus the tab's NAGs.
/// For comparison and export only; a restore uses [BoardPaneSession.game].
ChessGame boardSessionUserGame(BoardPaneSession session) =>
    mergeUserMainlineNags(session.game, session.userNags);

bool boardSessionHasUnsavedAnalysis(BoardPaneSession? session) {
  if (session == null) return false;
  return shouldConfirmBoardAnalysisDiscard(
    dirtySinceLoad: session.dirtySinceLoad,
    currentPgn: exportGameToPgn(boardSessionUserGame(session)),
    lastAppliedPgn: session.lastAppliedPgn,
    lastSavedAnalysisPgn: session.lastSavedAnalysisPgn,
  );
}

/// Compare all persisted annotations/branches, without presentation whitespace
/// or header insertion order turning an already committed snapshot dirty.
String _savedAnalysisContent(String pgn) {
  final game = ChessGame.fromPgn('', pgn);
  final keys = game.metadata.keys.toList()..sort();
  return exportGameToPgn(
    game.copyWith(metadata: {for (final key in keys) key: game.metadata[key]}),
  ).trim();
}

/// Shared shell/rail entry; read at command time, not at an earlier render.
bool boardTabHasUnsavedAnalysis({
  required String tabId,
  required T Function<T>(ProviderListenable<T> provider) read,
}) {
  final reader = read(boardPaneSnapshotReadersProvider)[tabId];
  if (reader != null) {
    final args = read(boardTabGameArgsByTabIdProvider)[tabId];
    final snapshot = reader();
    if (identical(snapshot.seed, args?.retainedSeedIdentity ?? args)) {
      return boardSessionHasUnsavedAnalysis(snapshot.session);
    }
  }
  return boardSessionHasUnsavedAnalysis(
    read(boardPaneSessionByTabIdProvider)[tabId],
  );
}
