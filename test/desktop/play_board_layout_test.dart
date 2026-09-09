import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/board_resize_handle.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';

/// Space a tall window hands the Play pane's board column at the default
/// 64/36 split, after the shell chrome and the column's own 16px padding.
const _wideColumnWidth = 850.0;
const _wideColumnHeight = 900.0;

void main() {
  group('play board metrics', () {
    test('uses the same default square as the watching board', () {
      final metrics = computePlayBoardMetrics(
        width: _wideColumnWidth,
        height: _wideColumnHeight,
      );

      // The old fixed layout squeezed both player rows AND the move-nav bar
      // inside the board square and then capped the result at 720, so the
      // playable board landed near 520px. Reserving that chrome outside the
      // square is what makes Play match the Board pane's default.
      expect(metrics.boardSize, kDesktopBoardDefaultSize);
    });

    test('spends every spare pixel of height on the board', () {
      // Below the default the board is height-bound, and the only deductions
      // allowed are the two player rows and their gaps.
      final metrics = computePlayBoardMetrics(
        width: _wideColumnWidth,
        height: 700,
      );
      expect(metrics.boardSize, 700 - (52 * 2) - (10 * 2));
    });

    test('honours an explicit board-size preference within bounds', () {
      final grown = computePlayBoardMetrics(
        width: 1400,
        height: 1400,
        boardSizePreference: 980,
      );
      expect(grown.boardSize, 980);

      final overMax = computePlayBoardMetrics(
        width: 4000,
        height: 4000,
        boardSizePreference: kDesktopBoardMaxSize + 400,
      );
      expect(overMax.boardSize, kDesktopBoardMaxSize);
    });

    test('never renders a board larger than the space it was given', () {
      final narrow = computePlayBoardMetrics(
        width: 420,
        height: _wideColumnHeight,
        boardSizePreference: 1100,
      );
      expect(narrow.boardSize, 420);

      final short = computePlayBoardMetrics(
        width: _wideColumnWidth,
        height: 500,
        boardSizePreference: 1100,
      );
      // Two 52px player rows plus two 10px gaps come off the height first.
      expect(short.boardSize, 376);
    });

    test('grip may grow past the current column width, bounded vertically', () {
      final metrics = computePlayBoardMetrics(
        width: 420,
        height: 1000,
        boardSizePreference: 420,
      );

      // Width is the current bottleneck, but a grow-drag must not be clamped
      // to it — the split view widens the column to follow the new size.
      expect(metrics.boardSize, 420);
      expect(metrics.growLimit, greaterThan(metrics.boardSize));
      expect(metrics.growLimit, 876);
    });

    test('collapses to nothing rather than overflowing a tiny column', () {
      final metrics = computePlayBoardMetrics(width: 300, height: 100);
      expect(metrics.boardSize, 0);
    });
  });

  group('play board layout renders', () {
    testWidgets('lays out board, player rows and split gutter without overflow',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_playHarness());
      // Drain the board-size preference read's timeout timer.
      await tester.pump(const Duration(seconds: 5));

      // The split view is what makes the pane resizable — a plain Row here
      // would mean the board is stuck at whatever flex it was given.
      expect(find.byType(ResizableSplitView), findsOneWidget);
      // The corner grip is the second half of the promise: an explicit,
      // persisted board size on top of the draggable gutter.
      expect(find.byType(BoardResizeHandle), findsOneWidget);

      // The regression this whole change exists for: the old layout squeezed
      // the player rows and the move-nav bar inside one 720px square, leaving
      // roughly a 520px board on this exact surface.
      final boardSize = tester.getSize(find.byType(DesktopChessBoard));
      expect(boardSize.width, boardSize.height);
      expect(boardSize.width, greaterThan(700));
    });
  });
}

Widget _playHarness() {
  const tabId = 'play-layout-test';
  return ProviderScope(
    overrides: [
      playSessionBootEngineProvider.overrideWithValue(false),
      playSessionArgsByTabIdProvider.overrideWith(
        (ref) => const <String, PlaySessionArgs>{
          tabId: PlaySessionArgs(
            config: PlayConfig(
              engine: BotEngineKind.stockfish,
              elo: 1500,
              category: TimeControlCategory.blitz,
              baseSeconds: 180,
              incrementSeconds: 2,
              color: PlayColorChoice.white,
              startClockImmediately: false,
              startingFen: null,
              startingMovesUci: <String>[],
            ),
            engineBinaryPath: '/no-engine-needed',
            botIdentity: BotIdentity(
              firstName: 'Test',
              lastName: 'Bot',
              countryCode: 'US',
              elo: 1500,
            ),
          ),
        },
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: PlayActiveGameView(tabId: tabId)),
    ),
  );
}
