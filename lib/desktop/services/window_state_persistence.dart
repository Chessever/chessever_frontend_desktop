import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_window.dart';
import 'package:chessever/desktop/services/desktop_window_geometry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

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
      final preferredRect = Rect.fromLTWH(
        x ?? currentBounds.left,
        y ?? currentBounds.top,
        _validDimension(width) ? width! : currentBounds.width,
        _validDimension(height) ? height! : currentBounds.height,
      );
      final visibleBounds = await _visibleBoundsFor(preferredRect);
      final restoredRect = fitWindowRectToVisibleBounds(
        preferredRect: preferredRect,
        minimumSize: DesktopWindow.minSize,
        visibleBounds: visibleBounds,
      );
      await windowManager.setMinimumSize(
        effectiveMinimumWindowSize(
          desiredMinimumSize: DesktopWindow.minSize,
          fittedSize: restoredRect.size,
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
        'maximized': isMaximized,
      });
      await AppDatabase.instance.setString(_kvKey, payload);
    } catch (e) {
      debugPrint('⚠️ WindowStatePersistence._save failed: $e');
    }
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<Rect> _visibleBoundsFor(Rect preferredRect) async {
    final primaryDisplay = await screenRetriever.getPrimaryDisplay();
    final allDisplays = await screenRetriever.getAllDisplays();
    final primaryBounds = visibleBoundsForDisplay(primaryDisplay);
    return pickVisibleBoundsForRect(
      preferredRect: preferredRect,
      primaryBounds: primaryBounds,
      allBounds: allDisplays.map(visibleBoundsForDisplay),
    );
  }

  bool _validDimension(double? value) {
    return value != null && value > 200;
  }
}
