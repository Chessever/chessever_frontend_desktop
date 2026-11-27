import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';
import 'package:chessever/theme/app_theme.dart';

/// A badge drawn in code: the badge's own silhouette holds an enamel field
/// in its colour, the frame is struck in the metal of the tier reached,
/// the glyph sits bare in the middle and the tier shows as small marks
/// under it. Locked badges keep their shape in dim metal.
class PlayAchievementBadgeArt extends StatelessWidget {
  const PlayAchievementBadgeArt({
    required this.definition,
    required this.unlocked,
    this.size = 54,
    this.tier,
    this.maxTier,
    this.sheen,
    super.key,
  });

  final PlayAchievementDefinition definition;
  final bool unlocked;
  final double size;

  /// Tier reached (1 = Bronze). When set, the frame takes that tier's
  /// metal and the tier marks show; when null the badge's own metal is
  /// used and no marks are drawn.
  final int? tier;

  /// Number of tiers on the track; empty marks are drawn for the rest.
  final int? maxTier;

  /// Position of a light sweep across the face, 0 to 1. Null draws none.
  final double? sheen;

  @override
  Widget build(BuildContext context) {
    final spec = _badgeSpec(definition.id);
    final accent = definition.color;
    final reached = tier;
    final lit = unlocked && (reached == null || reached > 0);
    final metal =
        !lit
            ? kWhiteColor.withValues(alpha: 0.30)
            : reached != null
            ? playBadgeTierMetal(reached)
            : spec.metal;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipPath(
            clipper: _BadgeFrameClipper(spec.frame),
            child: CustomPaint(
              painter: _BadgePatternPainter(
                accent: accent,
                pattern: spec.pattern,
                unlocked: lit,
                sheen: sheen,
              ),
            ),
          ),
          CustomPaint(
            painter: _BadgeFramePainter(
              frame: spec.frame,
              metal: metal,
              accent: accent,
              unlocked: lit,
            ),
          ),
          Align(
            alignment: const Alignment(0, -0.14),
            child: Icon(
              spec.icon,
              color: lit ? metal : kWhiteColor.withValues(alpha: 0.38),
              size: size * 0.34,
            ),
          ),
          if (reached != null && (maxTier ?? 0) > 0)
            Align(
              alignment: const Alignment(0, 0.52),
              child: _TierMarks(
                reached: reached,
                total: maxTier!,
                metal: metal,
                size: size,
              ),
            ),
        ],
      ),
    );
  }
}

/// Small diamonds, one per tier: filled up to the tier reached.
class _TierMarks extends StatelessWidget {
  const _TierMarks({
    required this.reached,
    required this.total,
    required this.metal,
    required this.size,
  });

  final int reached;
  final int total;
  final Color metal;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mark = size * 0.075;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++) ...[
          Transform.rotate(
            angle: math.pi / 4,
            child: SizedBox.square(
              dimension: mark,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color:
                      i < reached ? metal : kWhiteColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(mark * 0.18),
                ),
              ),
            ),
          ),
          if (i < total - 1) SizedBox(width: size * 0.045),
        ],
      ],
    );
  }
}

enum _BadgeFrame { shield, medallion, diamond, hex, banner }

enum _BadgePattern { rays, ranks, laurel, cross, wave }

class _BadgeSpec {
  const _BadgeSpec({
    required this.icon,
    required this.frame,
    required this.pattern,
    required this.metal,
  });

  final IconData icon;
  final _BadgeFrame frame;
  final _BadgePattern pattern;
  final Color metal;
}

_BadgeSpec _badgeSpec(PlayAchievementId id) {
  final index = PlayAchievementId.values.indexOf(id);
  final frame = _BadgeFrame.values[index % _BadgeFrame.values.length];
  final pattern = _BadgePattern.values[index % _BadgePattern.values.length];
  final metal = switch (index % 4) {
    0 => const Color(0xFFE8C36A),
    1 => const Color(0xFFD6DEE8),
    2 => const Color(0xFFD28A55),
    _ => const Color(0xFFFFE0A3),
  };
  return _BadgeSpec(
    icon: _badgeIcon(id),
    frame: frame,
    pattern: pattern,
    metal: metal,
  );
}

IconData _badgeIcon(PlayAchievementId id) {
  return switch (id) {
    PlayAchievementId.firstGame => Icons.event_seat_rounded,
    PlayAchievementId.firstWin => Icons.emoji_events_rounded,
    PlayAchievementId.firstDraw => Icons.balance_rounded,
    PlayAchievementId.tenGames => Icons.grid_3x3_rounded,
    PlayAchievementId.twentyFiveGames => Icons.view_module_rounded,
    PlayAchievementId.fiftyGames => Icons.auto_stories_rounded,
    PlayAchievementId.checkmateArtist => Icons.gps_fixed_rounded,
    PlayAchievementId.fiveWins => Icons.filter_5_rounded,
    PlayAchievementId.tenWins => Icons.filter_9_plus_rounded,
    PlayAchievementId.twentyFiveWins => Icons.military_tech_rounded,
    PlayAchievementId.whiteWin => Icons.light_mode_rounded,
    PlayAchievementId.bulletWinner => Icons.bolt_rounded,
    PlayAchievementId.blitzWinner => Icons.flash_on_rounded,
    PlayAchievementId.rapidWinner => Icons.speed_rounded,
    PlayAchievementId.classicalWinner => Icons.account_balance_rounded,
    PlayAchievementId.tournamentDirector => Icons.account_tree_rounded,
    PlayAchievementId.eventFinisher => Icons.flag_rounded,
    PlayAchievementId.fullHouseDirector => Icons.groups_rounded,
    PlayAchievementId.tournamentPoint => Icons.emoji_events_outlined,
    PlayAchievementId.stockfishSlayer => Icons.memory_rounded,
    PlayAchievementId.leelaBreaker => Icons.hub_rounded,
    PlayAchievementId.maiaMatch => Icons.psychology_alt_rounded,
    PlayAchievementId.blackWin => Icons.dark_mode_rounded,
    PlayAchievementId.defensiveHold => Icons.security_rounded,
    PlayAchievementId.resourcefulDraw => Icons.handshake_rounded,
    PlayAchievementId.comebackWin => Icons.trending_up_rounded,
    PlayAchievementId.swindleWin => Icons.swap_calls_rounded,
    PlayAchievementId.attackFinish => Icons.local_fire_department_rounded,
    PlayAchievementId.cleanConversion => Icons.done_all_rounded,
    PlayAchievementId.queenHunter => Icons.diamond_rounded,
    PlayAchievementId.rookRaider => Icons.castle_rounded,
    PlayAchievementId.minorPieceCollector => Icons.category_rounded,
    PlayAchievementId.promotionPoint => Icons.upgrade_rounded,
    PlayAchievementId.castleAndWin => Icons.fort_rounded,
    PlayAchievementId.endgameGrind => Icons.hourglass_bottom_rounded,
    PlayAchievementId.pawnEnding => Icons.grain_rounded,
    PlayAchievementId.rookEnding => Icons.maps_home_work_rounded,
    PlayAchievementId.minorPieceEnding => Icons.adjust_rounded,
    PlayAchievementId.caroKannWin => Icons.fort_rounded,
    PlayAchievementId.sicilianWin => Icons.bolt_rounded,
    PlayAchievementId.frenchWin => Icons.architecture_rounded,
    PlayAchievementId.queenGambitWin => Icons.workspace_premium_rounded,
    PlayAchievementId.ruyLopezWin => Icons.route_rounded,
    PlayAchievementId.londonSystemWin => Icons.foundation_rounded,
    PlayAchievementId.kingsIndianWin => Icons.temple_hindu_rounded,
    PlayAchievementId.nimzoIndianWin => Icons.schema_rounded,
    PlayAchievementId.slavWin => Icons.account_balance_rounded,
    PlayAchievementId.englishWin => Icons.park_rounded,
    PlayAchievementId.pircWin => Icons.shield_moon_rounded,
    PlayAchievementId.scandinavianWin => Icons.ac_unit_rounded,
    PlayAchievementId.playFromHereWin => Icons.my_location_rounded,
    PlayAchievementId.lowTimeSave => Icons.timer_10_select_rounded,
    PlayAchievementId.marathonSurvivor => Icons.directions_run_rounded,
    PlayAchievementId.miniatureWin => Icons.whatshot_rounded,
  };
}

class _BadgeFrameClipper extends CustomClipper<Path> {
  const _BadgeFrameClipper(this.frame);

  final _BadgeFrame frame;

  @override
  Path getClip(Size size) => _badgePath(size, frame);

  @override
  bool shouldReclip(_BadgeFrameClipper oldClipper) => frame != oldClipper.frame;
}

class _BadgeFramePainter extends CustomPainter {
  const _BadgeFramePainter({
    required this.frame,
    required this.metal,
    required this.accent,
    required this.unlocked,
  });

  final _BadgeFrame frame;
  final Color metal;
  final Color accent;
  final bool unlocked;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _badgePath(size, frame);
    final outer =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.055
          ..strokeJoin = StrokeJoin.round
          ..color = metal.withValues(alpha: unlocked ? 0.88 : 0.38);
    canvas.drawPath(path, outer);

    final inner =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.018
          ..color = kWhiteColor.withValues(alpha: unlocked ? 0.34 : 0.10);
    canvas.drawPath(path.shift(Offset(0, size.height * 0.004)), inner);
  }

  @override
  bool shouldRepaint(_BadgeFramePainter oldDelegate) =>
      frame != oldDelegate.frame ||
      metal != oldDelegate.metal ||
      accent != oldDelegate.accent ||
      unlocked != oldDelegate.unlocked;
}

class _BadgePatternPainter extends CustomPainter {
  const _BadgePatternPainter({
    required this.accent,
    required this.pattern,
    required this.unlocked,
    this.sheen,
  });

  final Color accent;
  final _BadgePattern pattern;
  final bool unlocked;
  final double? sheen;

  @override
  void paint(Canvas canvas, Size size) {
    // Enamel: the badge colour mixed down into the page ink, lighter at
    // the top where the light falls.
    final base = Color.lerp(kBlack2Color, accent, unlocked ? 0.30 : 0.07)!;
    final top = Color.lerp(kBlack2Color, accent, unlocked ? 0.42 : 0.10)!;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, base],
        ).createShader(Offset.zero & size),
    );
    _paintPattern(canvas, size);
    final s = sheen;
    if (s != null && unlocked) {
      // A narrow band of light crossing the face on a diagonal.
      final x = -size.width * 0.6 + s * size.width * 2.2;
      final band =
          Path()
            ..moveTo(x, 0)
            ..lineTo(x + size.width * 0.16, 0)
            ..lineTo(x + size.width * 0.16 - size.height * 0.6, size.height)
            ..lineTo(x - size.height * 0.6, size.height)
            ..close();
      canvas.drawPath(
        band,
        Paint()..color = kWhiteColor.withValues(alpha: 0.16),
      );
    }
  }

  void _paintPattern(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round
          ..color = kWhiteColor.withValues(alpha: unlocked ? 0.10 : 0.04);
    switch (pattern) {
      case _BadgePattern.rays:
        final center = Offset(size.width / 2, size.height / 2);
        for (var i = 0; i < 18; i++) {
          final a = i * math.pi / 9;
          final start =
              center + Offset(math.cos(a), math.sin(a)) * size.width * 0.18;
          final end =
              center + Offset(math.cos(a), math.sin(a)) * size.width * 0.52;
          canvas.drawLine(start, end, paint);
        }
      case _BadgePattern.ranks:
        for (
          var y = size.height * 0.18;
          y < size.height;
          y += size.height * 0.14
        ) {
          canvas.drawLine(
            Offset(size.width * 0.18, y),
            Offset(size.width * 0.82, y + size.height * 0.04),
            paint,
          );
        }
      case _BadgePattern.laurel:
        for (var i = 0; i < 6; i++) {
          final top = size.height * (0.22 + i * 0.08);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(size.width * 0.26, top),
              width: size.width * 0.12,
              height: size.height * 0.045,
            ),
            paint,
          );
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(size.width * 0.74, top),
              width: size.width * 0.12,
              height: size.height * 0.045,
            ),
            paint,
          );
        }
      case _BadgePattern.cross:
        canvas.drawLine(
          Offset(size.width * 0.24, size.height * 0.24),
          Offset(size.width * 0.76, size.height * 0.76),
          paint,
        );
        canvas.drawLine(
          Offset(size.width * 0.76, size.height * 0.24),
          Offset(size.width * 0.24, size.height * 0.76),
          paint,
        );
      case _BadgePattern.wave:
        final path = Path();
        for (var i = 0; i < 4; i++) {
          final y = size.height * (0.28 + i * 0.13);
          path
            ..moveTo(size.width * 0.16, y)
            ..quadraticBezierTo(
              size.width * 0.36,
              y - size.height * 0.08,
              size.width * 0.56,
              y,
            )
            ..quadraticBezierTo(
              size.width * 0.74,
              y + size.height * 0.08,
              size.width * 0.9,
              y,
            );
        }
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BadgePatternPainter oldDelegate) =>
      accent != oldDelegate.accent ||
      pattern != oldDelegate.pattern ||
      unlocked != oldDelegate.unlocked ||
      sheen != oldDelegate.sheen;
}

Path _badgePath(Size size, _BadgeFrame frame) {
  final w = size.width;
  final h = size.height;
  return switch (frame) {
    _BadgeFrame.shield =>
      Path()
        ..moveTo(w * 0.18, h * 0.12)
        ..lineTo(w * 0.82, h * 0.12)
        ..lineTo(w * 0.88, h * 0.56)
        ..quadraticBezierTo(w * 0.5, h * 0.95, w * 0.12, h * 0.56)
        ..close(),
    _BadgeFrame.medallion =>
      Path()..addOval(Rect.fromLTWH(w * 0.08, h * 0.08, w * 0.84, h * 0.84)),
    _BadgeFrame.diamond =>
      Path()
        ..moveTo(w * 0.5, h * 0.06)
        ..lineTo(w * 0.92, h * 0.5)
        ..lineTo(w * 0.5, h * 0.94)
        ..lineTo(w * 0.08, h * 0.5)
        ..close(),
    _BadgeFrame.hex =>
      Path()
        ..moveTo(w * 0.28, h * 0.08)
        ..lineTo(w * 0.72, h * 0.08)
        ..lineTo(w * 0.92, h * 0.5)
        ..lineTo(w * 0.72, h * 0.92)
        ..lineTo(w * 0.28, h * 0.92)
        ..lineTo(w * 0.08, h * 0.5)
        ..close(),
    _BadgeFrame.banner =>
      Path()
        ..moveTo(w * 0.17, h * 0.1)
        ..lineTo(w * 0.83, h * 0.1)
        ..lineTo(w * 0.83, h * 0.86)
        ..lineTo(w * 0.5, h * 0.72)
        ..lineTo(w * 0.17, h * 0.86)
        ..close(),
  };
}
