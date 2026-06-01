import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

class DesktopSegmentedTab<T> {
  const DesktopSegmentedTab({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

/// forui-backed segmented control for desktop pane chrome.
///
/// Keep tab switching out of Material's TabBar/Tooltip stack; the desktop
/// shell standardizes on forui chrome and this helper centralizes the
/// dark zinc defaults for Favorites, Countrymen, and future panes.
class DesktopSegmentedTabs<T> extends StatelessWidget {
  const DesktopSegmentedTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.wrap = false,
  });

  final List<DesktopSegmentedTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;

  /// When true, render pills inside a [Wrap] sized to their content so they
  /// flow onto multiple lines in narrow rails instead of overflowing.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    if (wrap) {
      return FTheme(
        data: FThemes.zinc.dark,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tab in tabs) _segmentButton(tab: tab),
          ],
        ),
      );
    }
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        height: 38,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              if (expand)
                Expanded(child: _segmentButton(tab: tabs[i]))
              else
                _segmentButton(tab: tabs[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _segmentButton({required DesktopSegmentedTab<T> tab}) {
    final isSelected = tab.value == selected;
    return FButton(
      style: _segmentStyle(selected: isSelected, wrap: wrap),
      mainAxisSize:
          (expand && !wrap) ? MainAxisSize.max : MainAxisSize.min,
      onPress: () => onChanged(tab.value),
      prefix: Icon(tab.icon),
      child: Text(tab.label),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _segmentStyle({
  required bool selected,
  bool wrap = false,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration:
          wrap
              ? _segmentWrapDecoration(selected: selected)
              : _segmentDecoration(selected: selected),
      contentStyle:
          (content) => content.copyWith(
            padding:
                wrap
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            spacing: wrap ? 6 : 7,
            textStyle: _segmentTextStyle(selected: selected),
            iconStyle: _segmentIconStyle(selected: selected),
          ),
    ),
  );
}

FWidgetStateMap<TextStyle> _segmentTextStyle({required bool selected}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: kWhiteColor,
      fontSize: 12,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
    ),
    WidgetState.any: TextStyle(
      color: selected ? kWhiteColor : kWhiteColor70,
      fontSize: 12,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
    ),
  });
}

FWidgetStateMap<IconThemeData> _segmentIconStyle({required bool selected}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color: selected ? kPrimaryColor : kWhiteColor,
      size: 14,
    ),
    WidgetState.any: IconThemeData(
      color: selected ? kPrimaryColor : kLightGreyColor,
      size: 14,
    ),
  });
}

FWidgetStateMap<BoxDecoration> _segmentWrapDecoration({
  required bool selected,
}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.18) : kBlack3Color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.42)
                : kWhiteColor.withValues(alpha: 0.18),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color:
          selected ? kPrimaryColor.withValues(alpha: 0.13) : kBlack2Color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.36)
                : kDividerColor,
      ),
    ),
  });
}

FWidgetStateMap<BoxDecoration> _segmentDecoration({required bool selected}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.18) : kBlack3Color,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.42)
                : kWhiteColor.withValues(alpha: 0.14),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color:
          selected ? kPrimaryColor.withValues(alpha: 0.13) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.36)
                : Colors.transparent,
      ),
    ),
  });
}
