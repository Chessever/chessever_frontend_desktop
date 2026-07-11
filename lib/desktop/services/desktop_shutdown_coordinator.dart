import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:chessever/desktop/state/player_workspace.dart';

/// Narrow native-window boundary used by terminal shutdown.
///
/// Keeping the platform actions behind this interface makes their ordering
/// testable without asking a widget test process to close its own window.
abstract interface class DesktopShutdownWindowController {
  bool get isSupported;

  bool get isWindows;

  void addListener(WindowListener listener);

  void removeListener(WindowListener listener);

  Future<void> setPreventClose(bool preventClose);

  Future<void> close();

  Future<void> destroy();

  void exitProcess(int code);
}

class _SystemDesktopShutdownWindowController
    implements DesktopShutdownWindowController {
  const _SystemDesktopShutdownWindowController();

  @override
  bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  void addListener(WindowListener listener) {
    windowManager.addListener(listener);
  }

  @override
  void removeListener(WindowListener listener) {
    windowManager.removeListener(listener);
  }

  @override
  Future<void> setPreventClose(bool preventClose) {
    return windowManager.setPreventClose(preventClose);
  }

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  void exitProcess(int code) => exit(code);
}

/// Coordinates desktop process shutdown for services that own local resources.
///
/// The tournament server already stops when its provider is disposed, but
/// native window close can outlive widget teardown. This hook gives the local
/// Dart Frog server a deterministic stop path before the process exits.
class DesktopShutdownCoordinator with WidgetsBindingObserver, WindowListener {
  DesktopShutdownCoordinator(
    this._container, {
    DesktopShutdownWindowController? windowController,
    @visibleForTesting Future<void> Function()? cancelPlayerOperations,
    @visibleForTesting Future<void> Function()? stopTournamentServer,
  }) : _windowController =
           windowController ?? const _SystemDesktopShutdownWindowController(),
       _cancelPlayerOperationsOverride = cancelPlayerOperations,
       _stopTournamentServerOverride = stopTournamentServer;

  static DesktopShutdownCoordinator? instance;

  final ProviderContainer _container;
  final DesktopShutdownWindowController _windowController;
  final Future<void> Function()? _cancelPlayerOperationsOverride;
  final Future<void> Function()? _stopTournamentServerOverride;
  bool _started = false;
  bool _shuttingDown = false;

  bool get _supportsWindowManager => _windowController.isSupported;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    instance = this;

    WidgetsBinding.instance.addObserver(this);
    if (_supportsWindowManager) {
      _windowController.addListener(this);
      await _windowController.setPreventClose(true);
    }
  }

  Future<void> dispose() async {
    await _disposeCoordinator();
  }

  Future<bool> _disposeCoordinator() async {
    if (!_started) return true;
    _started = false;

    var closeInterceptionDisabled = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_supportsWindowManager) {
      _windowController.removeListener(this);
      try {
        await _windowController.setPreventClose(false);
      } catch (error, stackTrace) {
        closeInterceptionDisabled = false;
        ErrorReporter.report(
          error,
          stackTrace: stackTrace,
          tag: 'desktop_shutdown_disable_close_interception',
        );
      }
    }
    if (identical(instance, this)) {
      instance = null;
    }
    return closeInterceptionDisabled;
  }

  Future<void> shutdown({bool destroyWindow = false}) async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    final isTerminalShutdown = destroyWindow;
    try {
      var closeInterceptionDisabled = true;
      await _cancelPlayerWorkspaceOperations();
      await _stopTournamentServer();
      // The container is still mounted by UncontrolledProviderScope while
      // native close/lifecycle callbacks can race a final widget build. The
      // process/window teardown owns its lifetime; disposing it here makes
      // those builds read an already-disposed provider graph.
      if (destroyWindow) {
        closeInterceptionDisabled = await _disposeCoordinator();
      }

      if (destroyWindow && _supportsWindowManager) {
        await _terminateWindow(
          allowGracefulWindowsClose: closeInterceptionDisabled,
        );
      }
    } finally {
      // A terminal coordinator must never admit another lifecycle/close pass,
      // including after the async native close request has been accepted.
      if (!isTerminalShutdown) {
        _shuttingDown = false;
      }
    }
  }

  Future<void> _terminateWindow({
    required bool allowGracefulWindowsClose,
  }) async {
    if (_windowController.isWindows && allowGracefulWindowsClose) {
      try {
        // On Windows close() posts WM_CLOSE, allowing WM_DESTROY to run before
        // the runner message loop exits. destroy() posts WM_QUIT directly.
        await _windowController.close();
        return;
      } catch (error, stackTrace) {
        ErrorReporter.report(
          error,
          stackTrace: stackTrace,
          tag: 'desktop_shutdown_windows_close',
        );
      }
    }

    try {
      await _windowController.destroy();
    } catch (error, stackTrace) {
      ErrorReporter.report(
        error,
        stackTrace: stackTrace,
        tag: 'desktop_shutdown_window_destroy',
      );
      _windowController.exitProcess(0);
    }
  }

  /// Stops local services and lets the native updater terminate the process.
  ///
  /// Keep the ProviderContainer alive until the platform plugin has accepted
  /// the install request. If that request fails, the app can recover and show
  /// the error instead of being left with a disposed provider graph.
  Future<void> prepareForExternalTermination() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await _cancelPlayerWorkspaceOperations();
      await _stopTournamentServer();
      if (_supportsWindowManager) {
        await _windowController.setPreventClose(false);
      }
    } finally {
      _shuttingDown = false;
    }
  }

  Future<void> restoreCloseInterception() async {
    if (!_started || !_supportsWindowManager) return;
    try {
      await _windowController.setPreventClose(true);
    } catch (_) {}
  }

  Future<void> _stopTournamentServer() async {
    try {
      final stop =
          _stopTournamentServerOverride ??
          () => _container.read(tournamentServerProvider.notifier).stop();
      await stop().timeout(const Duration(seconds: 4));
    } on TimeoutException {
      debugPrint('[desktop] tournament server stop timed out during shutdown');
    } catch (e, st) {
      debugPrint('[desktop] tournament server stop failed: $e\n$st');
    }
  }

  Future<void> _cancelPlayerWorkspaceOperations() async {
    try {
      final cancel =
          _cancelPlayerOperationsOverride ??
          () =>
              _container
                  .read(playerWorkspaceProvider.notifier)
                  .cancelAllOperations();
      await cancel().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      debugPrint('[desktop] player workspace cancellation timed out');
    } catch (e, st) {
      debugPrint('[desktop] player workspace cancellation failed: $e\n$st');
    }
  }

  @override
  Future<void> onWindowClose() async {
    await shutdown(destroyWindow: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(shutdown());
    }
  }
}
