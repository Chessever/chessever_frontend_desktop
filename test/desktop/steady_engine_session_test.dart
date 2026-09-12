import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';

const a = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test(
    'off cancellation cannot erase a newer on request during stop',
    () async {
      final engine = _Transport();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final first = singleton.evaluatePosition(a, ownerId: 'old', multiPV: 1);
      await pumpEventQueue();
      final off = singleton.cancelAllEvaluations();
      final offAgain = singleton.cancelAllEvaluations();
      final next = singleton.evaluatePosition(b, ownerId: 'new', multiPV: 1);
      engine.output.add('readyok');
      await pumpEventQueue();
      expect(engine.searches, 1);
      engine.output.add('bestmove e2e4');
      await Future.wait([off, offAgain]);
      await pumpEventQueue();
      expect((await first).isCancelled, isTrue);
      expect(engine.searches, 2);
      engine.output.add('info depth 6 multipv 1 score cp 15 pv e7e5');
      engine.output.add('bestmove e7e5');
      expect((await next).isCancelled, isFalse);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );
  test(
    'readyok cannot start the next search; superseded queued B cannot beat return to A',
    () async {
      final engine = _Transport();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      var generation = 1;
      final first = singleton.evaluatePosition(
        a,
        ownerId: 'first',
        isCurrentPosition: true,
        isRequestCurrent: () => generation == 1,
        multiPV: 1,
      );
      await pumpEventQueue();
      expect(engine.searches, 1);
      generation = 2;
      final second = singleton.evaluatePosition(
        b,
        ownerId: 'second',
        isCurrentPosition: true,
        isRequestCurrent: () => generation == 2,
        multiPV: 1,
      );
      await pumpEventQueue();
      generation = 3;
      final third = singleton.evaluatePosition(
        a,
        ownerId: 'third',
        isCurrentPosition: true,
        isRequestCurrent: () => generation == 3,
        multiPV: 1,
        completePvBatches: true,
      );
      engine.output.add('readyok');
      engine.output.add('info depth 30 multipv 1 score cp 999 pv e2e4');
      await pumpEventQueue();
      expect(engine.searches, 1);
      engine.output.add('bestmove e2e4');
      await pumpEventQueue();
      expect((await first).isCancelled, isTrue);
      expect((await second).isCancelled, isTrue);
      expect(engine.searches, 2);
      expect(engine.commands.where((c) => c == 'position fen $b'), isEmpty);
      engine.output.add('info depth 8 multipv 1 score cp 21 pv d2d4');
      engine.output.add('bestmove d2d4');
      final result = await third;
      expect(result.depth, 8);
      expect(result.pvs.single.cp, 21);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );

  test(
    'complete PV callback and final result never expose an unfinished iteration',
    () async {
      final engine = _Transport();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final seen = <String>[];
      final result = singleton.evaluatePosition(
        a,
        ownerId: 'batch',
        multiPV: 2,
        completePvBatches: true,
        onPvUpdate:
            (pvs, depth) => seen.add('$depth:${pvs.length}:${pvs.first.cp}'),
      );
      await pumpEventQueue();
      engine.output.add('info depth 8 multipv 1 score cp 30 pv e2e4');
      await pumpEventQueue();
      expect(seen, isEmpty);
      engine.output.add('info depth 8 multipv 2 score cp 20 pv d2d4');
      engine.output.add('info depth 9 multipv 1 score cp 60 pv c2c4');
      engine.output.add('bestmove c2c4');
      final complete = await result;
      expect(seen, ['8:2:30']);
      expect(complete.depth, 8);
      expect(complete.pvs.first.cp, 30);
      await pumpEventQueue();
      await engine.output.close();
      engine.state.dispose();
    },
  );

  testWidgets('a stop timeout retires its process and ignores late info', (
    tester,
  ) async {
    final engine = _Transport();
    final singleton = StockfishSingleton.withEngineForTesting(engine);
    var updates = 0;
    final result = singleton.evaluatePosition(
      a,
      ownerId: 'timeout',
      multiPV: 1,
      onPvUpdate: (_, _) => updates++,
    );
    await tester.pump();
    await tester.pump();
    final cancel = singleton.cancelEvaluationsForOwner('timeout');
    await tester.pump(const Duration(milliseconds: 801));
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump(const Duration(milliseconds: 101));
    await cancel;
    expect(engine.disposed, isTrue);
    engine.output.add('info depth 40 multipv 1 score cp 500 pv e2e4');
    engine.output.add('bestmove e2e4');
    await tester.pump();
    expect((await result).isCancelled, isTrue);
    expect(updates, 0);
    await engine.output.close();
    engine.state.dispose();
  });
}

class _Transport implements Stockfish {
  final output = StreamController<String>.broadcast();
  final commands = <String>[];
  bool disposed = false;
  int get searches => commands.where((c) => c.startsWith('go ')).length;
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
  void dispose() {
    disposed = true;
    state.value = StockfishState.disposed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
