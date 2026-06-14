import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';

/// Identifier for the primary content pane shown in the desktop shell.
///
/// The desktop shell does not push routes for top-level navigation; the user
/// opens content as Chrome-style tabs. This enum is the legacy identifier
/// the sidebar and existing intents speak in — it maps 1:1 onto the subset
/// of [TabKind] values the sidebar can spawn. Newer kinds (opening explorer,
/// board editor, watch) live only on `TabKind`.
enum DesktopPane {
  board,
  tournaments,
  library,
  favorites,
  players,
  calendar,
  countrymen,
  openingExplorer,
  boardEditor,
  play,
  settings,
}

/// Maps a sidebar pane identifier to its corresponding tab kind.
TabKind tabKindForPane(DesktopPane pane) {
  switch (pane) {
    case DesktopPane.board:
      return TabKind.board;
    case DesktopPane.tournaments:
      return TabKind.tournaments;
    case DesktopPane.library:
      return TabKind.library;
    case DesktopPane.favorites:
      return TabKind.favorites;
    case DesktopPane.players:
      return TabKind.players;
    case DesktopPane.calendar:
      return TabKind.calendar;
    case DesktopPane.countrymen:
      return TabKind.countrymen;
    case DesktopPane.openingExplorer:
      return TabKind.openingExplorer;
    case DesktopPane.boardEditor:
      return TabKind.boardEditor;
    case DesktopPane.play:
      return TabKind.play;
    case DesktopPane.settings:
      return TabKind.settings;
  }
}

/// Inverse of [tabKindForPane]. Returns null for tab kinds with no matching
/// sidebar entry (opening explorer, board editor, watch — they live only in
/// the new-tab menu).
DesktopPane? paneForTabKind(TabKind kind) {
  switch (kind) {
    case TabKind.board:
      return DesktopPane.board;
    case TabKind.tournaments:
    case TabKind.tournamentDetail:
    case TabKind.smartGames:
      // Tournament detail and smart game collection tabs map back to the
      // Tournaments sidebar entry — they're deeper views of the same category.
      return DesktopPane.tournaments;
    case TabKind.library:
    case TabKind.databaseWorkspace:
      return DesktopPane.library;
    case TabKind.favorites:
      return DesktopPane.favorites;
    case TabKind.players:
      return DesktopPane.players;
    case TabKind.calendar:
      return DesktopPane.calendar;
    case TabKind.countrymen:
      return DesktopPane.countrymen;
    case TabKind.settings:
      return DesktopPane.settings;
    case TabKind.watch:
      return null;
    case TabKind.openingExplorer:
      return DesktopPane.openingExplorer;
    case TabKind.boardEditor:
      return DesktopPane.boardEditor;
    case TabKind.play:
      return DesktopPane.play;
    case TabKind.playerScoreCard:
    case TabKind.playerProfile:
    case TabKind.userProfile:
      // Player tabs land under the Players sidebar category since that's
      // closest in spirit; keeps the sidebar highlight sensible while a
      // score card or profile is in the foreground.
      return DesktopPane.players;
    case TabKind.boardSettings:
    case TabKind.notificationSettings:
      // Both subscreens of the desktop preferences pane — keep the
      // Settings sidebar item highlighted while one is foregrounded.
      return DesktopPane.settings;
  }
}

/// Active pane derived from the foreground tab. Read-only — to *change* the
/// active pane, open or activate a tab via `desktopTabsProvider.notifier`.
/// Returns `DesktopPane.board` as a stable fallback when the foreground tab
/// is one of the kinds the sidebar doesn't represent.
final desktopPaneProvider = Provider<DesktopPane>((ref) {
  final kind = ref.watch(activeTabKindProvider);
  if (kind == null) return DesktopPane.board;
  return paneForTabKind(kind) ?? DesktopPane.board;
});
