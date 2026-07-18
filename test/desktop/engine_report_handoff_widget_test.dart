import 'dart:async';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'visible report detaches both live-eval watchers and restores them on cancel',
    (tester) async {
      final evaluatorResult = Completer<EnhancedCloudEval>();
      final controller = GameAnalysisReportController(
        evaluator:
            (
              fen, {
              required depth,
              required multiPv,
              required ownerId,
              onProgress,
            }) => evaluatorResult.future,
      );
      final lifecycle = _BoardEvalLifecycle();
      final game = ChessGame.fromPgn('report-handoff', '1. e4 *');

      addTearDown(() {
        if (!evaluatorResult.isCompleted) {
          evaluatorResult.complete(_evaluation(game.startingFen));
        }
        controller.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            engineSettingsProviderNew.overrideWith(
              _EngineAndAutoAnalysisOnNotifier.new,
            ),
            boardEvalProvider.overrideWith(
              (ref, _) => _TrackingBoardEvalNotifier(ref, lifecycle),
            ),
          ],
          child: MaterialApp(
            home: _ReportHandoffHarness(game: game, controller: controller),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(controller.state.status, GameReportStatus.running);
      expect(lifecycle.created, 1);
      expect(lifecycle.disposed, 1);
      expect(
        find.text('Live analysis paused while the game report runs.'),
        findsOneWidget,
      );

      await controller.cancel();
      await tester.pump();
      await tester.pump();

      expect(controller.state.status, GameReportStatus.cancelled);
      expect(lifecycle.created, 2);
      expect(lifecycle.disposed, 1);

      evaluatorResult.complete(_evaluation(game.startingFen));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('disposing a running report panel clears its parent signal', (
    tester,
  ) async {
    final evaluatorResult = Completer<EnhancedCloudEval>();
    final controller = GameAnalysisReportController(
      evaluator:
          (
            fen, {
            required depth,
            required multiPv,
            required ownerId,
            onProgress,
          }) => evaluatorResult.future,
    );
    final lifecycle = _BoardEvalLifecycle();
    final game = ChessGame.fromPgn('report-dispose', '1. e4 *');
    final harnessKey = GlobalKey<_DisposableReportHarnessState>();

    addTearDown(() {
      if (!evaluatorResult.isCompleted) {
        evaluatorResult.complete(_evaluation(game.startingFen));
      }
      controller.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineSettingsProviderNew.overrideWith(
            _EngineAndAutoAnalysisOnNotifier.new,
          ),
          boardEvalProvider.overrideWith(
            (ref, _) => _TrackingBoardEvalNotifier(ref, lifecycle),
          ),
        ],
        child: MaterialApp(
          home: _DisposableReportHarness(
            key: harnessKey,
            game: game,
            controller: controller,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(harnessKey.currentState!.reportRunning, isTrue);

    harnessKey.currentState!.hidePanel();
    await tester.pump();
    await tester.pump();

    expect(harnessKey.currentState!.reportRunning, isFalse);

    await controller.cancel();
    evaluatorResult.complete(_evaluation(game.startingFen));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('backgrounding the engine panel cancels a running report', (
    tester,
  ) async {
    final evaluatorResult = Completer<EnhancedCloudEval>();
    final controller = GameAnalysisReportController(
      evaluator:
          (
            fen, {
            required depth,
            required multiPv,
            required ownerId,
            onProgress,
          }) => evaluatorResult.future,
    );
    final game = ChessGame.fromPgn('report-background', '1. e4 *');
    final harnessKey = GlobalKey<_ForegroundReportHarnessState>();
    addTearDown(() {
      if (!evaluatorResult.isCompleted) {
        evaluatorResult.complete(_evaluation(game.startingFen));
      }
      controller.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineSettingsProviderNew.overrideWith(
            _EngineAndAutoAnalysisOnNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: _ForegroundReportHarness(
            key: harnessKey,
            game: game,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(controller.state.status, GameReportStatus.running);

    harnessKey.currentState!.setForeground(false);
    await tester.pump();
    await tester.pump();
    expect(controller.state.status, GameReportStatus.cancelled);
  });
}

EnhancedCloudEval _evaluation(String fen) => EnhancedCloudEval(
  fen: fen,
  knodes: 1,
  depth: GameAnalysisReportController.reportDepth,
  pvs: [Pv(moves: 'e2e4', cp: 20)],
);

class _ReportHandoffHarness extends ConsumerStatefulWidget {
  const _ReportHandoffHarness({required this.game, required this.controller});

  final ChessGame game;
  final GameAnalysisReportController controller;

  @override
  ConsumerState<_ReportHandoffHarness> createState() =>
      _ReportHandoffHarnessState();
}

class _ReportHandoffHarnessState extends ConsumerState<_ReportHandoffHarness> {
  bool _reportRunning = false;

  @override
  Widget build(BuildContext context) {
    final runLiveAnalysis = shouldRunLiveBoardAnalysis(
      isForeground: true,
      reportVisible: true,
      reportRunning: _reportRunning,
    );
    if (runLiveAnalysis) {
      ref.watch(boardEvalProvider(widget.game.startingFen));
    }

    return SizedBox(
      width: 520,
      height: 420,
      child: EnginePanel(
        fen: widget.game.startingFen,
        sideToMove: 'w',
        game: widget.game,
        reportVisible: true,
        autoAnalysisAllowed: true,
        reportController: widget.controller,
        onReportRunningChanged: (running) {
          if (mounted && _reportRunning != running) {
            setState(() => _reportRunning = running);
          }
        },
      ),
    );
  }
}

class _DisposableReportHarness extends StatefulWidget {
  const _DisposableReportHarness({
    super.key,
    required this.game,
    required this.controller,
  });

  final ChessGame game;
  final GameAnalysisReportController controller;

  @override
  State<_DisposableReportHarness> createState() =>
      _DisposableReportHarnessState();
}

class _DisposableReportHarnessState extends State<_DisposableReportHarness> {
  bool _showPanel = true;
  bool reportRunning = false;

  void hidePanel() => setState(() => _showPanel = false);

  @override
  Widget build(BuildContext context) {
    if (!_showPanel) return const SizedBox.shrink();
    return SizedBox(
      width: 520,
      height: 420,
      child: EnginePanel(
        fen: widget.game.startingFen,
        sideToMove: 'w',
        game: widget.game,
        reportVisible: true,
        autoAnalysisAllowed: true,
        reportController: widget.controller,
        onReportRunningChanged: (running) {
          if (mounted && reportRunning != running) {
            setState(() => reportRunning = running);
          }
        },
      ),
    );
  }
}

class _ForegroundReportHarness extends StatefulWidget {
  const _ForegroundReportHarness({
    super.key,
    required this.game,
    required this.controller,
  });

  final ChessGame game;
  final GameAnalysisReportController controller;

  @override
  State<_ForegroundReportHarness> createState() =>
      _ForegroundReportHarnessState();
}

class _ForegroundReportHarnessState extends State<_ForegroundReportHarness> {
  bool foreground = true;

  void setForeground(bool value) => setState(() => foreground = value);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 520,
      height: 420,
      child: EnginePanel(
        fen: widget.game.startingFen,
        sideToMove: 'w',
        game: widget.game,
        reportVisible: true,
        isForegroundTab: foreground,
        autoAnalysisAllowed: foreground,
        reportController: widget.controller,
      ),
    );
  }
}

class _BoardEvalLifecycle {
  int created = 0;
  int disposed = 0;
}

class _TrackingBoardEvalNotifier extends BoardEvalNotifier {
  _TrackingBoardEvalNotifier(Ref ref, this.lifecycle)
    : super(
        ref,
        '',
        const BoardEvalConfig(
          enabled: false,
          searchTimeIndex: 0,
          principalVariationIndex: 0,
        ),
      ) {
    lifecycle.created++;
  }

  final _BoardEvalLifecycle lifecycle;

  @override
  void dispose() {
    lifecycle.disposed++;
    super.dispose();
  }
}

class _EngineAndAutoAnalysisOnNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(
      showEngineAnalysis: true,
      autoGameAnalysis: true,
    );
    state = const AsyncValue.data(settings);
    return settings;
  }
}
