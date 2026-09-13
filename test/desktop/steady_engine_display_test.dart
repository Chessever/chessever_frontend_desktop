import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/state/engine_display.dart';

BoardEvalState reading(double score) => BoardEvalState(
  pvs: [BoardPv(evaluation: score, mate: null, moves: 'e2e4 e7e5')],
  isEvaluating: true,
  depth: 12,
);

void main() {
  test('last-listener cancellation cannot revive the old provider owner', () {
    final container = ProviderContainer(
      overrides: [
        boardEvalProvider.overrideWith(
          (ref, fen) => BoardEvalNotifier(
            ref,
            fen,
            const BoardEvalConfig(
              enabled: false,
              searchTimeIndex: 0,
              principalVariationIndex: 0,
            ),
          ),
        ),
      ],
    );
    const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final first = container.listen(boardEvalProvider(fen), (_, _) {});
    final oldOwner = container.read(boardEvalProvider(fen).notifier);
    first.close();
    final second = container.listen(boardEvalProvider(fen), (_, _) {});
    expect(
      container.read(boardEvalProvider(fen).notifier),
      isNot(same(oldOwner)),
    );
    expect(second.read().pvs, isEmpty);
    second.close();
    container.dispose();
  });
  test('A-B-A retains a whole readout but never promotes it to current', () {
    final display = EngineDisplay();
    final a = reading(0.3);
    const loading = BoardEvalState.evaluating();
    expect(display.update('A', a, enabled: true), same(a));
    expect(display.isCurrent('A', a), isTrue);
    expect(display.update('B', loading, enabled: true), same(a));
    expect(display.isCurrent('B', loading), isFalse);
    expect(display.update('A', loading, enabled: true), same(a));
    expect(display.isCurrent('A', loading), isFalse);
    expect(loading.evaluation, isNull); // no persistence/provenance leakage
    expect(loading.pvs, isEmpty); // no arrows, keyboard insertion or PV play
    final fresh = reading(-0.2);
    expect(display.update('A', fresh, enabled: true), same(fresh));
    expect(display.isCurrent('A', fresh), isTrue);
  });
  test('terminal, off and failure clear rather than retain', () {
    for (final end in [
      const BoardEvalState.terminal(evaluation: 0, statusText: 'Draw'),
      const BoardEvalState(pvs: [], isEvaluating: false, depth: 0),
    ]) {
      final display = EngineDisplay();
      display.update('A', reading(1), enabled: true);
      expect(display.update('B', end, enabled: true), same(end));
      expect(display.reading, isNull);
      expect(
        display
            .update('C', const BoardEvalState.evaluating(), enabled: true)
            .evaluation,
        isNull,
      );
    }
    final display = EngineDisplay();
    display.update('A', reading(1), enabled: true);
    display.update('A', const BoardEvalState.evaluating(), enabled: false);
    expect(display.reading, isNull);
  });
  test('retained tabs never share display caches', () {
    final first = EngineDisplay();
    final second = EngineDisplay();
    first.update('A', reading(2), enabled: true);
    expect(
      second
          .update('B', const BoardEvalState.evaluating(), enabled: true)
          .evaluation,
      isNull,
    );
    first.clear();
    expect(first.fen, isNull);
  });
}
