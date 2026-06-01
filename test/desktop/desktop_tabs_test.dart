import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

void main() {
  group('DesktopTabsNotifier', () {
    test('starts on the Tournaments tab', () {
      final tabs = DesktopTabsNotifier();

      expect(tabs.state.tabs, hasLength(1));
      expect(tabs.state.activeId, 'tournaments-default');
      expect(tabs.state.active?.kind, TabKind.tournaments);
      expect(tabs.state.active?.title, 'Tournaments');
    });

    test('opens background tabs without changing the active tab', () {
      final tabs = DesktopTabsNotifier();

      final first = tabs.state.activeId;
      final background = tabs.open(
        TabKind.board,
        reuseExisting: false,
        focus: false,
      );

      expect(tabs.state.activeId, first);
      expect(tabs.state.tabs.map((t) => t.id), contains(background));
    });

    test('switches tabs by Chrome-style index and last-tab shortcuts', () {
      final tabs = DesktopTabsNotifier();
      final board = tabs.open(TabKind.board, reuseExisting: false);
      final library = tabs.open(TabKind.library, reuseExisting: false);
      final players = tabs.open(TabKind.players, reuseExisting: false);

      tabs.activateAt(1);
      expect(tabs.state.activeId, board);

      tabs.activateLast();
      expect(tabs.state.activeId, players);

      tabs.activateAt(2);
      expect(tabs.state.activeId, library);
    });

    test('cycles next and previous with wraparound', () {
      final tabs = DesktopTabsNotifier();
      tabs.open(TabKind.board, reuseExisting: false);
      final library = tabs.open(TabKind.library, reuseExisting: false);

      expect(tabs.state.activeId, library);

      tabs.activateNext();
      expect(tabs.state.activeId, tabs.state.tabs.first.id);

      tabs.activatePrevious();
      expect(tabs.state.activeId, library);
    });

    test('closing the active tab activates the right neighbor first', () {
      final tabs = DesktopTabsNotifier();
      final board = tabs.open(TabKind.board, reuseExisting: false);
      final library = tabs.open(TabKind.library, reuseExisting: false);
      final players = tabs.open(TabKind.players, reuseExisting: false);

      tabs.activate(board);
      tabs.close(board);
      expect(tabs.state.activeId, library);

      tabs.close(players);
      expect(tabs.state.activeId, library);
    });

    test('keeps independent route history per tab', () {
      final tabs = DesktopTabsNotifier();

      tabs.navigateActive(TabKind.library);
      tabs.navigateActive(TabKind.players);
      final firstTab = tabs.state.activeId!;
      final secondTab = tabs.open(TabKind.calendar, reuseExisting: false);
      tabs.navigateActive(TabKind.countrymen);

      tabs.activate(firstTab);
      expect(tabs.state.active?.kind, TabKind.players);
      expect(tabs.state.canGoBack, isTrue);
      expect(tabs.state.canGoForward, isFalse);

      tabs.goBack();
      expect(tabs.state.active?.kind, TabKind.library);
      expect(tabs.state.canGoForward, isTrue);

      tabs.activate(secondTab);
      expect(tabs.state.active?.kind, TabKind.countrymen);
      tabs.goBack();
      expect(tabs.state.active?.kind, TabKind.calendar);
    });

    test('route back and forward preserve browser stack semantics', () {
      final tabs = DesktopTabsNotifier();

      tabs.navigateActive(TabKind.library);
      tabs.navigateActive(TabKind.players);
      tabs.navigateActive(TabKind.calendar);

      tabs.goBack();
      expect(tabs.state.active?.kind, TabKind.players);
      expect(tabs.state.canGoBack, isTrue);
      expect(tabs.state.canGoForward, isTrue);

      tabs.goBack();
      expect(tabs.state.active?.kind, TabKind.library);
      expect(tabs.state.canGoBack, isTrue);

      tabs.goForward();
      expect(tabs.state.active?.kind, TabKind.players);

      tabs.navigateActive(TabKind.favorites);
      expect(tabs.state.active?.kind, TabKind.favorites);
      expect(tabs.state.canGoForward, isFalse);
    });

    test('route history is bounded for long-running tabs', () {
      final tabs = DesktopTabsNotifier();

      for (var i = 0; i < 60; i++) {
        tabs.navigateActive(i.isEven ? TabKind.library : TabKind.players);
      }

      expect(tabs.state.active?.backHistory.length, 50);
    });

    test('reorders using ReorderableListView indexes', () {
      final tabs = DesktopTabsNotifier();
      final board = tabs.open(TabKind.board, reuseExisting: false);
      final library = tabs.open(TabKind.library, reuseExisting: false);
      final players = tabs.open(TabKind.players, reuseExisting: false);

      // ReorderableListView.onReorder reports the destination before the old
      // item is removed, so moving board after library reports 3.
      tabs.reorder(1, 3);
      expect(tabs.state.tabs.map((t) => t.id), [
        'tournaments-default',
        library,
        board,
        players,
      ]);

      tabs.reorder(3, 1);
      expect(tabs.state.tabs.map((t) => t.id), [
        'tournaments-default',
        players,
        library,
        board,
      ]);
    });

    test('opens database workspace tabs as separate database routes', () {
      final tabs = DesktopTabsNotifier();

      final first = tabs.open(
        TabKind.databaseWorkspace,
        title: 'TWIC',
        reuseExisting: false,
      );
      final second = tabs.open(
        TabKind.databaseWorkspace,
        title: 'Rep-Ruben.pgn',
        reuseExisting: false,
      );

      expect(first, isNot(second));
      expect(tabs.state.activeId, second);
      expect(
        tabs.state.tabs.where((t) => t.kind == TabKind.databaseWorkspace),
        hasLength(2),
      );
      expect(tabs.state.active?.title, 'Rep-Ruben.pgn');
    });
    test(
      'container helper reuses an existing local database workspace tab',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final first = openDatabaseWorkspaceTabForContainer(
          container,
          const DatabaseWorkspaceArgs.local(
            localPath: '/tmp/repertoire.pgn',
            title: 'repertoire.pgn',
          ),
        );
        final second = openDatabaseWorkspaceTabForContainer(
          container,
          const DatabaseWorkspaceArgs.local(
            localPath: '/tmp/repertoire.pgn',
            title: 'repertoire.pgn',
          ),
        );

        final tabs = container.read(desktopTabsProvider);
        expect(second, first);
        expect(tabs.activeId, first);
        expect(
          tabs.tabs.where((tab) => tab.kind == TabKind.databaseWorkspace),
          hasLength(1),
        );
        expect(
          container
              .read(databaseWorkspaceArgsByTabIdProvider)[first]
              ?.localPath,
          '/tmp/repertoire.pgn',
        );
      },
    );
  });
}
