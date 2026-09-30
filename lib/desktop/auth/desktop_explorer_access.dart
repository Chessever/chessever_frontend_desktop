/// Opening explorer admission, evaluated BELOW timers, cache and prefetch.
///
/// `GamebaseExplorerNotifier` takes an optional `accessCheck` (null on
/// mobile). Desktop injects [desktopExplorerFetchAllowed], so every path that
/// reaches a statistics fetch (board moves, held arrow navigation, PV apply,
/// FEN seeds, filter changes, refresh, prefetch of the next plies) is judged
/// by the same rule, not only the pointer handlers.
///
/// Moving pieces on your own board is never gated; only the database query
/// for the resulting position is.
library;

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

const String _initialBoardFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Played plies of the explorer's current position.
///
/// A line explored from the initial position counts its moves. A FEN seed
/// (a board position, a PV apply, an editor position) counts from the FEN's
/// move counters, so a seed deep in a game is not mistaken for an opening.
int desktopExplorerPlayedPlies(GamebaseExplorerState state, {int advance = 0}) {
  final startingFen = state.game?.startingFen.trim() ?? _initialBoardFen;
  final fromInitial =
      startingFen.split(RegExp(r'\s+')).take(4).join(' ') ==
      _initialBoardFen.split(' ').take(4).join(' ');
  final byLine = fromInitial ? state.exploredMoves.length : 0;
  final byFen = _pliesFromFen(state.currentFen);
  final plies = byLine > byFen ? byLine : byFen;
  return plies + advance;
}

int _pliesFromFen(String fen) {
  final parts = fen.trim().split(RegExp(r'\s+'));
  if (parts.length < 6) return 0;
  final fullMove = int.tryParse(parts[5]) ?? 1;
  return (fullMove - 1) * 2 + (parts[1] == 'b' ? 1 : 0);
}

/// The request a statistics fetch for [state] makes. [advance] looks ahead
/// (prefetching the next ply asks about `plies + 1`).
DesktopAccessContext desktopExplorerAccessContext(
  GamebaseExplorerState state, {
  int advance = 0,
  bool exactPosition = false,
}) => DesktopAccessContext(
  feature: DesktopFeature.openingExplorer,
  action: exactPosition
      ? DesktopAction.acquireSource
      : DesktopAction.previewNavigate,
  origin: DesktopDiscoveryOrigin.gamebase,
  playedPlies: desktopExplorerPlayedPlies(state, advance: advance),
  playerScoped: state.filters.playerIds.isNotEmpty,
);

/// The `accessCheck` desktop injects into `GamebaseExplorerNotifier`. Pure
/// read; never presents a paywall (a fetch is not a user action).
bool desktopExplorerFetchAllowed(
  DesktopProviderRead read,
  GamebaseExplorerState state,
  int advance,
) => readDesktopAccess(
  read,
  desktopExplorerAccessContext(state, advance: advance),
).isAllowed;
