import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/theme/app_theme.dart';

/// Selectable time window for the chart's x-axis.
enum PlayRatingChartRange { last30Days, last90Days, last180Days, allTime }

extension PlayRatingChartRangeLabel on PlayRatingChartRange {
  String get label {
    switch (this) {
      case PlayRatingChartRange.last30Days:
        return '30D';
      case PlayRatingChartRange.last90Days:
        return '90D';
      case PlayRatingChartRange.last180Days:
        return '6M';
      case PlayRatingChartRange.allTime:
        return 'ALL';
    }
  }

  Duration? get window {
    switch (this) {
      case PlayRatingChartRange.last30Days:
        return const Duration(days: 30);
      case PlayRatingChartRange.last90Days:
        return const Duration(days: 90);
      case PlayRatingChartRange.last180Days:
        return const Duration(days: 180);
      case PlayRatingChartRange.allTime:
        return null;
    }
  }
}

/// Animated date-vs-Elo chart for a single rated ladder.
///
/// - Pure Flutter (CustomPainter + AnimationController). No third-party
///   chart packages, so it inherits the existing theme tokens and the
///   forui-driven dark palette without extra theming work.
/// - Animates `progress` 0->1 on mount and on data swaps; the path is
///   sliced by `Path.computeMetrics()` so the line literally draws in.
/// - Hover via MouseRegion: the nearest point to the cursor x snaps into
///   focus and renders a guideline + tooltip with date, rating, and
///   delta.
class PlayRatingChart extends StatefulWidget {
  const PlayRatingChart({
    super.key,
    required this.points,
    required this.accent,
    this.range = PlayRatingChartRange.last90Days,
    this.showAxisLabels = true,
    this.height = 220,
  });

  final List<PlayRatingPoint> points;
  final Color accent;
  final PlayRatingChartRange range;
  final bool showAxisLabels;
  final double height;

  @override
  State<PlayRatingChart> createState() => _PlayRatingChartState();
}

class _PlayRatingChartState extends State<PlayRatingChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  Offset? _hover;
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant PlayRatingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final swappedData = oldWidget.points != widget.points ||
        oldWidget.range != widget.range;
    if (swappedData) {
      _controller
        ..stop()
        ..reset()
        ..forward();
      _hover = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<PlayRatingPoint> _windowedPoints() {
    final window = widget.range.window;
    if (window == null) return widget.points;
    final cutoff = DateTime.now().subtract(window);
    return widget.points.where((p) => !p.playedAt.isBefore(cutoff)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final pts = _windowedPoints();
    return SizedBox(
      height: widget.height,
      child: MouseRegion(
        onHover: (event) => setState(() => _hover = event.localPosition),
        onExit: (_) => setState(() => _hover = null),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _lastSize = Size(constraints.maxWidth, constraints.maxHeight);
            return AnimatedBuilder(
              animation: _progress,
              builder: (context, _) {
                return CustomPaint(
                  size: _lastSize,
                  painter: _PlayRatingChartPainter(
                    points: pts,
                    accent: widget.accent,
                    progress: _progress.value,
                    hover: _hover,
                    showAxisLabels: widget.showAxisLabels,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PlayRatingChartPainter extends CustomPainter {
  _PlayRatingChartPainter({
    required this.points,
    required this.accent,
    required this.progress,
    required this.hover,
    required this.showAxisLabels,
  });

  final List<PlayRatingPoint> points;
  final Color accent;
  final double progress;
  final Offset? hover;
  final bool showAxisLabels;

  static const double _padLeft = 44;
  static const double _padRight = 12;
  static const double _padTop = 16;
  static const double _padBottom = 26;

  @override
  void paint(Canvas canvas, Size size) {
    final plotRect = Rect.fromLTRB(
      _padLeft,
      _padTop,
      size.width - _padRight,
      size.height - _padBottom,
    );

    _paintGrid(canvas, plotRect);

    if (points.isEmpty) {
      _paintEmptyHint(canvas, plotRect);
      return;
    }

    final ratings = points.map((p) => p.rating).toList(growable: false);
    final minR = ratings.reduce(math.min);
    final maxR = ratings.reduce(math.max);
    final padding = math.max(20, ((maxR - minR) * 0.25).round());
    final ymin = (minR - padding).clamp(0, 4000).toDouble();
    final ymax = (maxR + padding).clamp(0, 4000).toDouble();
    final yspan = math.max(1.0, ymax - ymin);

    final firstDate = points.first.playedAt;
    final lastDate = points.last.playedAt;
    final dayspan = math.max(
      1,
      lastDate.difference(firstDate).inSeconds,
    );

    Offset xy(int i) {
      final p = points[i];
      final tx = points.length == 1
          ? plotRect.right
          : plotRect.left +
              (plotRect.width *
                  p.playedAt.difference(firstDate).inSeconds /
                  dayspan);
      final ty = plotRect.bottom -
          (plotRect.height * (p.rating - ymin) / yspan);
      return Offset(tx, ty);
    }

    if (showAxisLabels) {
      _paintYAxisLabels(canvas, plotRect, ymin, ymax);
      _paintXAxisLabels(canvas, plotRect, firstDate, lastDate);
    }

    // --- area fill + line, draw-in via path metrics --------------------
    final linePath = Path();
    for (var i = 0; i < points.length; i++) {
      final pt = xy(i);
      if (i == 0) {
        linePath.moveTo(pt.dx, pt.dy);
      } else {
        linePath.lineTo(pt.dx, pt.dy);
      }
    }

    final drawnLine = _slicePath(linePath, progress);

    // Build a clipped gradient fill that follows only the drawn portion.
    final fillPath = Path.from(drawnLine);
    if (progress > 0 && points.isNotEmpty) {
      final lastDrawnX = _lastDrawnX(drawnLine, fallback: xy(0).dx);
      fillPath
        ..lineTo(lastDrawnX, plotRect.bottom)
        ..lineTo(xy(0).dx, plotRect.bottom)
        ..close();
    }

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(plotRect.left, plotRect.top),
          Offset(plotRect.left, plotRect.bottom),
          [
            accent.withValues(alpha: 0.32),
            accent.withValues(alpha: 0.02),
          ],
        ),
    );

    canvas.drawPath(
      drawnLine,
      Paint()
        ..color = accent
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Dots only fade in once the line has fully drawn so the chart
    // resolves cleanly instead of dots popping mid-animation.
    final dotOpacity = ((progress - 0.65) / 0.35).clamp(0.0, 1.0);
    if (dotOpacity > 0) {
      for (var i = 0; i < points.length; i++) {
        final c = xy(i);
        canvas.drawCircle(
          c,
          2.6,
          Paint()..color = accent.withValues(alpha: 0.65 * dotOpacity),
        );
      }
    }

    // Headline dot on the latest rating.
    if (progress >= 0.98) {
      final last = xy(points.length - 1);
      canvas.drawCircle(
        last,
        9,
        Paint()..color = accent.withValues(alpha: 0.18),
      );
      canvas.drawCircle(last, 4.5, Paint()..color = accent);
    }

    // --- hover overlay -------------------------------------------------
    final hover = this.hover;
    if (hover != null && progress >= 0.95 && points.isNotEmpty) {
      final nearestIdx = _nearestIndex(hover.dx, xy);
      final pt = xy(nearestIdx);
      final guidePaint = Paint()
        ..color = kWhiteColor.withValues(alpha: 0.18)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(pt.dx, plotRect.top),
        Offset(pt.dx, plotRect.bottom),
        guidePaint,
      );
      canvas.drawCircle(
        pt,
        6,
        Paint()..color = accent.withValues(alpha: 0.22),
      );
      canvas.drawCircle(pt, 3.5, Paint()..color = accent);
      _paintTooltip(canvas, plotRect, pt, points[nearestIdx]);
    }
  }

  void _paintGrid(Canvas canvas, Rect rect) {
    final gridPaint = Paint()
      ..color = kDividerColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), gridPaint);
    }
  }

  void _paintEmptyHint(Canvas canvas, Rect rect) {
    final tp = TextPainter(
      text: const TextSpan(
        text: 'No rated games yet.',
        style: TextStyle(
          color: kSecondaryTextColor,
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    tp.paint(
      canvas,
      rect.center.translate(-tp.width / 2, -tp.height / 2),
    );
  }

  void _paintYAxisLabels(Canvas canvas, Rect rect, double ymin, double ymax) {
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      final value = ymin + (ymax - ymin) * (1 - t);
      final tp = TextPainter(
        text: TextSpan(
          text: value.round().toString(),
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 10,
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          rect.left - tp.width - 6,
          rect.top + rect.height * t - tp.height / 2,
        ),
      );
    }
  }

  void _paintXAxisLabels(
    Canvas canvas,
    Rect rect,
    DateTime first,
    DateTime last,
  ) {
    String fmt(DateTime d) {
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[d.month - 1]} ${d.day}';
    }

    final leftTp = TextPainter(
      text: TextSpan(
        text: fmt(first),
        style: const TextStyle(
          color: kSecondaryTextColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    leftTp.paint(canvas, Offset(rect.left, rect.bottom + 6));

    final rightTp = TextPainter(
      text: TextSpan(
        text: fmt(last),
        style: const TextStyle(
          color: kSecondaryTextColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    rightTp.paint(
      canvas,
      Offset(rect.right - rightTp.width, rect.bottom + 6),
    );
  }

  void _paintTooltip(
    Canvas canvas,
    Rect plotRect,
    Offset anchor,
    PlayRatingPoint point,
  ) {
    final deltaText = point.delta >= 0 ? '+${point.delta}' : '${point.delta}';
    final deltaColor = point.delta > 0
        ? kGreenColor
        : point.delta < 0
            ? kRedColor
            : kSecondaryTextColor;

    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = point.playedAt;
    final dateLabel = '${months[d.month - 1]} ${d.day}, ${d.year}';

    final tpDate = TextPainter(
      text: TextSpan(
        text: dateLabel,
        style: const TextStyle(
          color: kSecondaryTextColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final tpRating = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '${point.rating}',
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(
            text: '  $deltaText',
            style: TextStyle(
              color: deltaColor,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final boxPadX = 10.0;
    final boxPadY = 8.0;
    final boxWidth =
        math.max(tpDate.width, tpRating.width) + boxPadX * 2;
    final boxHeight = tpDate.height + tpRating.height + 6 + boxPadY * 2;

    var left = anchor.dx + 10;
    if (left + boxWidth > plotRect.right) {
      left = anchor.dx - boxWidth - 10;
    }
    final top = (anchor.dy - boxHeight / 2)
        .clamp(plotRect.top, plotRect.bottom - boxHeight);

    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, boxWidth, boxHeight),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      box,
      Paint()..color = kBlack2Color.withValues(alpha: 0.96),
    );
    canvas.drawRRect(
      box,
      Paint()
        ..color = kDividerColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    tpRating.paint(canvas, Offset(left + boxPadX, top + boxPadY));
    tpDate.paint(
      canvas,
      Offset(left + boxPadX, top + boxPadY + tpRating.height + 6),
    );
  }

  // ------------------------------------------------------------------
  // Geometry helpers
  // ------------------------------------------------------------------

  Path _slicePath(Path full, double t) {
    if (t >= 1) return full;
    if (t <= 0) return Path();
    final metrics = full.computeMetrics().toList();
    final totalLength = metrics.fold<double>(0, (sum, m) => sum + m.length);
    final target = totalLength * t;
    final out = Path();
    double consumed = 0;
    for (final metric in metrics) {
      if (consumed + metric.length <= target) {
        out.addPath(metric.extractPath(0, metric.length), Offset.zero);
        consumed += metric.length;
      } else {
        out.addPath(
          metric.extractPath(0, target - consumed),
          Offset.zero,
        );
        break;
      }
    }
    return out;
  }

  double _lastDrawnX(Path path, {required double fallback}) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return fallback;
    final last = metrics.last;
    final tan = last.getTangentForOffset(last.length);
    return tan?.position.dx ?? fallback;
  }

  int _nearestIndex(double hoverX, Offset Function(int) xy) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final dist = (xy(i).dx - hoverX).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    return best;
  }

  @override
  bool shouldRepaint(covariant _PlayRatingChartPainter old) =>
      old.points != points ||
      old.progress != progress ||
      old.hover != hover ||
      old.accent != accent;
}
