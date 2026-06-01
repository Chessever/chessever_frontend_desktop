import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopForYouStripLayout', () {
    test('keeps four boards on ordinary wide rows', () {
      const availableForFour =
          DesktopForYouStripLayout.minCardWidth * 4 +
          DesktopForYouStripLayout.gap * 3;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFour,
        gameCount: 5,
      );

      expect(layout.visibleCount, 4);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('allows a fifth board when the row is wide enough', () {
      const availableForFive =
          DesktopForYouStripLayout.minCardWidth * 5 +
          DesktopForYouStripLayout.gap * 4;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFive,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('caps board width instead of stretching across ultra-wide rows', () {
      final layout = DesktopForYouStripLayout.compute(
        available: 1800,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.maxCardWidth);
    });
  });
}
