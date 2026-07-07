import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

const double _kCompactExpandedSegmentWidth = 112;

class DesktopSegmentedTab<T> {
  const DesktopSegmentedTab({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
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
    return FTheme(
      data: FThemes.zinc.dark,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (wrap) return _wrappedTabs();

          final tabCount = tabs.isEmpty ? 1 : tabs.length;
          final compact =
              expand &&
              constraints.hasBoundedWidth &&
              constraints.maxWidth.isFinite &&
              constraints.maxWidth / tabCount < _kCompactExpandedSegmentWidth;

          return _segmentedRow(compact: compact);
        },
      ),
    );
  }

  Widget _wrappedTabs() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final tab in tabs) _segmentButton(tab: tab)],
    );
  }

  Widget _segmentedRow({required bool compact}) {
    return Container(
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
              Expanded(child: _segmentButton(tab: tabs[i], compact: compact))
            else
              _segmentButton(tab: tabs[i]),
          ],
        ],
      ),
    );
  }

  Widget _segmentButton({
    required DesktopSegmentedTab<T> tab,
    bool compact = false,
  }) {
    final isSelected = tab.value == selected;
    final icon = tab.icon;
    if (compact && icon != null) {
      return DesktopTooltip(
        message: tab.label,
        child: Semantics(
          button: true,
          label: tab.label,
          child: FButton(
            style: desktopSegmentButtonStyle(
              selected: isSelected,
              wrap: wrap,
              compact: true,
            ),
            mainAxisSize: MainAxisSize.max,
            onPress: () => onChanged(tab.value),
            child: Icon(icon),
          ),
        ),
      );
    }

    return FButton(
      style: desktopSegmentButtonStyle(
        selected: isSelected,
        wrap: wrap,
        compact: compact,
      ),
      mainAxisSize: (expand && !wrap) ? MainAxisSize.max : MainAxisSize.min,
      onPress: () => onChanged(tab.value),
      prefix: icon == null ? null : Icon(icon),
      child: Text(
        tab.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) desktopSegmentButtonStyle({
  required bool selected,
  bool wrap = false,
  bool compact = false,
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
                    : EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 12,
                      vertical: 7,
                    ),
            spacing: compact ? 0 : (wrap ? 6 : 7),
            textStyle: _segmentTextStyle(selected: selected),
            iconStyle: _segmentIconStyle(selected: selected),
          ),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
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
    WidgetState.hovered | WidgetState.pressed: const IconThemeData(
      color: kWhiteColor,
      size: 14,
    ),
    WidgetState.any: IconThemeData(
      color: selected ? kWhiteColor70 : kLightGreyColor,
      size: 14,
    ),
  });
}

FWidgetStateMap<BoxDecoration> _segmentWrapDecoration({
  required bool selected,
}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.09) : kBlack3Color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.22)
                : kWhiteColor.withValues(alpha: 0.18),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.06) : kBlack2Color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color: selected ? kPrimaryColor.withValues(alpha: 0.18) : kDividerColor,
      ),
    ),
  });
}

FWidgetStateMap<BoxDecoration> _segmentDecoration({required bool selected}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.09) : kBlack3Color,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.22)
                : kWhiteColor.withValues(alpha: 0.14),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color:
          selected ? kPrimaryColor.withValues(alpha: 0.06) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.18)
                : Colors.transparent,
      ),
    ),
  });
}
