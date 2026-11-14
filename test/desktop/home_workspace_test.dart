import 'package:chessever/desktop/services/desktop_how_to_use_onboarding.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'tab cycling from Home resumes real work without creating a Home tab',
    () {
      final tabs = DesktopTabsNotifier();
      addTearDown(tabs.dispose);
      final first = tabs.open(TabKind.library);
      final last = tabs.open(TabKind.board);
      tabs.showHome();
      tabs.activateNext();
      expect(tabs.state.activeId, first);
      tabs.showHome();
      tabs.activatePrevious();
      expect(tabs.state.activeId, last);
    },
  );
  test('Search is first and Home is the primary workspace action', () {
    expect(debugDesktopSidebarLabelsInOrder().take(2), ['Search', 'Home']);
  });
  test('disabled Calendar cannot be opened or reached through commands', () {
    final tabs = DesktopTabsNotifier();
    addTearDown(tabs.dispose);
    final library = tabs.open(TabKind.library);
    tabs.open(TabKind.calendar);
    expect(tabs.state.active?.kind, TabKind.tournaments);
    expect(tabs.state.tabs.map((tab) => tab.id), [library]);
    expect(
      desktopMainRoutes.where((route) => route.label == 'Calendar'),
      isEmpty,
    );
  });

  test('help is never automatic after install or update', () {
    expect(
      shouldOpenDesktopHowToUse(
        currentVersion: '22.30.8',
        dismissedVersion: null,
      ),
      isFalse,
    );
  });
  test(
    'Home is a tabless landing view and preserves open workspace identities',
    () {
      final tabs = DesktopTabsNotifier();
      addTearDown(tabs.dispose);
      expect(tabs.state.tabs, isEmpty);
      expect(tabs.state.active?.title, 'Home');
      final home = tabs.state.activeId!;
      final library = tabs.open(TabKind.library);
      final board = tabs.open(TabKind.board);
      final before = tabs.state.tabs;
      tabs.open(TabKind.tournaments);
      expect(tabs.state.activeId, home);
      expect(tabs.state.tabs, same(before));
      expect(tabs.state.tabs.map((tab) => tab.id), [library, board]);
      tabs.activate(board);
      expect(tabs.state.activeId, board);
      tabs.close(board);
      tabs.close(library);
      expect(tabs.state.tabs, isEmpty);
      expect(tabs.state.activeId, home);
      expect(tabs.state.active?.title, 'Home');
    },
  );
}
