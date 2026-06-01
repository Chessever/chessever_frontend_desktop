import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';

/// Coordinates desktop process shutdown for services that own local resources.
///
/// The tournament server already stops when its provider is disposed, but
/// native window close can outlive widget teardown. This hook gives the local
/// Dart Frog server a deterministic stop path before the process exits.
class DesktopShutdownCoordinator with WidgetsBindingObserver, WindowListener {
  DesktopShutdownCoordinator(this._container);

  static DesktopShutdownCoordinator? instance;

  final ProviderContainer _container;
  bool _started = false;
  bool _shuttingDown = false;
  bool _containerDisposed = false;

  bool get _supportsWindowManager =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    instance = this;

    WidgetsBinding.instance.addObserver(this);
    if (_supportsWindowManager) {
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    }
  }

  Future<void> dispose() async {
    if (!_started) return;
    _started = false;

    WidgetsBinding.instance.removeObserver(this);
    if (_supportsWindowManager) {
      windowManager.removeListener(this);
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
    }
    if (identical(instance, this)) {
      instance = null;
    }
  }

  Future<void> shutdown({
    bool destroyWindow = false,
    bool disposeContainer = false,
  }) async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await _stopTournamentServer();
      if (disposeContainer && !_containerDisposed) {
        _containerDisposed = true;
        _container.dispose();
      }
    } finally {
      _shuttingDown = false;
    }

    if (disposeContainer) {
      await dispose();
    }

    if (destroyWindow && _supportsWindowManager) {
      try {
        await windowManager.destroy();
      } catch (e) {
        debugPrint(
          '[desktop] window destroy failed after shutdown; exiting: $e',
        );
        exit(0);
      }
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
      await _stopTournamentServer();
      if (_supportsWindowManager) {
        await windowManager.setPreventClose(false);
      }
    } finally {
      _shuttingDown = false;
    }
  }

  Future<void> restoreCloseInterception() async {
    if (!_started || !_supportsWindowManager) return;
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {}
  }

  Future<void> _stopTournamentServer() async {
    if (_containerDisposed) return;
    try {
      await _container
          .read(tournamentServerProvider.notifier)
          .stop()
          .timeout(const Duration(seconds: 4));
    } on TimeoutException {
      debugPrint('[desktop] tournament server stop timed out during shutdown');
    } catch (e, st) {
      debugPrint('[desktop] tournament server stop failed: $e\n$st');
    }
  }

  @override
  Future<void> onWindowClose() async {
    await shutdown(destroyWindow: true, disposeContainer: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(shutdown(disposeContainer: true));
    }
  }
}
