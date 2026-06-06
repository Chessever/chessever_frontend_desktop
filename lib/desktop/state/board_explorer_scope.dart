import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

@immutable
class BoardExplorerScope {
  const BoardExplorerScope({
    required this.player,
    this.initialFilters = const GamebaseFilters(),
  });

  final GamebasePlayer player;
  final GamebaseFilters initialFilters;

  GamebaseFilters get initialScopedFilters => enforce(initialFilters);

  GamebaseFilters enforce(GamebaseFilters filters) {
    return filters.copyWith(
      playerIds: <String>[player.id],
      selectedPlayers: <GamebasePlayer>[player],
    );
  }

  String get identityKey {
    return <Object?>[
      player.id,
      initialFilters.timeControls.map((t) => t.name).join(','),
      initialFilters.minRating,
      initialFilters.maxRating,
      initialFilters.playerColor?.name,
      initialFilters.gameResult?.apiValue,
      initialFilters.isOnline,
      initialFilters.yearFrom,
      initialFilters.yearTo,
    ].join('|');
  }
}

/// Returns the filter update required when a board rail Explorer enters or
/// leaves a player-scoped Build Tree tab.
///
/// `null` means the normal, unscoped Explorer should keep its current user
/// filters unless a player-scoped Build Tree tab previously applied a global
/// board Explorer scope. A concrete [GamebaseFilters] value should be pushed
/// into `gamebaseExplorerProvider` before syncing the position.
GamebaseFilters? boardExplorerFiltersForScope({
  required BoardExplorerScope? scope,
  required GamebaseFilters currentFilters,
  required String? appliedScopeKey,
}) {
  if (scope == null) {
    return appliedScopeKey == null ? null : const GamebaseFilters();
  }
  return appliedScopeKey == scope.identityKey
      ? scope.enforce(currentFilters)
      : scope.initialScopedFilters;
}

/// Tracks the player-scoped Build Tree filter currently applied to the shared
/// gamebase Explorer provider.
///
/// The Explorer provider itself is global, while Board tabs are independent. A
/// normal Board tab therefore cannot rely on its local widget state to know
/// whether another tab left a player scope behind; this key lets the next
/// unscoped Board Explorer clear that global filter back to the default view.
final appliedBoardExplorerScopeKeyProvider = StateProvider<String?>(
  (_) => null,
);

final boardExplorerScopeByTabIdProvider =
    StateProvider<Map<String, BoardExplorerScope>>(
      (_) => const <String, BoardExplorerScope>{},
    );
