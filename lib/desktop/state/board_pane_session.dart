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
}

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
