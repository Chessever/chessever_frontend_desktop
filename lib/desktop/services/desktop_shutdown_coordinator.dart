import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';

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
    @visibleForTesting void Function()? suspendEngineProcesses,
    @visibleForTesting Future<void> Function()? disposeEngineProcesses,
    @visibleForTesting Future<void> Function()? resetEngineOwners,
    @visibleForTesting void Function()? resumeEngineProcesses,
    @visibleForTesting Future<void> Function()? reconnectEngineOwners,
  }) : _windowController =
           windowController ?? const _SystemDesktopShutdownWindowController(),
       _cancelPlayerOperationsOverride = cancelPlayerOperations,
       _stopTournamentServerOverride = stopTournamentServer,
       _suspendEngineProcessesOverride = suspendEngineProcesses,
       _disposeEngineProcessesOverride = disposeEngineProcesses,
       _resetEngineOwnersOverride = resetEngineOwners,
       _resumeEngineProcessesOverride = resumeEngineProcesses,
       _reconnectEngineOwnersOverride = reconnectEngineOwners;

  static DesktopShutdownCoordinator? instance;

  final ProviderContainer _container;
  final DesktopShutdownWindowController _windowController;
  final Future<void> Function()? _cancelPlayerOperationsOverride;
  final Future<void> Function()? _stopTournamentServerOverride;
  final void Function()? _suspendEngineProcessesOverride;
  final Future<void> Function()? _disposeEngineProcessesOverride;
  final Future<void> Function()? _resetEngineOwnersOverride;
  final void Function()? _resumeEngineProcessesOverride;
  final Future<void> Function()? _reconnectEngineOwnersOverride;
  bool _started = false;
  bool _terminalShutdownRequested = false;
  bool _externalTerminationRequested = false;
  bool _externalRecoveryPending = false;
  Future<void>? _lifecycleOperation;
  Future<void>? _terminalShutdownFuture;
  Future<void>? _externalPreparationFuture;

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

  Future<void> shutdown({
    bool destroyWindow = false,
    bool terminalProcess = false,
  }) {
    final isTerminalShutdown = destroyWindow || terminalProcess;
    if (isTerminalShutdown) {
      final activeTerminalShutdown = _terminalShutdownFuture;
      if (_terminalShutdownRequested && activeTerminalShutdown != null) {
        return activeTerminalShutdown;
      }
      // Close the child-process gate synchronously. A queued lifecycle
      // operation may still be unwinding, but no new Process.start is allowed
      // once terminal shutdown has been requested.
      _terminalShutdownRequested = true;
      _externalTerminationRequested = false;
      _externalRecoveryPending = false;
      _suspendEngineProcesses();
    } else if (_terminalShutdownRequested) {
      return _terminalShutdownFuture ?? Future<void>.value();
    }

    final operation = _runLifecycleOperation(
      () => _performShutdown(destroyWindow: destroyWindow),
    );
    if (isTerminalShutdown) {
      var completedSuccessfully = false;
      late final Future<void> retryableOperation;
      retryableOperation = operation
          .then((_) {
            completedSuccessfully = true;
          })
          .whenComplete(() {
            // A drain failure must keep the process gate closed, but it must
            // not permanently memoize the failed Future. A later close event
            // gets a fresh chance to drain before attempting native teardown.
            if (!completedSuccessfully &&
                identical(_terminalShutdownFuture, retryableOperation)) {
              _terminalShutdownFuture = null;
            }
          });
      _terminalShutdownFuture = retryableOperation;
      return retryableOperation;
    }
    return operation;
  }

  Future<void> _performShutdown({required bool destroyWindow}) async {
    var closeInterceptionDisabled = true;
    await _cancelPlayerWorkspaceOperations();
    await _stopTournamentServer();
    await _disposeEngineProcesses();
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
  Future<void> prepareForExternalTermination() {
    if (_terminalShutdownRequested) {
      return Future<void>.error(
        StateError('Terminal desktop shutdown is already in progress.'),
      );
    }
    if (_externalTerminationRequested) {
      return _externalPreparationFuture ?? Future<void>.value();
    }

    _externalTerminationRequested = true;
    _externalRecoveryPending = true;
    _suspendEngineProcesses();
    final preparation = _runLifecycleOperation(() async {
      if (_terminalShutdownRequested) {
        throw StateError('Terminal desktop shutdown superseded the updater.');
      }
      await _cancelPlayerWorkspaceOperations();
      if (_terminalShutdownRequested) {
        throw StateError('Terminal desktop shutdown superseded the updater.');
      }
      await _stopTournamentServer();
      if (_terminalShutdownRequested) {
        throw StateError('Terminal desktop shutdown superseded the updater.');
      }
      await _disposeEngineProcesses();
      if (_terminalShutdownRequested) {
        throw StateError('Terminal desktop shutdown superseded the updater.');
      }
      if (_supportsWindowManager) {
        await _windowController.setPreventClose(false);
      }
    });
    _externalPreparationFuture = preparation;
    return preparation;
  }

  Future<void> restoreCloseInterception() {
    if (_terminalShutdownRequested || !_started || !_externalRecoveryPending) {
      return Future<void>.value();
    }

    return _runLifecycleOperation(() async {
      if (_terminalShutdownRequested ||
          !_started ||
          !_externalRecoveryPending) {
        return;
      }

      if (!await _resetEngineOwners()) return;
      if (_terminalShutdownRequested || !_started) return;

      // Restore native close interception while child creation is still
      // suspended. If this fails, remaining process-free is safer than
      // reopening a path that can bypass the coordinated close barrier.
      if (_supportsWindowManager) {
        try {
          await _windowController.setPreventClose(true);
        } catch (e, st) {
          debugPrint('[desktop] close interception recovery failed: $e\n$st');
          return;
        }
      }
      if (_terminalShutdownRequested || !_started) return;

      final resume = _resumeEngineProcessesOverride ?? UciEngine.resumeSpawns;
      resume();
      await _reconnectEngineOwners();
      _externalRecoveryPending = false;
      _externalTerminationRequested = false;
      _externalPreparationFuture = null;
    });
  }

  Future<void> _runLifecycleOperation(Future<void> Function() operation) {
    final previous = _lifecycleOperation;
    late final Future<void> current;
    current = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // The previous caller still receives its error. A queued terminal
          // operation must nevertheless get a chance to run its own barrier.
        }
      }
      await operation();
    }();
    _lifecycleOperation = current;
    return current.whenComplete(() {
      if (identical(_lifecycleOperation, current)) {
        _lifecycleOperation = null;
      }
    });
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

  Future<void> _disposeEngineProcesses() async {
    try {
      final dispose = _disposeEngineProcessesOverride ?? UciEngine.disposeAll;
      // Do not wrap this in Future.timeout: a timed-out Future keeps running,
      // which would recreate the exact dart:io shutdown race we are avoiding.
      await dispose();
    } catch (e, st) {
      debugPrint('[desktop] UCI engine shutdown failed: $e\n$st');
      rethrow;
    }
  }

  Future<bool> _resetEngineOwners() async {
    try {
      final reset =
          _resetEngineOwnersOverride ??
          () => StockfishSingleton().forceRecovery();
      await reset();
      return true;
    } catch (e, st) {
      debugPrint('[desktop] engine owner reset failed: $e\n$st');
      return false;
    }
  }

  Future<void> _reconnectEngineOwners() async {
    try {
      final reconnect =
          _reconnectEngineOwnersOverride ?? _reconnectPlaySessionEngines;
      await reconnect();
    } catch (e, st) {
      // Close interception is already restored and process creation is safe.
      // A failed individual owner can expose its normal engine error state.
      debugPrint('[desktop] engine owner reconnect failed: $e\n$st');
    }
  }

  Future<void> _reconnectPlaySessionEngines() async {
    final tabIds =
        _container.read(playSessionArgsByTabIdProvider).keys.toList();
    for (final tabId in tabIds) {
      final provider = playSessionProviderFor(tabId);
      if (!_container.exists(provider)) continue;
      await _container
          .read(provider.notifier)
          .reconnectEngineAfterExternalDrain();
    }
  }

  void _suspendEngineProcesses() {
    final suspend = _suspendEngineProcessesOverride ?? UciEngine.suspendSpawns;
    suspend();
  }

  @override
  Future<void> onWindowClose() async {
    await shutdown(destroyWindow: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The native host is already detaching, so do not issue another window
      // action. Still enter terminal mode synchronously to close the child
      // process gate before asynchronous cleanup begins.
      unawaited(shutdown(terminalProcess: true));
    }
  }
}
