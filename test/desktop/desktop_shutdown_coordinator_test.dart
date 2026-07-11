import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_shutdown_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      );

      await coordinator.start();
      events.clear();

      final firstShutdown = coordinator.onWindowClose();
      await closeStarted.future;
      final overlappingShutdown = coordinator.onWindowClose();
      await overlappingShutdown;

      expect(container.read(providerProbe), 42);
      expect(events, <String>[
        'cancel-players',
        'stop-server',
        'remove-listener',
        'prevent-close:false',
        'close',
      ]);
      expect(window.destroyCount, 0);

      allowCloseToFinish.complete();
      await firstShutdown;
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

  test('service cleanup failures cannot strand native close', () async {
    final events = <String>[];
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
    );

    await coordinator.start();
    events.clear();
    await coordinator.onWindowClose();

    expect(
      events,
      containsAllInOrder(<String>[
        'cancel-players',
        'stop-server',
        'remove-listener',
        'prevent-close:false',
        'close',
      ]),
    );
    expect(container.read(providerProbe), 42);
    expect(window.closeCount, 1);
    expect(window.destroyCount, 0);
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
    );

    await coordinator.start();
    events.clear();
    coordinator.didChangeAppLifecycleState(AppLifecycleState.detached);
    await cleanupFinished.future;
    await pumpEventQueue();

    expect(container.read(providerProbe), 42);
    expect(events, <String>['cancel-players', 'stop-server']);
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
