import 'package:fastlottie/fastlottie.dart';
import 'package:flutter/widgets.dart';

/// The Play reward animations (Lottie, played by FastLottie). Drawn in
/// white and tinted here, so one file serves every tier metal. Authored by
/// `tool/play_rewards_lottie.dart`.
enum PlayRewardMotion {
  /// A badge tier struck: a ring engraved round the badge, shards and stars.
  /// Its canvas is twice the badge.
  badgeStrike('assets/play/lottie/badge_strike.json'),

  /// Pointer over an earned badge: two stars wink on its rim. Same canvas
  /// as [badgeStrike].
  badgeGlint('assets/play/lottie/badge_glint.json'),

  /// A level reached: chevrons climb and one settles.
  levelUp('assets/play/lottie/level_up.json');

  const PlayRewardMotion(this.asset);

  final String asset;
}

final Map<PlayRewardMotion, Future<FastLottieComposition?>> _compositions = {};

/// Moments already played this run (a badge tier as `track:tier`, a level
/// as `level:N`), shared by the profile and the post-game brief, so one
/// reward is celebrated once however often its screen is opened.
final Set<String> playRewardsCelebrated = {};

/// Compiled once per app run and shared by every player. A file that fails
/// to load or compile resolves to null and the moment simply does not play:
/// these are flourishes over content that is already on screen.
Future<FastLottieComposition?> _composition(PlayRewardMotion motion) =>
    _compositions[motion] ??= FastLottieComposition.loadAsset(
      motion.asset,
    ).then<FastLottieComposition?>((c) => c).catchError((Object _) => null);

/// Plays [motion] once, tinted [color], when it is mounted. Give it a new
/// key to play it again. Never takes pointer events, and draws nothing
/// before the file is ready, after the last frame, or (FastLottie's rule)
/// when the system asks for reduced motion.
class PlayRewardBurst extends StatefulWidget {
  const PlayRewardBurst({
    required this.motion,
    required this.color,
    required this.size,
    this.onceKey,
    super.key,
  });

  final PlayRewardMotion motion;
  final Color color;
  final double size;

  /// Plays only the first time this key mounts in a run
  /// ([playRewardsCelebrated]); later it keeps its room and draws nothing.
  final String? onceKey;

  @override
  State<PlayRewardBurst> createState() => _PlayRewardBurstState();
}

class _PlayRewardBurstState extends State<PlayRewardBurst> {
  FastLottieComposition? _ready;
  late final bool _plays =
      widget.onceKey == null || playRewardsCelebrated.add(widget.onceKey!);

  @override
  void initState() {
    super.initState();
    if (_plays) _load();
  }

  @override
  void didUpdateWidget(PlayRewardBurst oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_plays && oldWidget.motion != widget.motion) {
      _ready = null;
      _load();
    }
  }

  Future<void> _load() async {
    final motion = widget.motion;
    final composition = await _composition(motion);
    if (!mounted || motion != widget.motion) return;
    setState(() => _ready = composition);
  }

  @override
  Widget build(BuildContext context) {
    final composition = _ready;
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.size,
        child:
            composition == null
                ? null
                : ColorFiltered(
                  colorFilter: ColorFilter.mode(widget.color, BlendMode.srcIn),
                  child: FastLottie(
                    composition: composition,
                    width: widget.size,
                    height: widget.size,
                    repeat: false,
                    // Vector playback: a few small, short moments at a
                    // time, crisp at any scale, no raster workers.
                    usePipeline: false,
                  ),
                ),
      ),
    );
  }
}

/// [child] (a badge of [badgeSize]) with [motion] played over it. The
/// burst's canvas is twice the badge, so it is drawn in the app's overlay,
/// pinned to the badge: a scroll view or a card edge around the badge
/// cannot shave its shards. [playKey] restarts it; null shows the badge
/// alone.
class PlayBadgeWithBurst extends StatefulWidget {
  const PlayBadgeWithBurst({
    required this.badgeSize,
    required this.child,
    required this.color,
    this.motion = PlayRewardMotion.badgeStrike,
    this.playKey,
    this.onceKey,
    super.key,
  });

  final double badgeSize;
  final Widget child;
  final Color color;
  final PlayRewardMotion motion;
  final Object? playKey;

  /// See [PlayRewardBurst.onceKey].
  final String? onceKey;

  @override
  State<PlayBadgeWithBurst> createState() => _PlayBadgeWithBurstState();
}

class _PlayBadgeWithBurstState extends State<PlayBadgeWithBurst> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    // Shown from the first burst on and never hidden: after its last frame
    // the burst draws nothing.
    if (widget.playKey != null) _portal.show();
  }

  @override
  void didUpdateWidget(PlayBadgeWithBurst oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Not during build: show() rebuilds the portal. The burst mounts (and
    // starts) with the next frame.
    if (widget.playKey != null && !_portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_portal.isShowing) _portal.show();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.playKey;
    final size = widget.badgeSize;
    final badge = SizedBox.square(dimension: size, child: widget.child);
    final burst =
        key == null
            ? null
            : PlayRewardBurst(
              key: ValueKey(key),
              motion: widget.motion,
              color: widget.color,
              size: size * 2,
              onceKey: widget.onceKey,
            );
    // No overlay above (a bare test harness): draw it in place instead.
    if (Overlay.maybeOf(context) == null) {
      return SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: widget.child),
            if (burst != null)
              Positioned(
                left: -size / 2,
                top: -size / 2,
                width: size * 2,
                height: size * 2,
                child: burst,
              ),
          ],
        ),
      );
    }
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder:
            (context) => Align(
              alignment: Alignment.topLeft,
              child: CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.center,
                followerAnchor: Alignment.center,
                child: burst ?? const SizedBox.shrink(),
              ),
            ),
        child: badge,
      ),
    );
  }
}
