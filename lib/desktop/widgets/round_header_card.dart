import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// Sticky-style round header rendered above each round's games in the
/// Tournament Detail's Games sub-view.
///
/// Mirrors mobile's `RoundHeader` semantics — tap to collapse/expand, status
/// pill on the left, name + datetime in the middle, chevron on the right —
/// retuned for desktop visuals (denser padding, chip status indicator,
/// outline border).
class RoundHeaderCard extends StatefulWidget {
  const RoundHeaderCard({
    super.key,
    required this.round,
    required this.gameCount,
    required this.expanded,
    required this.onToggle,
  });

  final GamesAppBarModel round;
  final int gameCount;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<RoundHeaderCard> createState() => _RoundHeaderCardState();
}

class _RoundHeaderCardState extends State<RoundHeaderCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _pressed
                  ? kBlack3Color
                  : (_hovered ? kBlack3Color : kBlack2Color),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _pressed
                    ? kPrimaryColor.withValues(alpha: 0.55)
                    : (_hovered
                        ? kPrimaryColor.withValues(alpha: 0.3)
                        : kDividerColor),
              ),
            ),
            child: Row(
              children: [
                _StatusChip(status: widget.round.roundStatus),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.round.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.round.formattedRoundDateTime.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.round.formattedRoundDateTime,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (widget.gameCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      widget.gameCount == 1
                          ? '1 game'
                          : '${widget.gameCount} games',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                SingleMotionBuilder(
                  value: widget.expanded ? 1.0 : 0.0,
                  motion: DesktopMotion.layout,
                  builder: (context, t, child) => Transform.rotate(
                    angle: t * 3.14159,
                    child: child,
                  ),
                  child: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: kWhiteColor70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final RoundStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      RoundStatus.live => ('LIVE', kRedColor),
      RoundStatus.ongoing => ('ONGOING', kGreenColor),
      RoundStatus.completed => ('DONE', kLightGreyColor),
      RoundStatus.upcoming => ('SOON', kPrimaryColor),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == RoundStatus.live) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
