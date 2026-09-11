import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

/// Injected into the reused notifier; protects timers, seeds, filters, cache
/// reuse and prefetch, not just pointer and keyboard controls.
bool canFetchDesktopExplorer(
  Ref ref,
  GamebaseExplorerState state,
  int advance,
) {
  final filters = state.filters;
  final hasPlayer =
      filters.playerIds.isNotEmpty || filters.selectedPlayers.isNotEmpty;
  final starting = state.game?.startingFen;
  const initial = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  return desktopExplorerAccess(
        ref.read(desktopPremiumAccessProvider),
        playedPlies: state.currentMoveNumber - 1 + advance,
        preparation: hasPlayer,
        exactPosition: starting != null && starting != initial,
      ) ==
      DesktopAccess.allowed;
}
