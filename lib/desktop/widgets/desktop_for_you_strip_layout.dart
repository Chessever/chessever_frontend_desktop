import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:flutter/widgets.dart';

class DesktopForYouStripLayout {
  const DesktopForYouStripLayout({
    required this.visibleCount,
    required this.cardWidth,
    this.columns = 0,
    this.rows = 0,
  });

  static const double gap = 14;
  static const double minCardWidth = 220;
  static const double maxCardWidth = 280;

  final int visibleCount;
  final double cardWidth;
  final int columns;
  final int rows;

  /// Keep every preview inside the adjacent event card's height. Compact
  /// cards occupy three rows; the larger list previews occupy two.
  static double heightFor(DesktopCardLayout layout) {
    if (layout == DesktopCardLayout.grid) return 292;
    final metrics = DesktopGameCardsFlow.metricsFor(layout);
    final rows = layout == DesktopCardLayout.compact ? 3 : 2;
    return rows * metrics.tileHeight + (rows - 1) * metrics.spacing;
  }

  /// Use the same columns as the shared desktop card flow. Grid mode keeps
  /// one row of boards; Compact and List fill the adjacent event's height.
  static DesktopForYouStripLayout compute({
    required double available,
    required int gameCount,
    DesktopCardLayout layout = DesktopCardLayout.grid,
  }) {
    if (!available.isFinite || available <= 0 || gameCount <= 0) {
      return const DesktopForYouStripLayout(visibleCount: 0, cardWidth: 0);
    }

    if (layout != DesktopCardLayout.grid) {
      final metrics = DesktopGameCardsFlow.metricsFor(layout);
      final columns = DesktopGameCardsFlow.columnCountForWidth(
        layout,
        available,
      );
      final rows = layout == DesktopCardLayout.compact ? 3 : 2;
      return DesktopForYouStripLayout(
        visibleCount: (columns * rows).clamp(0, gameCount),
        cardWidth: (available - (columns - 1) * metrics.spacing) / columns,
        columns: columns,
        rows: rows,
      );
    }

    final fitsAtMin = ((available + gap) / (minCardWidth + gap)).floor();
    final visible = fitsAtMin.clamp(1, gameCount).toInt();
    final raw =
        visible == 1 ? available : (available - (visible - 1) * gap) / visible;
    final width = raw.clamp(0.0, maxCardWidth).toDouble();

    return DesktopForYouStripLayout(
      visibleCount: visible,
      cardWidth: width,
      columns: visible,
      rows: 1,
    );
  }
}

/// Bounded game previews used for both loaded cards and loading placeholders.
/// The caller keeps event ordering and controls how many games are fetched;
/// this widget only chooses how many of those games fit on screen.
class DesktopForYouGamesPreview extends StatelessWidget {
  const DesktopForYouGamesPreview({
    super.key,
    required this.layout,
    required this.itemCount,
    required this.itemBuilder,
    this.onLayoutResolved,
  });

  final DesktopCardLayout layout;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Called during layout. State changes must be deferred until after frame.
  final ValueChanged<DesktopForYouStripLayout>? onLayoutResolved;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final strip = DesktopForYouStripLayout.compute(
        available: constraints.maxWidth,
        gameCount: itemCount,
        layout: layout,
      );
      onLayoutResolved?.call(strip);
      if (layout != DesktopCardLayout.grid) {
        return DesktopGameCardsFlow(
          layout: layout,
          itemCount: strip.visibleCount,
          embedded: true,
          itemBuilder: itemBuilder,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < strip.visibleCount; i++) ...[
            if (i > 0) const SizedBox(width: DesktopForYouStripLayout.gap),
            SizedBox(width: strip.cardWidth, child: itemBuilder(context, i)),
          ],
          const Spacer(),
        ],
      );
    },
  );
}
