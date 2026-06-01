import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_window_geometry.dart';

/// Window-manager bootstrap for desktop platforms.
///
/// Sets a sensible minimum size and hides the window until the first frame
/// renders to avoid the white flash that database users would never tolerate.
class DesktopWindow {
  DesktopWindow._();

  static const Size minSize = Size(1024, 720);
  static const Size defaultSize = Size(1440, 900);
  static const String windowTitle = 'ChessEver';

  static Future<void> initialize() async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return;
    }
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();

    final initialSize = await _initialSizeForCurrentDisplay();
    final effectiveMinSize = effectiveMinimumWindowSize(
      desiredMinimumSize: minSize,
      fittedSize: initialSize,
    );

    final options = WindowOptions(
      size: initialSize,
      minimumSize: effectiveMinSize,
      center: true,
      title: windowTitle,
      backgroundColor: const Color(0xFF0C0C0E),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitle(windowTitle);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  static Future<Size> _initialSizeForCurrentDisplay() async {
    try {
      final primaryDisplay = await screenRetriever.getPrimaryDisplay();
      final allDisplays = await screenRetriever.getAllDisplays();
      final cursorPosition = await screenRetriever.getCursorScreenPoint();
      final currentDisplay = allDisplays.firstWhere(
        (display) => visibleBoundsForDisplay(display).contains(cursorPosition),
        orElse: () => primaryDisplay,
      );
      return fitWindowSizeToVisibleBounds(
        preferredSize: defaultSize,
        minimumSize: minSize,
        visibleBounds: visibleBoundsForDisplay(currentDisplay),
      );
    } catch (_) {
      return defaultSize;
    }
  }
}
