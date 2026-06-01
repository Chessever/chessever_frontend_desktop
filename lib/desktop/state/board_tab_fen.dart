import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Latest FEN rendered by each Board-kind tab, keyed by [DesktopTab.id].
///
/// The Board pane writes its current cursor FEN here on every move-step or
/// new-game load. The tab bar reads it back so a Board tab chip can render
/// a thin live eval bar — turning every "this is a game" tab into a glance-
/// able indicator without adding state to the tab itself.
final boardTabFenProvider =
    StateProvider<Map<String, String>>((_) => const <String, String>{});

extension BoardTabFenWriter on StateController<Map<String, String>> {
  /// Set the FEN for [tabId]. Pass an empty string (or call [clear]) to
  /// reset, e.g. when the tab returns to a freeplay starting position.
  void setFen(String tabId, String fen) {
    final current = state;
    if (current[tabId] == fen) return;
    state = <String, String>{...current, tabId: fen};
  }

  /// Drop [tabId] from the map (typically when the tab is closed).
  void clear(String tabId) {
    if (!state.containsKey(tabId)) return;
    final next = <String, String>{...state}..remove(tabId);
    state = next;
  }
}
