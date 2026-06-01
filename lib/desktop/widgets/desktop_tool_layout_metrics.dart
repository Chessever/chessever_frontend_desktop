import 'package:flutter/widgets.dart';

/// Shared column widths for desktop board tools.
///
/// Opening Explorer and Board Editor both put the board on the left with
/// supporting data rails to the right. Keeping these rail widths identical
/// prevents the board column from jumping when switching between the tools.
class DesktopToolLayoutMetrics {
  const DesktopToolLayoutMetrics({
    required this.middleRailWidth,
    required this.gamesRailWidth,
  });

  final double middleRailWidth;
  final double gamesRailWidth;
}

const double _kCompactBreakpoint = 1320;

DesktopToolLayoutMetrics desktopToolLayoutMetrics(BoxConstraints constraints) {
  final compact = constraints.maxWidth < _kCompactBreakpoint;
  return DesktopToolLayoutMetrics(
    middleRailWidth: compact ? 322 : 356,
    gamesRailWidth: compact ? 330 : 382,
  );
}
