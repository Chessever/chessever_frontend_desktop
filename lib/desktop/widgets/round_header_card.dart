import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// Sticky-style round header rendered above each round's games in the
/// Tournament Detail's Games sub-view.
///
/// Mirrors mobile's `RoundHeader` semantics — tap to collapse/expand, compact
/// round name + datetime on one line, chevron on the right — retuned for
/// desktop visuals (denser padding and quiet outline border).
class RoundHeaderCard extends StatefulWidget {
  const RoundHeaderCard({
    super.key,
    required this.round,
    required this.gameCount,
    required this.expanded,
    required this.onToggle,
    this.selected = false,
  });

  final GamesAppBarModel round;
  final int gameCount;
  final bool expanded;
  final VoidCallback onToggle;
  final bool selected;

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
        onExit:
            (_) => setState(() {
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color:
                  widget.selected
                      ? kBlack3Color
                      : _pressed
                      ? kBlack3Color
                      : (_hovered ? kBlack3Color : kBlack2Color),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    widget.selected
                        ? kPrimaryColor.withValues(alpha: 0.58)
                        : _pressed
                        ? kPrimaryColor.withValues(alpha: 0.55)
                        : (_hovered
                            ? kPrimaryColor.withValues(alpha: 0.3)
                            : kDividerColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.round.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.round.formattedRoundDateTime.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          '· ${widget.round.formattedRoundDateTime}',
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
                const SizedBox(width: 10),
                if (widget.gameCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
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
                  builder:
                      (context, t, child) =>
                          Transform.rotate(angle: t * 3.14159, child: child),
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
