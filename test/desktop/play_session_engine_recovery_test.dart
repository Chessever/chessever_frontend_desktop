import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';

void main() {
  setUp(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  tearDown(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  test('engine reconnect preserves the live game and clock state', () async {
    var spawnCount = 0;
    final process = _HandshakeProcess();
    final notifier = PlaySessionNotifier(
      config: PlayConfig.defaults.copyWith(
        color: PlayColorChoice.white,
        startClockImmediately: true,
        startingMovesUci: const <String>['e2e4', 'e7e5'],
      ),
      engineBinaryPath: 'test-engine',
      botIdentity: _testBot,
      bootEngine: false,
      spawnEngine: () async {
        spawnCount += 1;
        return UciEngine.fromProcessForTesting(
          process,
          gracefulExitTimeout: const Duration(milliseconds: 20),
        );
      },
    );
    addTearDown(notifier.dispose);
    final before = notifier.state;

    await notifier.reconnectEngineAfterExternalDrain();

    expect(spawnCount, 1);
    expect(notifier.state.position.fen, before.position.fen);
    expect(notifier.state.history, before.history);
    expect(notifier.state.whiteMillis, before.whiteMillis);
    expect(notifier.state.blackMillis, before.blackMillis);
    expect(notifier.state.activeClock, before.activeClock);
    expect(notifier.state.lastClockTick, before.lastClockTick);
    expect(notifier.state.engineReady, isTrue);
  });

  test(
    'a boot completed after reconnect cannot replace the new engine',
    () async {
      final firstSpawn = Completer<UciEngine>();
      final staleProcess = _HandshakeProcess();
      final replacementProcess = _HandshakeProcess();
      var spawnCount = 0;
      final notifier = PlaySessionNotifier(
        config: PlayConfig.defaults.copyWith(color: PlayColorChoice.white),
        engineBinaryPath: 'test-engine',
        botIdentity: _testBot,
        spawnEngine: () {
          spawnCount += 1;
          if (spawnCount == 1) return firstSpawn.future;
          return Future<UciEngine>.value(
            UciEngine.fromProcessForTesting(
              replacementProcess,
              gracefulExitTimeout: const Duration(milliseconds: 20),
            ),
          );
        },
      );
      addTearDown(notifier.dispose);
      await pumpEventQueue();
      expect(spawnCount, 1);

      await notifier.reconnectEngineAfterExternalDrain();
      expect(spawnCount, 2);
      expect(notifier.state.engineReady, isTrue);

      firstSpawn.complete(
        UciEngine.fromProcessForTesting(
          staleProcess,
          gracefulExitTimeout: const Duration(milliseconds: 20),
        ),
      );
      await pumpEventQueue();

      expect(
        staleProcess.commands,
        containsAllInOrder(<String>['stop', 'quit']),
      );
      expect(replacementProcess.commands, isNot(contains('quit')));
      expect(notifier.state.engineReady, isTrue);
    },
  );
}

const _testBot = BotIdentity(
  firstName: 'Test',
  lastName: 'Bot',
  countryCode: 'US',
  elo: 1500,
);

class _HandshakeProcess implements Process {
  _HandshakeProcess() {
    _stdout = StreamController<List<int>>();
    _stderr = StreamController<List<int>>();
    _stdin = IOSink(
      _LineConsumer(
        onLine: (line) {
          commands.add(line);
          if (line == 'uci') _emit('uciok');
          if (line == 'isready') _emit('readyok');
          if (line == 'quit') _completeExit(0);
        },
      ),
    );
  }

  final List<String> commands = <String>[];
  final Completer<int> _exit = Completer<int>();
  late final IOSink _stdin;
  late final StreamController<List<int>> _stdout;
  late final StreamController<List<int>> _stderr;

  void _emit(String line) {
    if (!_stdout.isClosed) _stdout.add(utf8.encode('$line\n'));
  }

  void _completeExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 42;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _completeExit(-1);
    return true;
  }
}

class _LineConsumer implements StreamConsumer<List<int>> {
  _LineConsumer({required this.onLine});

  final void Function(String line) onLine;
  String _pending = '';

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      _pending += utf8.decode(bytes);
      while (_pending.contains('\n')) {
        final newline = _pending.indexOf('\n');
        final line = _pending.substring(0, newline).replaceAll('\r', '');
        _pending = _pending.substring(newline + 1);
        onLine(line);
      }
    }
  }

  @override
  Future<void> close() async {}
}
