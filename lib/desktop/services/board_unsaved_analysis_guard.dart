import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

bool shouldConfirmBoardAnalysisDiscard({
  required bool dirtySinceLoad,
  required String currentPgn,
  required String? lastAppliedPgn,
}) {
  if (!dirtySinceLoad) return false;
  final current = currentPgn.trim();
  final applied = lastAppliedPgn?.trim();
  if (applied == null || applied.isEmpty) return current.isNotEmpty;
  return current != applied;
}

bool boardSessionHasUnsavedAnalysis(BoardPaneSession? session) {
  if (session == null) return false;
  return shouldConfirmBoardAnalysisDiscard(
    dirtySinceLoad: session.dirtySinceLoad,
    currentPgn: exportGameToPgn(session.game),
    lastAppliedPgn: session.lastAppliedPgn,
  );
}
