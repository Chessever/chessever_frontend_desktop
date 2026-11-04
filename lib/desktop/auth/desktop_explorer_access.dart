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

import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;

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
int desktopExplorerPlayedPlies(
  GamebaseExplorerState state, {
  int advance = 0,
  bool isWebApp = kIsWeb,
}) {
  final startingFen = state.game?.startingFen.trim() ?? _initialBoardFen;
  final fromInitial =
      startingFen.split(RegExp(r'\s+')).take(4).join(' ') ==
      _initialBoardFen.split(' ').take(4).join(' ');
  final byLine = fromInitial ? state.exploredMoves.length : 0;
  final byFen = _pliesFromFen(state.currentFen);
  var plies = byLine > byFen ? byLine : byFen;
  if (isWebApp) {
    plies = math.max(
      math.max(plies, state.exploredMoves.length + _pliesFromFen(startingFen)),
      desktopExplorerMinimumPliesToReach(state.currentFen),
    );
  }
  return plies + advance;
}

/// Phone's piece-placement floor (`explorerMinimumPliesToReach`). A pasted
/// middlegame cannot reset access depth by setting its FEN move counter to 1.
/// Pawn advances, developed pieces and captures each supply a lower bound;
/// taking their maximum never overstates the moves needed to reach a board.
int desktopExplorerMinimumPliesToReach(String fen) {
  final fields = fen.trim().split(RegExp(r'\s+'));
  final rows = fields.first.split('/');
  if (rows.length != 8) return 0;
  var whiteMoves = 0;
  var blackMoves = 0;
  var whiteUnits = 0;
  var blackUnits = 0;
  int pawnMoves(int rank) => rank <= 2 ? 0 : (rank <= 4 ? 1 : rank - 3);
  for (var row = 0; row < 8; row++) {
    final rank = 8 - row;
    for (final symbol in rows[row].split('')) {
      if (int.tryParse(symbol) != null) continue;
      final piece = symbol.toLowerCase();
      if (!'pnbrqk'.contains(piece)) return 0;
      if (symbol != piece) {
        whiteUnits++;
        whiteMoves += piece == 'p' ? pawnMoves(rank) : (rank == 1 ? 0 : 1);
      } else {
        blackUnits++;
        blackMoves += piece == 'p' ? pawnMoves(9 - rank) : (rank == 8 ? 0 : 1);
      }
    }
  }
  whiteMoves = math.max(whiteMoves, 16 - blackUnits);
  blackMoves = math.max(blackMoves, 16 - whiteUnits);
  var plies = math.max(math.max(2 * whiteMoves - 1, 2 * blackMoves), 0);
  final blackToMove = fields.length > 1 && fields[1] == 'b';
  if (plies.isOdd != blackToMove) plies++;
  return plies;
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
  action:
      exactPosition
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
) =>
    readDesktopAccess(
      read,
      desktopExplorerAccessContext(state, advance: advance),
    ).isAllowed;
