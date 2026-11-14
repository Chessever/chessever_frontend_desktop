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

  test('discovery destinations are hidden only from the sidebar', () {
    for (final name in ['Countrymen', 'Favorites', 'Collections', 'Rankings']) {
      expect(debugDesktopSidebarLabelsInOrder(), isNot(contains(name)));
      expect(debugDesktopSidebarPaneForLabel(name), isNull);
      expect(desktopMainRoutes.map((route) => route.label), contains(name));
      expect(debugDesktopSidebarShortcutForLabel(name, isMacOS: false), isNull);
    }
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
    const labels = ['Home', 'Library', 'Prepare', 'Board', 'Play'];
    expect(
      debugDesktopSidebarLabelsInOrder().skip(1).take(labels.length),
      labels,
    );
    for (var index = 0; index < labels.length; index++) {
      final digit = (index + 1) % 10;
      expect(
        debugDesktopSidebarShortcutForLabel(labels[index], isMacOS: false),
        'Ctrl+$digit',
      );
      expect(
        debugDesktopSidebarShortcutForLabel(labels[index], isMacOS: true),
        '⌘$digit',
      );
    }
  });

  test('Prepare follows Library after discovery shortcuts move to cards', () {
    final labels = debugDesktopSidebarLabelsInOrder();
    expect(labels[labels.indexOf('Library') + 1], 'Prepare');
    expect(
      debugDesktopSidebarShortcutForLabel('Prepare', isMacOS: false),
      'Ctrl+3',
    );
    expect(debugDesktopSidebarShortcutForLabel('Prepare', isMacOS: true), '⌘3');
  });

  test('hidden collection tabs retain their existing pane mapping', () {
    expect(
      sidebarPaneForActiveTabKind(TabKind.collections),
      DesktopPane.collections,
    );
    expect(
      sidebarPaneForActiveTabKind(TabKind.collectionWorkspace),
      DesktopPane.collections,
    );
  });

  test('numbered route bindings match the visible sidebar labels', () {
    final bindings = desktopMainRouteShortcutBindings().toList();

    expect(bindings.map((binding) => binding.pane), [
      DesktopPane.tournaments,
      DesktopPane.library,

      DesktopPane.players,

      DesktopPane.board,
      DesktopPane.play,
    ]);
    expect(bindings.map((binding) => binding.key), [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ]);
    for (var index = 0; index < bindings.length; index++) {
      final label = debugDesktopSidebarLabelsInOrder()[index + 1];
      expect(bindings[index].pane, debugDesktopSidebarPaneForLabel(label));
    }
  });

  test('Board Editor is launched from board context, not the sidebar', () {
    expect(debugDesktopSidebarPaneForLabel('Board Editor'), isNull);
  });
  test('Search appears first above Home', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels.first, 'Search');
    expect(labels[1], 'Home');
  });

  test('How to use and Feedback remain below primary navigation', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Play') + 1], 'How to use');
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
