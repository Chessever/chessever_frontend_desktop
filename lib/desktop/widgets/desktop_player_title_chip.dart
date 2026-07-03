import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Desktop player-title chip shared by game-view rows and player/event cards.
///
/// Keep this visually aligned with the desktop game-view title treatment:
/// subtle ChessEver-blue fill + thin blue border + blue title text.
class DesktopPlayerTitleChip extends StatelessWidget {
  const DesktopPlayerTitleChip({
    super.key,
    required this.title,
    this.compact = false,
  });

  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 5,
        vertical: compact ? 1 : 1.5,
      ),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: kPrimaryColor.withValues(alpha: 0.38),
          width: 0.7,
        ),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: kPrimaryColor,
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
