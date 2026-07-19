import 'package:chessever/desktop/utils/desktop_for_you_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopForYouPaneLayout', () {
    test('keeps the event summary subordinate to game boards', () {
      expect(DesktopForYouPaneLayout.eventSummaryHeight, 120);
      expect(DesktopForYouPaneLayout.eventSummaryToGamesGap, 8);
    });

    test('uses the full tournaments workspace', () {
      expect(DesktopForYouPaneLayout.paneWidthFor(1840), 1840);
      expect(DesktopForYouPaneLayout.paneWidthFor(0), 0);
      expect(DesktopForYouPaneLayout.paneWidthFor(double.infinity), 0);
    });

    test('uses one full-width event at every desktop width', () {
      expect(DesktopForYouPaneLayout.eventColumnCountFor(1840), 1);
      expect(DesktopForYouPaneLayout.eventColumnCountFor(920), 1);
      expect(DesktopForYouPaneLayout.eventColumnCountFor(619), 1);
    });

    test('pairs events without dropping an odd final tournament', () {
      expect(
        DesktopForYouPaneLayout.eventRowCount(eventCount: 5, columnCount: 2),
        3,
      );
      expect(
        DesktopForYouPaneLayout.eventRowCount(eventCount: 5, columnCount: 1),
        5,
      );
    });

    test('uses one responsive row with five boards on a wide desktop', () {
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(1800), 5);
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(1400), 5);
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(1399), 4);
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(1049), 3);
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(759), 2);
      expect(DesktopForYouPaneLayout.boardColumnCountForEventWidth(499), 1);
      expect(DesktopForYouPaneLayout.previewLimitForEventWidth(1800), 5);
      expect(DesktopForYouPaneLayout.previewLimitForEventWidth(1200), 4);
    });

    test('balances short event rows around their actual game count', () {
      expect(
        DesktopForYouPaneLayout.balancedGameColumnCount(
          gameCount: 3,
          widthResolvedColumnCount: 3,
        ),
        3,
      );
      expect(
        DesktopForYouPaneLayout.balancedGameColumnCount(
          gameCount: 4,
          widthResolvedColumnCount: 3,
        ),
        4,
      );
      expect(
        DesktopForYouPaneLayout.balancedGameColumnCount(
          gameCount: 6,
          widthResolvedColumnCount: 3,
        ),
        3,
      );
    });

    test('page keys scroll substantially farther than arrow keys', () {
      expect(DesktopForYouPaneLayout.keyboardArrowScrollExtent, 96);
      expect(DesktopForYouPaneLayout.keyboardPageScrollExtent(800), 680);
      expect(
        DesktopForYouPaneLayout.keyboardPageScrollExtent(double.infinity),
        384,
      );
    });

    test('keyboard and middle-drag targets stay inside the scroll range', () {
      expect(
        DesktopForYouPaneLayout.clampedScrollTarget(
          currentOffset: 500,
          delta: 96,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
        ),
        596,
      );
      expect(
        DesktopForYouPaneLayout.clampedScrollTarget(
          currentOffset: 40,
          delta: -96,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
        ),
        0,
      );
      expect(
        DesktopForYouPaneLayout.clampedScrollTarget(
          currentOffset: 950,
          delta: 680,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
        ),
        1000,
      );
    });
  });
}
