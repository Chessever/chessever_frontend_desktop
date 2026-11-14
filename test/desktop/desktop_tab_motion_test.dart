import 'dart:ui' show PointerDeviceKind;

import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _StableEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}

void main() {
  testWidgets('tab buttons never move vertically on hover or activation', (
    tester,
  ) async {
    final tabs = DesktopTabsNotifier();
    final first = tabs.open(TabKind.library);
    tabs.open(TabKind.favorites);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopTabsProvider.overrideWith((ref) => tabs),
          engineSettingsProviderNew.overrideWith(_StableEngineSettings.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 760, height: 46, child: DesktopTabBar()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('Library');
    expect(label, findsOneWidget);
    final initialY = tester.getTopLeft(label).dy;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 200));
    await mouse.moveTo(tester.getCenter(label));
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getTopLeft(label).dy, closeTo(initialY, 0.01));
    }
    await tester.tap(label);
    await tester.pump();
    expect(tabs.state.activeId, first);
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getTopLeft(label).dy, closeTo(initialY, 0.01));
    }
    await mouse.moveTo(const Offset(700, 200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(label).dy, closeTo(initialY, 0.01));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('click jitter never replaces a game tab with a drag proxy', (
    tester,
  ) async {
    final fixture = await _pumpGameTabs(tester);
    final name = find.textContaining('Carlsen');
    expect(name, findsOneWidget);
    final original = tester.element(name);
    final ids =
        fixture.container
            .read(desktopTabsProvider)
            .tabs
            .map((t) => t.id)
            .toList();
    final mouse = await tester.startGesture(
      tester.getCenter(name),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.first);
    expect(
      tester.element(name),
      same(original),
      reason: 'pointer-down must retain the tab label',
    );
    final pressedRect = tester.getRect(find.byKey(ValueKey(fixture.first)));
    await mouse.moveBy(const Offset(3, 0));
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      tester.getRect(find.byKey(ValueKey(fixture.first))),
      pressedRect,
      reason: 'a small click drift must not lift, scale or move the chip',
    );
    expect(
      tester.element(name),
      same(original),
      reason: 'normal click jitter must not mount a drag proxy',
    );
    await mouse.moveBy(const Offset(-2, 3));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.element(name), same(original));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.element(name), same(original));
    expect(
      fixture.container.read(desktopTabsProvider).tabs.map((t) => t.id),
      ids,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('game tab selection changes only its background immediately', (
    tester,
  ) async {
    final fixture = await _pumpGameTabs(tester);
    final name = find.textContaining('Carlsen');
    final otherName = find.textContaining('Anand');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 200));
    await mouse.moveTo(tester.getCenter(name));
    await tester.pumpAndSettle();
    final labels = [name, otherName];
    final rects = labels.map(tester.getRect).toList();
    final styles =
        labels.map((label) => tester.widget<Text>(label).style).toList();
    Color? background(Finder label) =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: label,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(background(name), isNot(kBackgroundColor));
    await mouse.down(tester.getCenter(name));
    await tester.pump();
    expect(
      background(name),
      kBackgroundColor,
      reason: 'selection must not fade through intermediate colors',
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
      for (var i = 0; i < labels.length; i++) {
        expect(
          tester.getRect(labels[i]),
          rects[i],
          reason: 'selecting must not move or resize either label',
        );
        expect(
          tester.widget<Text>(labels[i]).style,
          styles[i],
          reason:
              'only the tab background changes, not its text weight or color',
        );
      }
      expect(background(name), kBackgroundColor);
    }
    final primaryPaint = find.descendant(
      of: find.byKey(ValueKey(fixture.first)),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color == kPrimaryColor,
      ),
    );
    expect(primaryPaint, findsNothing, reason: 'no blue active-tab line');
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('deliberate horizontal dragging still reorders game tabs', (
    tester,
  ) async {
    final fixture = await _pumpGameTabs(tester);
    final first = find.byKey(ValueKey(fixture.first));
    final second = find.byKey(ValueKey(fixture.second));
    final dropTarget = tester.getCenter(second) - const Offset(60, 0);
    final mouse = await tester.startGesture(
      tester.getCenter(first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await mouse.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await mouse.moveTo(dropTarget);
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(fixture.container.read(desktopTabsProvider).tabs.map((t) => t.id), [
      fixture.second,
      fixture.first,
    ]);
    expect(find.textContaining('Carlsen'), findsOneWidget);
    expect(find.textContaining('Anand'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Future<({ProviderContainer container, String first, String second})>
_pumpGameTabs(WidgetTester tester) async {
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
  final first = open('game-a', 'Magnus Carlsen', 'Hikaru Nakamura');
  final second = open('game-b', 'Viswanathan Anand', 'Ding Liren');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 760, height: 46, child: DesktopTabBar()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, first: first, second: second);
}
