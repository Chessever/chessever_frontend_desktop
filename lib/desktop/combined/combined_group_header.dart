import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:chessever/theme/app_theme.dart';

/// Keyboard-accessible source toggle shared by native and browser builds.
class CombinedGroupHeader extends StatelessWidget {
  const CombinedGroupHeader({
    super.key,
    required this.label,
    required this.expanded,
    required this.onToggle,
  });
  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    expanded: expanded,
    child: FTappable(
      onPress: onToggle,
      semanticsLabel: label,
      builder:
          (context, states, child) => Container(
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: states.contains(WidgetState.hovered) ? kBlack3Color : null,
              borderRadius: BorderRadius.circular(8),
              border:
                  states.contains(WidgetState.focused)
                      ? Border.all(color: kPrimaryColor)
                      : null,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: kWhiteColor70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
    ),
  );
}
