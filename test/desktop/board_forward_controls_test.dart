import 'dart:io';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/move_navigation_bar.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final game = ChessGame.fromPgn(
    'controls-boundary',
    r'1. e4 e5 (1... c5) 2. Nf3 Nc6 *',
  );
  const endpoint = <int>[0, 0, 0];
  final canTraverse =
      traversalBoardForwardPointerForTesting(game, endpoint) != null;
  final canStep = manualBoardForwardPointerForTesting(game, endpoint) != null;

  testWidgets('under-board next alone is disabled at a variation endpoint', (
    tester,
  ) async {
    var next = 0, last = 0, play = 0;
    expect(canTraverse, isTrue);
    expect(canStep, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveNavigationBar(
            canGoBack: true,
            canGoForward: canTraverse,
            canStepForward: canStep,
            onFirst: () {},
            onPrevious: () {},
            onNext: () => next++,
            onLast: () => last++,
            onPlayPause: () => play++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(next, 0);
    await tester.tap(find.byIcon(Icons.last_page_rounded));
    await tester.pumpAndSettle();
    expect(last, 1);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(play, 1);
  });

  testWidgets('Explorer next alone is disabled and Last remains available', (
    tester,
  ) async {
    var next = 0, last = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: explorerNavigationClusterForTesting(
            canGoForward: canTraverse,
            canStepForward: canStep,
            onNext: () => next++,
            onLast: () => last++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(next, 0);
    await tester.tap(find.byIcon(Icons.last_page_rounded));
    await tester.pumpAndSettle();
    expect(last, 1);
  });

  testWidgets('other MoveNavigationBar callers keep the existing default', (
    tester,
  ) async {
    var next = 0, last = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveNavigationBar(
            canGoBack: false,
            canGoForward: true,
            onFirst: () {},
            onPrevious: () {},
            onNext: () => next++,
            onLast: () => last++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.last_page_rounded));
    await tester.pumpAndSettle();
    expect(next, 1);
    expect(last, 1);
  });

  test('Board sends manual capability separately from Last and replay', () {
    final source = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    expect(
      RegExp(
        r'final\s+canForward\s*=\s*_nextPointer\(\s*chessGame\.value,\s*pointer\.value,?\s*\)\s*!=\s*null;',
      ).hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(
        r'final\s+canStepForward\s*=\s*_nextManualPointer\(\s*chessGame\.value,\s*pointer\.value,?\s*\)\s*!=\s*null;',
      ).hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(r'canStepForward:\s*canStepForward').allMatches(source),
      hasLength(2),
    );
  });
}
