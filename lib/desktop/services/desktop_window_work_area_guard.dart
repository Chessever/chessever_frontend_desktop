import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_window.dart';
import 'package:chessever/desktop/services/desktop_window_geometry.dart';
import 'package:chessever/utils/host_platform.dart';

/// Keeps the main window inside the usable work area of the display it is on.
///
/// Startup sizing (`DesktopWindow.initialize`, `WindowStatePersistence
/// .restore`) fits the window once. The work area can change afterwards: the
/// window is dragged or Win+Shift+Arrowed to a smaller display, Windows
/// scaling changes (100 % to 125 % shrinks the logical work area), a display
/// is plugged or unplugged. The window then keeps a size, and a minimum size,
/// that no longer fits, its bottom edge (the sidebar's Settings button) sits
/// under the taskbar or off the screen, and maximizing cannot help because
/// Windows never sizes a window below its minimum.
///
/// The guard keeps the minimum size small enough for every display and, after
/// such an environment change only, fits a window that no longer fits. It
/// never resizes in response to the user's own move or resize on the same
/// display, and never while a move or resize is in progress.
class DesktopWindowWorkAreaGuard
    with WindowListener, ScreenListener, WidgetsBindingObserver {
  DesktopWindowWorkAreaGuard._()
    : _windowScale = windowManager.getDevicePixelRatio,
      _perMonitorScaling = (() => desktopUsesPerMonitorScaling);

  /// A guard driven directly by tests, with the window's scale and the
  /// platform's coordinate model supplied instead of read from the engine.
  @visibleForTesting
  DesktopWindowWorkAreaGuard.forTesting({
    required double Function() windowScale,
    required bool perMonitorScaling,
  }) : _windowScale = windowScale,
       _perMonitorScaling = (() => perMonitorScaling);

  static final DesktopWindowWorkAreaGuard instance =
      DesktopWindowWorkAreaGuard._();

  final double Function() _windowScale;
  final bool Function() _perMonitorScaling;

  static const Duration _settleDelay = Duration(milliseconds: 350);

  /// A live move/resize keeps postponing the check for this long after its
  /// last event. macOS reports no end event for programmatic resizes, so the
  /// window must not wait for one.
  static const Duration _interactionHold = Duration(milliseconds: 1500);

  bool _started = false;
  Timer? _timer;
  bool _checking = false;
  bool _checkAgain = false;
  bool _environmentChanged = true;
  DateTime? _interactingUntil;
  Size? _appliedMinimum;
  String? _lastDisplayId;
  double? _lastScale;

  /// Starts watching the main window. Call once, after the window has its
  /// startup bounds.
  Future<void> start() async {
    if (_started) return;
    if (!(hostIsMacOS || hostIsWindows || hostIsLinux)) return;
    _started = true;
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    try {
      screenRetriever.addListener(this);
    } catch (e) {
      debugPrint('⚠️ DesktopWindowWorkAreaGuard: no display events: $e');
    }
    _schedule(environmentChanged: true);
  }

  @override
  void onWindowMove() => _holdForInteraction();

  @override
  void onWindowResize() => _holdForInteraction();

  @override
  void onWindowMoved() {
    _interactingUntil = null;
    _schedule();
  }

  @override
  void onWindowResized() {
    _interactingUntil = null;
    _schedule();
  }

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  @override
  void onWindowRestore() => _schedule();

  @override
  void onWindowLeaveFullScreen() => _schedule();

  @override
  void onScreenEvent(String eventName) => _schedule(environmentChanged: true);

  /// Fires when the window lands on a display with another scale factor, and
  /// on every frame of a resize; the check itself works out which it was.
  @override
  void didChangeMetrics() => _schedule();

  /// Runs one check now, as if [environmentChanged] had just been reported.
  @visibleForTesting
  Future<void> debugCheck({bool environmentChanged = false}) {
    if (environmentChanged) _environmentChanged = true;
    return _check();
  }

  void _holdForInteraction() {
    _interactingUntil = DateTime.now().add(_interactionHold);
    _schedule();
  }

  void _schedule({bool environmentChanged = false}) {
    if (environmentChanged) _environmentChanged = true;
    _timer?.cancel();
    _timer = Timer(_settleDelay, () => unawaited(_check()));
  }

  Future<void> _check() async {
    final interactingUntil = _interactingUntil;
    if (interactingUntil != null && DateTime.now().isBefore(interactingUntil)) {
      _schedule();
      return;
    }
    if (_checking) {
      _checkAgain = true;
      return;
    }
    _checking = true;
    try {
      await _fitToWorkArea();
    } catch (e) {
      debugPrint('⚠️ DesktopWindowWorkAreaGuard check failed: $e');
    } finally {
      _checking = false;
      if (_checkAgain) {
        _checkAgain = false;
        _schedule();
      }
    }
  }

  Future<void> _fitToWorkArea() async {
    final displays = [
      for (final display in await screenRetriever.getAllDisplays())
        DesktopDisplayArea.fromDisplay(display),
    ];
    if (displays.isEmpty) return;

    final minimum = minimumWindowSizeForDisplays(
      desiredMinimumSize: DesktopWindow.minSize,
      visibleBounds: displays.map((display) => display.visibleBounds),
    );
    if (minimum != _appliedMinimum) {
      await windowManager.setMinimumSize(minimum);
      _appliedMinimum = minimum;
    }

    if (await windowManager.isFullScreen() ||
        await windowManager.isMinimized()) {
      return;
    }

    final perMonitorScaling = _perMonitorScaling();
    final scale = _windowScale();
    final bounds = await windowManager.getBounds();
    final index = displayIndexForPoint(
      point: bounds.center,
      windowScale: scale,
      displays: displays,
      perMonitorScaling: perMonitorScaling,
    );
    if (index < 0) return;
    final display = displays[index];

    final changed =
        _environmentChanged ||
        display.id != _lastDisplayId ||
        scale != _lastScale;
    _environmentChanged = false;
    _lastDisplayId = display.id;
    _lastScale = scale;
    if (!changed) return;

    // Crossing between monitors with different scaling, Windows has not yet
    // given the window the new monitor's DPI. That scale change fires
    // didChangeMetrics and checks again.
    if (perMonitorScaling && (display.scaleFactor - scale).abs() > 0.01) {
      _environmentChanged = true;
      return;
    }

    final workArea = workAreaInWindowCoordinates(
      display: display,
      windowScale: scale,
      perMonitorScaling: perMonitorScaling,
    );
    if (!windowOverflowsWorkArea(windowBounds: bounds, workArea: workArea)) {
      return;
    }

    if (await windowManager.isMaximized()) {
      // Maximized under a minimum this display cannot hold. The minimum now
      // fits, so maximizing again fills exactly the work area.
      await windowManager.unmaximize();
      await windowManager.maximize();
      return;
    }

    await windowManager.setBounds(
      fitWindowRectToVisibleBounds(
        preferredRect: bounds,
        minimumSize: minimum,
        visibleBounds: workArea,
      ),
    );
  }
}
