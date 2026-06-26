import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
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
/// in lockstep.
class DesktopCollectionCards extends StatelessWidget {
  const DesktopCollectionCards({
    super.key,
    required this.onFavoritesTap,
    required this.onCountrymenTap,
    required this.onSmartCollectionTap,
  });

  final VoidCallback onFavoritesTap;
  final VoidCallback onCountrymenTap;
  final ValueChanged<PremiumGamesType> onSmartCollectionTap;

  // A "shelf" of fixed-width tiles, left-aligned. Keeping these at their
  // natural width avoids the top row becoming a full-width dashboard band.
  static const double _collectionCardWidth = 260;
  static const double _smartCardWidth = 170;
  static const double _cardHeight = 140;
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            SizedBox(
              width: _collectionCardWidth,
              height: _cardHeight,
              child: _CollectionCard(
                title: 'Favorites',
                hint: 'Track your starred players',
                background: const FavoritePlayersGridBackground(),
                onTap: onFavoritesTap,
              ),
            ),
            const SizedBox(width: _gap),
            SizedBox(
              width: _collectionCardWidth,
              height: _cardHeight,
              child: _CollectionCard(
                title: 'Countrymen',
                hint: 'Players from your federation',
                background: const FlagFullBackground(),
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
              colors: const [Color(0xFF0EA5E9), Color(0xFF14B8A6)],
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
              title: 'Classical',
              hint: 'Standard games',
              icon: Icons.timer_outlined,
              colors: const [Color(0xFF6366F1), Color(0xFF2563EB)],
              onTap: () => onSmartCollectionTap(PremiumGamesType.classical),
            ),
            const SizedBox(width: _gap),
            _MiniaturesCollectionCard(
              width: _smartCardWidth + 24,
              height: _cardHeight,
              onTap: () => onSmartCollectionTap(PremiumGamesType.miniatures),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.05, end: 0);
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
  });

  final double width;
  final double height;
  final String title;
  final String hint;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  State<_SmartCollectionCard> createState() => _SmartCollectionCardState();
}

class _SmartCollectionCardState extends State<_SmartCollectionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClickCursor(
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
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.colors,
                  ),
                  border: Border.all(
                    color:
                        _hovered
                            ? kWhiteColor.withValues(alpha: 0.45)
                            : kWhiteColor.withValues(alpha: 0.18),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -8,
                      top: -8,
                      child: Icon(
                        widget.icon,
                        size: 76,
                        color: kWhiteColor.withValues(alpha: 0.16),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(
                          widget.icon,
                          size: 20,
                          color: kWhiteColor.withValues(alpha: 0.9),
                        ),
                        const Spacer(),
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: kWhiteColor.withValues(alpha: 0.76),
                            fontSize: 11,
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
    );
  }
}

class _MiniaturesCollectionCard extends StatefulWidget {
  const _MiniaturesCollectionCard({
    required this.width,
    required this.height,
    required this.onTap,
  });

  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  State<_MiniaturesCollectionCard> createState() =>
      _MiniaturesCollectionCardState();
}

class _MiniaturesCollectionCardState extends State<_MiniaturesCollectionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: MotionCard(
              borderRadius: 14,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF1F1028),
                      Color(0xFF7C2D12),
                      Color(0xFFEAB308),
                    ],
                    stops: [0, 0.58, 1],
                  ),
                  border: Border.all(
                    color:
                        _hovered
                            ? const Color(0xFFFFF7AD).withValues(alpha: 0.62)
                            : kWhiteColor.withValues(alpha: 0.2),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -22,
                      top: -24,
                      child: Icon(
                        Icons.auto_awesome_rounded,
                        size: 106,
                        color: kWhiteColor.withValues(alpha: 0.11),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 4,
                      child: AnimatedScale(
                        scale: _hovered ? 1.04 : 1,
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: kBlackColor.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: kWhiteColor.withValues(alpha: 0.28),
                            ),
                          ),
                          child: const Text(
                            '≤25',
                            style: TextStyle(
                              color: kWhiteColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
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
                              alpha: _hovered ? 0.2 : 0.14,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.local_fire_department_rounded,
                            size: 20,
                            color: kWhiteColor,
                          ),
                        ),
                        const Spacer(),
                        const Text(
                          'Miniatures',
                          style: TextStyle(
                            color: kWhiteColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.25,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Brilliancies by move 25',
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
    );
  }
}

class _CollectionCard extends StatefulWidget {
  const _CollectionCard({
    required this.title,
    required this.hint,
    required this.background,
    required this.onTap,
  });

  final String title;
  final String hint;
  final Widget background;
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
                          color: kBlack2Color.withValues(alpha: 0.65),
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
