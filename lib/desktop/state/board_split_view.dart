import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

/// A Round Wall keeps one full Board pane and up to nine watched positions.
@immutable
class BoardSplitLayout {
  BoardSplitLayout({
    required this.id,
    required List<String> tabIds,
    String? anchorTabId,
  }) : anchorTabId = anchorTabId ?? tabIds.first,
       tabIds = List.unmodifiable(tabIds);

  factory BoardSplitLayout.single(String tabId) =>
      BoardSplitLayout(id: 'single:$tabId', tabIds: [tabId]);

  static const maxWatched = 9;

  final String id;

  /// The raw tab slot that represents the group, even when its main changes.
  final String anchorTabId;

  /// Main board first, followed by the watched slots in reading order.
  final List<String> tabIds;

  String get mainTabId => tabIds.first;
  Iterable<String> get watchedTabIds => tabIds.skip(1);
  bool get isSplit => tabIds.length > 1;
  bool get hasRoom => tabIds.length <= maxWatched;
  bool contains(String tabId) => tabIds.contains(tabId);
  bool isWatched(String tabId) => tabId != mainTabId && contains(tabId);

  BoardSplitLayout append(String tabId) => BoardSplitLayout(
    id: isSplit ? id : 'split-${_nextGroupNumber++}',
    anchorTabId: anchorTabId,
    tabIds: [...tabIds, tabId],
  );

  /// The old main board takes exactly the slot that was selected.
  BoardSplitLayout promote(String tabId) {
    if (!isWatched(tabId)) return this;
    return BoardSplitLayout(
      id: id,
      anchorTabId: anchorTabId,
      tabIds: [
        tabId,
        for (final id in watchedTabIds)
          if (id == tabId) mainTabId else id,
      ],
    );
  }

  BoardSplitLayout? without(String tabId) {
    if (!contains(tabId)) return this;
    if (tabIds.length <= 2) return null;
    return BoardSplitLayout(
      id: id,
      anchorTabId: anchorTabId == tabId ? null : anchorTabId,
      tabIds: tabIds.where((id) => id != tabId).toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BoardSplitLayout &&
      other.id == id &&
      other.anchorTabId == anchorTabId &&
      listEquals(other.tabIds, tabIds);

  @override
  int get hashCode => Object.hash(id, anchorTabId, Object.hashAll(tabIds));
}

int _nextGroupNumber = 0;

/// Every split group of Board tabs. A tab belongs to at most one group.
@immutable
class BoardSplitState {
  const BoardSplitState({this.groups = const <BoardSplitLayout>[]});

  final List<BoardSplitLayout> groups;

  BoardSplitLayout? groupOf(String? tabId) {
    if (tabId == null) return null;
    for (final group in groups) {
      if (group.contains(tabId)) return group;
    }
    return null;
  }
}

/// The request a split asks admission for. Showing two or more boards at
/// once is Premium; one board on its own is free for everyone.
const DesktopAccessContext boardSplitAccessContext = DesktopAccessContext(
  feature: DesktopFeature.boardSplit,
  action: DesktopAction.create,
  origin: DesktopDiscoveryOrigin.localFile,
);

/// Whether the current membership may split the Board workspace.
///
/// Read only when a split is made or shown, so nothing watches the
/// membership for a reader who never splits.
final boardSplitAccessProvider = Provider<DesktopAccessDecision>(
  (ref) => readDesktopAccess(ref.watch, boardSplitAccessContext),
);

/// Admission for an explicit split (a drop onto a split zone, "Open
/// beside"). Returns true when splitting is allowed now. Otherwise opens the
/// window's Premium prompt (sign in, upgrade or Retry, whichever the
/// membership calls for) and returns false: the caller must not split.
/// [resume] runs once after a verified purchase.
bool admitBoardSplit(
  ProviderContainer container, {
  required String surface,
  DesktopAccessResume? resume,
}) => admitDesktopAction(
  container,
  boardSplitAccessContext,
  surface: surface,
  resume: resume,
);

class BoardSplitNotifier extends StateNotifier<BoardSplitState> {
  /// [canSplit] answers whether a layout of two or more boards may be made
  /// now. It is the last line behind the drop and menu gates: any placement
  /// that would leave a split is refused without it. Defaults to allowed.
  BoardSplitNotifier({bool Function()? canSplit})
    : _canSplit = canSplit ?? _alwaysAllowed,
      super(const BoardSplitState());

  static bool _alwaysAllowed() => true;

  final bool Function() _canSplit;

  String? _keepHistoryOnCloseOf;

  /// The tab strip marks a close that starts from the close button of a
  /// tab the same press selected (the press on a background tab activates
  /// it first). Closing it returns to the tab history picks, instead of
  /// moving focus into the split that tab belonged to.
  void keepHistoryOnClose(String tabId) => _keepHistoryOnCloseOf = tabId;

  BoardSplitState get current => state;

  /// The layout a drop over [tabId] plans against: its group, or the board
  /// on its own.
  BoardSplitLayout layoutFor(String tabId) =>
      state.groupOf(tabId) ?? BoardSplitLayout.single(tabId);

  /// Adds a board to the wall without changing the board in focus.
  bool watch({required String targetTabId, required String incomingTabId}) {
    final target = layoutFor(targetTabId);
    if (target.contains(incomingTabId) || !target.hasRoom || !_canSplit()) {
      return false;
    }
    state = BoardSplitState(
      groups: [
        for (final group in state.groups)
          if (group.id == target.id)
            target.append(incomingTabId)
          else if (group.without(incomingTabId) case final remaining?)
            remaining,
        if (!target.isSplit) target.append(incomingTabId),
      ],
    );
    return true;
  }

  void promote(String tabId) {
    final group = state.groupOf(tabId);
    if (group == null || !group.isWatched(tabId)) return;
    state = BoardSplitState(
      groups: [
        for (final current in state.groups)
          if (current.id == group.id) current.promote(tabId) else current,
      ],
    );
  }

  /// Takes [tabId] out of its group. The tab stays open; a group left with
  /// one board dissolves.
  void remove(String tabId) {
    final group = state.groupOf(tabId);
    if (group == null) return;
    final rest = group.without(tabId);
    state = BoardSplitState(
      groups: [
        for (final g in state.groups)
          if (g.id != group.id) g else if (rest != null) rest,
      ],
    );
  }

  /// Dissolves every split. The tabs stay open; each shows on its own.
  void collapseAll() {
    if (state.groups.isEmpty) return;
    state = const BoardSplitState();
  }

  /// Drops every member that is no longer an open Board tab.
  void retainBoardTabs(Set<String> boardTabIds) {
    var changed = false;
    final groups = <BoardSplitLayout>[];
    for (final group in state.groups) {
      BoardSplitLayout? next = group;
      for (final id in group.tabIds) {
        if (boardTabIds.contains(id)) continue;
        next = next?.without(id);
        changed = true;
      }
      if (next != null) groups.add(next);
    }
    if (changed) state = BoardSplitState(groups: groups);
  }
}

final boardSplitProvider =
    StateNotifierProvider<BoardSplitNotifier, BoardSplitState>((ref) {
      final notifier = BoardSplitNotifier(
        canSplit: () => ref.read(boardSplitAccessProvider).isAllowed,
      );
      // Losing Premium (signing out, an expiry, a lapsed renewal) closes
      // every split: the boards stay open as tabs, each on its own. Only a
      // known lapse does; a membership that is still being checked or
      // cannot be reached keeps what is on screen, as admitted work does
      // everywhere else. Membership is watched only while a split exists.
      ProviderSubscription<DesktopAccessDecision>? access;
      void watchAccess(BoardSplitState split) {
        if (split.groups.isEmpty) {
          access?.close();
          access = null;
          return;
        }
        access ??= ref.listen<DesktopAccessDecision>(boardSplitAccessProvider, (
          _,
          next,
        ) {
          if (next.outcome != DesktopAccess.premiumRequired) return;
          // Not while the membership change is still being delivered.
          scheduleMicrotask(() {
            if (!notifier.mounted) return;
            final now = ref.read(boardSplitAccessProvider);
            if (now.outcome == DesktopAccess.premiumRequired) {
              notifier.collapseAll();
            }
          });
        });
      }

      final removeAccessWatch = notifier.addListener(
        watchAccess,
        fireImmediately: false,
      );
      ref.onDispose(() {
        removeAccessWatch();
        access?.close();
      });
      // Closing a tab, or navigating it away from the Board, takes it out of
      // its split; the rest of the group closes up around the gap.
      ref.listen<DesktopTabsState>(desktopTabsProvider, (previous, next) {
        final closedActiveId = previous?.activeId;
        final closedGroup = notifier.current.groupOf(closedActiveId);
        final keepHistory = notifier._keepHistoryOnCloseOf;
        // Left the tab without closing it: the mark no longer applies.
        if (keepHistory != null &&
            next.activeId != keepHistory &&
            next.tabs.any((t) => t.id == keepHistory)) {
          notifier._keepHistoryOnCloseOf = null;
        }
        notifier.retainBoardTabs({
          for (final tab in next.tabs)
            if (tab.kind == TabKind.board) tab.id,
        });
        final activated = next.activeId;
        if (activated != null && activated != closedActiveId) {
          notifier.promote(activated);
        }
        // The focused board of a visible split was closed and tab history
        // picked a tab outside the split, hiding the boards still in it:
        // focus the cell beside the closed one instead.
        if (closedActiveId == null ||
            closedGroup == null ||
            next.tabs.any((t) => t.id == closedActiveId) ||
            closedGroup.contains(next.activeId ?? '') ||
            ref.read(boardFocusModeProvider)) {
          return;
        }
        final tabs = ref.read(desktopTabsProvider.notifier);
        // Close others / close to the right name their successor.
        if (!tabs.lastCloseSuccessorFromHistory) return;
        // Closed from the close button of a tab its own press selected: the
        // split was never really in view, keep history's pick.
        if (closedActiveId == keepHistory) {
          notifier._keepHistoryOnCloseOf = null;
          return;
        }
        final neighbour = splitNeighbourAfterClose(
          closedGroup,
          closedActiveId,
          openTabIds: {for (final tab in next.tabs) tab.id},
        );
        if (neighbour == null) return;
        final pickedByHistory = next.activeId;
        // Not while the tab state is still notifying its listeners; and not
        // if anything moved the active tab again in the meantime.
        scheduleMicrotask(() {
          final current = tabs.currentState;
          if (current.activeId != pickedByHistory) return;
          if (current.tabs.any((t) => t.id == neighbour)) {
            tabs.activate(neighbour);
          }
        });
      });
      return notifier;
    });

/// The split group the workspace shows right now: the active tab's group,
/// or null when the active tab is shown on its own. Board focus mode
/// maximises the focused board, so it shows no split either.
final visibleBoardSplitProvider = Provider<BoardSplitLayout?>((ref) {
  if (ref.watch(boardFocusModeProvider)) return null;
  final activeId = ref.watch(desktopTabsProvider.select((s) => s.activeId));
  return ref.watch(boardSplitProvider.select((s) => s.groupOf(activeId)));
});

/// Whether [tabId] is on screen: the active tab, or a cell of the visible
/// split group even while another cell holds keyboard focus.
///
/// Live moves, clocks and rail rows follow this, because a visible board
/// that froze would be lying. Keyboard focus, shortcuts, sounds, the engine
/// (there is one Stockfish process) and the stream player stay with the
/// active tab alone.
final boardTabOnScreenProvider = Provider.family<bool, String>((ref, tabId) {
  final activeId = ref.watch(desktopTabsProvider.select((s) => s.activeId));
  if (activeId == tabId) return true;
  if (ref.watch(visibleBoardSplitProvider)?.contains(tabId) ?? false) {
    return true;
  }
  // A press on a tab switches at once, and may turn into a pull that brings
  // the previous board straight back. Until the press ends, that board (and
  // its split) still counts as on screen, so the blip resets nothing.
  final held = ref.watch(boardPressHeldTabProvider);
  if (held == null || ref.watch(boardFocusModeProvider)) return false;
  if (held == tabId) return true;
  return ref
          .watch(boardSplitProvider.select((s) => s.groupOf(held)))
          ?.contains(tabId) ??
      false;
});

/// The Board tab that was on screen when a press on another tab began, set
/// for the length of that press by the tab strip. See
/// [boardTabOnScreenProvider].
final boardPressHeldTabProvider = StateProvider<String?>((ref) => null);

/// The first remaining watched board takes over when the main tab closes.
@visibleForTesting
String? splitNeighbourAfterClose(
  BoardSplitLayout group,
  String closedTabId, {
  required Set<String> openTabIds,
}) {
  if (!group.contains(closedTabId)) return null;
  for (final id in group.tabIds) {
    if (id != closedTabId && openTabIds.contains(id)) return id;
  }
  return null;
}
