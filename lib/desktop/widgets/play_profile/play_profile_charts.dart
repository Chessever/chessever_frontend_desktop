import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_stats_summary.dart';
import 'package:chessever/theme/app_theme.dart';

/// Colour steps shared by every result chart: wins in the brand teal,
/// draws and losses as two quiet ink steps.
const Color kPlayWinColor = kPrimaryColor;
final Color kPlayDrawColor = kWhiteColor.withValues(alpha: 0.42);
final Color kPlayLossColor = kWhiteColor.withValues(alpha: 0.16);

const TextStyle _kAxis = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 10,
  fontWeight: FontWeight.w600,
  fontFeatures: [FontFeature.tabularFigures()],
);

String _shortDate(DateTime d) {
  const months = [
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

// ---------------------------------------------------------------------------
// Rating timeline
// ---------------------------------------------------------------------------

/// Rating after every rated game on one ladder, oldest left. Games are
/// spaced evenly so a busy evening does not squash into one pixel; the
/// dates under the axis give the span. Provisional stretches (RD above the
/// "?" line) are drawn fainter. Hovering a game shows its numbers.
class PlayRatingTimeline extends StatefulWidget {
  const PlayRatingTimeline({
    super.key,
    required this.points,
    this.height = 200,
    this.emptyLabel = 'No rated games on this clock yet.',
  });

  final List<PlayRatingPoint> points;
  final double height;
  final String emptyLabel;

  @override
  State<PlayRatingTimeline> createState() => _PlayRatingTimelineState();
}

class _PlayRatingTimelineState extends State<PlayRatingTimeline> {
  int? _hover;

  static const double _right = 44;
  static const double _top = 30;
  static const double _bottom = 22;

  void _track(Offset local, double width) {
    final n = widget.points.length;
    if (n == 0) return;
    final plot = width - _right;
    final x = local.dx.clamp(0.0, plot);
    final i = n == 1 ? 0 : (x / plot * (n - 1)).round().clamp(0, n - 1);
    if (i != _hover) setState(() => _hover = i);
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            widget.emptyLabel,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    final focus = points[_hover ?? points.length - 1];
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder:
            (context, constraints) => MouseRegion(
              onHover: (e) => _track(e.localPosition, constraints.maxWidth),
              onExit: (_) => setState(() => _hover = null),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        labelStyle: DefaultTextStyle.of(
                          context,
                        ).style.merge(_kAxis),
                        points: points,
                        hover: _hover,
                        right: _right,
                        top: _top,
                        bottom: _bottom,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    right: _right,
                    child: _Readout(point: focus, hovering: _hover != null),
                  ),
                ],
              ),
            ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.point, required this.hovering});

  final PlayRatingPoint point;
  final bool hovering;

  @override
  Widget build(BuildContext context) {
    final d = point.delta;
    final result =
        point.score == 1
            ? 'Won'
            : point.score == 0.5
            ? 'Drew'
            : 'Lost';
    final opp = point.opponentElo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(hovering ? _shortDate(point.playedAt) : 'Latest', style: _kAxis),
        const SizedBox(width: 10),
        Text(
          '${point.rating}${point.isProvisional ? '?' : ''}',
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          d == 0 ? '0' : (d > 0 ? '+$d' : '$d'),
          style: TextStyle(
            color:
                d > 0
                    ? kPlayWinColor
                    : d < 0
                    ? kWhiteColor70
                    : kSecondaryTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            opp == null ? result : '$result vs $opp',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _kAxis,
          ),
        ),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.labelStyle,
    required this.points,
    required this.hover,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final TextStyle labelStyle;
  final List<PlayRatingPoint> points;
  final int? hover;
  final double right;
  final double top;
  final double bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      0,
      top,
      size.width - right,
      size.height - bottom,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    var lo = points.map((p) => p.rating).reduce(math.min);
    var hi = points.map((p) => p.rating).reduce(math.max);
    lo = ((lo - 20) / 50).floor() * 50;
    hi = ((hi + 20) / 50).ceil() * 50;
    if (hi - lo < 100) {
      final mid = (hi + lo) ~/ 2;
      lo = mid - 50;
      hi = mid + 50;
    }

    double xOf(int i) =>
        points.length == 1
            ? plot.center.dx
            : plot.left + plot.width * i / (points.length - 1);
    double yOf(int r) => plot.bottom - plot.height * (r - lo) / (hi - lo);

    // Three guide ratings with their labels on the right.
    final guide =
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.05)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round;
    for (var k = 0; k <= 2; k++) {
      final r = (lo + (hi - lo) * k / 2).round();
      final y = yOf(r);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), guide);
      _text(canvas, '$r', Offset(plot.right + 8, y - 6));
    }
    _text(
      canvas,
      _shortDate(points.first.playedAt),
      Offset(0, plot.bottom + 7),
    );
    if (points.length > 1) {
      _text(
        canvas,
        _shortDate(points.last.playedAt),
        Offset(plot.right, plot.bottom + 7),
        alignRight: true,
      );
    }

    final offsets = [
      for (var i = 0; i < points.length; i++)
        Offset(xOf(i), yOf(points[i].rating)),
    ];

    if (offsets.length > 1) {
      final area = Path()..moveTo(offsets.first.dx, plot.bottom);
      for (final o in offsets) {
        area.lineTo(o.dx, o.dy);
      }
      area
        ..lineTo(offsets.last.dx, plot.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()..color = kPrimaryColor.withValues(alpha: 0.07),
      );

      for (var i = 1; i < offsets.length; i++) {
        final faint = points[i].isProvisional;
        canvas.drawLine(
          offsets[i - 1],
          offsets[i],
          Paint()
            ..color = kPrimaryColor.withValues(alpha: faint ? 0.45 : 0.95)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // Peak marker: a small ring on the best rating.
    var peak = 0;
    for (var i = 1; i < points.length; i++) {
      if (points[i].rating > points[peak].rating) peak = i;
    }
    canvas.drawCircle(
      offsets[peak],
      3.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = kWhiteColor.withValues(alpha: 0.7),
    );

    final focus = hover ?? points.length - 1;
    if (hover != null) {
      canvas.drawLine(
        Offset(offsets[focus].dx, plot.top),
        Offset(offsets[focus].dx, plot.bottom),
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.16)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(offsets[focus], 4.5, Paint()..color = kBackgroundColor);
    canvas.drawCircle(offsets[focus], 3.5, Paint()..color = kPrimaryColor);
  }

  void _text(Canvas canvas, String s, Offset at, {bool alignRight = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, alignRight ? at - Offset(tp.width, 0) : at);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.points != points || old.hover != hover;
}

// ---------------------------------------------------------------------------
// Result bar
// ---------------------------------------------------------------------------

/// Won / drawn / lost as one rounded bar. Segments ease to new widths when
/// the numbers change; on first build they are already at their width.
class PlayWdlBar extends StatelessWidget {
  const PlayWdlBar({super.key, required this.record, this.height = 6});

  final PlayWdl record;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = record.games;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child:
            total == 0
                ? ColoredBox(color: kWhiteColor.withValues(alpha: 0.06))
                : LayoutBuilder(
                  builder: (context, c) {
                    double w(int v) => c.maxWidth * v / total;
                    return Row(
                      children: [
                        _Seg(width: w(record.wins), color: kPlayWinColor),
                        _Seg(width: w(record.draws), color: kPlayDrawColor),
                        _Seg(width: w(record.losses), color: kPlayLossColor),
                      ],
                    );
                  },
                ),
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      width: width,
      color: color,
    );
  }
}

// ---------------------------------------------------------------------------
// Form strip
// ---------------------------------------------------------------------------

/// The last results as small squares, oldest left. Hover names the result.
class PlayFormStrip extends StatelessWidget {
  const PlayFormStrip({super.key, required this.form, this.cell = 14});

  final List<PlayStreakKind> form;
  final double cell;

  @override
  Widget build(BuildContext context) {
    if (form.isEmpty) {
      return const Text('No games yet', style: _kAxis);
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final k in form)
          SizedBox.square(
            dimension: cell,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: switch (k) {
                  PlayStreakKind.win => kPlayWinColor,
                  PlayStreakKind.draw => kPlayDrawColor,
                  PlayStreakKind.loss => kPlayLossColor,
                },
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Score by bot strength
// ---------------------------------------------------------------------------

/// Score percentage against each 200-point band of bot strength. Bars
/// rise from the bottom; the dashed level marks 50%, and the band that
/// holds [yourRating] is labelled.
class PlayStrengthChart extends StatefulWidget {
  const PlayStrengthChart({
    super.key,
    required this.bands,
    this.yourRating,
    this.height = 168,
  });

  final List<PlayStrengthBand> bands;
  final int? yourRating;
  final double height;

  @override
  State<PlayStrengthChart> createState() => _PlayStrengthChartState();
}

class _PlayStrengthChartState extends State<PlayStrengthChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final bands = widget.bands;
    if (bands.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: const Center(
          child: Text(
            'Finish a game to see how you score by bot strength.',
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    final focus = _hover == null ? null : bands[_hover!];
    return SizedBox(
      height: widget.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 18,
            child: Text(
              focus == null
                  ? 'Hover a bar for the games behind it'
                  : '${focus.from} to ${focus.to}: '
                      '${focus.record.wins}W ${focus.record.draws}D '
                      '${focus.record.losses}L, ${focus.record.scorePct}%',
              style: _kAxis,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final slot = c.maxWidth / bands.length;
                return MouseRegion(
                  onHover: (e) {
                    final i = (e.localPosition.dx / slot).floor().clamp(
                      0,
                      bands.length - 1,
                    );
                    if (i != _hover) setState(() => _hover = i);
                  },
                  onExit: (_) => setState(() => _hover = null),
                  child: CustomPaint(
                    size: Size(c.maxWidth, c.maxHeight),
                    painter: _StrengthPainter(
                      labelStyle: DefaultTextStyle.of(
                        context,
                      ).style.merge(_kAxis),
                      bands: bands,
                      hover: _hover,
                      yourRating: widget.yourRating,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StrengthPainter extends CustomPainter {
  _StrengthPainter({
    required this.labelStyle,
    required this.bands,
    required this.hover,
    required this.yourRating,
  });

  final TextStyle labelStyle;
  final List<PlayStrengthBand> bands;
  final int? hover;
  final int? yourRating;

  static const double _labelH = 18;
  static const double _valueH = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final plotTop = _valueH;
    final plotBottom = size.height - _labelH;
    final plotH = plotBottom - plotTop;
    if (plotH <= 0) return;
    final slot = size.width / bands.length;
    final barW = math.min(34.0, slot * 0.56);

    // 50% level, drawn as short rounded dashes.
    final half = plotBottom - plotH * 0.5;
    final dash =
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.14)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, half),
        Offset(math.min(x + 3, size.width), half),
        dash,
      );
    }

    for (var i = 0; i < bands.length; i++) {
      final b = bands[i];
      final cx = slot * i + slot / 2;
      final pct = b.record.scorePct / 100;
      final h = math.max(3.0, plotH * pct);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - barW / 2, plotBottom - h, barW, h),
        topLeft: const Radius.circular(5),
        topRight: const Radius.circular(5),
      );
      final yours =
          yourRating != null && yourRating! >= b.from && yourRating! <= b.to;
      final active = hover == null || hover == i;
      final base = pct >= 0.5 ? kPlayWinColor : kWhiteColor;
      canvas.drawRRect(
        rect,
        Paint()
          ..color = base.withValues(
            alpha: (pct >= 0.5 ? 0.85 : 0.32) * (active ? 1 : 0.45),
          ),
      );
      _text(
        canvas,
        '${b.record.scorePct}%',
        Offset(cx, plotBottom - h - _valueH + 2),
        color: active ? kWhiteColor70 : kSecondaryTextColor,
      );
      _text(
        canvas,
        yours ? '${b.from} you' : '${b.from}',
        Offset(cx, plotBottom + 5),
        color: yours ? kWhiteColor : kSecondaryTextColor,
      );
    }
  }

  void _text(Canvas canvas, String s, Offset center, {required Color color}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: labelStyle.copyWith(color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy));
  }

  @override
  bool shouldRepaint(_StrengthPainter old) =>
      old.bands != bands || old.hover != hover || old.yourRating != yourRating;
}

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------

/// Games per day over the last [kPlayActivityDays] days: one column per
/// week, Monday on top, today bottom-right. Busier days are brighter.
class PlayActivityGrid extends StatelessWidget {
  const PlayActivityGrid({
    super.key,
    required this.activity,
    this.cell = 13,
    this.gap = 3,
    this.now,
  });

  final Map<int, int> activity;
  final double cell;
  final double gap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final today = now ?? DateTime.now();
    final weeks = (kPlayActivityDays / 7).ceil();
    // Row of today in its week, Monday = 0.
    final todayRow = today.weekday - 1;
    final busiest = activity.values.fold<int>(0, math.max);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var w = weeks - 1; w >= 0; w--) ...[
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var row = 0; row < 7; row++) ...[
                _cellFor(w * 7 + (todayRow - row), busiest),
                if (row < 6) SizedBox(height: gap),
              ],
            ],
          ),
          if (w > 0) SizedBox(width: gap),
        ],
      ],
    );
  }

  Widget _cellFor(int daysAgo, int busiest) {
    final inRange = daysAgo >= 0 && daysAgo < kPlayActivityDays;
    final count = inRange ? (activity[daysAgo] ?? 0) : 0;
    final Color color;
    if (!inRange) {
      color = Colors.transparent;
    } else if (count == 0) {
      color = kWhiteColor.withValues(alpha: 0.05);
    } else {
      final t = busiest <= 1 ? 1.0 : (count / busiest).clamp(0.0, 1.0);
      color = kPrimaryColor.withValues(alpha: 0.30 + 0.65 * t);
    }
    return SizedBox.square(
      dimension: cell,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
    );
  }
}
