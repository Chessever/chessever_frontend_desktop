import 'dart:async';

import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Black to move after 1.e4.
const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

// searchTimeIndex 5 is the "∞" setting; one line keeps the batches simple.
const _infinite = BoardEvalConfig(
  enabled: true,
  searchTimeIndex: 5,
  principalVariationIndex: 0,
);

const _timed = BoardEvalConfig(
  enabled: true,
  searchTimeIndex: 1,
  principalVariationIndex: 0,
);

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
    if (command == 'stop') output.add('bestmove e7e5');
  }

  List<String> get searches =>
      commands.where((c) => c.startsWith('go ')).toList();
  int get stops => commands.where((c) => c == 'stop').length;

  @override
  void dispose() => state.value = StockfishState.disposed;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lets queued engine output and the provider's 80 ms UI throttle drain.
Future<void> _settle() async {
  await pumpEventQueue();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await pumpEventQueue();
}

({
  _Engine engine,
  ProviderContainer container,
  ProviderSubscription<BoardEvalState> eval,
  LiveGameStreamingLifecycleController lifecycle,
})
_harness(BoardEvalConfig config) {
  final engine = _Engine();
  final stockfish = StockfishSingleton.withEngineForTesting(engine);
  final container = ProviderContainer(
    overrides: [
      boardEvalProvider.overrideWith(
        (ref, fen) => BoardEvalNotifier(ref, fen, config, stockfish: stockfish),
      ),
    ],
  );
  final eval = container.listen<BoardEvalState>(
    boardEvalProvider(_fen),
    (_, _) {},
    fireImmediately: true,
  );
  // The board pane also watches the window signal; keep it alive like it does.
  final window = container.listen<bool>(
    liveGameStreamingLifecycleProvider,
    (_, _) {},
  );
  final lifecycle = container.read(liveGameStreamingLifecycleProvider.notifier);
  addTearDown(() async {
    window.close();
    eval.close();
    container.dispose();
    await _settle();
    await engine.output.close();
    engine.state.dispose();
  });
  return (
    engine: engine,
    container: container,
    eval: eval,
    lifecycle: lifecycle,
  );
}

void main() {
  test(
    'infinite analysis pauses while the window is hidden and resumes on the '
    'same engine when it is visible again; focus loss keeps it running',
    () async {
      final h = _harness(_infinite);
      await _settle();
      expect(h.engine.searches, ['go infinite']);

      h.engine.output.add('info depth 24 multipv 1 score cp 31 pv e7e5 g1f3');
      await _settle();
      expect(h.eval.read().pvs.single.moves, 'e7e5 g1f3');

      // Looking at another app only takes focus away: keep analysing.
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await _settle();
      expect(h.engine.stops, 0);

      // Minimised or hidden: stop the search, keep the last reading.
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await _settle();
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _settle();
      expect(h.engine.stops, 1);
      expect(h.engine.searches, hasLength(1));
      expect(h.eval.read().isEvaluating, isFalse);
      expect(h.eval.read().pvs.single.moves, 'e7e5 g1f3');
      expect(h.eval.read().depth, 24);

      // Visible again (macOS restores through hidden -> inactive -> resumed):
      // exactly one new search on the same engine, nothing respawned.
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await _settle();
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await _settle();
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _settle();
      expect(h.engine.searches, ['go infinite', 'go infinite']);
      expect(h.engine.state.value, StockfishState.ready);
      expect(h.engine.commands, isNot(contains('quit')));
      expect(h.eval.read().isEvaluating, isTrue);

      // The resumed search re-climbs through shallow depths; those must not
      // replace the deeper reading the user already had on screen.
      h.engine.output.add('info depth 6 multipv 1 score cp 12 pv d7d5');
      await _settle();
      expect(h.eval.read().pvs.single.moves, 'e7e5 g1f3');
      expect(h.eval.read().depth, 24);

      h.engine.output.add(
        'info depth 25 multipv 1 score cp 33 pv e7e5 g1f3 b8c6',
      );
      await _settle();
      expect(h.eval.read().pvs.single.moves, 'e7e5 g1f3 b8c6');
      expect(h.eval.read().depth, 25);
    },
  );

  test(
    'a board opened while the window is hidden waits until it is visible',
    () async {
      final h = _harness(_infinite);
      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await _settle();
      expect(h.engine.searches, isEmpty);

      h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _settle();
      expect(h.engine.searches, ['go infinite']);
    },
  );

  test('a timed search is left to finish on its own while hidden', () async {
    final h = _harness(_timed);
    await _settle();
    expect(h.engine.searches, hasLength(1));
    expect(h.engine.searches.single, startsWith('go movetime'));

    h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await _settle();
    expect(h.engine.stops, 0);

    h.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _settle();
    expect(h.engine.searches, hasLength(1));
  });
}
