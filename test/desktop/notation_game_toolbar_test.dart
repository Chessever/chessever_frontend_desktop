import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StepIntent extends Intent {
  const _StepIntent();
}

void main() {
  Widget harness(
    double width, {
    bool playing = false,
    bool canBack = true,
    bool canForward = true,
    bool? canStep,
    ValueChanged<String>? onAction,
  }) => ProviderScope(
    child: MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: boardToolbarForTesting(
            canGoBack: canBack,
            canGoForward: canForward,
            canStepForward: canStep,
            onFirst: () => onAction?.call('first'),
            onPrevious: () => onAction?.call('previous'),
            onNext: () => onAction?.call('next'),
            onLast: () => onAction?.call('last'),
            onPlayPause: () => onAction?.call('replay'),
            isPlaying: playing,
            onPreviousGame: () => onAction?.call('previous-game'),
            onNextGame: () => onAction?.call('next-game'),
            trailingActions: const SizedBox(
              key: ValueKey('game-actions'),
              width: 156,
              height: 40,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'five move controls stay equal and above separate game navigation',
    (tester) async {
      final actions = <String>[];
      for (final width in [700.0, 580.0, 400.0, 320.0, 240.0, 220.0, 700.0]) {
        await tester.pumpWidget(harness(width, onAction: actions.add));
        final icons = [
          Icons.first_page_rounded,
          Icons.chevron_left_rounded,
          Icons.play_arrow_rounded,
          Icons.chevron_right_rounded,
          Icons.last_page_rounded,
        ];
        final rects =
            icons
                .map(
                  (icon) => tester.getRect(
                    find
                        .ancestor(
                          of: find.byIcon(icon),
                          matching: find.byType(GestureDetector),
                        )
                        .first,
                  ),
                )
                .toList();
        for (final rect in rects) {
          expect(rect.height, 44);
          expect(rect.width, closeTo((width - 20 - 24) / 5, 0.01));
          expect(rect.top, rects.first.top);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        final previousGame = find.byIcon(
          Icons.keyboard_double_arrow_left_rounded,
        );
        expect(
          tester.getTopLeft(previousGame).dy,
          greaterThan(rects.first.bottom),
        );
        expect(
          find.text('Previous game'),
          width >= 580 ? findsOneWidget : findsNothing,
        );
        for (final icon in [
          ...icons,
          Icons.keyboard_double_arrow_left_rounded,
          Icons.keyboard_double_arrow_right_rounded,
        ]) {
          await tester.tap(find.byIcon(icon));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      }
      expect(actions.length, 49);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'terminal variation disables only manual next, not replay or last',
    (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(
        harness(700, canStep: false, onAction: actions.add),
      );
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.tap(find.byIcon(Icons.last_page_rounded));
      expect(actions, ['replay', 'last']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    },
  );

  testWidgets(
    'end state preserves a working pause button during active replay',
    (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(
        harness(700, playing: true, canForward: false, onAction: actions.add),
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.tap(find.byIcon(Icons.last_page_rounded));
      expect(actions, ['replay']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    },
  );

  testWidgets(
    'start and end controls are inert at their respective boundaries',
    (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(
        harness(700, canBack: false, canForward: false, onAction: actions.add),
      );
      for (final icon in [
        Icons.first_page_rounded,
        Icons.chevron_left_rounded,
        Icons.play_arrow_rounded,
        Icons.chevron_right_rounded,
        Icons.last_page_rounded,
      ]) {
        await tester.tap(find.byIcon(icon));
        await tester.pump();
      }
      expect(actions, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    },
  );

  testWidgets(
    'focused replay buttons activate without owning arrow navigation',
    (tester) async {
      var arrows = 0;
      var replay = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(),
              },
              child: Actions(
                actions: {
                  _StepIntent: CallbackAction<_StepIntent>(
                    onInvoke: (_) {
                      arrows++;
                      return null;
                    },
                  ),
                },
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 700,
                    child: boardToolbarForTesting(
                      canGoBack: true,
                      canGoForward: true,
                      onFirst: () {},
                      onPrevious: () {},
                      onNext: () {},
                      onLast: () {},
                      onPlayPause: () => replay++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Focus.of(
        tester.element(find.byIcon(Icons.play_arrow_rounded)),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(replay, 1);
      expect(arrows, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
