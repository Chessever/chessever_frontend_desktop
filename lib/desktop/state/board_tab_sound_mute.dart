import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Per-desktop-tab sound mute state for Board tabs.
///
/// This intentionally lives outside board settings: board settings control the
/// global/user preference, while this provider lets a noisy live board be muted
/// without silencing other open game tabs.
class BoardTabSoundMuteNotifier extends StateNotifier<Set<String>> {
  BoardTabSoundMuteNotifier() : super(<String>{});

  bool isMuted(String tabId) => state.contains(tabId);

  void setMuted(String tabId, bool muted) {
    if (tabId.isEmpty) return;
    if (muted == state.contains(tabId)) return;
    final next = <String>{...state};
    if (muted) {
      next.add(tabId);
    } else {
      next.remove(tabId);
    }
    state = next;
  }

  void toggle(String tabId) {
    setMuted(tabId, !state.contains(tabId));
  }

  void clear(String tabId) {
    if (!state.contains(tabId)) return;
    state = <String>{...state}..remove(tabId);
  }
}

final boardTabSoundMuteProvider =
    StateNotifierProvider<BoardTabSoundMuteNotifier, Set<String>>(
      (ref) => BoardTabSoundMuteNotifier(),
    );

final isBoardTabSoundMutedProvider = Provider.family<bool, String>((
  ref,
  tabId,
) {
  return ref.watch(
    boardTabSoundMuteProvider.select((muted) => muted.contains(tabId)),
  );
});

/// Whether a tab may play a move/takeover sound right now.
///
/// Desktop tabs stay mounted in a persistent stack, so a board left
/// open in the background keeps streaming live games. Move sounds must follow
/// the tab the user is looking at: without [activeTabId] the Events feed is
/// silent, but every hidden Board/Play tab keeps announcing moves.
///
/// A null or empty [tabId] is a standalone board (PiP window, embedded
/// preview); those have no tab identity and were opened deliberately, so they
/// keep their sound until the user reaches the board's own mute control.
bool shouldPlayTabSound({
  required String? tabId,
  required String? activeTabId,
  required bool globallyEnabled,
  bool tabMuted = false,
}) {
  if (!globallyEnabled) return false;
  final id = tabId?.trim() ?? '';
  if (id.isEmpty) return true;
  if (tabMuted) return false;
  return activeTabId == id;
}
