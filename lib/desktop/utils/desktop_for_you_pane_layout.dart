class DesktopForYouPaneLayout {
  const DesktopForYouPaneLayout._();

  static const double eventColumnGap = 12;
  static const double fiveBoardColumnBreakpoint = 1400;
  static const double fourBoardColumnBreakpoint = 1050;
  static const double threeBoardColumnBreakpoint = 760;
  static const double twoBoardColumnBreakpoint = 500;
  static const double eventSummaryHeight = 120;
  static const double eventSummaryToGamesGap = 8;
  static const double keyboardArrowScrollExtent = 96;
  static const double keyboardPageScrollFactor = 0.85;

  /// The desktop For You feed uses the full tournaments workspace. Its event
  /// columns retain the familiar tablet hierarchy without leaving unused
  /// desktop space beside the feed.
  static double paneWidthFor(double availableWidth) {
    if (!availableWidth.isFinite || availableWidth <= 0) return 0;
    return availableWidth;
  }

  static int eventColumnCountFor(double paneWidth) {
    return 1;
  }

  static int eventRowCount({
    required int eventCount,
    required int columnCount,
  }) {
    if (eventCount <= 0) return 0;
    final columns = columnCount <= 0 ? 1 : columnCount;
    return (eventCount + columns - 1) ~/ columns;
  }

  /// A full-width event gets one row of larger boards: five on a wide desktop,
  /// then progressively fewer as the window narrows so previews never become
  /// cramped on a laptop.
  static int boardColumnCountForEventWidth(double eventWidth) {
    if (!eventWidth.isFinite || eventWidth <= 0) return 1;
    if (eventWidth >= fiveBoardColumnBreakpoint) return 5;
    if (eventWidth >= fourBoardColumnBreakpoint) return 4;
    if (eventWidth >= threeBoardColumnBreakpoint) return 3;
    if (eventWidth >= twoBoardColumnBreakpoint) return 2;
    return 1;
  }

  /// Keep previews to a single complete row. On a wide desktop this is five;
  /// narrower windows automatically show four, three, two, or one.
  static int previewLimitForEventWidth(double eventWidth) {
    return boardColumnCountForEventWidth(eventWidth);
  }

  /// Avoid visibly broken final rows when an event has fewer games than the
  /// responsive preview allowance. Four games use one balanced row on a wide
  /// desktop instead of an awkward 3 + 1 layout; partial final rows are
  /// centered by the game-card flow.
  static int balancedGameColumnCount({
    required int gameCount,
    required int widthResolvedColumnCount,
  }) {
    final resolved = widthResolvedColumnCount.clamp(1, 6).toInt();
    if (gameCount <= 0) return resolved;
    if (gameCount == 1) return 2;
    if (gameCount <= resolved) return gameCount;
    if (gameCount == 4 && resolved == 3) return 4;
    return resolved;
  }

  /// Arrow keys move by a readable fraction of one event section, while Page
  /// Up/Down move by most of the viewport so the two controls feel distinct.
  static double keyboardPageScrollExtent(double viewportExtent) {
    final minimum = keyboardArrowScrollExtent * 4;
    if (!viewportExtent.isFinite || viewportExtent <= 0) return minimum;
    return (viewportExtent * keyboardPageScrollFactor)
        .clamp(minimum, double.infinity)
        .toDouble();
  }

  static double clampedScrollTarget({
    required double currentOffset,
    required double delta,
    required double minScrollExtent,
    required double maxScrollExtent,
  }) {
    return (currentOffset + delta)
        .clamp(minScrollExtent, maxScrollExtent)
        .toDouble();
  }
}
