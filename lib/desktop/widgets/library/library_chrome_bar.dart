import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Dense shared chrome for Library content headers — single tight row, soft
/// surface, primary-tinted icon tile. Replaces tall icon + title + subtitle
/// stacks that wasted vertical space above the board/table.
class LibraryChromeBar extends StatelessWidget {
  const LibraryChromeBar({
    super.key,
    required this.icon,
    required this.title,
    this.meta,
    this.badge,
    this.trailing,
    this.bottom,
    this.showBottomBorder = true,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String? meta;
  final Widget? badge;
  final Widget? trailing;
  final Widget? bottom;
  final bool showBottomBorder;

  /// When set, tints the leading icon well (folder amber vs database primary).
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final metaText = meta?.trim();
    final accentColor = accent ?? kPrimaryColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color.withValues(alpha: 0.72),
        border:
            showBottomBorder
                ? Border(
                  bottom: BorderSide(
                    color: kDividerColor.withValues(alpha: 0.9),
                  ),
                )
                : null,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          14,
          bottom == null ? 8 : 7,
          12,
          bottom == null ? 8 : 7,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.38),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.10),
                        blurRadius: 10,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Icon(icon, size: 15, color: accentColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.15,
                            height: 1.1,
                          ),
                        ),
                      ),
                      if (metaText != null && metaText.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          child: Text(
                            '·',
                            style: TextStyle(
                              color: kWhiteColor.withValues(alpha: 0.28),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            metaText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kLightGreyColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                              height: 1.1,
                            ),
                          ),
                        ),
                      ],
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        badge!,
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  trailing!,
                ],
              ],
            ),
            if (bottom != null) ...[
              const SizedBox(height: 6),
              bottom!,
            ],
          ],
        ),
      ),
    );
  }
}
