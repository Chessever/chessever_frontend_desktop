import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const int _maxRouteHistoryEntries = 50;

/// Identifier for the kind of content a tab hosts. Mapped 1:1 onto the
/// pre-existing `DesktopPane` enum and extended with the Chrome-style "new
/// tab" affordances (opening explorer, board editor, watch) the desktop
/// shell will land in subsequent passes.
enum TabKind {
  board,
  tournaments,

  /// A single tournament's detail (about / games / standings). The active
  /// tournament is read from `activeTournamentProvider`.
  tournamentDetail,
  library,
  favorites,
  players,
  calendar,
  countrymen,
  settings,
  openingExplorer,
  boardEditor,
  watch,

  /// A player's score card (mobile's `ScoreCardScreen`). Opened by tapping
  /// a player name on the board or in a roster. The focused player is
  /// stored per-tab via `playerScoreCardArgsProvider`.
  playerScoreCard,

  /// A player's full profile (mobile's `PlayerProfileScreen`). Reached
  /// from the score card's "View profile" affordance.
  playerProfile,

  /// Signed-in user's desktop player profile: avatar, rating curve,
  /// achievements, and game history.
  userProfile,

  /// Mobile's `ChessBoardSettingsPage` — board theme, piece set, sound,
  /// auto-pin, etc. Reached from the desktop Settings pane.
  boardSettings,

  /// Mobile's `ChessBoardNotificationSettingsPage` — push prefs +
  /// per-event notification cadence. Reached from the Settings pane.
  notificationSettings,

  /// Play-vs-bot home. Setup screen (time control, engine, ELO, color) and
  /// — once a game is started — the active game view. Also hosts the local
  /// engine tournament browser. Spawned from the sidebar's Play entry and
  /// from the "Play from here" context action on any board view.
  play,

  /// reference-style opened database workspace: dense game table plus a
  /// selected-game board/notation preview. Per-tab source args live in the
  /// Library pane so multiple databases can be opened side-by-side.
  databaseWorkspace,
}

extension TabKindLabel on TabKind {
  String get defaultTitle {
    switch (this) {
      case TabKind.board:
        return 'Board';
      case TabKind.tournaments:
        return 'Tournaments';
      case TabKind.tournamentDetail:
        return 'Tournament';
      case TabKind.library:
        return 'Library';
      case TabKind.favorites:
        return 'Favorites';
      case TabKind.players:
        return 'Players';
      case TabKind.calendar:
        return 'Calendar';
      case TabKind.countrymen:
        return 'Countrymen';
      case TabKind.settings:
        return 'Settings';
      case TabKind.openingExplorer:
        return 'Opening Explorer';
      case TabKind.boardEditor:
        return 'Board Editor';
      case TabKind.watch:
        return 'Watch';
      case TabKind.playerScoreCard:
        return 'Score Card';
      case TabKind.playerProfile:
        return 'Player';
      case TabKind.userProfile:
        return 'My profile';
      case TabKind.boardSettings:
        return 'Board Settings';
      case TabKind.notificationSettings:
        return 'Notifications';
      case TabKind.play:
        return 'Play';
      case TabKind.databaseWorkspace:
        return 'Database';
    }
  }
}

@immutable
class DesktopTabRoute {
  const DesktopTabRoute({
    required this.kind,
    required this.title,
    this.subtitle,
  });

  final TabKind kind;
  final String title;
  final String? subtitle;

  factory DesktopTabRoute.fromTab(DesktopTab tab) {
    return DesktopTabRoute(
      kind: tab.kind,
      title: tab.title,
      subtitle: tab.subtitle,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DesktopTabRoute &&
            other.kind == kind &&
            other.title == title &&
            other.subtitle == subtitle;
  }

  @override
  int get hashCode => Object.hash(kind, title, subtitle);
}

@immutable
class DesktopTab {
  const DesktopTab({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.closable = true,
    this.backHistory = const <DesktopTabRoute>[],
    this.forwardHistory = const <DesktopTabRoute>[],
  });

  final String id;
  final TabKind kind;
  final String title;
  final String? subtitle;

  /// Some tabs can be pinned by the shell and should not surface a close
  /// button. Ordinary user-created tabs keep Chrome-like close semantics.
  final bool closable;

  /// Per-tab route history. These stacks track shell-level route changes
  /// inside this tab only; tab activation/reordering does not touch them.
  final List<DesktopTabRoute> backHistory;
  final List<DesktopTabRoute> forwardHistory;

  DesktopTabRoute get route => DesktopTabRoute.fromTab(this);
  bool get canGoBack => backHistory.isNotEmpty;
  bool get canGoForward => forwardHistory.isNotEmpty;

  DesktopTab copyWith({String? title, String? subtitle}) {
    return DesktopTab(
      id: id,
      kind: kind,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      closable: closable,
      backHistory: backHistory,
      forwardHistory: forwardHistory,
    );
  }

  DesktopTab withRoute(
    DesktopTabRoute route, {
    required List<DesktopTabRoute> backHistory,
    required List<DesktopTabRoute> forwardHistory,
  }) {
    return DesktopTab(
      id: id,
      kind: route.kind,
      title: route.title,
      subtitle: route.subtitle,
      closable: closable,
      backHistory: backHistory,
      forwardHistory: forwardHistory,
    );
  }
}

@immutable
class DesktopTabsState {
  const DesktopTabsState({
    required this.tabs,
    required this.activeId,
    this.activationHistory = const <String>[],
  });

  final List<DesktopTab> tabs;
  final String? activeId;

  /// Most-recently-active tab ids, newest first, excluding [activeId]. This
  /// lets closing a tab return to the exact context the user came from rather
  /// than picking a strip neighbor that may be visually adjacent but unrelated.
  final List<String> activationHistory;

  DesktopTab? get active {
    if (activeId == null) return null;
    for (final t in tabs) {
      if (t.id == activeId) return t;
    }
    return null;
  }

  bool get canGoBack => active?.canGoBack ?? false;
  bool get canGoForward => active?.canGoForward ?? false;
}

class DesktopTabsNotifier extends StateNotifier<DesktopTabsState> {
  DesktopTabsNotifier()
    : super(
        const DesktopTabsState(
          tabs: [
            DesktopTab(
              id: 'tournaments-default',
              kind: TabKind.tournaments,
              title: 'Tournaments',
            ),
          ],
          activeId: 'tournaments-default',
        ),
      );

  static int _idCounter = 0;
  static String _nextId() => 'tab-${_idCounter++}';

  DesktopTabsState _stateWithActive({
    required List<DesktopTab> tabs,
    required String? activeId,
  }) {
    final previousActiveId = state.activeId;
    final validIds = tabs.map((tab) => tab.id).toSet();
    final history = <String>[
      if (previousActiveId != null &&
          previousActiveId != activeId &&
          validIds.contains(previousActiveId))
        previousActiveId,
      for (final id in state.activationHistory)
        if (id != activeId && id != previousActiveId && validIds.contains(id))
          id,
    ];
    return DesktopTabsState(
      tabs: tabs,
      activeId: activeId,
      activationHistory: history,
    );
  }

  /// Opens a tab of [kind]. If [reuseExisting] is true (default) and a tab of
  /// the same kind is already open, it's just activated rather than spawning
  /// a duplicate — matching what users expect from category browsers.
  /// Returns the id of the now-active tab so callers (e.g. the Tournaments
  /// pane) can stash per-tab metadata against it.
  ///
  /// When [focus] is false the new tab is appended to the strip but the
  /// currently active tab stays foregrounded — used for Cmd/Ctrl-click and
  /// middle-click background-tab opens.
  String open(
    TabKind kind, {
    String? title,
    String? subtitle,
    bool reuseExisting = true,
    bool focus = true,
  }) {
    if (reuseExisting) {
      for (final tab in state.tabs) {
        if (tab.kind == kind) {
          if (focus) {
            state = _stateWithActive(tabs: state.tabs, activeId: tab.id);
          }
          return tab.id;
        }
      }
    }
    final tab = DesktopTab(
      id: _nextId(),
      kind: kind,
      title: title ?? kind.defaultTitle,
      subtitle: subtitle,
    );
    final newTabs = [...state.tabs, tab];
    state = focus
        ? _stateWithActive(tabs: newTabs, activeId: tab.id)
        : DesktopTabsState(
            tabs: newTabs,
            activeId: state.activeId,
            activationHistory: state.activationHistory,
          );
    return tab.id;
  }

  /// Replace the *active* tab's route in-place (without changing its position
  /// in the strip or its id). Returns the id of the now-active tab, or `null`
  /// if there is no active tab to navigate. Used by the sidebar — clicking a
  /// sidebar entry navigates the current tab to that route ("main route"
  /// semantics) instead of spawning a new tab every time. Cmd/Ctrl-click on the
  /// sidebar bypasses this and calls `open(...)` for explicit new-tab
  /// behaviour.
  ///
  /// Note: per-tab metadata (player args, board-game args, tournament args)
  /// attached to the old route remains keyed by the tab id. Panes ignore
  /// metadata for other route kinds, and the shell's tab-close listener prunes
  /// those maps when tabs close.
  String? navigateActive(TabKind kind, {String? title, String? subtitle}) {
    final activeId = state.activeId;
    final route = DesktopTabRoute(
      kind: kind,
      title: title ?? kind.defaultTitle,
      subtitle: subtitle,
    );
    if (activeId == null) {
      // No tab to navigate — fall back to opening one.
      return open(kind, title: route.title, subtitle: route.subtitle);
    }
    final idx = state.tabs.indexWhere((t) => t.id == activeId);
    if (idx < 0) {
      return open(kind, title: route.title, subtitle: route.subtitle);
    }
    final old = state.tabs[idx];
    if (old.route == route) {
      // Already showing this route — nothing to do.
      return activeId;
    }
    final replaced = old.withRoute(
      route,
      backHistory: _pushRoute(old.backHistory, old.route),
      forwardHistory: const <DesktopTabRoute>[],
    );
    final newTabs = [
      for (var i = 0; i < state.tabs.length; i++)
        if (i == idx) replaced else state.tabs[i],
    ];
    state = DesktopTabsState(
      tabs: newTabs,
      activeId: activeId,
      activationHistory: state.activationHistory,
    );
    return activeId;
  }

  /// Move the active tab one shell route back, Chrome-style. No-op when the
  /// active tab has no back stack.
  void goBack() {
    final activeId = state.activeId;
    if (activeId == null) return;
    final idx = state.tabs.indexWhere((t) => t.id == activeId);
    if (idx < 0) return;
    final old = state.tabs[idx];
    if (old.backHistory.isEmpty) return;

    final previous = old.backHistory.last;
    final updated = old.withRoute(
      previous,
      backHistory: old.backHistory.sublist(0, old.backHistory.length - 1),
      forwardHistory: _pushRoute(old.forwardHistory, old.route),
    );
    final newTabs = [
      for (var i = 0; i < state.tabs.length; i++)
        if (i == idx) updated else state.tabs[i],
    ];
    state = DesktopTabsState(
      tabs: newTabs,
      activeId: activeId,
      activationHistory: state.activationHistory,
    );
  }

  /// Move the active tab one shell route forward, Chrome-style. No-op when the
  /// active tab has no forward stack.
  void goForward() {
    final activeId = state.activeId;
    if (activeId == null) return;
    final idx = state.tabs.indexWhere((t) => t.id == activeId);
    if (idx < 0) return;
    final old = state.tabs[idx];
    if (old.forwardHistory.isEmpty) return;

    final next = old.forwardHistory.last;
    final updated = old.withRoute(
      next,
      backHistory: _pushRoute(old.backHistory, old.route),
      forwardHistory: old.forwardHistory.sublist(
        0,
        old.forwardHistory.length - 1,
      ),
    );
    final newTabs = [
      for (var i = 0; i < state.tabs.length; i++)
        if (i == idx) updated else state.tabs[i],
    ];
    state = DesktopTabsState(
      tabs: newTabs,
      activeId: activeId,
      activationHistory: state.activationHistory,
    );
  }

  /// Brings the tab with [id] to the foreground. No-op if it doesn't exist.
  void activate(String id) {
    if (state.activeId == id) return;
    for (final tab in state.tabs) {
      if (tab.id == id) {
        state = _stateWithActive(tabs: state.tabs, activeId: id);
        return;
      }
    }
  }

  /// Activates the tab at a zero-based strip [index]. Kept as the underlying
  /// browser-style tab-index primitive even when the shell binds number keys
  /// to sidebar navigation.
  void activateAt(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    activate(state.tabs[index].id);
  }

  /// Activates the last tab in the strip. Mirrors Chrome's `Cmd/Ctrl+9`.
  void activateLast() {
    if (state.tabs.isEmpty) return;
    activate(state.tabs.last.id);
  }

  /// Cycles to the next tab, wrapping at the end. Mirrors `Ctrl+Tab` and
  /// Chrome's bracket shortcuts.
  void activateNext() {
    final activeId = state.activeId;
    if (state.tabs.isEmpty || activeId == null) return;
    final idx = state.tabs.indexWhere((t) => t.id == activeId);
    if (idx < 0) return;
    activate(state.tabs[(idx + 1) % state.tabs.length].id);
  }

  /// Cycles to the previous tab, wrapping at the start.
  void activatePrevious() {
    final activeId = state.activeId;
    if (state.tabs.isEmpty || activeId == null) return;
    final idx = state.tabs.indexWhere((t) => t.id == activeId);
    if (idx < 0) return;
    activate(state.tabs[(idx - 1 + state.tabs.length) % state.tabs.length].id);
  }

  /// Closes the tab with [id]. Pinned tabs (closable == false) are ignored.
  /// When the active tab closes, returns to the most recently active remaining
  /// tab. If there is no activation history, falls back to strip-neighbor
  /// browser semantics.
  void close(String id) {
    final idx = state.tabs.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final tab = state.tabs[idx];
    if (!tab.closable) return;

    final remaining = [
      for (var i = 0; i < state.tabs.length; i++)
        if (i != idx) state.tabs[i],
    ];

    String? newActive = state.activeId;
    if (state.activeId == id) {
      final validRemainingIds = remaining.map((tab) => tab.id).toSet();
      newActive = state.activationHistory.firstWhere(
        validRemainingIds.contains,
        orElse: () {
          if (remaining.isEmpty) return '';
          if (idx < remaining.length) return remaining[idx].id;
          return remaining.last.id;
        },
      );
      if (newActive.isEmpty) newActive = null;
    }

    state = DesktopTabsState(
      tabs: remaining,
      activeId: newActive,
      activationHistory: [
        for (final historyId in state.activationHistory)
          if (historyId != id && historyId != newActive) historyId,
      ],
    );
  }

  /// Close every closable tab *except* [keepId]. Mirrors Chrome's
  /// "Close other tabs" context-menu action.
  void closeOthers(String keepId) {
    final keep = <DesktopTab>[
      for (final t in state.tabs)
        if (t.id == keepId || !t.closable) t,
    ];
    if (keep.length == state.tabs.length) return;
    final activeStillExists = keep.any((t) => t.id == state.activeId);
    final keptIds = keep.map((tab) => tab.id).toSet();
    final nextActiveId = activeStillExists ? state.activeId : keepId;
    state = DesktopTabsState(
      tabs: keep,
      activeId: nextActiveId,
      activationHistory: [
        for (final id in state.activationHistory)
          if (id != nextActiveId && keptIds.contains(id)) id,
      ],
    );
  }

  /// Close every closable tab on the right of [pivotId]. Mirrors Chrome's
  /// "Close tabs to the right" action.
  void closeToTheRight(String pivotId) {
    final idx = state.tabs.indexWhere((t) => t.id == pivotId);
    if (idx < 0) return;
    final keep = <DesktopTab>[
      for (var i = 0; i < state.tabs.length; i++)
        if (i <= idx || !state.tabs[i].closable) state.tabs[i],
    ];
    if (keep.length == state.tabs.length) return;
    final activeStillExists = keep.any((t) => t.id == state.activeId);
    final keptIds = keep.map((tab) => tab.id).toSet();
    final nextActiveId = activeStillExists ? state.activeId : pivotId;
    state = DesktopTabsState(
      tabs: keep,
      activeId: nextActiveId,
      activationHistory: [
        for (final id in state.activationHistory)
          if (id != nextActiveId && keptIds.contains(id)) id,
      ],
    );
  }

  /// Reorder a tab. ReorderableListView semantics — Flutter passes a
  /// pre-removal drop index for [newIndex], so we adjust when moving forward.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final tabs = List<DesktopTab>.of(state.tabs);
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (adjusted < 0 || adjusted > tabs.length - 1) return;
    final moved = tabs.removeAt(oldIndex);
    tabs.insert(adjusted, moved);
    state = DesktopTabsState(
      tabs: tabs,
      activeId: state.activeId,
      activationHistory: state.activationHistory,
    );
  }

  /// Update the visible label of an existing tab (e.g. when a Board tab
  /// loads a specific game and wants to show "Carlsen — Nepo, R5").
  void rename(String id, {String? title, String? subtitle}) {
    final idx = state.tabs.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final updated = state.tabs[idx].copyWith(title: title, subtitle: subtitle);
    final newTabs = [
      for (var i = 0; i < state.tabs.length; i++)
        if (i == idx) updated else state.tabs[i],
    ];
    state = DesktopTabsState(
      tabs: newTabs,
      activeId: state.activeId,
      activationHistory: state.activationHistory,
    );
  }
}

List<DesktopTabRoute> _pushRoute(
  List<DesktopTabRoute> stack,
  DesktopTabRoute route,
) {
  if (stack.isNotEmpty && stack.last == route) {
    return stack;
  }
  if (stack.length >= _maxRouteHistoryEntries) {
    return <DesktopTabRoute>[
      ...stack.skip(stack.length - _maxRouteHistoryEntries + 1),
      route,
    ];
  }
  return <DesktopTabRoute>[...stack, route];
}

final desktopTabsProvider =
    StateNotifierProvider<DesktopTabsNotifier, DesktopTabsState>(
      (ref) => DesktopTabsNotifier(),
    );

/// Convenience derived view of "what kind is the active tab". Lets the rest
/// of the app keep talking in terms of the original `DesktopPane`-style enum
/// even after the shell switched to a tab model.
final activeTabKindProvider = Provider<TabKind?>((ref) {
  final state = ref.watch(desktopTabsProvider);
  return state.active?.kind;
});
