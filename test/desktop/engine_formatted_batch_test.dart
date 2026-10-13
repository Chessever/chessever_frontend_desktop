import 'dart:async';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _a = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _first = BoardEvalState(
  pvs: [
    BoardPv(evaluation: .31, mate: null, moves: 'e2e4 e7e5'),
    BoardPv(evaluation: .23, mate: null, moves: 'd2d4 d7d5'),
    BoardPv(evaluation: .10, mate: null, moves: 'c2c4 e7e5'),
  ],
  isEvaluating: true,
  depth: 12,
);
const _second = BoardEvalState(
  pvs: [
    BoardPv(evaluation: .42, mate: null, moves: 'e7e5 g1f3'),
    BoardPv(evaluation: .32, mate: null, moves: 'c7c5 g1f3'),
    BoardPv(evaluation: .22, mate: null, moves: 'e7e6 d2d4'),
  ],
  isEvaluating: true,
  depth: 18,
);

class _Worker {
  final requests = <Map<String, String>>[];
  final results = <Completer<List<String>>>[];
  Future<List<String>> call(Map<String, String> input) {
    requests.add(input);
    final result = Completer<List<String>>();
    results.add(result);
    return result.future;
  }

  void complete(int index) =>
      results[index].complete(formatEnginePvSanLine(requests[index]));
}

class _Harness {
  final target = ValueNotifier(_a);
  final gameId = ValueNotifier('same-game');
  final evals = <String, _ManualEval>{};
  final worker = _Worker();
  final controller = GameAnalysisReportController();
  final played = <String>[];

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineSettingsProviderNew.overrideWith(_Settings.new),
          boardEvalProvider.overrideWith((ref, fen) {
            final notifier = _ManualEval(ref, fen);
            evals[fen] = notifier;
            return notifier;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 550,
              height: 400,
              child: ValueListenableBuilder<String>(
                valueListenable: target,
                builder:
                    (context, fen, _) => ValueListenableBuilder<String>(
                      valueListenable: gameId,
                      builder:
                          (context, id, _) => EnginePanel(
                            fen: fen,
                            sideToMove: 'w',
                            game: ChessGame.fromPgn(id, '*'),
                            reportController: controller,
                            onPlayUci: played.add,
                            pvPlayOwner: id,
                            pvSanFormatter: worker.call,
                          ),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
  }

  Future<void> firstReading(WidgetTester tester) async {
    evals[_a]!.emit(_first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 121));
    expect(worker.results, hasLength(3));
    for (var i = 0; i < 3; i++) {
      worker.complete(i);
    }
    await tester.pump();
    await tester.pump();

    expect(find.text('1.e4', findRichText: true), findsOneWidget);
  }

  Future<void> retarget(WidgetTester tester, String fen) async {
    target.value = fen;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    target.dispose();
    gameId.dispose();
  }
}

void main() {
  testWidgets(
    'new game clears retained rows and refuses former formatting completion',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      await h.retarget(tester, _b);
      h.evals[_b]!.emit(_second);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      h.gameId.value = 'different-game';
      await tester.pump();
      expect(find.text('1.e4', findRichText: true), findsNothing);
      expect(find.text('+0.31'), findsNothing);
      for (var i = 3; i < 6; i++) {
        h.worker.complete(i);
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('1…e5', findRichText: true), findsNothing);
      expect(find.text('+0.42'), findsNothing);
      await h.dispose(tester);
    },
  );

  testWidgets(
    'pending score-only update publishes with its matching SAN without another conversion',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      await h.retarget(tester, _b);
      h.evals[_b]!.emit(_second);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      final improved = _second.copyWith(
        pvs: [
          const BoardPv(evaluation: .60, mate: null, moves: 'e7e5 g1f3'),
          ..._second.pvs.skip(1),
        ],
        depth: 20,
      );
      h.evals[_b]!.emit(improved);
      await tester.pump();
      expect(find.text('+0.60'), findsNothing);
      expect(find.text('+0.31'), findsNWidgets(2));
      for (var i = 3; i < 6; i++) {
        h.worker.complete(i);
      }
      await tester.pump();
      await tester.pump();
      expect(h.worker.results, hasLength(6));
      expect(find.text('+0.60'), findsNWidgets(2));
      expect(find.text('1…e5', findRichText: true), findsOneWidget);
      expect(find.text('+0.42'), findsNothing);
      await h.dispose(tester);
    },
  );

  for (final invalid in [
    <String>[],
    ['e7e5', 'g1f3'],
  ]) {
    testWidgets('invalid SAN batch $invalid cannot replace readable rows', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      await h.retarget(tester, _b);
      h.evals[_b]!.emit(_second);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      h.worker.results[3].complete(invalid);
      h.worker.complete(4);
      h.worker.complete(5);
      await tester.pump();
      await tester.pump();
      expect(find.text('1.e4', findRichText: true), findsOneWidget);
      expect(find.text('+0.31'), findsNWidgets(2));
      expect(find.text('1…e5', findRichText: true), findsNothing);
      expect(find.text('Formatting…'), findsNothing);
      await h.dispose(tester);
    });
  }
  testWidgets(
    'continuous same-position updates do not postpone the formatting window',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      BoardEvalState changed(String moves) => _first.copyWith(
        pvs: [
          BoardPv(evaluation: .50, mate: null, moves: moves),
          ..._first.pvs.skip(1),
        ],
      );
      h.evals[_a]!.emit(changed('e2e4 c7c5'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      h.evals[_a]!.emit(changed('e2e4 e7e6'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 61));
      expect(h.worker.results, hasLength(6));
      expect(h.worker.requests[3]['moves'], 'e2e4 e7e6');
      for (var i = 3; i < 6; i++) {
        h.worker.complete(i);
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('+0.50'), findsNWidgets(2));
      await h.dispose(tester);
    },
  );

  testWidgets('late abandoned target cannot replace the newest complete set', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.firstReading(tester);
    await h.retarget(tester, _b);
    h.evals[_b]!.emit(_second);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 121));
    await h.retarget(tester, _a);
    h.evals[_a]!.emit(_first.copyWith(depth: 24));
    await tester.pump();
    // A retained reading can be reused only after a fresh A provider emits it.
    for (var i = 3; i < 6; i++) {
      h.worker.complete(i);
    }
    await tester.pump();
    await tester.pump();
    expect(find.text('1.e4', findRichText: true), findsOneWidget);
    expect(find.text('1…e5', findRichText: true), findsNothing);
    expect(find.text('+0.42'), findsNothing);
    expect(find.text('Formatting…'), findsNothing);
    await h.dispose(tester);
  });

  testWidgets(
    'failed replacement retains full snapshot and disposal rejects late work',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      await h.retarget(tester, _b);
      h.evals[_b]!.emit(_second);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      h.worker.results[3].completeError(StateError('format failure'));
      h.worker.complete(4);
      h.worker.complete(5);
      await tester.pump();
      await tester.pump();
      expect(find.text('1.e4', findRichText: true), findsOneWidget);
      expect(find.text('+0.31'), findsNWidgets(2));
      expect(find.text('+0.42'), findsNothing);
      expect(
        tester
            .widgetList<MoveHoverPreview>(find.byType(MoveHoverPreview))
            .every((p) => !p.enabled),
        isTrue,
      );
      h.evals[_b]!.emit(_second.copyWith(depth: 19));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 121));
      final pending = h.worker.results.length;
      await h.dispose(tester);
      for (var i = 6; i < pending; i++) {
        h.worker.complete(i);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'navigation keeps all formatted rows until entire new batch is ready',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.firstReading(tester);
      final rect = tester.getRect(find.byType(ListView).first);
      await h.retarget(tester, _b);
      h.evals[_b]!.emit(_second);
      await tester.pump();
      expect(find.text('Formatting…'), findsNothing);
      expect(find.text('Searching…'), findsNothing);
      expect(find.text('1.e4', findRichText: true), findsOneWidget);
      expect(find.text('+0.31'), findsNWidgets(2));
      expect(find.text('+0.42'), findsNothing);
      expect(find.text('18'), findsNothing);
      expect(tester.getRect(find.byType(ListView).first), rect);
      await tester.tap(
        find.text('1.e4', findRichText: true),
        warnIfMissed: false,
      );
      expect(h.played, isEmpty);
      await tester.pump(const Duration(milliseconds: 121));
      expect(h.worker.results, hasLength(6));
      h.worker.complete(3);
      await tester.pump();
      await tester.pump();
      expect(find.text('1.e4', findRichText: true), findsOneWidget);
      expect(find.text('1…e5', findRichText: true), findsNothing);
      expect(find.text('+0.42'), findsNothing);
      h.worker.complete(4);
      h.worker.complete(5);
      await tester.pump();
      await tester.pump();
      expect(find.text('1.e4', findRichText: true), findsNothing);
      expect(find.text('1…e5', findRichText: true), findsOneWidget);
      expect(find.text('+0.42'), findsNWidgets(2));
      expect(find.text('Formatting…'), findsNothing);
      await tester.tap(
        find.text('1…e5', findRichText: true),
        warnIfMissed: false,
      );
      expect(h.played, ['e7e5']);
      await h.dispose(tester);
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
  // The disabled production bootstrap must not inject unrelated empty states.
  @override
  set state(BoardEvalState value) {}
  void emit(BoardEvalState value) => super.state = value;
}

class _Settings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineAnalysis: true);
}
