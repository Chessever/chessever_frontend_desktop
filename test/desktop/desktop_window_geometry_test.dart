import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_window_geometry.dart';

void main() {
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

  group('pickVisibleBoundsForRect', () {
    test('preserves the display containing the restored center point', () {
      final primary = Rect.fromLTWH(0, 0, 1280, 720);
      final secondary = Rect.fromLTWH(1280, 0, 1920, 1080);

      final picked = pickVisibleBoundsForRect(
        preferredRect: Rect.fromLTWH(1500, 100, 900, 700),
        primaryBounds: primary,
        allBounds: [primary, secondary],
      );

      expect(picked, secondary);
    });
  });
}
