import 'package:chessever/desktop/state/signed_out_events_presentation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/screens/group_event/widget/premium_collection_cards.dart'
    show FavoritePlayersGridBackground, FlagFullBackground;
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Top-of-feed collection cards on the desktop For You view.
///
/// Mirrors the mobile "Premium Collection Cards" — Favorites (auto-scrolling
/// player photo mosaic) and Countrymen (federation flag full-bleed) — but
/// taps route through the desktop tab system rather than pushing a mobile
/// route. Visuals share the same provider-driven primitives mobile uses
/// (`FavoritePlayersGridBackground` / `FlagFullBackground`) so the two stay
/// in lockstep. Empty Favorites uses the mobile Discovery heart artwork.
class DesktopCollectionCards extends StatelessWidget {
  const DesktopCollectionCards({
    super.key,
    required this.onFavoritesTap,
    required this.onCountrymenTap,
    required this.onSmartCollectionTap,
    required this.onLikesTap,
  });

  final VoidCallback onFavoritesTap;
  final VoidCallback onCountrymenTap;
  final ValueChanged<PremiumGamesType> onSmartCollectionTap;

  /// Opens the community Likes ranking (the phone's Discovery › Likes).
  final VoidCallback onLikesTap;

  // A "shelf" of fixed-width tiles, left-aligned. Keeping these at their
  // natural width avoids the top row becoming a full-width dashboard band.
  static const double _collectionCardWidth = 260;
  static const double _smartCardWidth = 194;
  static const double _cardHeight = 140;
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: _CollectionShelf(
        child: Row(
          children: [
            SizedBox(
              width: _collectionCardWidth,
              height: _cardHeight,
              child: _FavoritesCollectionCard(onTap: onFavoritesTap),
            ),
            const SizedBox(width: _gap),
            SizedBox(
              width: _collectionCardWidth,
              height: _cardHeight,
              child: _CollectionCard(
                title: 'Countrymen',
                hint: 'Players from your federation',
                background: FlagFullBackground(readOnlyPresentation: SignedOutEventsPresentationScope.maybeOf(context) != null),
                onTap: onCountrymenTap,
              ),
            ),
            const SizedBox(width: _gap),
            _SmartCollectionCard(
              width: _smartCardWidth,
              height: _cardHeight,
              title: 'Live',
              hint: 'All live games',
              icon: Icons.bolt_rounded,
              // Deep enough that the white subtitle reads (the lighter
              // sky-to-teal measured about 2.1:1).
              colors: const [Color(0xFF0369A1), Color(0xFF0F766E)],
              onTap: () => onSmartCollectionTap(PremiumGamesType.live),
            ),
            const SizedBox(width: _gap),
            _SmartCollectionCard(
              width: _smartCardWidth,
              height: _cardHeight,
              title: 'GM',
              hint: '2500+ avg games',
              icon: Icons.military_tech_rounded,
              colors: const [Color(0xFF7C3AED), Color(0xFF0F766E)],
              onTap: () => onSmartCollectionTap(PremiumGamesType.gm),
            ),
            const SizedBox(width: _gap),
            _SmartCollectionCard(
              width: _smartCardWidth,
              height: _cardHeight,
              title: 'Miniatures',
              hint: 'Brilliancies by move 25',
              icon: Icons.local_fire_department_rounded,
              backgroundIcon: Icons.auto_awesome_rounded,
              badge: '≤25',
              colors: const [
                Color(0xFF1F1028),
                Color(0xFF7C2D12),
                Color(0xFFEAB308),
              ],
              stops: const [0, 0.58, 1],
              onTap: () => onSmartCollectionTap(PremiumGamesType.miniatures),
            ),
            const SizedBox(width: _gap),
            _SmartCollectionCard(
              width: _smartCardWidth,
              height: _cardHeight,
              title: 'Likes',
              hint: 'Community favorites',
              icon: Icons.favorite_rounded,
              // Deep rose into oxblood: white copy stays well above 4.5:1.
              colors: const [Color(0xFF881337), Color(0xFF581C1C)],
              onTap: onLikesTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _SmartCollectionCard extends StatefulWidget {
  const _SmartCollectionCard({
    required this.width,
    required this.height,
    required this.title,
    required this.hint,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.backgroundIcon,
    this.badge,
    this.stops,
  });

  final double width;
  final double height;
  final String title;
  final String hint;
  final IconData icon;
  final IconData? backgroundIcon;
  final String? badge;
  final List<Color> colors;
  final List<double>? stops;
  final VoidCallback onTap;

  @override
  State<_SmartCollectionCard> createState() => _SmartCollectionCardState();
}

class _SmartCollectionCardState extends State<_SmartCollectionCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: DesktopTappable(
            onPress: widget.onTap,
            semanticsLabel: '${widget.title}, ${widget.hint}',
            borderRadius: BorderRadius.circular(14),
            child: ExcludeSemantics(
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style,
                child: MotionCard(
                  borderRadius: 14,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: widget.colors,
                        stops: widget.stops,
                      ),
                      border: Border.all(
                        color: kWhiteColor.withValues(
                          alpha: _hovered || _focused ? 0.62 : 0.2,
                        ),
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            kBlackColor.withValues(alpha: 0.44),
                          ],
                          stops: const [0.4, 1],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Stack(
                          children: [
                            Positioned(
                              right: -22,
                              top: -24,
                              child: ExcludeSemantics(
                                child: Icon(
                                  widget.backgroundIcon ?? widget.icon,
                                  size: 106,
                                  color: kWhiteColor.withValues(alpha: 0.11),
                                ),
                              ),
                            ),
                            if (widget.badge case final badge?)
                              Positioned(
                                right: 8,
                                top: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: kBlackColor.withValues(alpha: 0.28),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: kWhiteColor.withValues(
                                        alpha: 0.28,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    badge,
                                    style: const TextStyle(
                                      color: kWhiteColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  curve: Curves.easeOutCubic,
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: kWhiteColor.withValues(
                                      alpha: _hovered || _focused ? 0.2 : 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    widget.icon,
                                    size: 20,
                                    color: kWhiteColor,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  widget.title,
                                  style: const TextStyle(
                                    color: kWhiteColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.25,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  widget.hint,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: kWhiteColor.withValues(alpha: 0.8),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoritesCollectionCard extends ConsumerWidget {
  const _FavoritesCollectionCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasFavorites = SignedOutEventsPresentationScope.maybeOf(context) == null &&
        (ref.watch(favoritePlayersProviderNew).valueOrNull?.isNotEmpty ?? false);

    return _CollectionCard(
      title: 'Favorites',
      hint: 'Track your starred players',
      background:
          hasFavorites
              ? const FavoritePlayersGridBackground()
              : ExcludeSemantics(
                child: Image.asset(
                  'assets/pngs/hub_most_liked_icon.webp',
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  cacheWidth: 768,
                  cacheHeight: 512,
                  filterQuality: FilterQuality.medium,
                ),
              ),
      backgroundDim: hasFavorites ? 0.65 : 0.25,
      onTap: onTap,
    );
  }
}

class _CollectionCard extends StatefulWidget {
  const _CollectionCard({
    required this.title,
    required this.hint,
    required this.background,
    required this.onTap,
    this.backgroundDim = 0.65,
  });

  final String title;
  final String hint;
  final Widget background;
  final double backgroundDim;
  final VoidCallback onTap;

  @override
  State<_CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<_CollectionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: MotionCard(
            borderRadius: 12,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.45)
                          : kWhiteColor.withValues(alpha: 0.18),
                ),
                // no selection concept here; hover/press shadow now owned by MotionCard
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    Positioned.fill(child: widget.background),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: kBlack2Color.withValues(
                            alpha: widget.backgroundDim,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: kWhiteColor.withValues(alpha: 0.7),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shelf scrolls sideways when the window is too narrow for every card:
/// a vertical mouse wheel moves it, and the edge with more cards beyond it
/// fades out so the hidden cards read as "more this way".
class _CollectionShelf extends StatefulWidget {
  const _CollectionShelf({required this.child});

  final Widget child;

  @override
  State<_CollectionShelf> createState() => _CollectionShelfState();
}

class _CollectionShelfState extends State<_CollectionShelf> {
  final ScrollController _controller = DesktopScrollController();
  bool _moreLeft = false;
  bool _moreRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEdges());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateEdges() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final moreLeft = position.pixels > position.minScrollExtent + 1;
    final moreRight = position.pixels < position.maxScrollExtent - 1;
    if (moreLeft != _moreLeft || moreRight != _moreRight) {
      setState(() {
        _moreLeft = moreLeft;
        _moreRight = moreRight;
      });
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final delta = event.scrollDelta;
    final position = _controller.position;
    if (delta.dy.abs() <= delta.dx.abs() || position.maxScrollExtent <= 0) {
      return;
    }
    final target = (position.pixels + delta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // Hand the wheel to the page once the shelf is at its end.
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) {
        event.respond(allowPlatformDefault: false);
        position.pointerScroll(delta.dy);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _updateEdges());
        return false;
      },
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback:
              (bounds) => LinearGradient(
                colors: [
                  _moreLeft ? Colors.transparent : Colors.black,
                  Colors.black,
                  Colors.black,
                  _moreRight ? Colors.transparent : Colors.black,
                ],
                stops: const [0, 0.06, 0.94, 1],
              ).createShader(bounds),
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
