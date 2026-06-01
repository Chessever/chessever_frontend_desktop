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
