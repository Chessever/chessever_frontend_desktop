import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/chessboard/widgets/nag_display.dart';

/// Per-tab + per-mainline-half-move user-applied NAG codes.
///
/// Outer key: `DesktopTab.id` (so two open Board tabs can carry their
/// own annotations without colliding). Inner key: zero-based half-move index
/// (`0` is the first move, `1` is the reply). Value: list of NAG ints, e.g.
/// `[1]` for `!`, `[3]` for `!!`, `[1, 16]` for `!±`.
///
/// The board's move list merges these with PGN-baked NAGs and Lichess
/// analysis NAGs at render time, deduped, then resolved through
/// `getNagDisplay` for the inline glyph next to the SAN.
final userMoveNagsProvider = StateNotifierProvider<
  UserMoveNagsNotifier,
  Map<String, Map<int, List<int>>>
>((ref) => UserMoveNagsNotifier());

class UserMoveNagsNotifier
    extends StateNotifier<Map<String, Map<int, List<int>>>> {
  UserMoveNagsNotifier() : super(const <String, Map<int, List<int>>>{});

  /// Replace the NAG list for a single half-move. Pass an empty list to clear.
  void setNags(String tabId, int ply, List<int> nags) {
    final tabMap = Map<int, List<int>>.from(
      state[tabId] ?? const <int, List<int>>{},
    );
    if (nags.isEmpty) {
      tabMap.remove(ply);
    } else {
      tabMap[ply] = List<int>.unmodifiable(nags);
    }
    final next = Map<String, Map<int, List<int>>>.from(state);
    if (tabMap.isEmpty) {
      next.remove(tabId);
    } else {
      next[tabId] = tabMap;
    }
    state = next;
  }

  /// Replace the *quality* NAG (`! ? !! ?? !? ?!`) for [ply], preserving any
  /// non-quality NAGs (evaluation/observation glyphs from PGN). Pass `null` to
  /// clear the quality NAG entirely.
  void setQualityNag(String tabId, int ply, int? qualityNag) {
    final existing = state[tabId]?[ply] ?? const <int>[];
    final preserved = existing.where((n) => !_isQualityNag(n)).toList();
    if (qualityNag != null) preserved.add(qualityNag);
    setNags(tabId, ply, preserved);
  }

  /// Toggle a single NAG for [ply].
  ///
  /// Desktop notation mirrors the mobile picker: quality, evaluation, and
  /// observation each have one active user slot. Tapping the same glyph clears
  /// it; tapping another glyph in the same category replaces the old one.
  void toggleNag(String tabId, int ply, int nag) {
    final tapped = getNagDisplay(nag);
    if (tapped == null) return;

    final existing = List<int>.from(state[tabId]?[ply] ?? const <int>[]);
    if (existing.contains(nag)) {
      existing.remove(nag);
    } else {
      existing.removeWhere((other) {
        final display = getNagDisplay(other);
        return display != null && display.category == tapped.category;
      });
      existing.add(nag);
    }
    setNags(tabId, ply, existing);
  }

  /// Clear all user-applied NAGs for a single half-move.
  void clearNags(String tabId, int ply) {
    setNags(tabId, ply, const <int>[]);
  }

  /// Wipe all annotations for [tabId] (used when the tab closes).
  void clearTab(String tabId) {
    if (!state.containsKey(tabId)) return;
    final next = Map<String, Map<int, List<int>>>.from(state)..remove(tabId);
    state = next;
  }

  /// Replace the entire NAG map for [tabId] with [nags]. Used by the
  /// undo stack to restore the pre-mutation snapshot. An empty map
  /// removes the tab entry entirely.
  void restoreTab(String tabId, Map<int, List<int>> nags) {
    final next = Map<String, Map<int, List<int>>>.from(state);
    if (nags.isEmpty) {
      next.remove(tabId);
    } else {
      next[tabId] = Map<int, List<int>>.unmodifiable({
        for (final entry in nags.entries)
          entry.key: List<int>.unmodifiable(entry.value),
      });
    }
    state = next;
  }
}

/// Whether a NAG code is a quality / move-quality glyph
/// (`!`, `?`, `!!`, `??`, `!?`, `?!`, `□`). Mirrors `getNagDisplay`'s
/// `NagCategory.quality` set so the right-click menu only ever
/// overwrites a quality glyph, never an evaluation (`±`/`=`/`∞`/...) or
/// observation (`⟳`/`→`/`N`) NAG that came from the PGN.
bool _isQualityNag(int nag) => nag >= 1 && nag <= 7;
