import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_window_geometry.dart';

void main() {
  group('pictureInPictureRectForVisibleBounds', () {
    test('anchors the compact window inside the top-right safe area', () {
      final rect = pictureInPictureRectForVisibleBounds(
        size: const Size(520, 650),
        visibleBounds: const Rect.fromLTWH(100, 40, 1920, 1040),
      );

      expect(rect, const Rect.fromLTWH(1476, 64, 520, 650));
    });

    test('fits a compact window inside a smaller visible work area', () {
      final rect = pictureInPictureRectForVisibleBounds(
        size: const Size(520, 650),
        visibleBounds: const Rect.fromLTWH(0, 0, 480, 600),
      );

      expect(rect, const Rect.fromLTWH(24, 24, 432, 552));
    });
  });

  group('fitWindowSizeToVisibleBounds', () {
    test('keeps the preferred size when the display can fit it', () {
      final size = fitWindowSizeToVisibleBounds(
        preferredSize: const Size(1440, 900),
        minimumSize: const Size(1024, 720),
        visibleBounds: Rect.fromLTWH(0, 0, 1920, 1080),
      );

      expect(size, const Size(1440, 900));
    });

    test('shrinks below the desired minimum when the display is smaller', () {
      final size = fitWindowSizeToVisibleBounds(
        preferredSize: const Size(1440, 900),
        minimumSize: const Size(1024, 720),
        visibleBounds: Rect.fromLTWH(0, 0, 1280, 680),
      );

      expect(size, const Size(1232, 632));
    });
  });

  group('fitWindowRectToVisibleBounds', () {
    test('clamps a restored big-screen rect back into a small display', () {
      final rect = fitWindowRectToVisibleBounds(
        preferredRect: Rect.fromLTWH(2200, -80, 1440, 900),
        minimumSize: const Size(1024, 720),
        visibleBounds: Rect.fromLTWH(0, 0, 1366, 728),
      );

      expect(rect.left, 24);
      expect(rect.top, 24);
      expect(rect.right, 1342);
      expect(rect.bottom, 704);
    });
  });

  group('displayIndexForPoint', () {
    test('keeps the display holding the point on a shared logical space', () {
      const primary = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(0, 0, 1280, 720),
      );
      const secondary = DesktopDisplayArea(
        visibleBounds: Rect.fromLTWH(1280, 0, 1920, 1080),
      );

      final index = displayIndexForPoint(
        point: const Offset(1950, 450),
        windowScale: 1,
        displays: const [primary, secondary],
        perMonitorScaling: false,
      );

      expect(index, 1);
    });

    test('falls back to the nearest display for an off-screen point', () {
      final index = displayIndexForPoint(
        point: const Offset(5000, 300),
        windowScale: 1,
        displays: [_windowsMonitor, _windowsLaptop],
        perMonitorScaling: false,
      );

      expect(index, 1);
    });

    test('mixed Windows scaling resolves through physical pixels', () {
      // The 150 % laptop's per-monitor logical rect (x 1280-2560) overlaps
      // the 100 % monitor's (x 0-1920), so the same window-logical point
      // belongs to whichever monitor matches the window's own scale.
      const point = Offset(1600, 250);

      expect(
        displayIndexForPoint(
          point: point,
          windowScale: 1,
          displays: [_windowsLaptop, _windowsMonitor],
          perMonitorScaling: true,
        ),
        1,
      );
      expect(
        displayIndexForPoint(
          point: point,
          windowScale: 1.5,
          displays: [_windowsMonitor, _windowsLaptop],
          perMonitorScaling: true,
        ),
        1,
      );
    });

    test('returns -1 without displays', () {
      expect(
        displayIndexForPoint(
          point: Offset.zero,
          windowScale: 1,
          displays: const [],
          perMonitorScaling: true,
        ),
        -1,
      );
    });
  });

  group('workAreaInWindowCoordinates', () {
    test('matches the reported work area once the window has its DPI', () {
      expect(
        workAreaInWindowCoordinates(
          display: _windowsLaptop,
          windowScale: 1.5,
          perMonitorScaling: true,
        ),
        const Rect.fromLTWH(1280, 0, 1280, 688),
      );
    });

    test('maps through physical pixels while the window has another DPI', () {
      expect(
        workAreaInWindowCoordinates(
          display: _windowsLaptop,
          windowScale: 1,
          perMonitorScaling: true,
        ),
        const Rect.fromLTWH(1920, 0, 1920, 1032),
      );
    });

    test('is the reported work area on a shared logical space', () {
      expect(
        workAreaInWindowCoordinates(
          display: _windowsLaptop,
          windowScale: 2,
          perMonitorScaling: false,
        ),
        _windowsLaptop.visibleBounds,
      );
    });
  });

  group('windowBoundsForDisplayRect', () {
    test('maps the position through physical pixels, not the size', () {
      expect(
        windowBoundsForDisplayRect(
          rect: const Rect.fromLTWH(1304, 24, 1232, 640),
          display: _windowsLaptop,
          windowScale: 1,
          perMonitorScaling: true,
        ),
        const Rect.fromLTWH(1956, 36, 1232, 640),
      );
    });

    test('is the identity on a shared logical space', () {
      const rect = Rect.fromLTWH(1304, 24, 1232, 640);
      expect(
        windowBoundsForDisplayRect(
          rect: rect,
          display: _windowsLaptop,
          windowScale: 1,
          perMonitorScaling: false,
        ),
        rect,
      );
    });
  });

  group('minimumWindowSizeForDisplays', () {
    test('keeps the desired minimum when every display can hold it', () {
      expect(
        minimumWindowSizeForDisplays(
          desiredMinimumSize: const Size(1024, 720),
          visibleBounds: [_windowsMonitor.visibleBounds],
        ),
        const Size(1024, 720),
      );
    });

    test('lowers the minimum to fit the smallest work area', () {
      // A 720 px minimum set on the monitor would keep the window taller
      // than the 150 % laptop's 688 px work area after moving there.
      expect(
        minimumWindowSizeForDisplays(
          desiredMinimumSize: const Size(1024, 720),
          visibleBounds: [
            _windowsMonitor.visibleBounds,
            _windowsLaptop.visibleBounds,
          ],
        ),
        const Size(1024, 640),
      );
    });
  });

  group('windowOverflowsWorkArea', () {
    const workArea = Rect.fromLTWH(0, 0, 1366, 728);

    test('ignores the frame overhang of a maximized Windows window', () {
      expect(
        windowOverflowsWorkArea(
          windowBounds: workArea.inflate(8),
          workArea: workArea,
        ),
        isFalse,
      );
    });

    test('flags a window taller than the work area', () {
      expect(
        windowOverflowsWorkArea(
          windowBounds: const Rect.fromLTWH(24, 24, 1318, 900),
          workArea: workArea,
        ),
        isTrue,
      );
    });

    test('flags a window whose bottom sits under the taskbar', () {
      expect(
        windowOverflowsWorkArea(
          windowBounds: const Rect.fromLTWH(24, 120, 1318, 680),
          workArea: workArea,
        ),
        isTrue,
      );
    });
  });
}

/// 1920x1080 monitor at 100 %, taskbar 40 px.
const _windowsMonitor = DesktopDisplayArea(
  visibleBounds: Rect.fromLTWH(0, 0, 1920, 1040),
  id: 'monitor',
);

/// 1920x1080 laptop at 150 % to the right of [_windowsMonitor]. Its work
/// area is (1920, 0)-(3840, 1032) physical, which screen_retriever reports
/// divided by the laptop's own scale.
const _windowsLaptop = DesktopDisplayArea(
  visibleBounds: Rect.fromLTWH(1280, 0, 1280, 688),
  scaleFactor: 1.5,
  id: 'laptop',
);
