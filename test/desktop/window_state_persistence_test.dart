import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_window_geometry.dart';
import 'package:chessever/desktop/services/window_state_persistence.dart';

void main() {
  const minimumSize = Size(1024, 720);

  group('restoredWindowBounds', () {
    test('a single display restores to the plain fit', () {
      const laptop = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(0, 0, 1366, 728),
      );

      final rect = restoredWindowBounds(
        savedRect: const Rect.fromLTWH(2200, -80, 1440, 900),
        savedScale: 1,
        windowScale: 1,
        minimumSize: minimumSize,
        displays: const [laptop],
        perMonitorScaling: true,
      );

      expect(rect, const Rect.fromLTRB(24, 24, 1342, 704));
    });

    test('a big-monitor window restored on a 125 % laptop fits its work '
        'area', () {
      // 1920x1080 at 125 %: 1536x864 logical, taskbar 38 px.
      const laptop = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(0, 0, 1536, 826),
        scaleFactor: 1.25,
      );

      final rect = restoredWindowBounds(
        savedRect: const Rect.fromLTWH(60, 40, 1800, 1000),
        savedScale: 1.25,
        windowScale: 1.25,
        minimumSize: minimumSize,
        displays: const [laptop],
        perMonitorScaling: true,
      );

      expect(rect, const Rect.fromLTWH(24, 24, 1488, 778));
    });

    test('mixed Windows scaling returns to the monitor it was saved on', () {
      // Saved on a 150 % laptop to the right of a 100 % monitor; the new
      // window starts on the monitor at scale 1.
      const monitor = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(0, 0, 1920, 1040),
      );
      const laptop = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(1280, 0, 1280, 688),
        scaleFactor: 1.5,
      );

      final rect = restoredWindowBounds(
        savedRect: const Rect.fromLTWH(1310, 30, 1200, 640),
        savedScale: 1.5,
        windowScale: 1,
        minimumSize: minimumSize,
        displays: const [monitor, laptop],
        perMonitorScaling: true,
      );

      // Position: laptop logical (1310, 24) is physical (1965, 36), which
      // the scale-1 window expresses as-is. Size stays laptop-logical;
      // Windows rescales it on arrival.
      expect(rect, const Rect.fromLTWH(1965, 36, 1200, 640));
    });
  });
}
