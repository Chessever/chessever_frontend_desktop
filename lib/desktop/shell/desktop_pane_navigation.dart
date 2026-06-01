import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';

/// Shared sidebar/command-palette pane navigation.
///
/// Plain sidebar clicks usually navigate the foreground tab in-place, but
/// game-hosting tabs are user workspaces. Leaving a live Board game for a
/// category pane should preserve the game tab and open/activate the category
/// tab instead.
void openDesktopPaneFromContainer(
  ProviderContainer container,
  DesktopPane pane, {
  bool inNewTab = false,
}) {
  final tabsNotifier = container.read(desktopTabsProvider.notifier);
  final kind = tabKindForPane(pane);

  // Special-case Board's scratch tab - the user expects "Board" (Cmd+T new
  // tab, command palette, etc.) to land on a clean workspace, never on a per-game
  // Board tab. Only relevant on plain clicks.
  if (!inNewTab && pane == DesktopPane.board) {
    final tabsState = container.read(desktopTabsProvider);
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);
    for (final t in tabsState.tabs) {
      if (t.kind == TabKind.board && !argsByTab.containsKey(t.id)) {
        tabsNotifier.activate(t.id);
        return;
      }
    }
  }

  // Preserve active game tabs when jumping to a category pane. Without this,
  // clicking Favorites/Library/etc. while reviewing a game rewrites the same
  // tab route and the game disappears from the tab strip.
  if (!inNewTab && pane != DesktopPane.board) {
    final tabsState = container.read(desktopTabsProvider);
    final active = tabsState.active;
    final activeBoardGame =
        active != null &&
        active.kind == TabKind.board &&
        container.read(boardTabGameArgsByTabIdProvider).containsKey(active.id);
    if (activeBoardGame) {
      tabsNotifier.open(kind);
      return;
    }
  }

  // Special-case Play - sidebar click should always land the user on a tab
  // where they can start a *new* game. If the active tab is already a Play tab
  // and it's mid-session, navigating in place is a no-op (the route doesn't
  // change) and the user feels stuck. Look for any existing Play tab in setup;
  // failing that, spawn a fresh one.
  if (!inNewTab && pane == DesktopPane.play) {
    final tabsState = container.read(desktopTabsProvider);
    final sessions = container.read(playSessionArgsByTabIdProvider);
    final active = tabsState.active;
    final activeIsPlayInSetup =
        active != null &&
        active.kind == TabKind.play &&
        !sessions.containsKey(active.id);
    if (!activeIsPlayInSetup) {
      for (final t in tabsState.tabs) {
        if (t.kind == TabKind.play && !sessions.containsKey(t.id)) {
          tabsNotifier.activate(t.id);
          return;
        }
      }
      tabsNotifier.open(TabKind.play, reuseExisting: false);
      return;
    }
  }

  if (inNewTab) {
    // Explicit "open in new tab" - bypass active-tab navigation.
    tabsNotifier.open(kind, reuseExisting: false);
  } else {
    // Default: navigate the active tab in place. If there's no active tab,
    // navigateActive falls back to opening one.
    tabsNotifier.navigateActive(kind);
  }
}
