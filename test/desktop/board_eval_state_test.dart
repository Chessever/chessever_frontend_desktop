import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  group('BoardEvalState search depth', () {
    test('never reports a lower depth than the current state', () {
      expect(monotonicSearchDepth(current: 32, incoming: 31), 32);
      expect(monotonicSearchDepth(current: 32, incoming: 32), 32);
      expect(monotonicSearchDepth(current: 32, incoming: 33), 33);
    });

    test('preserves deeper PVs when a shallower update arrives', () {
      const deepPv = BoardPv(evaluation: 0.35, mate: null, moves: 'e2e4 e7e5');
      const shallowPv = BoardPv(
        evaluation: 0.12,
        mate: null,
        moves: 'd2d4 d7d5',
      );
      const state = BoardEvalState(
        pvs: <BoardPv>[deepPv],
        isEvaluating: true,
        depth: 32,
      );

      final next = state.applySearchUpdate(
        pvs: const <BoardPv>[shallowPv],
        isEvaluating: true,
        depth: 31,
        preserveExistingPvsOnDepthRegression: true,
      );

      expect(next.depth, 32);
      expect(next.pvs.single.moves, deepPv.moves);
    });

    test('accepts same-depth PV refreshes', () {
      const oldPv = BoardPv(evaluation: 0.35, mate: null, moves: 'e2e4 e7e5');
      const refreshedPv = BoardPv(
        evaluation: 0.42,
        mate: null,
        moves: 'g1f3 g8f6',
      );
      const state = BoardEvalState(
        pvs: <BoardPv>[oldPv],
        isEvaluating: true,
        depth: 32,
      );

      final next = state.applySearchUpdate(
        pvs: const <BoardPv>[refreshedPv],
        isEvaluating: true,
        depth: 32,
        preserveExistingPvsOnDepthRegression: true,
      );

      expect(next.depth, 32);
      expect(next.pvs.single.moves, refreshedPv.moves);
    });

    test('compares PV snapshots by value', () {
      expect(
        const BoardPv(evaluation: 0.35, mate: null, moves: 'e2e4 e7e5'),
        const BoardPv(evaluation: 0.35, mate: null, moves: 'e2e4 e7e5'),
      );
      expect(
        const BoardPv(evaluation: 0.35, mate: null, moves: 'e2e4 e7e5'),
        isNot(const BoardPv(evaluation: 0.40, mate: null, moves: 'e2e4 e7e5')),
      );
    });

    test('detects checkmate positions without starting a search', () {
      final state = terminalBoardEvalStateForFen(
        'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
      );

      expect(state, isNotNull);
      expect(state!.isEvaluating, isFalse);
      expect(state.evaluation, -10.0);
      expect(state.mate, 0);
      expect(state.pvs, isEmpty);
      expect(state.statusText, 'Checkmate');
    });

    test('detects drawn terminal positions without starting a search', () {
      final state = terminalBoardEvalStateForFen(
        '7k/5K2/6Q1/8/8/8/8/8 b - - 0 1',
      );

      expect(state, isNotNull);
      expect(state!.isEvaluating, isFalse);
      expect(state.evaluation, 0.0);
      expect(state.mate, isNull);
      expect(state.pvs, isEmpty);
      expect(state.statusText, 'Draw by stalemate');
    });

    test('keeps playable positions on the normal engine path', () {
      final state = terminalBoardEvalStateForFen(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      );

      expect(state, isNull);
    });

    test('builds threat FEN by flipping turn and clearing en passant', () {
      expect(
        threatFenForBoardEval(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        ),
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1',
      );
    });

    test('leaves malformed threat FEN input unchanged', () {
      expect(threatFenForBoardEval('not-a-fen'), 'not-a-fen');
      expect(
        threatFenForBoardEval('8/8/8/8/8/8/8/8 x - - 0 1'),
        '8/8/8/8/8/8/8/8 x - - 0 1',
      );
    });

    test('uses one threat target for the gauge and disables PV play', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

      final target = activeBoardEvalTarget(
        fen: fen,
        threatMode: true,
        isCheck: false,
      );

      expect(target.fen, threatFenForBoardEval(fen));
      expect(target.isThreatProbe, isTrue);
      expect(target.canPlayPv, isFalse);
    });

    test('falls back to the real FEN and PV play while in check', () {
      const fen =
          'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';

      final target = activeBoardEvalTarget(
        fen: fen,
        threatMode: true,
        isCheck: true,
      );

      expect(target.fen, fen);
      expect(target.isThreatProbe, isFalse);
      expect(target.canPlayPv, isTrue);
    });

    test(
      'does not clear depth tracker while provider is initializing',
      () async {
        final container = ProviderContainer(
          overrides: [
            engineSettingsProviderNew.overrideWith(
              _TestEngineSettingsNotifier.new,
            ),
          ],
        );
        addTearDown(container.dispose);

        final progress = EngineSearchProgress(
          depth: 18,
          kiloNodes: 42,
          fenFragment: 'previous-position',
        );
        container
            .read(engineDepthTrackerProvider.notifier)
            .update(
              component: EngineComponent.principalVariation,
              progress: progress,
            );

        final subscription = container.listen<BoardEvalState>(
          boardEvalProvider(''),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        expect(
          container.read(engineDepthTrackerProvider),
          containsPair(EngineComponent.principalVariation, progress),
        );

        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(engineDepthTrackerProvider),
          isNot(contains(EngineComponent.principalVariation)),
        );
        expect(subscription.read().isEvaluating, isFalse);
      },
    );

    test('defaults engine analysis off until explicitly enabled', () {
      expect(const EngineSettings().showEngineAnalysis, isFalse);
    });

    test('defaults PV arrows on', () {
      expect(const EngineSettings().showPvArrows, isTrue);
    });

    test('defaults automatic whole-game analysis on', () {
      expect(const EngineSettings().autoGameAnalysis, isTrue);
    });

    test(
      'does not start board evaluation while engine settings are still loading',
      () async {
        final container = ProviderContainer(
          overrides: [
            engineSettingsProviderNew.overrideWith(
              _LoadingEngineSettingsNotifier.new,
            ),
          ],
        );
        addTearDown(container.dispose);

        final subscription = container.listen<BoardEvalState>(
          boardEvalProvider(
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          ),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await Future<void>.delayed(Duration.zero);

        expect(subscription.read().isEvaluating, isFalse);
        expect(subscription.read().pvs, isEmpty);
        expect(container.read(engineDepthTrackerProvider), isEmpty);
      },
    );
  });

  group('threat PV arrows', () {
    // White to move; a black reply is illegal in the real position but becomes
    // legal in the null-move threat position. This is exactly the case that
    // silently dropped every threat arrow before the fix.
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const settings = EngineSettings(
      showPvArrows: true,
      showEngineAnalysis: true,
    );
    const opponentReplyPv = BoardPv(evaluation: 0.0, mate: null, moves: 'e7e5');

    test('drops arrows whose first move is illegal in the real position', () {
      final shapes = debugEnginePvArrowShapes(
        fen: startFen,
        pvs: const <BoardPv>[opponentReplyPv],
        settings: settings,
      );

      expect(shapes, isEmpty);
    });

    test('renders arrows against the null-move threat position', () {
      final shapes = debugEnginePvArrowShapes(
        fen: startFen,
        pvs: const <BoardPv>[opponentReplyPv],
        settings: settings,
        threatMode: true,
      );

      expect(shapes, hasLength(1));
    });
  });
}

class _TestEngineSettingsNotifier extends AsyncNotifier<EngineSettings>
    implements EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LoadingEngineSettingsNotifier extends AsyncNotifier<EngineSettings>
    implements EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() => Completer<EngineSettings>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
