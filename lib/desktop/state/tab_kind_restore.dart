import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';

/// Tab kinds that earlier builds could persist but this build no longer
/// has. A restored payload (a detached tab window, a saved session) may
/// still name one; it resolves to the closest surviving destination instead
/// of silently turning into an unrelated Board tab.
@visibleForTesting
const Map<String, TabKind> retiredTabKindReplacements = <String, TabKind>{
  // Desktop notification preferences were removed. Desktop has no push
  // channel, and the pane wrote the phone's shared push preference.
  'notificationSettings': TabKind.settings,
};

/// Outcome of resolving a persisted tab kind name.
@immutable
class RestoredTabKind {
  const RestoredTabKind(this.kind, {required this.retired});

  final TabKind kind;

  /// True when the persisted name was a retired kind that was redirected.
  /// Callers should drop any persisted title, because it described the
  /// retired surface rather than [kind].
  final bool retired;
}

/// Resolves a persisted tab kind [value] without ever throwing.
///
/// Known names map to themselves, retired names map through
/// [retiredTabKindReplacements], and anything else falls back to [fallback].
RestoredTabKind restoreTabKindByName(
  Object? value, {
  TabKind fallback = TabKind.board,
}) {
  final name = value?.toString();
  for (final kind in TabKind.values) {
    if (kind.name == name) return RestoredTabKind(kind, retired: false);
  }
  final replacement = retiredTabKindReplacements[name];
  if (replacement != null) return RestoredTabKind(replacement, retired: true);
  return RestoredTabKind(fallback, retired: false);
}
