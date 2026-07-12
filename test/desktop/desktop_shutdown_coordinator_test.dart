import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_shutdown_coordinator.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(UciEngine.resumeSpawns);
  tearDown(UciEngine.resumeSpawns);

  test(
    'Windows native close keeps the provider container alive and stays single-flight',
    () async {
      final events = <String>[];
      final closeStarted = Completer<void>();
      final allowCloseToFinish = Completer<void>();
      final window = _FakeShutdownWindowController(
        isWindows: true,
        events: events,
        onClose: () async {
          closeStarted.complete();
          await allowCloseToFinish.future;
        },
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final providerProbe = Provider<int>((ref) => 42);
      final coordinator = DesktopShutdownCoordinator(
        container,
        windowController: window,
        cancelPlayerOperations: () async => events.add('cancel-players'),
        stopTournamentServer: () async => events.add('stop-server'),
        disposeEngineProcesses: () async => events.add('dispose-engines'),
      );

      await coordinator.start();
      events.clear();

      final firstShutdown = coordinator.onWindowClose();
      await closeStarted.future;
      final overlappingShutdown = coordinator.onWindowClose();
      var overlappingCompleted = false;
      unawaited(overlappingShutdown.then((_) => overlappingCompleted = true));
      await pumpEventQueue();

      expect(container.read(providerProbe), 42);
      expect(overlappingCompleted, isFalse);
      expect(events, <String>[
        'cancel-players',
        'stop-server',
        'dispose-engines',
        'remove-listener',
        'prevent-close:false',
        'close',
      ]);
      expect(window.destroyCount, 0);

      allowCloseToFinish.complete();
      await Future.wait(<Future<void>>[firstShutdown, overlappingShutdown]);
      await coordinator.onWindowClose();

      expect(container.read(providerProbe), 42);
      expect(window.closeCount, 1);
      expect(window.destroyCount, 0);
    },
  );

  test('Windows close failure falls back to destroy', () async {
    final events = <String>[];
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
      onClose: () async => throw StateError('close failed'),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.onWindowClose();

    expect(events, containsAllInOrder(<String>['close', 'destroy']));
    expect(window.closeCount, 1);
    expect(window.destroyCount, 1);
    expect(window.exitCount, 0);
  });

  test(
    'Windows interception failure skips blocked close and destroys',
    () async {
      final events = <String>[];
      final window = _FakeShutdownWindowController(
        isWindows: true,
        events: events,
        onSetPreventClose: (preventClose) async {
          if (!preventClose) throw StateError('interception stayed enabled');
        },
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final coordinator = DesktopShutdownCoordinator(
        container,
        windowController: window,
        cancelPlayerOperations: () async {},
        stopTournamentServer: () async {},
      );

      await coordinator.start();
      events.clear();
      await coordinator.onWindowClose();

      expect(
        events,
        containsAllInOrder(<String>[
          'remove-listener',
          'prevent-close:false',
          'destroy',
        ]),
      );
      expect(window.closeCount, 0);
      expect(window.destroyCount, 1);
      expect(window.exitCount, 0);
    },
  );

  test('engine drain failure prevents native close', () async {
    final events = <String>[];
    var engineDrainAttempts = 0;
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final providerProbe = Provider<int>((ref) => 42);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {
        events.add('cancel-players');
        throw StateError('player cleanup failed');
      },
      stopTournamentServer: () async {
        events.add('stop-server');
        throw StateError('server cleanup failed');
      },
      disposeEngineProcesses: () async {
        engineDrainAttempts += 1;
        events.add('dispose-engines');
        if (engineDrainAttempts == 1) {
          throw StateError('engine cleanup failed');
        }
      },
    );

    await coordinator.start();
    events.clear();
    await expectLater(coordinator.onWindowClose(), throwsA(isA<StateError>()));

    expect(
      events,
      containsAllInOrder(<String>[
        'cancel-players',
        'stop-server',
        'dispose-engines',
      ]),
    );
    expect(container.read(providerProbe), 42);
    expect(events, isNot(contains('remove-listener')));
    expect(events, isNot(contains('prevent-close:false')));
    expect(window.closeCount, 0);
    expect(window.destroyCount, 0);
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);

    events.clear();
    await coordinator.onWindowClose();

    expect(engineDrainAttempts, 2);
    expect(events, containsAllInOrder(<String>['dispose-engines', 'close']));
    expect(window.closeCount, 1);
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);
  });

  test('detached lifecycle keeps the provider container alive', () async {
    final events = <String>[];
    final cleanupFinished = Completer<void>();
    final window = _FakeShutdownWindowController(
      isWindows: false,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final providerProbe = Provider<int>((ref) => 42);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async => events.add('cancel-players'),
      stopTournamentServer: () async {
        events.add('stop-server');
        cleanupFinished.complete();
      },
      disposeEngineProcesses: () async => events.add('dispose-engines'),
    );

    await coordinator.start();
    events.clear();
    coordinator.didChangeAppLifecycleState(AppLifecycleState.detached);
    expect(UciEngine.spawnsSuspendedForTesting, isTrue);
    var processStarterCalled = false;
    await expectLater(
      UciEngine.spawnForTesting(() {
        processStarterCalled = true;
        throw StateError('must not start');
      }),
      throwsA(isA<StateError>()),
    );
    expect(processStarterCalled, isFalse);
    await cleanupFinished.future;
    await pumpEventQueue();

    expect(container.read(providerProbe), 42);
    expect(events, <String>[
      'cancel-players',
      'stop-server',
      'dispose-engines',
    ]);
    expect(window.closeCount, 0);
    expect(window.destroyCount, 0);
  });

  test('macOS and Linux terminal shutdown retains destroy behavior', () async {
    final events = <String>[];
    final window = _FakeShutdownWindowController(
      isWindows: false,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.onWindowClose();

    expect(window.closeCount, 0);
    expect(window.destroyCount, 1);
    expect(window.exitCount, 0);
    expect(events, contains('destroy'));
  });

  test('failed terminal destroy falls back to process exit', () async {
    final events = <String>[];
    final window = _FakeShutdownWindowController(
      isWindows: false,
      events: events,
      onDestroy: () async => throw StateError('destroy failed'),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.onWindowClose();

    expect(events, containsAllInOrder(<String>['destroy', 'exit:0']));
    expect(window.destroyCount, 1);
    expect(window.exitCount, 1);
  });

  test('external termination drains engines before releasing close', () async {
    final events = <String>[];
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async => events.add('cancel-players'),
      stopTournamentServer: () async => events.add('stop-server'),
      disposeEngineProcesses: () async => events.add('dispose-engines'),
    );

    await coordinator.start();
    events.clear();
    await coordinator.prepareForExternalTermination();

    expect(events, <String>[
      'cancel-players',
      'stop-server',
      'dispose-engines',
      'prevent-close:false',
    ]);
    expect(window.closeCount, 0);
    expect(window.destroyCount, 0);
  });

  test(
    'failed external termination restores engine spawning and close',
    () async {
      final events = <String>[];
      final window = _FakeShutdownWindowController(
        isWindows: true,
        events: events,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final coordinator = DesktopShutdownCoordinator(
        container,
        windowController: window,
        cancelPlayerOperations: () async {},
        stopTournamentServer: () async {},
        disposeEngineProcesses: () async {},
        resetEngineOwners: () async => events.add('reset-engine-owners'),
        resumeEngineProcesses: () => events.add('resume-engines'),
        reconnectEngineOwners:
            () async => events.add('reconnect-engine-owners'),
      );

      await coordinator.start();
      await coordinator.prepareForExternalTermination();
      events.clear();
      await coordinator.restoreCloseInterception();

      expect(events, <String>[
        'reset-engine-owners',
        'prevent-close:true',
        'resume-engines',
        'reconnect-engine-owners',
      ]);
    },
  );

  test('external preparation cannot overtake terminal shutdown', () async {
    final events = <String>[];
    final engineDrainStarted = Completer<void>();
    final finishEngineDrain = Completer<void>();
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
      disposeEngineProcesses: () async {
        engineDrainStarted.complete();
        await finishEngineDrain.future;
      },
    );

    await coordinator.start();
    events.clear();
    final terminalShutdown = coordinator.onWindowClose();
    await engineDrainStarted.future;

    await expectLater(
      coordinator.prepareForExternalTermination(),
      throwsA(isA<StateError>()),
    );
    expect(window.closeCount, 0);
    expect(window.destroyCount, 0);

    finishEngineDrain.complete();
    await terminalShutdown;
    expect(window.closeCount, 1);
  });

  test('terminal shutdown safely supersedes external preparation', () async {
    final events = <String>[];
    final externalCleanupStarted = Completer<void>();
    final finishExternalCleanup = Completer<void>();
    var cancelCount = 0;
    var disposeCount = 0;
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {
        cancelCount += 1;
        if (cancelCount == 1) {
          externalCleanupStarted.complete();
          await finishExternalCleanup.future;
        }
      },
      stopTournamentServer: () async {},
      disposeEngineProcesses: () async => disposeCount += 1,
    );

    await coordinator.start();
    final externalPreparation = coordinator.prepareForExternalTermination();
    await externalCleanupStarted.future;
    final terminalShutdown = coordinator.onWindowClose();
    finishExternalCleanup.complete();

    await expectLater(externalPreparation, throwsA(isA<StateError>()));
    await terminalShutdown;

    expect(cancelCount, 2);
    expect(disposeCount, 1);
    expect(window.closeCount, 1);
  });

  test('updater recovery cannot reopen a terminal engine gate', () async {
    final events = <String>[];
    final terminalDrainStarted = Completer<void>();
    final finishTerminalDrain = Completer<void>();
    var disposeCount = 0;
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
      disposeEngineProcesses: () async {
        disposeCount += 1;
        if (disposeCount == 2) {
          terminalDrainStarted.complete();
          await finishTerminalDrain.future;
        }
      },
      resetEngineOwners: () async => events.add('reset-engine-owners'),
      resumeEngineProcesses: () => events.add('resume-engines'),
      reconnectEngineOwners: () async => events.add('reconnect-engine-owners'),
    );

    await coordinator.start();
    await coordinator.prepareForExternalTermination();
    events.clear();

    final terminalShutdown = coordinator.onWindowClose();
    await terminalDrainStarted.future;
    await coordinator.restoreCloseInterception();

    expect(events, isNot(contains('resume-engines')));
    expect(window.closeCount, 0);

    finishTerminalDrain.complete();
    await terminalShutdown;
    await coordinator.restoreCloseInterception();
    expect(events, isNot(contains('resume-engines')));
  });

  test('failed close-interception recovery keeps spawning suspended', () async {
    final events = <String>[];
    final window = _FakeShutdownWindowController(
      isWindows: true,
      events: events,
      onSetPreventClose: (preventClose) async {
        if (preventClose &&
            events.where((e) => e == 'prevent-close:true').length > 1) {
          throw StateError('cannot restore interception');
        }
      },
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = DesktopShutdownCoordinator(
      container,
      windowController: window,
      cancelPlayerOperations: () async {},
      stopTournamentServer: () async {},
      disposeEngineProcesses: () async {},
      resetEngineOwners: () async => events.add('reset-engine-owners'),
      resumeEngineProcesses: () => events.add('resume-engines'),
      reconnectEngineOwners: () async => events.add('reconnect-engine-owners'),
    );

    await coordinator.start();
    await coordinator.prepareForExternalTermination();
    await coordinator.restoreCloseInterception();

    expect(events, isNot(contains('resume-engines')));
  });
}

class _FakeShutdownWindowController implements DesktopShutdownWindowController {
  _FakeShutdownWindowController({
    required this.isWindows,
    required this.events,
    this.onClose,
    this.onDestroy,
    this.onSetPreventClose,
  });

  final List<String> events;
  final Future<void> Function()? onClose;
  final Future<void> Function()? onDestroy;
  final Future<void> Function(bool preventClose)? onSetPreventClose;

  @override
  final bool isWindows;

  int closeCount = 0;
  int destroyCount = 0;
  int exitCount = 0;

  @override
  bool get isSupported => true;

  @override
  void addListener(WindowListener listener) {
    events.add('add-listener');
  }

  @override
  Future<void> close() async {
    closeCount++;
    events.add('close');
    await onClose?.call();
  }

  @override
  Future<void> destroy() async {
    destroyCount++;
    events.add('destroy');
    await onDestroy?.call();
  }

  @override
  void exitProcess(int code) {
    exitCount++;
    events.add('exit:$code');
  }

  @override
  void removeListener(WindowListener listener) {
    events.add('remove-listener');
  }

  @override
  Future<void> setPreventClose(bool preventClose) async {
    events.add('prevent-close:$preventClose');
    await onSetPreventClose?.call(preventClose);
  }
}
