import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/theme/app_theme.dart';

class PlayAchievementBadgeArt extends StatelessWidget {
  const PlayAchievementBadgeArt({
    required this.definition,
    required this.unlocked,
    this.size = 54,
    super.key,
  });

  final PlayAchievementDefinition definition;
  final bool unlocked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final spec = _badgeSpec(definition.id);
    final accent = definition.color;
    final metal = unlocked ? spec.metal : kWhiteColor.withValues(alpha: 0.36);
    final enamel = unlocked ? accent : kBlack3Color;

    return AnimatedScale(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      scale: unlocked ? 1 : 0.94,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.24),
                boxShadow: [
                  if (unlocked)
                    BoxShadow(
                      color: accent.withValues(alpha: 0.22),
                      blurRadius: size * 0.18,
                      offset: Offset(0, size * 0.08),
                    ),
                ],
              ),
            ),
            ClipPath(
              clipper: _BadgeFrameClipper(spec.frame),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: enamel.withValues(alpha: unlocked ? 0.42 : 0.18),
                ),
                child: CustomPaint(
                  painter: _BadgePatternPainter(
                    accent: accent,
                    pattern: spec.pattern,
                    unlocked: unlocked,
                  ),
                ),
              ),
            ),
            CustomPaint(
              painter: _BadgeFramePainter(
                frame: spec.frame,
                metal: metal,
                accent: accent,
                unlocked: unlocked,
              ),
            ),
            Center(
              child: Container(
                width: size * 0.48,
                height: size * 0.48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      unlocked
                          ? kBlackColor.withValues(alpha: 0.34)
                          : kBlackColor.withValues(alpha: 0.54),
                  border: Border.all(
                    color: metal.withValues(alpha: unlocked ? 0.74 : 0.32),
                    width: 1.1,
                  ),
                ),
                child: Icon(
                  spec.icon,
                  color: unlocked ? metal : kWhiteColor.withValues(alpha: 0.54),
                  size: size * 0.27,
                ),
              ),
            ),
            Positioned(
              right: size * 0.16,
              bottom: size * 0.13,
              child: Transform.rotate(
                angle: spec.runeTilt,
                child: Container(
                  width: size * 0.18,
                  height: size * 0.18,
                  decoration: BoxDecoration(
                    color:
                        unlocked
                            ? accent.withValues(alpha: 0.82)
                            : kBlack2Color,
                    borderRadius: BorderRadius.circular(size * 0.04),
                    border: Border.all(
                      color: metal.withValues(alpha: unlocked ? 0.86 : 0.34),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    spec.rune,
                    color:
                        unlocked
                            ? kWhiteColor.withValues(alpha: 0.92)
                            : kWhiteColor.withValues(alpha: 0.36),
                    size: size * 0.11,
                  ),
                ),
              ),
            ),
            if (!unlocked)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: kBlackColor.withValues(alpha: 0.36),
                  borderRadius: BorderRadius.circular(size * 0.24),
                ),
                child: Icon(
                  Icons.lock_outline,
                  color: kWhiteColor.withValues(alpha: 0.68),
                  size: size * 0.28,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _BadgeFrame { shield, medallion, diamond, hex, banner }

enum _BadgePattern { rays, ranks, laurel, cross, wave }

class _BadgeSpec {
  const _BadgeSpec({
    required this.icon,
    required this.rune,
    required this.frame,
    required this.pattern,
    required this.metal,
    required this.runeTilt,
  });

  final IconData icon;
  final IconData rune;
  final _BadgeFrame frame;
  final _BadgePattern pattern;
  final Color metal;
  final double runeTilt;
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
  final rune = switch (index % 5) {
    0 => Icons.diamond_outlined,
    1 => Icons.star_rounded,
    2 => Icons.circle_outlined,
    3 => Icons.change_history_rounded,
    _ => Icons.auto_awesome_rounded,
  };
  return _BadgeSpec(
    icon: _badgeIcon(id),
    rune: rune,
    frame: frame,
    pattern: pattern,
    metal: metal,
    runeTilt: (index.isEven ? -1 : 1) * math.pi / 4,
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
  });

  final Color accent;
  final _BadgePattern pattern;
  final bool unlocked;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = accent.withValues(alpha: unlocked ? 0.26 : 0.08);
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
      unlocked != oldDelegate.unlocked;
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
