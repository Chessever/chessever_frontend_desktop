import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/board_split_workspace.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/game_drag_source.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';

const _workspaceKey = ValueKey('workspace');

/// A workspace 1208 x 808 wide beside a 200 px column of draggable rows.
Widget _harness(
  ProviderContainer container, {
  List<Widget> sources = const <Widget>[],
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 200, child: Column(children: sources)),
            SizedBox(
              key: _workspaceKey,
              width: 1208,
              child: Consumer(
                builder: (context, ref, _) {
                  final tabs = ref.watch(desktopTabsProvider);
                  return BoardSplitDropLayer(
                    child: DesktopWorkspaceStack(
                      tabs: tabs.tabs,
                      activeId: tabs.activeId,
                      feedbackScreenshotKey: GlobalKey(),
                      split: ref.watch(visibleBoardSplitProvider),
                      onActivateCell:
                          ref.read(desktopTabsProvider.notifier).activate,
                      contentBuilder:
                          (tab) => TextField(key: ValueKey('editor:${tab.id}')),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void _sizeWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1408, 808);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _editor(String tabId) =>
    find.byKey(ValueKey('editor:$tabId'), skipOffstage: false);

void main() {
  testWidgets('entering and leaving a split keeps every board mounted', (
    tester,
  ) async {
    _sizeWindow(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final a = tabs.open(TabKind.board, reuseExisting: false);
    final b = tabs.open(TabKind.board, reuseExisting: false, focus: false);
    await tester.pumpWidget(_harness(container));

    await tester.enterText(_editor(a), 'analysis in progress');
    final aElement = tester.element(_editor(a));
    final bElement = tester.element(_editor(b));
    expect(find.byKey(ValueKey('editor:$b')), findsNothing);

    container
        .read(boardSplitProvider.notifier)
        .place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
    await tester.pump();

    // Both boards are on screen, each below its header, same elements.
    expect(tester.element(_editor(a)), same(aElement));
    expect(tester.element(_editor(b)), same(bElement));
    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    expect(
      tester.getRect(find.byKey(ValueKey('editor:$a'))),
      Rect.fromLTWH(
        origin.dx,
        origin.dy + kBoardSplitCellHeaderHeight,
        600,
        808 - kBoardSplitCellHeaderHeight,
      ),
    );
    expect(
      tester.getRect(find.byKey(ValueKey('editor:$b'))).left,
      origin.dx + 608,
    );
    expect(find.text('analysis in progress'), findsOneWidget);
    expect(find.byType(BoardSplitCellHeader), findsNWidgets(2));

    // A press in the other cell gives it the keyboard.
    await tester.tapAt(
      tester.getCenter(find.byKey(ValueKey('editor:$b'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(container.read(desktopTabsProvider).activeId, b);

    // Closing one board dissolves the split; the other keeps its state.
    tabs.close(b);
    await tester.pump();
    expect(container.read(boardSplitProvider).groups, isEmpty);
    expect(tester.element(_editor(a)), same(aElement));
    expect(find.byType(BoardSplitCellHeader), findsNothing);
    expect(
      tester.getSize(find.byKey(ValueKey('editor:$a'))),
      const Size(1208, 808),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a game row dropped on the right third opens beside the board', (
    tester,
  ) async {
    _sizeWindow(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final a = tabs.open(TabKind.board, reuseExisting: false);
    var spawned = 0;
    final payload = GameTabDragPayload(
      id: 'g1',
      label: 'Carlsen vs Nepomniachtchi',
      spawn: (ref, {required focus}) async {
        spawned++;
        expect(focus, isFalse);
        ref
            .read(desktopTabsProvider.notifier)
            .open(TabKind.board, reuseExisting: false, focus: focus);
      },
    );
    await tester.pumpWidget(
      _harness(
        container,
        sources: [
          GameDragSource(
            payload: payload,
            child: const SizedBox(
              key: ValueKey('row'),
              height: 40,
              width: 200,
              child: Text('Carlsen vs Nepomniachtchi'),
            ),
          ),
        ],
      ),
    );

    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('row'))),
      kind: PointerDeviceKind.mouse,
    );
    // A little jitter is still a click, not a drag.
    await gesture.moveBy(const Offset(3, 2));
    await tester.pump();
    expect(find.byType(GameDragChip), findsNothing);

    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(find.byType(GameDragChip), findsOneWidget);

    await gesture.moveTo(origin + const Offset(1060, 380));
    await tester.pump();
    // The drop arms once the pointer has moved on from where it came in.
    expect(find.text('Split right'), findsNothing);
    await gesture.moveTo(origin + const Offset(1120, 410));
    await tester.pump();
    expect(find.text('Split right'), findsOneWidget);

    await gesture.moveTo(origin + const Offset(600, 400));
    await tester.pump();
    expect(find.text('Open here'), findsOneWidget);

    await gesture.moveTo(origin + const Offset(1120, 410));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(spawned, 1);
    final split = container.read(visibleBoardSplitProvider);
    expect(split, isNotNull);
    expect(split!.columns.first, [a]);
    final opened = split.columns.last.single;
    expect(container.read(desktopTabsProvider).activeId, opened);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Split right'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full split only offers to replace a board', (tester) async {
    _sizeWindow(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final ids = [
      for (var i = 0; i < 4; i++)
        tabs.open(TabKind.board, reuseExisting: false),
    ];
    final split = container.read(boardSplitProvider.notifier);
    split.place(
      targetTabId: ids[0],
      incomingTabId: ids[1],
      zone: BoardSplitZone.right,
    );
    split.place(
      targetTabId: ids[0],
      incomingTabId: ids[2],
      zone: BoardSplitZone.bottom,
    );
    split.place(
      targetTabId: ids[1],
      incomingTabId: ids[3],
      zone: BoardSplitZone.bottom,
    );
    tabs.activate(ids[0]);
    final payload = GameTabDragPayload(
      id: 'g2',
      label: 'Ding vs Gukesh',
      spawn: (ref, {required focus}) async {
        ref
            .read(desktopTabsProvider.notifier)
            .open(TabKind.board, reuseExisting: false, focus: focus);
      },
    );
    await tester.pumpWidget(
      _harness(
        container,
        sources: [
          GameDragSource(
            payload: payload,
            child: const SizedBox(
              key: ValueKey('row'),
              height: 40,
              width: 200,
              child: Text('Ding vs Gukesh'),
            ),
          ),
        ],
      ),
    );
    expect(find.byType(BoardSplitCellHeader), findsNWidgets(4));

    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('row'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(300, 300));
    await tester.pump();
    // Hard against the left edge of the top-left board.
    await gesture.moveTo(origin + const Offset(24, 204));
    await tester.pump();
    expect(find.text('Replace this board'), findsOneWidget);
    expect(find.text('Split left'), findsNothing);

    await gesture.up();
    await tester.pump();
    await tester.pump();
    final layout = container.read(visibleBoardSplitProvider)!;
    expect(layout.cellCount, 4);
    expect(layout.contains(ids[0]), isFalse);
    // The replaced board is still an open tab.
    expect(
      container.read(desktopTabsProvider).tabs.any((t) => t.id == ids[0]),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a drag let go near where it came in splits nothing', (
    tester,
  ) async {
    _sizeWindow(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    tabs.open(TabKind.board, reuseExisting: false);
    var spawned = 0;
    final payload = GameTabDragPayload(
      id: 'g3',
      label: 'So vs Aronian',
      spawn: (ref, {required focus}) async => spawned++,
    );
    await tester.pumpWidget(
      _harness(
        container,
        sources: [
          GameDragSource(
            payload: payload,
            child: const SizedBox(
              key: ValueKey('row'),
              height: 40,
              width: 200,
              child: Text('So vs Aronian'),
            ),
          ),
        ],
      ),
    );
    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('row'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(40, 300));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(50, 306));
    await tester.pump();
    expect(find.text('Split left'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(spawned, 0);
    expect(container.read(boardSplitProvider).groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging the divider resizes the cells without rebuilding '
      'any board', (tester) async {
    _sizeWindow(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final a = tabs.open(TabKind.board, reuseExisting: false);
    final b = tabs.open(TabKind.board, reuseExisting: false, focus: false);
    container
        .read(boardSplitProvider.notifier)
        .place(targetTabId: a, incomingTabId: b, zone: BoardSplitZone.right);
    var builds = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 200),
                SizedBox(
                  key: _workspaceKey,
                  width: 1208,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final state = ref.watch(desktopTabsProvider);
                      return BoardSplitWorkspaceHost(
                        builder:
                            (context, split, geometry) => DesktopWorkspaceStack(
                              tabs: state.tabs,
                              activeId: state.activeId,
                              feedbackScreenshotKey: GlobalKey(),
                              split: split,
                              splitGeometry: geometry,
                              contentBuilder: (tab) {
                                builds++;
                                return ColoredBox(
                                  key: ValueKey('page:${tab.id}'),
                                  color: Colors.black,
                                );
                              },
                            ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final buildsBefore = builds;
    final page = find.byKey(ValueKey('page:$a'));
    expect(tester.getSize(page).width, 600);
    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    final drag = await tester.startGesture(
      origin + const Offset(604, 400),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 6; i++) {
      await drag.moveBy(const Offset(-25, 0));
      await tester.pump();
    }
    await drag.up();
    await tester.pump();
    expect(tester.getSize(page).width, lessThan(480));
    expect(builds, buildsBefore, reason: 'a divider drag only lays out');
    // Let the divider's double-click window close.
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
