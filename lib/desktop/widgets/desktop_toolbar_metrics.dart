import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Shared geometry for controls that occupy a desktop pane toolbar row.
const double desktopToolbarControlHeight = 36;

/// Search fields, action buttons, and read-only counters share this radius.
const double desktopToolbarControlRadius = 8;

/// Read-only status surface aligned with interactive toolbar controls.
class DesktopToolbarCountPill extends StatelessWidget {
  const DesktopToolbarCountPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: desktopToolbarControlHeight,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(desktopToolbarControlRadius),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
