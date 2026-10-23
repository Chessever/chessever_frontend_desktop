import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_window.dart';
import 'package:chessever/desktop/services/desktop_window_geometry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/utils/platform/io_platform.dart';

/// Saves and restores the window position, size, and maximized state across
/// app launches.
///
/// Stored in the existing SQLite key/value table so we do not introduce a
/// second persistence layer just for two ints. The save runs on a debounced
/// timer triggered by the WindowListener so a user dragging the window
/// border does not hammer the disk.
class WindowStatePersistence with WindowListener {
  WindowStatePersistence._();
  static final WindowStatePersistence instance = WindowStatePersistence._();

  static const String _kvKey = 'desktop.window_state.v1';
  static const Duration _saveDebounce = Duration(milliseconds: 400);

  Timer? _saveTimer;
  bool _restoredOnce = false;

  /// Restores the window to its last saved bounds. Safe to call before
  /// `runApp`; if no state is stored yet the window keeps the size set by
  /// `DesktopWindow.initialize()`.
  Future<void> restore() async {
    if (!_isDesktop) return;
    if (_restoredOnce) return;
    _restoredOnce = true;

    try {
      final raw = await AppDatabase.instance.getString(_kvKey);
      if (raw == null) return;

      final json = jsonDecode(raw) as Map<String, dynamic>;
      final maximized = json['maximized'] as bool? ?? false;
      final width = (json['width'] as num?)?.toDouble();
      final height = (json['height'] as num?)?.toDouble();
      final x = (json['x'] as num?)?.toDouble();
      final y = (json['y'] as num?)?.toDouble();

      final currentBounds = await windowManager.getBounds();
      final windowScale = windowManager.getDevicePixelRatio();
      // States saved before the scale was recorded were written at whatever
      // scale the window had; the current one is the best guess.
      final savedScale = _validScale(json['scale']) ?? windowScale;
      final savedRect = Rect.fromLTWH(
        x ?? currentBounds.left,
        y ?? currentBounds.top,
        _validDimension(width) ? width! : currentBounds.width,
        _validDimension(height) ? height! : currentBounds.height,
      );
      final displays = await _displays();
      final restoredRect = restoredWindowBounds(
        savedRect: savedRect,
        savedScale: savedScale,
        windowScale: windowScale,
        minimumSize: DesktopWindow.minSize,
        displays: displays,
        perMonitorScaling: desktopUsesPerMonitorScaling,
      );
      await windowManager.setMinimumSize(
        minimumWindowSizeForDisplays(
          desiredMinimumSize: DesktopWindow.minSize,
          visibleBounds: displays.map((display) => display.visibleBounds),
        ),
      );
      await windowManager.setBounds(restoredRect);

      if (maximized) {
        await windowManager.maximize();
      }
    } catch (e) {
      debugPrint('⚠️ WindowStatePersistence.restore failed: $e');
    }
  }

  /// Starts listening for window events. Subsequent moves and resizes are
  /// persisted (debounced) so the window comes back to the same place.
  Future<void> startTracking() async {
    if (!_isDesktop) return;
    windowManager.addListener(this);
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _save);
  }

  Future<void> _save() async {
    try {
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      final isMaximized = await windowManager.isMaximized();

      final payload = jsonEncode({
        'width': size.width,
        'height': size.height,
        'x': position.dx,
        'y': position.dy,
        // On Windows the bounds above are in the window's current monitor's
        // logical pixels; the scale lets restore find that monitor again.
        'scale': windowManager.getDevicePixelRatio(),
        'maximized': isMaximized,
      });
      await AppDatabase.instance.setString(_kvKey, payload);
    } catch (e) {
      debugPrint('⚠️ WindowStatePersistence._save failed: $e');
    }
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<List<DesktopDisplayArea>> _displays() async {
    final displays = [
      for (final display in await screenRetriever.getAllDisplays())
        DesktopDisplayArea.fromDisplay(display),
    ];
    if (displays.isNotEmpty) return displays;
    return [
      DesktopDisplayArea.fromDisplay(await screenRetriever.getPrimaryDisplay()),
    ];
  }

  bool _validDimension(double? value) {
    return value != null && value > 200;
  }

  double? _validScale(Object? value) {
    if (value is! num) return null;
    final scale = value.toDouble();
    return scale > 0 ? scale : null;
  }
}

/// window_manager bounds for a saved window rect, fitted into the work area
/// of the display it was saved on (or the nearest one).
///
/// [savedRect] is in logical pixels at [savedScale], the window's scale when
/// it was saved. On Windows that space belongs to the monitor the window was
/// on, so the saved monitor is found through physical pixels, the rect is
/// fitted in that monitor's logical pixels, and the result is mapped into the
/// window's current coordinates at [windowScale]. On a single monitor, or
/// with every monitor at one scale, this is the plain fit.
@visibleForTesting
Rect restoredWindowBounds({
  required Rect savedRect,
  required double savedScale,
  required double windowScale,
  required Size minimumSize,
  required List<DesktopDisplayArea> displays,
  required bool perMonitorScaling,
}) {
  final index = displayIndexForPoint(
    point: savedRect.center,
    windowScale: savedScale,
    displays: displays,
    perMonitorScaling: perMonitorScaling,
  );
  if (index < 0) return savedRect;
  final display = displays[index];

  // Saved position in the display's own logical pixels. The size stays
  // logical: it was the user's size on that display.
  final positionScale =
      perMonitorScaling ? savedScale / display.scaleFactor : 1.0;
  final preferredRect = Rect.fromLTWH(
    savedRect.left * positionScale,
    savedRect.top * positionScale,
    savedRect.width,
    savedRect.height,
  );
  final fitted = fitWindowRectToVisibleBounds(
    preferredRect: preferredRect,
    minimumSize: minimumSize,
    visibleBounds: display.visibleBounds,
  );
  return windowBoundsForDisplayRect(
    rect: fitted,
    display: display,
    windowScale: windowScale,
    perMonitorScaling: perMonitorScaling,
  );
}
