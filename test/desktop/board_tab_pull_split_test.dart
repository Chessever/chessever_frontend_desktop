import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/board_split_workspace.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/game_drag_source.dart';
import 'package:chessever/providers/engine_settings_provider.dart';

class _StableEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}

const _workspaceKey = ValueKey('workspace');

Future<({ProviderContainer container, String carlsen, String anand})> _pump(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1208, 854);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      engineSettingsProviderNew.overrideWith(_StableEngineSettings.new),
    ],
  );
  addTearDown(container.dispose);
  String open(String id, String white, String black) =>
      openBoardGameTabFromContainer(
        container,
        BoardTabGameArgs(
          gameId: id,
          pgn: '1. e4 e5 *',
          label: '$white vs $black',
          whiteName: white,
          blackName: black,
        ),
        reuseExisting: false,
      );
  final carlsen = open('game-a', 'Magnus Carlsen', 'Hikaru Nakamura');
  final anand = open('game-b', 'Viswanathan Anand', 'Ding Liren');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 46, child: DesktopTabBar()),
              Expanded(
                key: _workspaceKey,
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
                            (tab) => ColoredBox(
                              key: ValueKey('page:${tab.id}'),
                              color: Colors.black,
                            ),
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
  await tester.pumpAndSettle();
  return (container: container, carlsen: carlsen, anand: anand);
}

void main() {
  testWidgets('pulling a tab down drops it beside the board being viewed', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    final tabs = fixture.container.read(desktopTabsProvider.notifier);
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);

    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Carlsen')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // The press selects the tab at once, exactly as before.
    expect(
      fixture.container.read(desktopTabsProvider).activeId,
      fixture.carlsen,
    );

    await mouse.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(find.byType(GameDragChip), findsOneWidget);
    // The pull brings back the board the user was looking at.
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);

    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    await mouse.moveTo(origin + const Offset(1120, 400));
    await tester.pump();
    await mouse.moveTo(origin + const Offset(1130, 410));
    await tester.pump();
    expect(find.text('Split right'), findsOneWidget);

    await mouse.up();
    await tester.pump();
    final split = fixture.container.read(visibleBoardSplitProvider)!;
    expect(split.columns, [
      [fixture.anand],
      [fixture.carlsen],
    ]);
    expect(
      fixture.container.read(desktopTabsProvider).activeId,
      fixture.carlsen,
    );
    expect(find.byType(BoardSplitCellHeader), findsNWidgets(2));

    // Moving it out of the split from the tab's own split header.
    tabs.activate(fixture.anand);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.open_in_full_rounded).last);
    await tester.pump();
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the only board on screen keeps its old pull behaviour', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Anand')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(0, 30));
    await tester.pump();
    // Nothing to split with: no drag proxy, the tear-off path is untouched.
    expect(find.byType(GameDragChip), findsNothing);
    await mouse.up();
    await tester.pump();
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the tab menu shows a board beside the current one, the cell '
      'header closes it', (tester) async {
    final fixture = await _pump(tester);
    await tester.tapAt(
      tester.getCenter(find.textContaining('Carlsen')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    // The press of a right click does not switch boards.
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    await tester.tap(find.text('Show beside current board'));
    await tester.pumpAndSettle();
    expect(fixture.container.read(visibleBoardSplitProvider)!.columns, [
      [fixture.anand],
      [fixture.carlsen],
    ]);

    // The right cell's close button closes that board's tab.
    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pump();
    final tabs = fixture.container.read(desktopTabsProvider).tabs;
    expect(tabs.any((t) => t.id == fixture.carlsen), isFalse);
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a wobbly click on a tab still just selects it', (tester) async {
    final fixture = await _pump(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Carlsen')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(1, 12));
    await tester.pump();
    expect(find.byType(GameDragChip), findsNothing);
    await mouse.up();
    await tester.pump();
    expect(
      fixture.container.read(desktopTabsProvider).activeId,
      fixture.carlsen,
    );
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
