import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

const a = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
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
  void emit(BoardEvalState value) => state = value;
}

class _Settings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineAnalysis: true, autoGameAnalysis: false);
}
