import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

void main() {
  test('empty workspace has no selected sidebar pane', () {
    expect(sidebarPaneForActiveTabKind(null), isNull);
  });

  test('board tab selects the Board sidebar pane', () {
    expect(sidebarPaneForActiveTabKind(TabKind.board), DesktopPane.board);
  });

  test('opened game Board tab leaves the sidebar unselected', () {
    const tab = DesktopTab(
      id: 'database-game-tab',
      kind: TabKind.board,
      title: 'Jing - Zhou',
    );
    final args = BoardTabGameArgs(
      pgn: '1. d4 Nf6 *',
      label: 'Jing - Zhou',
      whiteName: 'Jing, Andrew',
      blackName: 'Zhou, Jianchao',
      databaseTitle: 'safs',
      databaseGames: const [],
    );

    expect(
      sidebarPaneForActiveTab(
        tab,
        boardArgsByTabId: {'database-game-tab': args},
      ),
      isNull,
    );
  });

  test('scratch Board tab still selects the Board sidebar pane', () {
    const tab = DesktopTab(
      id: 'scratch-board-tab',
      kind: TabKind.board,
      title: 'Board',
    );

    expect(sidebarPaneForActiveTab(tab), DesktopPane.board);
  });

  test('Board sidebar entry opens the regular board pane', () {
    expect(debugDesktopSidebarPaneForLabel('Board'), DesktopPane.board);
  });

  test('Prepare sidebar entry opens the player preparation workspace', () {
    expect(debugDesktopSidebarPaneForLabel('Prepare'), DesktopPane.players);
  });

  test('Rankings sidebar entry keeps the old player index route', () {
    expect(debugDesktopSidebarPaneForLabel('Rankings'), DesktopPane.rankings);
  });

  test('player detail tabs leave Prepare available in the sidebar', () {
    expect(sidebarPaneForActiveTabKind(TabKind.playerProfile), isNull);
    expect(sidebarPaneForActiveTabKind(TabKind.playerScoreCard), isNull);
    expect(sidebarPaneForActiveTabKind(TabKind.userProfile), isNull);
  });

  test('Rankings tab highlights Rankings', () {
    expect(sidebarPaneForActiveTabKind(TabKind.rankings), DesktopPane.rankings);
  });

  test('primary sidebar route shortcuts follow the visual route order', () {
    expect(
      debugDesktopSidebarShortcutForLabel('Events', isMacOS: false),
      'Ctrl+1',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Library', isMacOS: false),
      'Ctrl+2',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Favorites', isMacOS: false),
      'Ctrl+3',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Prepare', isMacOS: false),
      'Ctrl+4',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Rankings', isMacOS: false),
      'Ctrl+5',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Calendar', isMacOS: false),
      'Ctrl+6',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Countrymen', isMacOS: false),
      'Ctrl+7',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Board', isMacOS: false),
      'Ctrl+8',
    );
    expect(
      debugDesktopSidebarShortcutForLabel('Play', isMacOS: false),
      'Ctrl+9',
    );
  });

  test('numbered route bindings include Rankings and shift later routes', () {
    final bindings = desktopMainRouteShortcutBindings().toList();

    expect(bindings.map((binding) => binding.pane), [
      DesktopPane.tournaments,
      DesktopPane.library,
      DesktopPane.favorites,
      DesktopPane.players,
      DesktopPane.rankings,
      DesktopPane.calendar,
      DesktopPane.countrymen,
      DesktopPane.board,
      DesktopPane.play,
    ]);
    expect(bindings.map((binding) => binding.key), [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ]);
  });

  test('Board Editor is launched from board context, not the sidebar', () {
    expect(debugDesktopSidebarPaneForLabel('Board Editor'), isNull);
  });
  test('Search appears directly under Play', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Play') + 1], 'Search');
  });

  test('How to use and Feedback appear directly under Search', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Search') + 1], 'How to use');
    expect(labels[labels.indexOf('How to use') + 1], 'Feedback');
    expect(labels, isNot(contains('Feedback / Report issue')));
    expect(labels, isNot(contains('Tournaments')));
  });

  test('Search entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Search'), isNull);
  });

  test('Feedback entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Feedback'), isNull);
  });

  test('How to use entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('How to use'), isNull);
  });
}
