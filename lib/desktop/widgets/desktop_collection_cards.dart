import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/screens/group_event/widget/premium_collection_cards.dart'
    show FavoritePlayersGridBackground, FlagFullBackground;
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
  });

  final VoidCallback onFavoritesTap;
  final VoidCallback onCountrymenTap;

  // A "shelf" of two fixed-width tiles, left-aligned. Not stretched 50/50
  // across the feed — that visual reads as "tablet" rather than "desktop".
  // The trailing Spacer absorbs whatever horizontal room is left.
  static const double _cardWidth = 320;
  static const double _cardHeight = 140;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        children: [
          SizedBox(
            width: _cardWidth,
            height: _cardHeight,
            child: _CollectionCard(
              title: 'Favorites',
              hint: 'Track your starred players',
              background: const FavoritePlayersGridBackground(),
              onTap: onFavoritesTap,
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: _cardWidth,
            height: _cardHeight,
            child: _CollectionCard(
              title: 'Countrymen',
              hint: 'Players from your federation',
              background: const FlagFullBackground(),
              onTap: onCountrymenTap,
            ),
          ),
          const Spacer(),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.05, end: 0);
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
                color: _hovered
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
