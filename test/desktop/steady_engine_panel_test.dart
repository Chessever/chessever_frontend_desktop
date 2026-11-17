import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

const a = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  for (final scenario in [
    (
      name: 'waiting for a position',
      fen: '',
      foreground: true,
      message: 'Select a position to start analysis.',
    ),
    (
      name: 'in a background tab',
      fen: a,
      foreground: false,
      message: 'Live analysis resumes when this tab is active.',
    ),
  ]) {
    testWidgets(
      'inactive analysis ${scenario.name} does not ask to install the engine '
      'and resumes when a position is active',
      (tester) async {
        final target = ValueNotifier((
          fen: scenario.fen,
          foreground: scenario.foreground,
        ));
        final watchedPositions = <String>[];
        final controller = GameAnalysisReportController();
        addTearDown(target.dispose);
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              engineSettingsProviderNew.overrideWith(_Settings.new),
              boardEvalProvider.overrideWith((ref, fen) {
                watchedPositions.add(fen);
                return _ManualEval(ref, fen);
              }),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<({String fen, bool foreground})>(
                  valueListenable: target,
                  builder:
                      (context, value, _) => EnginePanel(
                        fen: value.fen,
                        sideToMove: 'w',
                        isForegroundTab: value.foreground,
                        reportController: controller,
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(watchedPositions, isEmpty);
        expect(find.text('Engine off'), findsNothing);
        expect(find.textContaining('Open Settings'), findsNothing);
        expect(find.textContaining('install via'), findsNothing);
        expect(find.text(scenario.message), findsOneWidget);

        target.value = (fen: a, foreground: true);
        await tester.pump();
        expect(watchedPositions, [a]);
        expect(find.text('Searching…'), findsOneWidget);
        expect(find.text(scenario.message), findsNothing);

        await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
        await tester.pump();
        expect(find.text('Searching…'), findsNothing);
        await tester.tap(find.byIcon(Icons.power_settings_new_outlined));
        await tester.pump();
        expect(find.text('Searching…'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  testWidgets(
    'retarget keeps score depth and three rows, but rejects retained PV clicks',
    (tester) async {
      final target = ValueNotifier(a);
      final notifiers = <String, _ManualEval>{};
      final controller = GameAnalysisReportController();
      final played = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            engineSettingsProviderNew.overrideWith(_Settings.new),
            boardEvalProvider.overrideWith((ref, fen) {
              final notifier = _ManualEval(ref, fen);
              notifiers[fen] = notifier;
              return notifier;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 500,
                height: 400,
                child: ValueListenableBuilder<String>(
                  valueListenable: target,
                  builder:
                      (context, fen, _) => EnginePanel(
                        fen: fen,
                        game: ChessGame.fromPgn(
                          'same-game',
                          fen == a ? '*' : '1. e4 *',
                        ),
                        sideToMove: 'w',
                        reportController: controller,
                        onPlayUci: played.add,
                        pvSanFormatter:
                            (input) async => formatEnginePvSanLine(input),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      const snapshot = BoardEvalState(
        pvs: [
          BoardPv(evaluation: 0.3, mate: null, moves: 'e2e4 e7e5'),
          BoardPv(evaluation: 0.2, mate: null, moves: 'd2d4 d7d5'),
          BoardPv(evaluation: 0.1, mate: null, moves: 'c2c4 e7e5'),
        ],
        isEvaluating: true,
        depth: 12,
      );
      notifiers[a]!.emit(snapshot);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump();
      await tester.pump();
      final before = tester.getRect(find.byType(ListView).first);
      expect(find.text('Searching…'), findsNothing);
      target.value = b;
      await tester.pump();
      notifiers[b]!.emit(const BoardEvalState.evaluating());
      await tester.pump();
      expect(find.text('Searching…'), findsNothing);
      expect(find.text('+0.30'), findsNWidgets(2));
      expect(tester.getRect(find.byType(ListView).first), before);
      await tester.tap(find.text('+0.30').last, warnIfMissed: false);
      expect(played, isEmpty);
      notifiers[b]!.emit(
        const BoardEvalState(pvs: [], isEvaluating: false, depth: 0),
      );
      await tester.pump();
      expect(find.text('+0.30'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      target.dispose();
    },
  );
}

class _ManualEval extends BoardEvalNotifier {
  _ManualEval(Ref ref, String fen)
    : super(
        ref,
        fen,
        const BoardEvalConfig(
          enabled: false,
          searchTimeIndex: 0,
          principalVariationIndex: 0,
        ),
      );
  @override
  set state(BoardEvalState value) {}
  void emit(BoardEvalState value) => super.state = value;
}

class _Settings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineAnalysis: true);

  @override
  Future<void> toggleEngineAnalysis(bool value) async {
    state = AsyncValue.data(
      state.requireValue.copyWith(showEngineAnalysis: value),
    );
  }
}
