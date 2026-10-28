import 'package:chessground/chessground.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';

@immutable
class BoardUndoSnapshot {
  const BoardUndoSnapshot({
    required this.game,
    required this.pointer,
    required this.dirtySinceLoad,
    this.shapes,
    this.userNags,
  });

  final ChessGame game;
  final ChessMovePointer pointer;
  final bool dirtySinceLoad;

  /// Annotation shapes (arrows + circles) at snapshot time. `null` means
  /// "don't restore" so move-only mutations don't clobber later shape edits.
  final Set<cg.Shape>? shapes;

  /// User-applied NAG codes per half-move at snapshot time. Same
  /// "null = don't restore" rule as [shapes].
  final Map<int, List<int>>? userNags;
}

@immutable
class BoardPaneSession {
  const BoardPaneSession({
    required this.game,
    required this.pointer,
    required this.pgnHeaders,
    required this.flipped,
    required this.loadedFrom,
    required this.lastAppliedPgn,
    required this.lastAppliedGameId,
    required this.lastAppliedInitialFenKey,
    required this.dirtySinceLoad,
    required this.hasUnseenMoves,
    required this.undoStack,
    this.lastSavedAnalysisPgn,
    this.lastBroadcastPgn,
    this.savedSourceSeedPgn,
    this.hasCommittedSave = false,
    this.detachedSeedPgn,
    this.userNags = const <int, List<int>>{},
  });

  final ChessGame game;
  final ChessMovePointer pointer;
  final Map<String, String> pgnHeaders;
  final bool flipped;
  final String? loadedFrom;
  final String? lastAppliedPgn;
  final String? lastAppliedGameId;
  final String? lastAppliedInitialFenKey;
  final bool dirtySinceLoad;
  final bool hasUnseenMoves;
  final List<BoardUndoSnapshot> undoStack;

  /// Open-time seed superseded by this tab's successful save. Retained remounts
  /// must not reapply it over the committed baseline or post-save edits.
  final String? savedSourceSeedPgn;

  /// Exact successful save baseline, independent of incoming Event PGNs.
  final String? lastSavedAnalysisPgn;

  /// Canonical feed provenance must never become a private saved tree.
  final String? lastBroadcastPgn;

  /// Clean after saving is not the unchanged opening source.
  final bool hasCommittedSave;

  /// Transport seed already represented by the restored working tree.
  final String? detachedSeedPgn;

  /// The tab's user NAGs (`userMoveNagsProvider`) when this was written. They
  /// stay out of [game]: a restore keeps reading them from the provider, so a
  /// copy baked into the tree would show twice and survive being toggled off.
  /// Only the close guard and exports merge them in.
  final Map<int, List<int>> userNags;
}

/// Mounted panes expose a synchronous reader: the retained post-frame session
/// can lag behind a just-completed save or the user's latest edit.
final boardPaneSnapshotReadersProvider = Provider<
  Map<String, ({Object? seed, BoardPaneSession session}) Function()>
>((_) => {});

final boardPaneSessionByTabIdProvider =
    StateProvider<Map<String, BoardPaneSession>>(
      (_) => const <String, BoardPaneSession>{},
    );

extension BoardPaneSessionWriter
    on StateController<Map<String, BoardPaneSession>> {
  void put(String tabId, BoardPaneSession session) {
    state = <String, BoardPaneSession>{...state, tabId: session};
  }

  void clear(String tabId) {
    if (!state.containsKey(tabId)) return;
    state = <String, BoardPaneSession>{...state}..remove(tabId);
  }
}
