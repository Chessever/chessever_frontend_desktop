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
            margin: EdgeInsets.only(bottom: expanded ? 8 : 0),
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
            // Same columns as the round card above it (RoundHeaderCard: a
            // 1px border and 14px of padding): the label starts where the
            // round title starts and the chevron sits under the card's.
            padding: const EdgeInsets.fromLTRB(15, 6, 15, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                const SizedBox(width: 10),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: kWhiteColor70,
                ),
              ],
            ),
          ),
    ),
  );
}
