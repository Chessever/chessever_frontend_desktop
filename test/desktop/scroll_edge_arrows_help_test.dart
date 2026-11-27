import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';

Widget _app(Widget child, {double width = 320}) => FTheme(
  data: FThemes.zinc.dark,
  child: MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width,
          child: Column(mainAxisSize: MainAxisSize.min, children: [child]),
        ),
      ),
    ),
  ),
);

Widget _rows(int count) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    for (var i = 0; i < count; i++) SizedBox(height: 40, child: Text('Row $i')),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('PlayShrinkingScroller', () {
    testWidgets('short content keeps its own height, with no arrows', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(PlayShrinkingScroller(maxHeight: 360, child: _rows(3))),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 120);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
    });

    testWidgets('tall content stops at the cap and an arrow scrolls it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(PlayShrinkingScroller(maxHeight: 360, child: _rows(20))),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 360);
      expect(find.byType(ScrollEdgeArrows), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);

      final down = find.byIcon(Icons.keyboard_arrow_down_rounded);
      expect(down, findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      final before = tester.getTopLeft(find.text('Row 0')).dy;
      await tester.tap(down);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Row 0')).dy, lessThan(before));
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    });

    testWidgets('content that grows past the cap gains the arrow', (
      tester,
    ) async {
      final count = ValueNotifier(2);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<int>(
            valueListenable: count,
            builder:
                (context, n, _) =>
                    PlayShrinkingScroller(maxHeight: 200, child: _rows(n)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 80);
      count.value = 12;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 200);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      count.value = 1;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 40);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    });
  });

  testWidgets('the Live help list scrolls by arrow, with no scrollbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyboardShortcutsProvider.overrideWith(_DefaultShortcuts.new),
          playHelpSectionExpandedProvider.overrideWith((ref) => true),
        ],
        child: _app(const PlayHelpModulesSection(), width: 640),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ScrollEdgeArrows), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
    final list = find.byType(PlayShrinkingScroller);
    expect(tester.getSize(list).height, lessThanOrEqualTo(300));

    final down = find.byIcon(Icons.keyboard_arrow_down_rounded);
    expect(down, findsOneWidget);
    final first = find.byType(FSwitch).first;
    final before = tester.getTopLeft(first).dy;
    await tester.tap(down);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dy, lessThan(before));
  });
}

class _DefaultShortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
