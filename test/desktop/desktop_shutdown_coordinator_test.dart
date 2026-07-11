import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_shutdown_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows terminal shutdown closes HWND once and stays single-flight',
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
      var containerDisposeCount = 0;
      final coordinator = DesktopShutdownCoordinator(
        container,
        windowController: window,
        cancelPlayerOperations: () async => events.add('cancel-players'),
        stopTournamentServer: () async => events.add('stop-server'),
        disposeContainer: () {
          containerDisposeCount++;
          events.add('dispose-container');
        },
      );

      await coordinator.start();
      events.clear();

      final firstShutdown = coordinator.shutdown(
        destroyWindow: true,
        disposeContainer: true,
      );
      await closeStarted.future;
      final overlappingShutdown = coordinator.shutdown(
        destroyWindow: true,
        disposeContainer: true,
      );
      await overlappingShutdown;

      expect(containerDisposeCount, 1);
      expect(events, <String>[
        'cancel-players',
        'stop-server',
        'dispose-container',
        'remove-listener',
        'prevent-close:false',
        'close',
      ]);
      expect(window.destroyCount, 0);

      allowCloseToFinish.complete();
      await firstShutdown;
      await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

      expect(containerDisposeCount, 1);
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
      disposeContainer: () {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

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
        disposeContainer: () {},
      );

      await coordinator.start();
      events.clear();
      await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

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

  test('provider disposal failure cannot strand terminal close', () async {
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
      disposeContainer: () {
        events.add('dispose-container');
        throw StateError('provider disposal failed');
      },
    );

    await coordinator.start();
    events.clear();
    await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

    expect(
      events,
      containsAllInOrder(<String>[
        'dispose-container',
        'remove-listener',
        'prevent-close:false',
        'close',
      ]),
    );
    expect(window.closeCount, 1);
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
      disposeContainer: () {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

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
      disposeContainer: () {},
    );

    await coordinator.start();
    events.clear();
    await coordinator.shutdown(destroyWindow: true, disposeContainer: true);

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
