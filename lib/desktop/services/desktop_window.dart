import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/desktop_build_identity.dart';
import 'package:chessever/desktop/services/desktop_window_geometry.dart';

/// Window-manager bootstrap for desktop platforms.
///
/// Sets a sensible minimum size and hides the window until the first frame
/// renders to avoid the white flash that database users would never tolerate.
class DesktopWindow {
  DesktopWindow._();

  static const Size minSize = Size(1024, 720);
  static const Size defaultSize = Size(1440, 900);
  static const double _pictureInPictureMinBoardEdge = 300;
  static const double _pictureInPictureHorizontalChrome = 56;
  static const double _pictureInPictureVerticalChrome = 124;
  // PiP is a responsive game card rather than a square crop. The width
  // reserves the board, evaluation gauge, and compact horizontal padding;
  // the height reserves both player rows and their spacing. Native and custom
  // title bars are intentionally absent.
  // Users can freely resize either dimension and the board layout fits the
  // largest complete square into the remaining space.
  static const Size pictureInPictureMinSize = Size(
    _pictureInPictureMinBoardEdge + _pictureInPictureHorizontalChrome,
    _pictureInPictureMinBoardEdge + _pictureInPictureVerticalChrome,
  );
  // Start at the same compact size users can reach by resizing to the
  // minimum. The window remains freely resizable above this on every desktop
  // platform.
  static const Size pictureInPictureDefaultSize = pictureInPictureMinSize;
  static String get windowTitle => DesktopBuildIdentity.current.displayName;

  static Future<void> initialize({bool pictureInPicture = false}) async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return;
    }
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();

    final displayGeometry = await _initialGeometryForCurrentDisplay(
      pictureInPicture: pictureInPicture,
    );
    final initialSize = displayGeometry.size;
    final desiredMinSize = pictureInPicture ? pictureInPictureMinSize : minSize;
    final effectiveMinSize = effectiveMinimumWindowSize(
      desiredMinimumSize: desiredMinSize,
      fittedSize: initialSize,
    );

    final options = WindowOptions(
      size: initialSize,
      minimumSize: effectiveMinSize,
      center: !pictureInPicture,
      alwaysOnTop: pictureInPicture ? true : null,
      fullScreen: pictureInPicture ? false : null,
      title: windowTitle,
      backgroundColor: const Color(0xFF0C0C0E),
      skipTaskbar: pictureInPicture,
      // PiP becomes truly frameless in the ready callback. Passing a title
      // style here would restore native framing after setAsFrameless().
      titleBarStyle: pictureInPicture ? null : TitleBarStyle.hidden,
      windowButtonVisibility: pictureInPicture ? false : Platform.isMacOS,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitle(windowTitle);
      if (pictureInPicture) {
        await windowManager.setAsFrameless();
        final visibleBounds = displayGeometry.visibleBounds;
        if (visibleBounds != null) {
          await windowManager.setBounds(
            pictureInPictureRectForVisibleBounds(
              size: initialSize,
              visibleBounds: visibleBounds,
            ),
          );
        } else {
          await windowManager.setAlignment(Alignment.topRight);
        }
        if (Platform.isMacOS || Platform.isWindows) {
          await windowManager.setMaximizable(false);
        }
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  static Future<({Size size, Rect? visibleBounds})>
  _initialGeometryForCurrentDisplay({required bool pictureInPicture}) async {
    final preferredSize =
        pictureInPicture ? pictureInPictureDefaultSize : defaultSize;
    final desiredMinSize = pictureInPicture ? pictureInPictureMinSize : minSize;
    try {
      final primaryDisplay = await screenRetriever.getPrimaryDisplay();
      final allDisplays = await screenRetriever.getAllDisplays();
      final cursorPosition = await screenRetriever.getCursorScreenPoint();
      final currentDisplay = allDisplays.firstWhere(
        (display) => visibleBoundsForDisplay(display).contains(cursorPosition),
        orElse: () => primaryDisplay,
      );
      final visibleBounds = visibleBoundsForDisplay(currentDisplay);
      return (
        size: fitWindowSizeToVisibleBounds(
          preferredSize: preferredSize,
          minimumSize: desiredMinSize,
          visibleBounds: visibleBounds,
        ),
        visibleBounds: visibleBounds,
      );
    } catch (_) {
      return (size: preferredSize, visibleBounds: null);
    }
  }
}
