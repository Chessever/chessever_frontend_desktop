import 'package:flutter_test/flutter_test.dart';

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

  test('database game Board tab keeps Library highlighted', () {
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
      DesktopPane.library,
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

  test('Board Editor is launched from board context, not the sidebar', () {
    expect(debugDesktopSidebarPaneForLabel('Board Editor'), isNull);
  });
  test('Search appears directly under Play', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Play') + 1], 'Search');
  });

  test('Feedback report entry appears directly under Search', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Search') + 1], 'Feedback / Report issue');
  });

  test('Search entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Search'), isNull);
  });

  test('Feedback report entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Feedback / Report issue'), isNull);
  });
}
