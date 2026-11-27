import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/desktop/widgets/play_achievement_badge.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_reward_motion.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

const TextStyle _kSmall = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 11,
  fontWeight: FontWeight.w600,
  fontFeatures: [FontFeature.tabularFigures()],
);

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 30) return '${d.inDays} days ago';
  return '${(d.inDays / 30).floor()} mo ago';
}

// ---------------------------------------------------------------------------
// Level
// ---------------------------------------------------------------------------

/// Level, its title and the XP bar to the next level. The bar eases to a
/// new value when XP changes; it is never hidden waiting for a reveal.
class PlayLevelPanel extends StatelessWidget {
  const PlayLevelPanel({super.key, required this.state, this.compact = false});

  final PlayAchievementsState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final level = state.level;
    final last = state.lastRewards;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _LevelMark(level: level.level, size: compact ? 44 : 58),
        SizedBox(width: compact ? 12 : 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    level.title,
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: compact ? 14 : 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${level.xpIntoLevel} / ${level.xpForNext} XP',
                    style: _kSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PlayProgressTrack(
                value: level.fraction,
                color: kPrimaryColor,
                height: compact ? 5 : 7,
              ),
              const SizedBox(height: 7),
              Text(
                last != null && last.xpEarned > 0
                    ? '+${last.xpEarned} XP from your last game. '
                        '${level.xpToNext} to level ${level.level + 1}.'
                    : '${level.xpToNext} XP to level ${level.level + 1}. '
                        '${level.totalXp} XP earned in total.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _kSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The level number set in a cut octagon: a coin-like mark of its own,
/// not an icon in a tile.
class _LevelMark extends StatelessWidget {
  const _LevelMark({required this.level, required this.size});

  final int level;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _OctagonPainter(),
        child: Center(
          child: Text(
            '$level',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: kWhiteColor,
              fontSize: size * (level >= 100 ? 0.32 : 0.4),
              fontWeight: FontWeight.w900,
              height: 1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _OctagonPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = w * 0.28;
    final path =
        Path()
          ..moveTo(c, 0)
          ..lineTo(w - c, 0)
          ..lineTo(w, c)
          ..lineTo(w, h - c)
          ..lineTo(w - c, h)
          ..lineTo(c, h)
          ..lineTo(0, h - c)
          ..lineTo(0, c)
          ..close();
    canvas.drawPath(
      path,
      Paint()..color = Color.lerp(kBlack3Color, kPrimaryColor, 0.16)!,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = kPrimaryColor.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_OctagonPainter oldDelegate) => false;
}

/// A rounded track with a fill that keeps round caps at every width
/// (the fill is a width, never a scale) and eases to new values.
class PlayProgressTrack extends StatelessWidget {
  const PlayProgressTrack({
    super.key,
    required this.value,
    required this.color,
    this.height = 6,
  });

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder:
            (context, c) => Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: kWhiteColor.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(height),
                    ),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: value.clamp(0.0, 1.0)),
                  duration: const Duration(milliseconds: 520),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) {
                    if (v <= 0) return const SizedBox.shrink();
                    // Never narrower than the track is tall, so the caps
                    // stay round.
                    final w = (c.maxWidth * v).clamp(height, c.maxWidth);
                    return SizedBox(
                      width: w,
                      height: height,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(height),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cabinet
// ---------------------------------------------------------------------------

/// The badges view: level, what was earned lately, what is closest, and
/// every track with its tiers.
class PlayBadgeCabinet extends StatefulWidget {
  const PlayBadgeCabinet({
    super.key,
    required this.state,
    required this.onClaim,
    required this.onClaimAll,
  });

  final PlayAchievementsState state;
  final Future<void> Function(List<PlayAchievementId> ids) onClaim;
  final Future<void> Function() onClaimAll;

  @override
  State<PlayBadgeCabinet> createState() => _PlayBadgeCabinetState();
}

class _PlayBadgeCabinetState extends State<PlayBadgeCabinet> {
  PlayAchievementGroup? _group;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final stats = state.stats;
    final now = DateTime.now();
    final recentKeys = {
      for (final up in state.recentUnlocks)
        if (now.difference(up.at).inDays < 3) up.trackKey,
    };
    final tracks =
        kPlayBadgeTracks
            .where((t) => _group == null || t.group == _group)
            .toList();
    // Earned tracks first, highest tier first; then the closest to Bronze.
    tracks.sort((a, b) {
      final ta = a.tierFor(a.progress(stats));
      final tb = b.tierFor(b.progress(stats));
      if (ta != tb) return tb.compareTo(ta);
      return b
          .fractionToNext(b.progress(stats))
          .compareTo(a.fractionToNext(a.progress(stats)));
    });
    final groups = <PlayAchievementGroup>{
      for (final t in kPlayBadgeTracks) t.group,
    };

    return ScrollEdgeArrows(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _CabinetHeader(state: state, now: now)),
          if (state.claimable.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _ClaimBar(
                  count: state.claimable.length,
                  onClaimAll: widget.onClaimAll,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
              child: Wrap(
                spacing: 2,
                runSpacing: 4,
                children: [
                  _GroupToggle(
                    label: 'All',
                    selected: _group == null,
                    onTap: () => setState(() => _group = null),
                  ),
                  for (final g in PlayAchievementGroup.values)
                    if (groups.contains(g))
                      _GroupToggle(
                        label: g.label,
                        selected: _group == g,
                        onTap: () => setState(() => _group = g),
                      ),
                ],
              ),
            ),
          ),
          SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisExtent: 116,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final track = tracks[i];
              final claimable = [
                for (final id in track.ids)
                  if (state.claimable.contains(id)) id,
              ];
              return _TrackCard(
                key: ValueKey(track.key),
                track: track,
                progress: track.progress(stats),
                isNew: recentKeys.contains(track.key),
                claimable: claimable,
                onClaim:
                    claimable.isEmpty ? null : () => widget.onClaim(claimable),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class _CabinetHeader extends StatelessWidget {
  const _CabinetHeader({required this.state, required this.now});

  final PlayAchievementsState state;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final stats = state.stats;
    final perTier = List<int>.filled(kPlayBadgeTierNames.length, 0);
    for (final t in kPlayBadgeTracks) {
      final tier = t.tierFor(t.progress(stats));
      if (tier > 0) perTier[tier - 1]++;
    }
    final reached = playBadgeTiersReached(stats);
    final total = playBadgeTiersTotal();
    // Tracks already under way first, nearest to their next tier; untouched
    // ones only fill in when fewer than three are moving.
    final open =
        kPlayBadgeTracks
            .where((t) => t.nextTarget(t.progress(stats)) != null)
            .toList();
    final moving =
        open.where((t) => t.progress(stats) > 0).toList()..sort(
          (a, b) => b
              .fractionToNext(b.progress(stats))
              .compareTo(a.fractionToNext(a.progress(stats))),
        );
    final closest = [...moving, ...open.where((t) => t.progress(stats) == 0)];

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final level = Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlayLevelPanel(state: state),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '$reached of $total tiers',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  for (var i = 0; i < 3; i++) ...[
                    _MetalCount(tier: i + 1, count: perTier[i]),
                    if (i < 2) const SizedBox(width: 14),
                  ],
                ],
              ),
            ],
          ),
        );
        final next = Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Closest next',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              for (final t in closest.take(3))
                _ClosestRow(track: t, progress: t.progress(stats)),
            ],
          ),
        );
        final recent =
            state.recentUnlocks.isEmpty
                ? null
                : _RecentStrip(unlocks: state.recentUnlocks, now: now);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: level),
                    const SizedBox(width: 10),
                    Expanded(flex: 4, child: next),
                  ],
                ),
              )
            else ...[
              level,
              const SizedBox(height: 10),
              next,
            ],
            if (recent != null) ...[const SizedBox(height: 18), recent],
          ],
        );
      },
    );
  }
}

class _MetalCount extends StatelessWidget {
  const _MetalCount({required this.tier, required this.count});

  final int tier;
  final int count;

  @override
  Widget build(BuildContext context) {
    final metal = playBadgeTierMetal(tier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: 0.785398,
          child: SizedBox.square(
            dimension: 7,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: metal,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count ${playBadgeTierName(tier)}',
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ClosestRow extends StatelessWidget {
  const _ClosestRow({required this.track, required this.progress});

  final PlayBadgeTrack track;
  final int progress;

  @override
  Widget build(BuildContext context) {
    final tier = track.tierFor(progress);
    final target = track.nextTarget(progress)!;
    final metal = playBadgeTierMetal(tier + 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$progress / $target to ${playBadgeTierName(tier + 1)}',
                style: _kSmall,
              ),
            ],
          ),
          const SizedBox(height: 6),
          PlayProgressTrack(
            value: track.fractionToNext(progress),
            color: metal,
            height: 4,
          ),
        ],
      ),
    );
  }
}

class _RecentStrip extends StatelessWidget {
  const _RecentStrip({required this.unlocks, required this.now});

  final List<PlayBadgeTierUp> unlocks;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final shown = unlocks.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recently earned',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 112,
          child: ScrollEdgeArrows(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: shown.length,
              separatorBuilder: (_, __) => const SizedBox(width: 18),
              itemBuilder: (context, i) {
                final up = shown[i];
                final track = up.track!;
                return SizedBox(
                  width: 96,
                  child: Column(
                    children: [
                      _ArrivalBadge(
                        key: ValueKey('${up.trackKey}:${up.tier}'),
                        fresh: i == 0 && now.difference(up.at).inMinutes < 10,
                        strikeKey: '${up.trackKey}:${up.tier}',
                        metal: playBadgeTierMetal(up.tier),
                        child: PlayAchievementBadgeArt(
                          definition: track.artDefinition,
                          unlocked: true,
                          size: 56,
                          tier: up.tier,
                          maxTier: track.maxTier,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${up.tierName}, ${_ago(up.at, now)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _kSmall.copyWith(
                          color: playBadgeTierMetal(up.tier),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// A just-earned badge lands with one small bounce and is struck once per
/// run. It is fully visible from the first frame: only its scale moves,
/// from 0.9, and the strike plays around it.
class _ArrivalBadge extends StatefulWidget {
  const _ArrivalBadge({
    super.key,
    required this.fresh,
    required this.strikeKey,
    required this.metal,
    required this.child,
  });

  final bool fresh;

  /// `track:tier`, shared with the track cards so one tier strikes once.
  final String strikeKey;
  final Color metal;
  final Widget child;

  @override
  State<_ArrivalBadge> createState() => _ArrivalBadgeState();
}

class _ArrivalBadgeState extends State<_ArrivalBadge> {
  late double _target = widget.fresh ? 0.9 : 1;
  late final bool _strike =
      widget.fresh && _struckTierUps.add(widget.strikeKey);

  @override
  void initState() {
    super.initState();
    if (widget.fresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _target = 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleMotionBuilder(
      value: _target,
      motion: DesktopMotion.arrival,
      builder:
          (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
      child: PlayBadgeWithBurst(
        badgeSize: 56,
        color: widget.metal,
        playKey: _strike ? widget.strikeKey : null,
        child: widget.child,
      ),
    );
  }
}

class _ClaimBar extends StatelessWidget {
  const _ClaimBar({required this.count, required this.onClaimAll});

  final int count;
  final Future<void> Function() onClaimAll;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: Color.lerp(kBlack2Color, kPrimaryColor, 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 1
                  ? 'One badge is ready to claim.'
                  : '$count badges are ready to claim.',
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FButton(
            style: playPrimaryActionButtonStyle(),
            onPress: onClaimAll,
            child: const Text('Claim all'),
          ),
        ],
      ),
    );
  }
}

class _GroupToggle extends StatefulWidget {
  const _GroupToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_GroupToggle> createState() => _GroupToggleState();
}

class _GroupToggleState extends State<_GroupToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _hovered = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? kBlack3Color : kBlack3Color.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color:
                  selected
                      ? kWhiteColor
                      : _hovered
                      ? kWhiteColor70
                      : kSecondaryTextColor,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// One track: its badge, the tier it holds, and the way to the next.
///
/// Hover tilts the badge a few degrees on a spring and sends one band of
/// light across its face; the card itself only shifts tone.
class _TrackCard extends StatefulWidget {
  const _TrackCard({
    super.key,
    required this.track,
    required this.progress,
    required this.isNew,
    required this.claimable,
    this.onClaim,
  });

  final PlayBadgeTrack track;
  final int progress;
  final bool isNew;
  final List<PlayAchievementId> claimable;
  final Future<void> Function()? onClaim;

  @override
  State<_TrackCard> createState() => _TrackCardState();
}

/// Tier-ups already struck this run (`track:tier`), so a new tier strikes
/// once when it first shows, not every time the profile is opened. Shared
/// with the post-game brief.
Set<String> get _struckTierUps => playRewardsCelebrated;

class _TrackCardState extends State<_TrackCard> {
  bool _hovered = false;
  int _sweeps = 0;

  /// The last moment played over the badge and a counter that replays it:
  /// a strike when a new tier first shows or the badge is claimed, a glint
  /// when the pointer comes onto an earned badge.
  PlayRewardMotion _burst = PlayRewardMotion.badgeGlint;
  int _bursts = 0;

  @override
  void initState() {
    super.initState();
    _strikeIfNew();
  }

  @override
  void didUpdateWidget(_TrackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Claimed, here or with Claim all: strike it.
    if (oldWidget.claimable.isNotEmpty && widget.claimable.isEmpty) {
      _struckTierUps.add(
        '${widget.track.key}:${widget.track.tierFor(widget.progress)}',
      );
      _burst = PlayRewardMotion.badgeStrike;
      _bursts++;
      return;
    }
    _strikeIfNew();
  }

  void _strikeIfNew() {
    if (!widget.isNew) return;
    final tier = widget.track.tierFor(widget.progress);
    if (tier <= 0) return;
    if (_struckTierUps.add('${widget.track.key}:$tier')) {
      _burst = PlayRewardMotion.badgeStrike;
      _bursts++;
    }
  }

  void _hover(bool value) {
    if (value == _hovered) return;
    setState(() {
      _hovered = value;
      if (!value) return;
      _sweeps++;
      if (widget.track.tierFor(widget.progress) > 0) {
        _burst = PlayRewardMotion.badgeGlint;
        _bursts++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final progress = widget.progress;
    final tier = track.tierFor(progress);
    final next = track.nextTarget(progress);
    final earned = tier > 0;
    final metal = playBadgeTierMetal(tier);
    final nextMetal = playBadgeTierMetal(tier + 1);
    final onClaim = widget.onClaim;

    final card = MouseRegion(
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        decoration: BoxDecoration(
          color: _hovered ? kBlack3Color : kBlack2Color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SingleMotionBuilder(
              value: _hovered ? 1.0 : 0.0,
              motion: DesktopMotion.select,
              builder:
                  (context, t, child) => Transform.rotate(
                    angle: -0.07 * t,
                    child: Transform.scale(scale: 1 + 0.04 * t, child: child),
                  ),
              child: PlayBadgeWithBurst(
                badgeSize: 64,
                color: metal,
                motion: _burst,
                playKey: _bursts == 0 ? null : _bursts,
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_sweeps),
                  tween: Tween<double>(begin: _sweeps == 0 ? 1 : 0, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeInOutCubic,
                  builder:
                      (context, s, _) => PlayAchievementBadgeArt(
                        definition: track.artDefinition,
                        unlocked: earned,
                        size: 64,
                        tier: tier,
                        maxTier: track.maxTier,
                        sheen: s >= 1 ? null : s,
                      ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: earned ? kWhiteColor : kWhiteColor70,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (widget.isNew) ...[
                        const Text(
                          'New',
                          style: TextStyle(
                            color: kPrimaryColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        onClaim != null
                            ? 'Claim'
                            : earned
                            ? playBadgeTierName(tier)
                            : 'Locked',
                        style: TextStyle(
                          color:
                              onClaim != null
                                  ? kPrimaryColor
                                  : earned
                                  ? metal
                                  : kSecondaryTextColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 9),
                  PlayProgressTrack(
                    value: track.fractionToNext(progress),
                    color: next == null ? metal : nextMetal,
                    height: 5,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    next == null
                        ? 'Every tier earned'
                        : '$progress / $next to ${playBadgeTierName(tier + 1)}',
                    style: _kSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onClaim == null) return card;
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onClaim(),
        child: card,
      ),
    );
  }
}
