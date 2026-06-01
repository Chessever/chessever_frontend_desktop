import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

/// Desktop date separator for game feeds.
///
/// This mirrors the role of mobile's date headers while keeping the chrome in
/// forui, matching the rest of the desktop shell.
class DesktopDateGroupCard extends StatelessWidget {
  const DesktopDateGroupCard({
    super.key,
    required this.label,
    required this.gameCount,
  });

  final String label;
  final int gameCount;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FCard.raw(
        style:
            (style) => style.copyWith(
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
            ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: kPrimaryColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              const Icon(
                Icons.calendar_today_rounded,
                size: 15,
                color: kWhiteColor70,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FBadge(
                style: FBadgeStyle.outline(
                  (style) => style.copyWith(
                    decoration: BoxDecoration(
                      color: kBlack3Color,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: kDividerColor),
                    ),
                    contentStyle:
                        (content) => content.copyWith(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          labelTextStyle: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                  ),
                ),
                child: Text(gameCount == 1 ? '1 game' : '$gameCount games'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
