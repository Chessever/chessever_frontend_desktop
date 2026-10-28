import 'dart:async';

import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const forcedReplyFen = '1r4k1/p5pp/4p3/8/2p5/2q2B2/Q6P/K2R1R2 w - - 2 34';

class TestEngine implements Stockfish {
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

  Future<void> close() async {
    await output.close();
    state.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'two legal roots wait for both ranks, not all requested ranks',
    () async {
      final engine = TestEngine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final observed = <int>[];
      final future = singleton.evaluatePosition(
        'k7/8/8/8/8/8/7r/6K1 w - - 0 1',
        multiPV: 5,
        ownerId: 'two-replies',
        completePvBatches: true,
        onPvUpdate: (pvs, _) => observed.add(pvs.length),
      );
      await pumpEventQueue();
      engine.output.add('info depth 8 multipv 1 score cp -200 pv g1f1');
      await pumpEventQueue();
      expect(observed, isEmpty);
      engine.output.add('info depth 8 multipv 2 score cp 0 pv g1h2');
      engine.output.add('bestmove g1f1');
      final result = await future;
      await pumpEventQueue();
      await engine.close();
      expect(result.pvs, hasLength(2));
      expect(result.requestedMultiPv, 2);
      expect(observed, [2]);
    },
  );

  test(
    'the reported forced reply publishes a valid mate line with three requested PVs',
    () async {
      final engine = TestEngine();
      final singleton = StockfishSingleton.withEngineForTesting(engine);
      final observed = <int>[];
      final future = singleton.evaluatePosition(
        forcedReplyFen,
        multiPV: 3,
        ownerId: 'forced-reply',
        completePvBatches: true,
        onPvUpdate: (pvs, _) => observed.add(pvs.length),
      );
      await pumpEventQueue();
      expect(engine.commands.where((c) => c.startsWith('go ')), isNotEmpty);
      engine.output.add(
        'info depth 12 seldepth 3 multipv 1 score mate -1 nodes 25 time 1 pv a2b2 c3b2',
      );
      engine.output.add('bestmove a2b2 ponder c3b2');
      final result = await future;
      await pumpEventQueue();
      await engine.close();
      expect(result.pvs.where((pv) => pv.moves.isNotEmpty), hasLength(1));
      expect(result.pvs.single.moves, 'a2b2 c3b2');
      expect(result.pvs.single.mate, -1);
      expect(result.requestedMultiPv, 1);
      expect(observed, [1]);
    },
  );
}
