import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _tabId = 'play-annotations-test';

/// Normalized key of the starting position the harness boots into.
String get _startKey => annotationPositionKey(Chess.initial.fen);

/// A different position's key: ink stored here must never show while the
/// starting position is on the board.
const _otherFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
String get _otherKey => annotationPositionKey(_otherFen);

PlaySessionArgs _args() => const PlaySessionArgs(
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
);

/// Pumps the live game view and returns its container. The container is owned
/// by the widget tree (like the layout test's harness) so provider timers
/// die with the tree instead of tripping the post-test pending-timer check.
Future<ProviderContainer> _pumpGame(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playSessionBootEngineProvider.overrideWithValue(false),
        playSessionArgsByTabIdProvider.overrideWith(
          (ref) => <String, PlaySessionArgs>{_tabId: _args()},
        ),
      ],
      child: Builder(
        builder: (context) {
          container = ProviderScope.containerOf(context);
          return FTheme(
            data: FThemes.zinc.dark,
            child: const MaterialApp(
              home: Scaffold(body: PlayActiveGameView(tabId: _tabId)),
            ),
          );
        },
      ),
    ),
  );
  // Drain the board-size preference read's timeout timer (no pumpAndSettle:
  // the session clock ticker would never settle).
  await tester.pump(const Duration(seconds: 5));
  return container;
}

Set<cg.Shape> _displayedShapes(WidgetTester tester) {
  final board = tester.widget<DesktopChessBoard>(
    find.byType(DesktopChessBoard),
  );
  return board.shapes.toSet();
}

BoardAnnotationsNotifier _ink(ProviderContainer container) =>
    container.read(boardAnnotationsProvider(_tabId).notifier);

/// Center of a square in board coordinates. The harness plays White, so
/// file 0/rank 0 is a1 at the bottom-left.
Offset _squareCenter(WidgetTester tester, int file, int rankIndex) {
  final rect = tester.getRect(find.byType(DesktopChessBoard));
  final sq = rect.width / 8;
  return rect.topLeft + Offset((file + 0.5) * sq, (7 - rankIndex + 0.5) * sq);
}

void main() {
  test('annotationPositionKey keeps the first four FEN fields', () {
    expect(
      annotationPositionKey(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      ),
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3',
    );
    // Counter-only differences share ink.
    expect(
      annotationPositionKey(Chess.initial.fen),
      annotationPositionKey(
        '${Chess.initial.fen.split(' ').take(4).join(' ')} 3 42',
      ),
    );
    expect(annotationPositionKey('short'), 'short');
  });

  group('play board annotations', () {
    testWidgets('shows only the current position shapes', (tester) async {
      final container = await _pumpGame(tester);

      // Ink from two positions: the displayed start plus a foreign one.
      _ink(container).toggleArrow(
        Square.e2,
        Square.e4,
        AnnotationColor.green,
        positionKey: _startKey,
      );
      _ink(
        container,
      ).toggleCircle(Square.e4, AnnotationColor.green, positionKey: _otherKey);
      await tester.pump();

      // The foreign circle must not leak onto the starting position.
      final shown = _displayedShapes(tester);
      expect(shown, hasLength(1));
      final shape = shown.single;
      expect(shape, isA<cg.Arrow>());
      expect((shape as cg.Arrow).orig, Square.e2);
      expect(shape.dest, Square.e4);
    });

    testWidgets('left-click clears the current position drawings', (
      tester,
    ) async {
      final container = await _pumpGame(tester);

      _ink(container).toggleArrow(
        Square.e2,
        Square.e4,
        AnnotationColor.green,
        positionKey: _startKey,
      );
      _ink(
        container,
      ).toggleCircle(Square.e4, AnnotationColor.green, positionKey: _otherKey);
      await tester.pump();
      expect(_displayedShapes(tester), hasLength(1));

      // Left-click an empty square in the middle of the board.
      await tester.tapAt(tester.getCenter(find.byType(DesktopChessBoard)));
      await tester.pump();

      expect(_displayedShapes(tester), isEmpty);
      expect(
        container
            .read(boardAnnotationsProvider(_tabId))
            .shapesForPosition(_startKey),
        isEmpty,
      );
      // The other position's ink survives: clearing is position-scoped.
      expect(
        container
            .read(boardAnnotationsProvider(_tabId))
            .shapesForPosition(_otherKey),
        hasLength(1),
      );
    });

    testWidgets('right-click draws a circle under the normalized key', (
      tester,
    ) async {
      final container = await _pumpGame(tester);

      // Plain right-click on e2, released without dragging.
      final gesture = await tester.startGesture(
        _squareCenter(tester, 4, 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();

      final stored = container
          .read(boardAnnotationsProvider(_tabId))
          .shapesForPosition(_startKey);
      expect(stored, hasLength(1));
      final shape = stored.single;
      expect(shape, isA<cg.Circle>());
      expect((shape as cg.Circle).orig, Square.e2);
      expect(_displayedShapes(tester), hasLength(1));
    });

    testWidgets('right-drag draws an arrow under the normalized key', (
      tester,
    ) async {
      final container = await _pumpGame(tester);

      // Right-drag from e2 to e4.
      final gesture = await tester.startGesture(
        _squareCenter(tester, 4, 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.moveTo(_squareCenter(tester, 4, 3));
      await gesture.up();
      await tester.pump();

      final stored = container
          .read(boardAnnotationsProvider(_tabId))
          .shapesForPosition(_startKey);
      expect(stored, hasLength(1));
      final shape = stored.single;
      expect(shape, isA<cg.Arrow>());
      expect((shape as cg.Arrow).orig, Square.e2);
      expect(shape.dest, Square.e4);
      expect(_displayedShapes(tester), hasLength(1));
    });

    testWidgets('aborting the game drops the tab ink', (tester) async {
      final container = await _pumpGame(tester);

      _ink(container).toggleArrow(
        Square.e2,
        Square.e4,
        AnnotationColor.green,
        positionKey: _startKey,
      );
      await tester.pump();
      expect(_displayedShapes(tester), hasLength(1));

      await tester.ensureVisible(find.text('Abort'));
      await tester.tap(find.text('Abort'));
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      // Let ForUI's tap-visual timer elapse so teardown sees no timers.
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        container
            .read(boardAnnotationsProvider(_tabId))
            .shapesForPosition(_startKey),
        isEmpty,
        reason: 'a discarded session must not leak ink into the next game',
      );
    });
  });
}
