import 'dart:async';

import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const fen = '1r4k1/p5pp/4p3/8/2p5/2q2B2/Q6P/K2R1R2 w - - 2 34';

class _Engine implements Stockfish {
  final output = StreamController<String>.broadcast();
  final commands = <String>[];
  @override
  final ValueNotifier<StockfishState> state = ValueNotifier<StockfishState>(
    StockfishState.ready,
  );
  @override
  Stream<String> get stdout => output.stream;
  @override
  set stdin(String command) {
    commands.add(command);
    if (command == 'isready') output.add('readyok');
  }

  @override
  void dispose() => state.value = StockfishState.disposed;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a finite cached result cannot satisfy a new infinite request',
    () async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final finite = singleton.evaluatePosition(
        fen,
        depth: 50,
        multiPV: 1,
        ownerId: 'mode',
        completePvBatches: true,
      );
      await pumpEventQueue();
      engine.output.add('info depth 12 multipv 1 score mate -1 pv a2b2 c3b2');
      engine.output.add('bestmove a2b2');
      await finite;
      await pumpEventQueue();
      final infinite = singleton.evaluatePosition(
        fen,
        depth: 50,
        multiPV: 1,
        ownerId: 'mode',
        infiniteSearch: true,
        completePvBatches: true,
      );
      await pumpEventQueue();
      expect(engine.commands.where((c) => c.startsWith('go ')), [
        'go depth 50',
        'go infinite',
      ]);
      final cancel = singleton.cancelEvaluationsForOwner('mode');
      await pumpEventQueue();
      engine.output.add('bestmove a2b2');
      await cancel;
      expect((await infinite).isCancelled, isTrue);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );

  test(
    'engine error state settles continuous analysis even without stdout closing',
    () async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final future = singleton.evaluatePosition(
        fen,
        multiPV: 1,
        ownerId: 'error',
        infiniteSearch: true,
      );
      await pumpEventQueue();
      engine.state.value = StockfishState.error;
      final result = await future.timeout(const Duration(seconds: 2));
      expect(result.isCancelled, isTrue);
      await singleton.disposeAsync();
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );

  test(
    'rapid infinite A to B to A drains old search and ignores obsolete output',
    () async {
      const a = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      var generation = 1;
      final first = singleton.evaluatePosition(
        a,
        ownerId: 'old',
        multiPV: 1,
        isCurrentPosition: true,
        infiniteSearch: true,
        isRequestCurrent: () => generation == 1,
      );
      await pumpEventQueue();
      generation = 2;
      final second = singleton.evaluatePosition(
        b,
        ownerId: 'B',
        multiPV: 1,
        isCurrentPosition: true,
        infiniteSearch: true,
        isRequestCurrent: () => generation == 2,
      );
      await pumpEventQueue();
      generation = 3;
      final scores = <int>[];
      final third = singleton.evaluatePosition(
        a,
        ownerId: 'new',
        multiPV: 1,
        isCurrentPosition: true,
        infiniteSearch: true,
        completePvBatches: true,
        isRequestCurrent: () => generation == 3,
        onPvUpdate: (pvs, _) => scores.add(pvs.single.cp),
      );
      engine.output.add('readyok');
      engine.output.add('info depth 30 multipv 1 score cp 999 pv e2e4');
      await pumpEventQueue();
      expect(engine.commands.where((c) => c.startsWith('go ')), hasLength(1));
      engine.output.add('bestmove e2e4');
      await pumpEventQueue();
      expect((await first).isCancelled, isTrue);
      expect((await second).isCancelled, isTrue);
      expect(engine.commands.where((c) => c == 'position fen $b'), isEmpty);
      expect(engine.commands.where((c) => c == 'go infinite'), hasLength(2));
      engine.output.add('info depth 8 multipv 1 score cp 21 pv d2d4');
      await pumpEventQueue();
      expect(scores, [21]);
      final cancel = singleton.cancelEvaluationsForOwner('new');
      await pumpEventQueue();
      engine.output.add('bestmove d2d4');
      await cancel;
      expect((await third).isCancelled, isTrue);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );

  test('ordinary report requests keep depth and timed limits', () async {
    for (final duration in <Duration?>[
      null,
      const Duration(milliseconds: 20),
    ]) {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final future = singleton.evaluatePosition(
        fen,
        depth: 12,
        maxDepth: 12,
        multiPV: 1,
        searchDuration: duration,
        ownerId: 'finite',
      );
      await pumpEventQueue();
      expect(
        engine.commands,
        contains(duration == null ? 'go depth 12' : 'go movetime 20 depth 12'),
      );
      expect(engine.commands, isNot(contains('go infinite')));
      engine.output.add('info depth 12 multipv 1 score mate -1 pv a2b2 c3b2');
      engine.output.add('bestmove a2b2 ponder c3b2');
      expect((await future).depth, 12);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    }
  });

  test(
    'a quiet infinite search is not stopped by the finite stall detector',
    () async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      var ended = false;
      final future = singleton.evaluatePosition(
        fen,
        depth: 15,
        multiPV: 1,
        infiniteSearch: true,
        ownerId: 'silent',
        completePvBatches: true,
      );
      future.then((_) => ended = true);
      await pumpEventQueue();
      engine.output.add('info depth 12 multipv 1 score mate -1 pv a2b2 c3b2');
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      final prematurelyEnded = ended;
      final prematurelyStopped = engine.commands.contains('stop');
      final cancelled = singleton.cancelEvaluationsForOwner('silent');
      await pumpEventQueue();
      engine.output.add('bestmove a2b2');
      await cancelled;
      await future;
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
      expect(prematurelyEnded, isFalse);
      expect(prematurelyStopped, isFalse);
    },
  );

  test(
    'closing engine output settles an infinite request rather than hanging forever',
    () async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      var ended = false;
      final future = singleton.evaluatePosition(
        fen,
        multiPV: 1,
        infiniteSearch: true,
        ownerId: 'closed-output',
      );
      future.then((_) => ended = true);
      await pumpEventQueue();
      await engine.output.close();
      await pumpEventQueue();
      final observedTermination = ended;
      await singleton.cancelEvaluationsForOwner('closed-output');
      await future;
      await singleton.disposeAsync();
      engine.state.dispose();
      expect(observedTermination, isTrue);
    },
  );

  testWidgets(
    'infinite analysis is not ended by the finite ten-minute safety timer',
    (tester) async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      var finished = false;
      final future = singleton.evaluatePosition(
        fen,
        depth: 50,
        multiPV: 1,
        infiniteSearch: true,
        completePvBatches: true,
        ownerId: 'quiet',
      );
      future.then((_) => finished = true);
      await tester.pump();
      await tester.pump();
      expect(engine.commands, contains('go infinite'));
      engine.output.add('info depth 12 multipv 1 score mate -1 pv a2b2 c3b2');
      await tester.pump();
      await tester.pump(const Duration(minutes: 11));
      final endedBeforeStop = finished;
      final stoppedBeforeUser = engine.commands.contains('stop');
      engine.output.add('bestmove a2b2 ponder c3b2');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await engine.output.close();
      engine.state.dispose();
      expect(endedBeforeStop, isFalse);
      expect(stoppedBeforeUser, isFalse);
      expect(finished, isTrue);
    },
  );

  test(
    'explicit infinite analysis sends go infinite and remains cancellable',
    () async {
      final engine = _Engine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final future = singleton.evaluatePosition(
        fen,
        depth: 50,
        multiPV: 3,
        infiniteSearch: true,
        isCurrentPosition: true,
        completePvBatches: true,
        ownerId: 'continuous',
      );
      await pumpEventQueue();
      final startedCommands = List<String>.of(engine.commands);
      final cancelled = singleton.cancelEvaluationsForOwner('continuous');
      await pumpEventQueue();
      engine.output.add('bestmove a2b2 ponder c3b2');
      await cancelled;
      expect((await future).isCancelled, isTrue);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
      expect(startedCommands, contains('go infinite'));
      expect(startedCommands.where((c) => c.startsWith('go depth')), isEmpty);
    },
  );
}
