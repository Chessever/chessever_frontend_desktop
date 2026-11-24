import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart'
    show shouldStackBoardPane;
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

import 'support/desktop_premium_test_overrides.dart';

void main() {
  test(
    'Round Wall keeps the main board and admits up to nine distinct watches',
    () {
      final split = BoardSplitNotifier();
      addTearDown(split.dispose);
      for (var i = 1; i <= 9; i++) {
        expect(
          split.watch(targetTabId: 'main', incomingTabId: 'board-$i'),
          isTrue,
        );
      }
      final wall = split.layoutFor('main');
      expect(wall.mainTabId, 'main');
      expect(
        wall.watchedTabIds,
        List.generate(9, (index) => 'board-${index + 1}'),
      );
      expect(
        split.watch(targetTabId: 'main', incomingTabId: 'another'),
        isFalse,
      );
      expect(
        split.watch(targetTabId: 'main', incomingTabId: 'board-1'),
        isFalse,
      );
      split.promote('board-2');
      expect(split.layoutFor('board-2').mainTabId, 'board-2');
      expect(split.layoutFor('board-2').watchedTabIds.take(3), [
        'board-1',
        'main',
        'board-3',
      ]);
      expect(split.layoutFor('board-2').id, wall.id);
      split.remove('main');
      expect(split.current.groupOf('main'), isNull);
      expect(split.layoutFor('board-2').watchedTabIds, hasLength(8));
    },
  );

  group('boardSplitProvider', () {
    group('closing the focused board keeps tab history', () {
      late ProviderContainer container;
      late DesktopTabsNotifier tabs;
      late String other, a, b, c;
      setUp(() {
        container = ProviderContainer(overrides: desktopPremiumTestOverrides);
        tabs = container.read(desktopTabsProvider.notifier);
        other = tabs.open(TabKind.library);
        a = tabs.open(TabKind.board, reuseExisting: false);
        b = tabs.open(TabKind.board, reuseExisting: false);
        c = tabs.open(TabKind.board, reuseExisting: false);
        final split = container.read(boardSplitProvider.notifier);
        split.watch(targetTabId: a, incomingTabId: b);
        split.watch(targetTabId: b, incomingTabId: c);
      });
      tearDown(() {
        container.dispose();
      });

      test('when history already picks a board of the split', () async {
        tabs.activate(a);
        tabs.activate(c);
        tabs.close(c);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(desktopTabsProvider).activeId, a);
      });

      test('for close to the right, which names its tab', () async {
        // Strip order [x, pivot, y] with x and y split, y focused.
        final local = ProviderContainer(overrides: desktopPremiumTestOverrides);
        addTearDown(local.dispose);
        final strip = local.read(desktopTabsProvider.notifier);
        final x = strip.open(TabKind.board, reuseExisting: false);
        final pivot = strip.open(TabKind.library);
        final y = strip.open(TabKind.board, reuseExisting: false);
        local
            .read(boardSplitProvider.notifier)
            .watch(targetTabId: x, incomingTabId: y);
        strip.activate(y);
        strip.closeToTheRight(pivot);
        await Future<void>.delayed(Duration.zero);
        expect(local.read(desktopTabsProvider).activeId, pivot);
      });

      test('the press mark lapses once the tab is left open', () async {
        tabs.activate(other);
        tabs.activate(c);
        container.read(boardSplitProvider.notifier).keepHistoryOnClose(c);
        // The close was cancelled; the user moved on and came back later.
        tabs.activate(b);
        tabs.activate(other);
        tabs.activate(c);
        tabs.close(c);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(desktopTabsProvider).activeId, b);
      });

      test('in focus mode, where the split is not shown', () async {
        container.read(boardFocusModeProvider.notifier).state = true;
        tabs.activate(other);
        tabs.activate(c);
        tabs.close(c);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(desktopTabsProvider).activeId, other);
      });

      test('when the same press selected and closed the tab', () async {
        tabs.activate(other);
        // The strip marks a close from the button of a tab its press
        // selected.
        tabs.activate(c);
        container.read(boardSplitProvider.notifier).keepHistoryOnClose(c);
        tabs.close(c);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(desktopTabsProvider).activeId, other);
      });
    });

    test('closing the focused board focuses the cell beside it', () async {
      final container = ProviderContainer(
        overrides: desktopPremiumTestOverrides,
      );
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      String board() => tabs.open(TabKind.board, reuseExisting: false);
      final other = tabs.open(TabKind.library);
      final a = board(), b = board(), c = board();
      final split = container.read(boardSplitProvider.notifier);
      split.watch(targetTabId: a, incomingTabId: b);
      split.watch(targetTabId: b, incomingTabId: c);
      // History says Library came last before c; c is focused.
      tabs.activate(other);
      tabs.activate(c);
      tabs.close(c);
      await Future<void>.delayed(Duration.zero);
      // c's column neighbour, not the Library tab.
      expect(container.read(desktopTabsProvider).activeId, b);
      expect(container.read(visibleBoardSplitProvider)!.tabIds, [b, a]);
    });

    test('a press on another tab keeps the board on screen until it ends', () {
      final container = ProviderContainer(
        overrides: desktopPremiumTestOverrides,
      );
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      final a = tabs.open(TabKind.board, reuseExisting: false);
      final b = tabs.open(TabKind.board, reuseExisting: false);
      final c = tabs.open(TabKind.board, reuseExisting: false);
      container
          .read(boardSplitProvider.notifier)
          .watch(targetTabId: a, incomingTabId: b);
      tabs.activate(a);
      // Press on c: it is selected at once, the split stays held.
      container.read(boardPressHeldTabProvider.notifier).state = a;
      tabs.activate(c);
      expect(container.read(boardTabOnScreenProvider(a)), isTrue);
      expect(container.read(boardTabOnScreenProvider(b)), isTrue);
      container.read(boardPressHeldTabProvider.notifier).state = null;
      expect(container.read(boardTabOnScreenProvider(a)), isFalse);
      expect(container.read(boardTabOnScreenProvider(b)), isFalse);
    });

    test('each split keeps its own id after its boards change', () {
      final container = ProviderContainer(
        overrides: desktopPremiumTestOverrides,
      );
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      String board() => tabs.open(TabKind.board, reuseExisting: false);
      final a = board(), b = board(), c = board(), d = board();
      final split = container.read(boardSplitProvider.notifier);
      split.watch(targetTabId: a, incomingTabId: b);
      split.watch(targetTabId: c, incomingTabId: d);
      split.promote(d);
      var state = container.read(boardSplitProvider);
      expect(state.groups, hasLength(2));
      expect(state.groupOf(a)!.id, isNot(state.groupOf(c)!.id));
      // Taking c out dissolves only its own split.
      split.remove(c);
      state = container.read(boardSplitProvider);
      expect(state.groupOf(a)!.tabIds, [a, b]);
      expect(state.groupOf(d), isNull);
    });

    test('a tab joins one group at a time and closed tabs leave it', () {
      final container = ProviderContainer(
        overrides: desktopPremiumTestOverrides,
      );
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      final a = tabs.open(TabKind.board, reuseExisting: false);
      final b = tabs.open(TabKind.board, reuseExisting: false);
      final c = tabs.open(TabKind.board, reuseExisting: false);
      final d = tabs.open(TabKind.board, reuseExisting: false);
      final split = container.read(boardSplitProvider.notifier);

      expect(split.watch(targetTabId: a, incomingTabId: b), isTrue);
      expect(split.watch(targetTabId: c, incomingTabId: d), isTrue);
      expect(container.read(boardSplitProvider).groups, hasLength(2));
      // b moves to c's group; a is left alone and its group dissolves.
      split.watch(targetTabId: c, incomingTabId: b);
      final state = container.read(boardSplitProvider);
      expect(state.groups, hasLength(1));
      expect(state.groupOf(a), isNull);
      expect(state.groupOf(c)!.tabIds, [c, d, b]);

      tabs.activate(c);
      expect(container.read(visibleBoardSplitProvider)?.contains(d), isTrue);
      expect(container.read(boardTabOnScreenProvider(d)), isTrue);
      expect(container.read(boardTabOnScreenProvider(a)), isFalse);

      // Focus mode shows the focused board alone.
      container.read(boardFocusModeProvider.notifier).state = true;
      expect(container.read(visibleBoardSplitProvider), isNull);
      expect(container.read(boardTabOnScreenProvider(d)), isFalse);
      container.read(boardFocusModeProvider.notifier).state = false;

      tabs.close(d);
      tabs.close(b);
      expect(container.read(boardSplitProvider).groups, isEmpty);
    });
  });

  test('a standalone board stacks only below 660 px', () {
    expect(shouldStackBoardPane(659), isTrue);
    expect(shouldStackBoardPane(660), isFalse);
  });
}
