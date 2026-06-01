import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_pane_navigation.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

void main() {
  group('openDesktopPaneFromContainer', () {
    test('opens Favorites in another tab when a game Board tab is active', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final boardId = openBoardGameTabFromContainer(
        container,
        _args('game-1'),
        reuseExisting: false,
      );

      openDesktopPaneFromContainer(container, DesktopPane.favorites);

      final tabs = container.read(desktopTabsProvider);
      final argsByTab = container.read(boardTabGameArgsByTabIdProvider);

      expect(tabs.activeId, isNot(boardId));
      expect(tabs.active?.kind, TabKind.favorites);
      expect(tabs.tabs.firstWhere((t) => t.id == boardId).kind, TabKind.board);
      expect(argsByTab[boardId]?.gameId, 'game-1');
    });

    test('reuses an existing Favorites tab instead of duplicating it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final tabsNotifier = container.read(desktopTabsProvider.notifier);
      final favoritesId = tabsNotifier.open(
        TabKind.favorites,
        reuseExisting: false,
      );
      final boardId = openBoardGameTabFromContainer(
        container,
        _args('game-1'),
        reuseExisting: false,
      );

      openDesktopPaneFromContainer(container, DesktopPane.favorites);

      final tabs = container.read(desktopTabsProvider);

      expect(tabs.activeId, favoritesId);
      expect(tabs.tabs.firstWhere((t) => t.id == boardId).kind, TabKind.board);
      expect(tabs.tabs.where((t) => t.kind == TabKind.favorites), hasLength(1));
    });

    test('keeps normal in-place navigation for scratch Board tabs', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final tabsNotifier = container.read(desktopTabsProvider.notifier);
      final scratchBoardId = tabsNotifier.open(
        TabKind.board,
        reuseExisting: false,
      );

      openDesktopPaneFromContainer(container, DesktopPane.favorites);

      final tabs = container.read(desktopTabsProvider);

      expect(tabs.activeId, scratchBoardId);
      expect(tabs.active?.kind, TabKind.favorites);
    });
  });
}

BoardTabGameArgs _args(String gameId) {
  return BoardTabGameArgs(
    gameId: gameId,
    pgn: '1. e4 e5 *',
    label: 'White vs Black',
    whiteName: 'White',
    blackName: 'Black',
  );
}
