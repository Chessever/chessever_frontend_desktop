import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/move_navigation_bar.dart';

void main() {
  group('MoveNavigationBar', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      bool canBack = false,
      bool canForward = true,
      VoidCallback? onPrevious,
      VoidCallback? onNext,
      VoidCallback? onFirst,
      VoidCallback? onLast,
      VoidCallback? onFlip,
      VoidCallback? onPlayPause,
      VoidCallback? onPreviousGame,
      VoidCallback? onNextGame,
      bool isPlaying = false,
      String? moveLabel,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveNavigationBar(
              canGoBack: canBack,
              canGoForward: canForward,
              onFirst: onFirst ?? () {},
              onPrevious: onPrevious ?? () {},
              onNext: onNext ?? () {},
              onLast: onLast ?? () {},
              onPlayPause: onPlayPause,
              onPreviousGame: onPreviousGame,
              onNextGame: onNextGame,
              isPlaying: isPlaying,
              onFlipBoard: onFlip ?? () {},
              moveLabel: moveLabel,
            ),
          ),
        ),
      );
    }

    testWidgets('renders the move label when provided', (tester) async {
      await pumpBar(tester, moveLabel: '12. Nf3 · 23/47');
      expect(find.text('12. Nf3 · 23/47'), findsOneWidget);
    });

    testWidgets('disables previous button when canGoBack is false', (
      tester,
    ) async {
      var pressed = false;
      await pumpBar(tester, canBack: false, onPrevious: () => pressed = true);
      await tester.tap(_byDesktopTooltip('Previous move (←)'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(
        pressed,
        isFalse,
        reason: 'previous should not fire when canGoBack=false',
      );
    });

    testWidgets('fires onNext when next button tapped and forward enabled', (
      tester,
    ) async {
      var pressed = false;
      await pumpBar(tester, onNext: () => pressed = true);
      await tester.tap(_byDesktopTooltip('Next move (→)'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(pressed, isTrue);
    });

    testWidgets('flip button is always enabled', (tester) async {
      var flipped = false;
      await pumpBar(
        tester,
        canBack: false,
        canForward: false,
        onFlip: () => flipped = true,
      );
      await tester.tap(_byDesktopTooltip('Flip board (F)'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(flipped, isTrue);
    });

    testWidgets('can hide the flip button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveNavigationBar(
              canGoBack: false,
              canGoForward: false,
              onFirst: () {},
              onPrevious: () {},
              onNext: () {},
              onLast: () {},
              showFlipBoard: false,
            ),
          ),
        ),
      );

      expect(_byDesktopTooltip('Flip board (F)'), findsNothing);
    });

    testWidgets('shows optional previous and next game jump controls', (
      tester,
    ) async {
      var previousGamePressed = false;
      var nextGamePressed = false;
      await pumpBar(
        tester,
        onPreviousGame: () => previousGamePressed = true,
        onNextGame: () => nextGamePressed = true,
      );

      await tester.tap(_byDesktopTooltip('Previous game'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await tester.tap(_byDesktopTooltip('Next game'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));

      expect(previousGamePressed, isTrue);
      expect(nextGamePressed, isTrue);
    });

    testWidgets('play pause uses the same compact button slot', (tester) async {
      var pressed = false;
      await pumpBar(tester, onPlayPause: () => pressed = true);

      await tester.tap(_byDesktopTooltip('Autoplay (Space)'));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));

      expect(pressed, isTrue);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });
  });
}

/// Matches a [DesktopTooltip] by its [message]. Replaces `find.byTooltip`,
/// which only locates Material `Tooltip` widgets — desktop chrome routes
/// through forui's `FTooltip` instead.
Finder _byDesktopTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is DesktopTooltip && widget.message == message,
);
