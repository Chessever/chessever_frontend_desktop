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
            foregroundDecoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: kDividerColor, width: 0.5),
              ),
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border:
                  states.contains(WidgetState.focused)
                      ? Border.all(color: kPrimaryColor)
                      : null,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: kWhiteColor70,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color:
                          states.contains(WidgetState.hovered)
                              ? kWhiteColor
                              : kWhiteColor70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
    ),
  );
}
