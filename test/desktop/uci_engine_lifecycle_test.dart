import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';

void main() {
  setUp(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  tearDown(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  test('dispose sends quit and awaits graceful process exit', () async {
    final events = <String>[];
    final process = _FakeProcess(events: events, exitOnQuit: true);
    final engine = UciEngine.fromProcessForTesting(
      process,
      gracefulExitTimeout: const Duration(milliseconds: 20),
    );
    final outputClosed = Completer<void>();
    engine.lines.listen(null, onDone: outputClosed.complete);

    await engine.dispose();

    expect(process.commands, <String>['stop', 'quit']);
    expect(process.killCount, 0);
    expect(events.indexOf('exit'), lessThan(events.indexOf('stdout-cancel')));
    expect(events.indexOf('exit'), lessThan(events.indexOf('stderr-cancel')));
    await outputClosed.future;
    expect(UciEngine.liveEngineCountForTesting, 0);
  });

  test('dispose force kills after the graceful exit timeout', () async {
    final events = <String>[];
    final process = _FakeProcess(events: events, exitOnQuit: false);
    final engine = UciEngine.fromProcessForTesting(
      process,
      gracefulExitTimeout: const Duration(milliseconds: 5),
    );

    await engine.dispose();

    expect(process.commands, <String>['stop', 'quit']);
    expect(process.killCount, 1);
    expect(events, containsAllInOrder(<String>['kill', 'exit']));
    expect(events.indexOf('exit'), lessThan(events.indexOf('stdout-cancel')));
    expect(events.indexOf('exit'), lessThan(events.indexOf('stderr-cancel')));
  });

  test('post-kill disposal still awaits the native exit callback', () async {
    final events = <String>[];
    final process = _FakeProcess(
      events: events,
      exitOnQuit: false,
      exitOnKill: false,
    );
    final engine = UciEngine.fromProcessForTesting(
      process,
      gracefulExitTimeout: const Duration(milliseconds: 5),
    );

    final disposal = engine.dispose();
    var disposalCompleted = false;
    unawaited(disposal.then((_) => disposalCompleted = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(process.commands, <String>['stop', 'quit']);
    expect(process.killCount, 1);
    expect(events, isNot(contains('exit')));
    expect(events, isNot(contains('stdout-cancel')));
    expect(events, isNot(contains('stderr-cancel')));
    expect(disposalCompleted, isFalse);

    process.completeExit(-1);
    await disposal;

    expect(events.indexOf('exit'), lessThan(events.indexOf('stdout-cancel')));
    expect(events.indexOf('exit'), lessThan(events.indexOf('stderr-cancel')));
  });

  test('concurrent dispose calls share one teardown', () async {
    final process = _FakeProcess(events: <String>[], exitOnQuit: true);
    final engine = UciEngine.fromProcessForTesting(
      process,
      gracefulExitTimeout: const Duration(milliseconds: 20),
    );

    final first = engine.dispose();
    final second = engine.dispose();

    expect(identical(first, second), isTrue);
    await Future.wait(<Future<void>>[first, second]);
    expect(identical(first, engine.dispose()), isTrue);
    expect(process.commands, <String>['stop', 'quit']);
    expect(process.killCount, 0);
  });

  test('disposeAll awaits every live engine', () async {
    final firstProcess = _FakeProcess(events: <String>[], exitOnQuit: true);
    final secondProcess = _FakeProcess(events: <String>[], exitOnQuit: true);
    UciEngine.fromProcessForTesting(firstProcess);
    UciEngine.fromProcessForTesting(secondProcess);

    expect(UciEngine.liveEngineCountForTesting, 2);

    final firstDisposeAll = UciEngine.disposeAll();
    final secondDisposeAll = UciEngine.disposeAll();
    await Future.wait(<Future<void>>[firstDisposeAll, secondDisposeAll]);

    expect(firstProcess.commands, <String>['stop', 'quit']);
    expect(secondProcess.commands, <String>['stop', 'quit']);
    expect(UciEngine.liveEngineCountForTesting, 0);
  });

  test('disposeAll drains a Process.start already in flight', () async {
    final processStarted = Completer<Process>();
    final process = _FakeProcess(events: <String>[], exitOnQuit: true);
    final spawn = UciEngine.spawnForTesting(
      () => processStarted.future,
      gracefulExitTimeout: const Duration(milliseconds: 20),
    );
    final spawnExpectation = expectLater(spawn, throwsA(isA<StateError>()));

    expect(UciEngine.inFlightSpawnCountForTesting, 1);
    final disposeAll = UciEngine.disposeAll();
    var shutdownCompleted = false;
    disposeAll.then((_) => shutdownCompleted = true);
    await pumpEventQueue();
    expect(shutdownCompleted, isFalse);

    processStarted.complete(process);
    await spawnExpectation;
    await disposeAll;

    expect(process.commands, <String>['stop', 'quit']);
    expect(UciEngine.inFlightSpawnCountForTesting, 0);
    expect(UciEngine.liveEngineCountForTesting, 0);
  });

  test('shutdown gate blocks new spawns until explicitly resumed', () async {
    await UciEngine.disposeAll();
    var processStarterCalled = false;

    await expectLater(
      UciEngine.spawnForTesting(() {
        processStarterCalled = true;
        return Future<Process>.value(
          _FakeProcess(events: <String>[], exitOnQuit: true),
        );
      }),
      throwsA(isA<StateError>()),
    );
    expect(processStarterCalled, isFalse);

    UciEngine.resumeSpawns();
    final process = _FakeProcess(events: <String>[], exitOnQuit: true);
    final engine = await UciEngine.spawnForTesting(
      () => Future<Process>.value(process),
    );
    await engine.dispose();

    expect(process.commands, <String>['stop', 'quit']);
  });

  test('disposeAll drains a PATH discovery child process', () async {
    final lookupResult = Completer<ProcessResult>();
    final lookup = UciEngine.runPathLookupForTesting(() => lookupResult.future);
    expect(UciEngine.inFlightSpawnCountForTesting, 1);

    final drain = UciEngine.disposeAll();
    var drainCompleted = false;
    unawaited(drain.then((_) => drainCompleted = true));
    await pumpEventQueue();
    expect(drainCompleted, isFalse);

    lookupResult.complete(ProcessResult(42, 0, 'stockfish.exe', ''));
    await lookup;
    await drain;

    expect(UciEngine.inFlightSpawnCountForTesting, 0);
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);
  });

  test('PATH discovery cannot start while shutdown is suspended', () async {
    await UciEngine.disposeAll();
    var processRunnerCalled = false;

    await expectLater(
      UciEngine.runPathLookupForTesting(() {
        processRunnerCalled = true;
        return Future<ProcessResult>.value(ProcessResult(42, 0, '', ''));
      }),
      throwsA(isA<StateError>()),
    );

    expect(processRunnerCalled, isFalse);
  });

  test('resume cannot reopen spawning during an active drain', () async {
    final process = _FakeProcess(
      events: <String>[],
      exitOnQuit: false,
      exitOnKill: false,
    );
    UciEngine.fromProcessForTesting(
      process,
      gracefulExitTimeout: const Duration(milliseconds: 5),
    );

    final drain = UciEngine.disposeAll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(process.killCount, 1);

    UciEngine.resumeSpawns();
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);

    process.completeExit(-1);
    await drain;
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);

    UciEngine.resumeSpawns();
    expect(UciEngine.spawnsSuspendedForTesting, isFalse);
  });
}

class _FakeProcess implements Process {
  _FakeProcess({
    required this.events,
    required this.exitOnQuit,
    this.exitOnKill = true,
  }) {
    _stdinConsumer = _RecordingConsumer(
      onLine: (line) {
        commands.add(line);
        events.add('stdin:$line');
        if (line == 'quit' && exitOnQuit) {
          completeExit(0);
        }
      },
      onClose: () => events.add('stdin-close'),
    );
    _stdin = IOSink(_stdinConsumer);
    _stdout = StreamController<List<int>>(
      onCancel: () => events.add('stdout-cancel'),
    );
    _stderr = StreamController<List<int>>(
      onCancel: () => events.add('stderr-cancel'),
    );
  }

  final List<String> events;
  final bool exitOnQuit;
  final bool exitOnKill;
  final List<String> commands = <String>[];
  final Completer<int> _exit = Completer<int>();
  late final _RecordingConsumer _stdinConsumer;
  late final IOSink _stdin;
  late final StreamController<List<int>> _stdout;
  late final StreamController<List<int>> _stderr;
  int killCount = 0;

  void completeExit(int code) {
    if (_exit.isCompleted) return;
    events.add('exit');
    _exit.complete(code);
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
    killCount += 1;
    events.add('kill');
    if (exitOnKill) completeExit(-1);
    return true;
  }
}

class _RecordingConsumer implements StreamConsumer<List<int>> {
  _RecordingConsumer({required this.onLine, required this.onClose});

  final void Function(String line) onLine;
  final void Function() onClose;
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
  Future<void> close() async {
    onClose();
  }
}
