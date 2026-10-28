import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeTransport implements Stockfish {
  _NativeTransport(this.driver);
  final UciEngine driver;
  final commands = <String>[];
  @override
  final ValueNotifier<StockfishState> state = ValueNotifier<StockfishState>(
    StockfishState.ready,
  );
  @override
  Stream<String> get stdout => driver.lines;
  @override
  set stdin(String command) {
    commands.add(command);
    driver.send(command);
  }

  @override
  void dispose() {
    state.value = StockfishState.disposed;
    unawaited(driver.dispose());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binary = Platform.environment['CHESSEVER_ENGINE_QA_BINARY'];
  test(
    'real Stockfish retains the forced-mate PV in finite and stoppable infinite searches',
    () async {
      final driver = await UciEngine.spawn(binary!);
      final transport = _NativeTransport(driver);
      final singleton = StockfishSingleton.withEngineForTesting(transport);
      const fen = '1r4k1/p5pp/4p3/8/2p5/2q2B2/Q6P/K2R1R2 w - - 2 34';
      try {
        final initialized = driver.lines.firstWhere((line) => line == 'uciok');
        driver.send('uci');
        await initialized.timeout(const Duration(seconds: 5));
        driver.send('setoption name Threads value 1');
        driver.send('setoption name Hash value 16');
        final ready = driver.lines.firstWhere((line) => line == 'readyok');
        driver.send('isready');
        await ready.timeout(const Duration(seconds: 5));
        final finite = await singleton
            .evaluatePosition(
              fen,
              depth: 12,
              multiPV: 3,
              completePvBatches: true,
              ownerId: 'native-finite',
            )
            .timeout(const Duration(seconds: 5));
        expect(finite.depth, 12);
        expect(finite.pvs.single.moves, 'a2b2 c3b2');
        expect(finite.pvs.single.mate, -1);
        final firstReading = Completer<void>();
        var ended = false;
        final continuous = singleton.evaluatePosition(
          fen,
          depth: 15,
          multiPV: 3,
          infiniteSearch: true,
          completePvBatches: true,
          ownerId: 'native-infinite',
          onPvUpdate: (pvs, _) {
            expect(pvs.single.moves, startsWith('a2b2'));
            if (!firstReading.isCompleted) firstReading.complete();
          },
        );
        continuous.then((_) => ended = true);
        await firstReading.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        expect(ended, isFalse);
        expect(transport.commands, contains('go infinite'));
        await singleton.cancelEvaluationsForOwner('native-infinite');
        expect((await continuous).isCancelled, isTrue);
      } finally {
        await singleton.disposeAsync();
        await driver.dispose();
        transport.state.dispose();
      }
      expect(UciEngine.liveEngineCountForTesting, 0);
    },
    skip: binary == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
