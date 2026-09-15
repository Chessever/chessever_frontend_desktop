/// How the Board rail's live-stream player should treat an already-created
/// native WebView when the owning tab or its stream list changes.
///
/// Only the first Board tab's player reliably survives a dispose /
/// re-attach cycle; every later tab's webview comes back fresh and the
/// broadcast restarts. Worse, merely relocating the host (a [GlobalKey]
/// move between a visible slot and a parked slot) detaches the platform
/// view the same way. Hidden tabs must therefore keep rendering the player
/// at its one stable tree position (the tab stack's own Offstage hides
/// it) until the 20s stop-grace blanks it.
enum BroadcastVideoPlayerRetention {
  /// Paint the player in the rail.
  show,

  /// Tab or window is not the surface the user is viewing: keep rendering
  /// the player in place (the tab stack hides it) so a quick switch-back
  /// neither moves nor reloads it.
  preserveOffstage,

  /// Take the player out of the tree (and blank it, when the caller decides).
  hide,
}

/// Decides whether the current native player may stay alive.
///
/// [hasPreservedPlayer] is true only while this panel's controller still
/// holds the embed it last loaded. A streams-family refetch (autoDispose
/// rebuilds the list when the hidden tab stops watching) must not look like
/// "no coverage" and tear that player down.
BroadcastVideoPlayerRetention resolveBroadcastVideoPlayerRetention({
  required bool tabActive,
  required bool windowVisible,
  required bool hasPreservedPlayer,
  required bool streamsResolved,
  required bool languageReady,
  required bool hasPlayableStream,
  required bool userHidden,
}) {
  final surfaceVisible = tabActive && windowVisible;
  if (!surfaceVisible) {
    return hasPreservedPlayer
        ? BroadcastVideoPlayerRetention.preserveOffstage
        : BroadcastVideoPlayerRetention.hide;
  }
  if (userHidden) return BroadcastVideoPlayerRetention.hide;
  if (!streamsResolved || !languageReady) {
    return hasPreservedPlayer
        ? BroadcastVideoPlayerRetention.show
        : BroadcastVideoPlayerRetention.hide;
  }
  if (!hasPlayableStream) return BroadcastVideoPlayerRetention.hide;
  return BroadcastVideoPlayerRetention.show;
}

/// A new embed document is fetched only when the URL actually changes.
/// Returning to a tab with the same stream must not call `loadRequest`.
bool shouldReloadBroadcastVideoEmbed({
  required String? loadedEmbedUrl,
  required String nextEmbedUrl,
}) => loadedEmbedUrl != nextEmbedUrl;
