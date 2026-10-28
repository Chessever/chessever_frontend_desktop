import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';

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
    this.eventBroadcastId,
    this.accessContext,
  });

  /// Source-stable identifier for the game (Supabase game id, saved
  /// analysis id, parsed-PGN game id). Used by the drop target to ignore
  /// no-op drags onto themselves.
  final String id;

  /// Short human label, e.g. "Carlsen vs Nepo". Currently used for hover
  /// affordances on the tab strip while a payload is in flight.
  final String label;

  /// Parent event carried by tournament payloads. Other payload sources leave
  /// this null. Exposing the identity here keeps modifier/middle-click and
  /// drag/drop paths auditable instead of hiding context inside a closure.
  final String? eventBroadcastId;

  /// Where the dragged game was discovered, when the source supplied it.
  /// Explicit new-tab gestures admit it BEFORE [spawn] runs (see
  /// [spawnAdmitted]), so a denied payload starts no fetch and opens no tab;
  /// the spawn then re-admits at the operation boundary. Null leaves the
  /// decision to the spawn's own admission (an ordinary broadcast, a library
  /// row).
  final DesktopAccessContext? accessContext;

  /// Materializes this game as a tab. The drop target invokes it with
  /// `focus: true` (drag-drop UX always foregrounds the result) — but the
  /// callback is responsible for honouring it via `openBoardGameTab` /
  /// `desktopTabsProvider.open`.
  final Future<void> Function(WidgetRef ref, {required bool focus}) spawn;

  /// Runs [spawn] for an explicit gesture (tab-strip drop, Cmd/Ctrl-click,
  /// middle-click) once [accessContext] is admitted. A denial presents the
  /// decision in this window, because the gesture is the user's own action.
  Future<void> spawnAdmitted(
    WidgetRef ref, {
    required bool focus,
    required String surface,
  }) async {
    final context = accessContext;
    if (context != null &&
        !admitDesktopAction(
          ProviderScope.containerOf(ref.context, listen: false),
          context.copyWith(action: DesktopAction.openContent),
          surface: surface,
        )) {
      return;
    }
    await spawn(ref, focus: focus);
  }
}
