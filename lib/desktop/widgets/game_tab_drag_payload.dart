import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// What gets handed to a [DragTarget] when the user drags a game card off a
/// pane and drops it on the tab strip. The payload itself is opaque — each
/// source (tournament feed, library, import preview) supplies a [spawn]
/// callback that knows how to materialize itself as a Board tab (fetch PGN
/// if needed, register live-stream args, then call `openBoardGameTab`).
///
/// `id` and `label` are passed straight through so [DragTarget]s can
/// dedupe and render hover affordances ("Open <label> in new tab") without
/// running the spawn function.
@immutable
class GameTabDragPayload {
  const GameTabDragPayload({
    required this.id,
    required this.label,
    required this.spawn,
  });

  /// Source-stable identifier for the game (Supabase game id, saved
  /// analysis id, parsed-PGN game id). Used by the drop target to ignore
  /// no-op drags onto themselves.
  final String id;

  /// Short human label, e.g. "Carlsen vs Nepo". Currently used for hover
  /// affordances on the tab strip while a payload is in flight.
  final String label;

  /// Materializes this game as a tab. The drop target invokes it with
  /// `focus: true` (drag-drop UX always foregrounds the result) — but the
  /// callback is responsible for honouring it via `openBoardGameTab` /
  /// `desktopTabsProvider.open`.
  final Future<void> Function(WidgetRef ref, {required bool focus}) spawn;
}
