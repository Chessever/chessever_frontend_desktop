import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

@immutable
class BoardExplorerScope {
  const BoardExplorerScope({
    required this.player,
    this.playerAliases = const <GamebasePlayer>[],
    this.initialFilters = const GamebaseFilters(),
  });

  final GamebasePlayer player;

  /// Source-specific names for the same person in a local combined database.
  ///
  /// Online PGNs commonly use a handle (for example `Hikaru`) while the
  /// ChessEver source uses the full player name. These remain name-only
  /// identities: remote Explorer requests continue to use [player.id].
  final List<GamebasePlayer> playerAliases;
  final GamebaseFilters initialFilters;

  List<GamebasePlayer> get _scopedPlayers => <GamebasePlayer>[
    player,
    ...playerAliases,
  ];

  GamebaseFilters get initialScopedFilters => enforce(initialFilters);

  GamebaseFilters enforce(GamebaseFilters filters) {
    return filters.copyWith(
      playerIds: <String>[player.id],
      selectedPlayers: _scopedPlayers,
    );
  }

  String get identityKey {
    return <Object?>[
      player.id,
      playerAliases.map((player) => '${player.id}:${player.name}').join(','),
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

/// Tracks the player-scoped Build Tree filter currently applied to this board
/// tab's Gamebase Explorer provider scope.
///
/// Board tabs keep independent explorer providers, but each tab still needs to
/// know whether its own explorer previously applied a player scope so returning
/// to an unscoped board can clear those filters back to the default view.
final appliedBoardExplorerScopeKeyProvider = StateProvider<String?>(
  (_) => null,
);

final boardExplorerScopeByTabIdProvider =
    StateProvider<Map<String, BoardExplorerScope>>(
      (_) => const <String, BoardExplorerScope>{},
    );
