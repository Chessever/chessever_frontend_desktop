import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

/// Cross-pane handoff for "open the Opening Explorer at this position".
///
/// Set by anything that wants to navigate the explorer to a specific
/// FEN — for example the Board Editor's "Search games" button and the
/// board pane's open-explorer shortcut. The pane consumes the seed on first
/// build and clears it
/// (one-shot semantics, so resizing or re-entering the pane doesn't
/// snap the position back).
@immutable
class OpeningExplorerSeed {
  const OpeningExplorerSeed({
    required this.fen,
    this.moves = const <String>[],
    this.exactFenSearch = false,
    this.player,
    this.filters,
  });

  final String fen;

  /// Optional UCI line that reaches [fen] from the normal starting position.
  ///
  /// Supplying this lets the desktop explorer use the same fast indexed
  /// position-games query as mobile for normal PGN/game positions.
  final List<String> moves;

  /// True when [fen] came from a standalone position, e.g. Board Editor paste
  /// FEN, and may not have a replayable PGN line from the initial position.
  final bool exactFenSearch;

  /// Player to scope the explorer to. When set, the pane replaces the
  /// explorer's `playerIds`/`selectedPlayers` filter with this player so
  /// the move-aggregate table reflects only that player's games.
  final GamebasePlayer? player;

  /// Filters to apply when seeding. Combined with [player] (if any) when
  /// the pane consumes the seed. When null, the pane leaves existing
  /// filters untouched.
  final GamebaseFilters? filters;
}

final openingExplorerSeedProvider = StateProvider<OpeningExplorerSeed?>(
  (ref) => null,
);
