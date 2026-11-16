import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart'
    show kBoardSplitCellMinSideBySideWidth, shouldStackBoardPane;
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

import 'support/desktop_premium_test_overrides.dart';

BoardSplitLayout _single(String id) => BoardSplitLayout.single(id);

void main() {
  group('BoardSplitLayout.place', () {
    test('the first split is a column beside the board', () {
      final right =
          _single('a').place(
            targetTabId: 'a',
            incomingTabId: 'b',
            zone: BoardSplitZone.right,
          )!;
      expect(right.columns, [
        ['a'],
        ['b'],
      ]);
      final left =
          _single('a').place(
            targetTabId: 'a',
            incomingTabId: 'b',
            zone: BoardSplitZone.left,
          )!;
      expect(left.columns, [
        ['b'],
        ['a'],
      ]);
    });

    test('each column then splits into two rows, four boards at most', () {
      var layout =
          _single('a').place(
            targetTabId: 'a',
            incomingTabId: 'b',
            zone: BoardSplitZone.right,
          )!;
      layout =
          layout.place(
            targetTabId: 'a',
            incomingTabId: 'c',
            zone: BoardSplitZone.bottom,
          )!;
      layout =
          layout.place(
            targetTabId: 'b',
            incomingTabId: 'd',
            zone: BoardSplitZone.top,
          )!;
      expect(layout.columns, [
        ['a', 'c'],
        ['d', 'b'],
      ]);
      expect(layout.cellCount, BoardSplitLayout.maxCells);
      // Full: only replacing a board is left.
      expect(layout.zonesFor('a'), {BoardSplitZone.replace});
      expect(
        layout.place(
          targetTabId: 'a',
          incomingTabId: 'e',
          zone: BoardSplitZone.left,
        ),
        isNull,
      );
      expect(
        layout.place(
          targetTabId: 'c',
          incomingTabId: 'e',
          zone: BoardSplitZone.bottom,
        ),
        isNull,
      );
    });

    test('a third column is never offered; a full column only offers '
        'the other edges', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'b'],
          ['c'],
        ],
      );
      expect(layout.zonesFor('a'), {BoardSplitZone.replace});
      expect(layout.zonesFor('c'), {
        BoardSplitZone.top,
        BoardSplitZone.bottom,
        BoardSplitZone.replace,
      });
    });

    test('replace swaps the dropped board in and leaves the old one out', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a'],
          ['b'],
        ],
      );
      final next =
          layout.place(
            targetTabId: 'b',
            incomingTabId: 'x',
            zone: BoardSplitZone.replace,
          )!;
      expect(next.columns, [
        ['a'],
        ['x'],
      ]);
      expect(next.contains('b'), isFalse);
    });

    test('a member dropped on another member swaps the two', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b'],
        ],
      );
      final next =
          layout.place(
            targetTabId: 'b',
            incomingTabId: 'a',
            zone: BoardSplitZone.replace,
          )!;
      expect(next.columns, [
        ['b', 'c'],
        ['a'],
      ]);
    });

    test('a member moved to an edge leaves its old place first', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a'],
          ['b'],
        ],
      );
      // From the right column to below the left board: one column of two.
      final next =
          layout.place(
            targetTabId: 'a',
            incomingTabId: 'b',
            zone: BoardSplitZone.bottom,
          )!;
      expect(next.columns, [
        ['a', 'b'],
      ]);
      expect(next.id, 'g');
    });

    test(
      'an unsplit board cannot be replaced by a tab, nor land on itself',
      () {
        expect(_single('a').zonesFor('a', incomingTabId: 'b'), {
          BoardSplitZone.left,
          BoardSplitZone.right,
          BoardSplitZone.top,
          BoardSplitZone.bottom,
        });
        expect(_single('a').zonesFor('a', incomingTabId: 'a'), isEmpty);
        // A dropped game may still open in place of an unsplit board.
        expect(_single('a').zonesFor('a'), contains(BoardSplitZone.replace));
      },
    );
  });

  group('BoardSplitLayout.without', () {
    test('closes up the gap and dissolves at one board', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b'],
        ],
        columnFraction: 0.7,
        rowFractions: [0.3, 0.5],
      );
      final noB = layout.without('b')!;
      expect(noB.columns, [
        ['a', 'c'],
      ]);
      expect(noB.rowFractions, [0.3]);
      final noC = layout.without('c')!;
      expect(noC.columns, [
        ['a'],
        ['b'],
      ]);
      expect(noC.columnFraction, 0.7);
      expect(noB.without('c'), isNull);
    });
  });

  group('geometry', () {
    test('an area thinner than the gutter never yields negative cells', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b'],
        ],
      );
      for (final size in const [Size(4, 4), Size(0, 600), Size(900, 6)]) {
        for (final rect in layout.cellRects(size).values) {
          expect(rect.width, greaterThanOrEqualTo(0), reason: '$size');
          expect(rect.height, greaterThanOrEqualTo(0), reason: '$size');
        }
      }
    });

    test('the cell to focus after a close stays inside the split', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b', 'd'],
        ],
      );
      final all = {'a', 'b', 'c', 'd'};
      expect(splitNeighbourAfterClose(layout, 'c', openTabIds: all), 'a');
      expect(
        splitNeighbourAfterClose(
          BoardSplitLayout(
            id: 'g',
            columns: [
              ['a'],
              ['b', 'd'],
            ],
          ),
          'a',
          openTabIds: all,
        ),
        'b',
      );
      expect(
        splitNeighbourAfterClose(layout, 'd', openTabIds: {'a', 'c'}),
        'c',
      );
    });

    const size = Size(1208, 808);

    test('cells share the area around an 8 px gutter', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b'],
        ],
      );
      final rects = layout.cellRects(size);
      expect(rects['a'], const Rect.fromLTRB(0, 0, 600, 400));
      expect(rects['c'], const Rect.fromLTRB(0, 408, 600, 808));
      expect(rects['b'], const Rect.fromLTRB(608, 0, 1208, 808));
      expect(
        layout.columnGutterRect(size),
        const Rect.fromLTRB(600, 0, 608, 808),
      );
      expect(
        layout.rowGutterRect(size, 0),
        const Rect.fromLTRB(0, 400, 600, 408),
      );
      expect(layout.rowGutterRect(size, 1), isNull);
    });

    test('a divider drag never leaves a cell below its minimum', () {
      final layout = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a'],
          ['b'],
        ],
      ).withColumnFraction(0.05);
      final rects = layout.cellRects(size);
      expect(rects['a']!.width, kBoardSplitMinCellWidth);
    });

    test('the preview marks where the dropped board will sit', () {
      final single = _single('a');
      expect(
        single.previewRect('a', BoardSplitZone.left, size),
        const Rect.fromLTWH(0, 0, 600, 808),
      );
      expect(
        single.previewRect('a', BoardSplitZone.bottom, size),
        const Rect.fromLTWH(0, 408, 1208, 400),
      );
      final split = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a'],
          ['b'],
        ],
      );
      expect(
        split.previewRect('b', BoardSplitZone.top, size),
        const Rect.fromLTRB(608, 0, 1208, 400),
      );
      // Moving b under a ends with one full-width column.
      expect(
        split.previewRect('a', BoardSplitZone.bottom, size, incomingTabId: 'b'),
        const Rect.fromLTWH(0, 408, 1208, 400),
      );
    });
  });

  group('resolveBoardSplitZone', () {
    const cell = Size(900, 600);
    const all = {
      BoardSplitZone.left,
      BoardSplitZone.right,
      BoardSplitZone.top,
      BoardSplitZone.bottom,
      BoardSplitZone.replace,
    };

    test('outer thirds split, the middle replaces', () {
      BoardSplitZone? at(double x, double y) => resolveBoardSplitZone(
        local: Offset(x, y),
        cellSize: cell,
        allowed: all,
      );
      expect(at(40, 300), BoardSplitZone.left);
      expect(at(860, 300), BoardSplitZone.right);
      expect(at(450, 30), BoardSplitZone.top);
      expect(at(450, 570), BoardSplitZone.bottom);
      expect(at(450, 300), BoardSplitZone.replace);
      // Corner: the closer edge wins.
      expect(at(20, 150), BoardSplitZone.left);
      expect(at(250, 20), BoardSplitZone.top);
    });

    test(
      'disallowed edges fall back to replace or the nearest allowed edge',
      () {
        expect(
          resolveBoardSplitZone(
            local: const Offset(40, 300),
            cellSize: cell,
            allowed: const {
              BoardSplitZone.top,
              BoardSplitZone.bottom,
              BoardSplitZone.replace,
            },
          ),
          BoardSplitZone.replace,
        );
        // A tab dropped mid-board where replacing is not allowed still lands.
        expect(
          resolveBoardSplitZone(
            local: const Offset(400, 300),
            cellSize: cell,
            allowed: const {BoardSplitZone.left, BoardSplitZone.right},
          ),
          BoardSplitZone.left,
        );
        expect(
          resolveBoardSplitZone(
            local: const Offset(40, 300),
            cellSize: cell,
            allowed: const {},
          ),
          isNull,
        );
      },
    );
  });

  group('besideBoardPlacement', () {
    test('right first, then below, then under the other column', () {
      expect(besideBoardPlacement(_single('a'), 'a'), (
        targetTabId: 'a',
        zone: BoardSplitZone.right,
      ));
      final two = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a'],
          ['b'],
        ],
      );
      expect(besideBoardPlacement(two, 'a'), (
        targetTabId: 'a',
        zone: BoardSplitZone.bottom,
      ));
      final three = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b'],
        ],
      );
      expect(besideBoardPlacement(three, 'a'), (
        targetTabId: 'b',
        zone: BoardSplitZone.bottom,
      ));
      final four = BoardSplitLayout(
        id: 'g',
        columns: [
          ['a', 'c'],
          ['b', 'd'],
        ],
      );
      expect(besideBoardPlacement(four, 'a'), isNull);
    });
  });

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
        split.place(
          targetTabId: a,
          incomingTabId: b,
          zone: BoardSplitZone.right,
        );
        split.place(
          targetTabId: b,
          incomingTabId: c,
          zone: BoardSplitZone.bottom,
        );
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
            .place(
              targetTabId: x,
              incomingTabId: y,
              zone: BoardSplitZone.right,
            );
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
      split.place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
      split.place(
        targetTabId: b,
        incomingTabId: c,
        zone: BoardSplitZone.bottom,
      );
      // History says Library came last before c; c is focused.
      tabs.activate(other);
      tabs.activate(c);
      tabs.close(c);
      await Future<void>.delayed(Duration.zero);
      // c's column neighbour, not the Library tab.
      expect(container.read(desktopTabsProvider).activeId, b);
      expect(container.read(visibleBoardSplitProvider)!.columns, [
        [a],
        [b],
      ]);
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
          .place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
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
      split.place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
      // Replace both boards: the group now holds c and d.
      split.place(
        targetTabId: a,
        incomingTabId: c,
        zone: BoardSplitZone.replace,
      );
      split.place(
        targetTabId: b,
        incomingTabId: d,
        zone: BoardSplitZone.replace,
      );
      // a and b form a second split of their own.
      split.place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
      var state = container.read(boardSplitProvider);
      expect(state.groups, hasLength(2));
      expect(state.groupOf(a)!.id, isNot(state.groupOf(c)!.id));
      // Taking c out dissolves only its own split.
      split.remove(c);
      state = container.read(boardSplitProvider);
      expect(state.groupOf(a)!.columns, [
        [a],
        [b],
      ]);
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

      expect(
        split.place(
          targetTabId: a,
          incomingTabId: b,
          zone: BoardSplitZone.right,
        ),
        isTrue,
      );
      expect(
        split.place(
          targetTabId: c,
          incomingTabId: d,
          zone: BoardSplitZone.left,
        ),
        isTrue,
      );
      expect(container.read(boardSplitProvider).groups, hasLength(2));
      // b moves to c's group; a is left alone and its group dissolves.
      split.place(targetTabId: c, incomingTabId: b, zone: BoardSplitZone.top);
      final state = container.read(boardSplitProvider);
      expect(state.groups, hasLength(1));
      expect(state.groupOf(a), isNull);
      expect(state.groupOf(c)!.columns, [
        [d],
        [b, c],
      ]);

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

  group('shouldStackBoardPane', () {
    test('a full-size board stacks only below 660 px', () {
      expect(
        shouldStackBoardPane(width: 659, height: 300, inSplitCell: false),
        isTrue,
      );
      expect(
        shouldStackBoardPane(width: 700, height: 2000, inSplitCell: false),
        isFalse,
      );
    });

    test('a split cell follows its shape', () {
      // A short, wide quarter keeps the board beside its notation.
      expect(
        shouldStackBoardPane(width: 600, height: 380, inSplitCell: true),
        isFalse,
      );
      // A tall half column stacks.
      expect(
        shouldStackBoardPane(width: 600, height: 780, inSplitCell: true),
        isTrue,
      );
      expect(
        shouldStackBoardPane(
          width: kBoardSplitCellMinSideBySideWidth - 1,
          height: 200,
          inSplitCell: true,
        ),
        isTrue,
      );
      expect(
        shouldStackBoardPane(width: 900, height: 2000, inSplitCell: true),
        isFalse,
      );
    });
  });
}
