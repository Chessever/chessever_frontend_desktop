class DesktopForYouStripLayout {
  const DesktopForYouStripLayout({
    required this.visibleCount,
    required this.cardWidth,
  });

  static const double gap = 14;
  static const double minCardWidth = 220;
  static const double maxCardWidth = 280;

  final int visibleCount;
  final double cardWidth;

  /// Pack as many board cards as fit at [minCardWidth]. There is NO hard
  /// game-count cap — the visible count is governed purely by how many
  /// [minCardWidth] cards fit in [available] and how many games the
  /// caller actually has. Card width is then clamped to [maxCardWidth]
  /// so individual boards never stretch.
  static DesktopForYouStripLayout compute({
    required double available,
    required int gameCount,
  }) {
    if (available <= 0 || gameCount <= 0) {
      return const DesktopForYouStripLayout(visibleCount: 0, cardWidth: 0);
    }

    final fitsAtMin = ((available + gap) / (minCardWidth + gap)).floor();
    final visible = fitsAtMin.clamp(1, gameCount).toInt();
    final raw =
        visible == 1 ? available : (available - (visible - 1) * gap) / visible;
    final width = raw.clamp(minCardWidth, maxCardWidth).toDouble();

    return DesktopForYouStripLayout(visibleCount: visible, cardWidth: width);
  }
}
