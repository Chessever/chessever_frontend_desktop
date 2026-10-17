import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopSidebarPremiumButton extends StatelessWidget {
  const DesktopSidebarPremiumButton({
    super.key,
    required this.expanded,
    required this.onPress,
    this.collapsedSize = 44,
    this.expandedHeight = 36,
    this.verticalPadding = 8,
  });

  final bool expanded;
  final VoidCallback? onPress;

  /// Edge of the square icon button on the collapsed rail.
  final double collapsedSize;

  /// Height of the labelled button on the expanded rail.
  final double expandedHeight;

  /// Space above and below the button.
  final double verticalPadding;

  static const double _expandedIconSize = 16;
  static const double _collapsedIconSize = 18;

  @override
  Widget build(BuildContext context) {
    // Padding is derived from the box so the glyph stays centred at every
    // sidebar density.
    final button =
        expanded
            ? SizedBox(
              height: expandedHeight,
              child: FButton(
                style: _premiumButtonStyle(
                  verticalPadding: math.max(
                    0,
                    (expandedHeight - _expandedIconSize) / 2,
                  ),
                ),
                onPress: onPress,
                mainAxisSize: MainAxisSize.max,
                prefix: const Icon(Icons.workspace_premium_rounded),
                child: const Text('Get Premium'),
              ),
            )
            : SizedBox(
              width: collapsedSize,
              height: collapsedSize,
              child: FButton.icon(
                style: _premiumIconButtonStyle(
                  padding: math.max(
                    0,
                    (collapsedSize - _collapsedIconSize) / 2,
                  ),
                ),
                onPress: onPress,
                child: const Icon(Icons.workspace_premium_rounded),
              ),
            );

    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: verticalPadding,
        ),
        child: DesktopTooltip(
          message: expanded ? '' : 'Get Premium',
          child: button,
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _premiumButtonStyle({
  required double verticalPadding,
}) {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _premiumDecoration(radius: 8),
      contentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: verticalPadding,
            ),
            spacing: 8,
            textStyle: _premiumTextStyle(),
            iconStyle: _premiumIconStyle(
              size: DesktopSidebarPremiumButton._expandedIconSize,
            ),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _premiumIconButtonStyle({
  required double padding,
}) {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _premiumDecoration(radius: 8),
      iconContentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.all(padding),
            iconStyle: _premiumIconStyle(
              size: DesktopSidebarPremiumButton._collapsedIconSize,
            ),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _premiumDecoration({required double radius}) {
  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color: kPrimaryColor.withValues(alpha: 0.38),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kPrimaryColor.withValues(alpha: 0.24)),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: kPrimaryColor,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kLightYellowColor.withValues(alpha: 0.72)),
    ),
    WidgetState.any: BoxDecoration(
      color: kPrimaryColor.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kPrimaryColor.withValues(alpha: 0.46)),
    ),
  });
}

FWidgetStateMap<TextStyle> _premiumTextStyle() {
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color: kBackgroundColor.withValues(alpha: 0.5),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.any: const TextStyle(
      color: kBackgroundColor,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
  });
}

FWidgetStateMap<IconThemeData> _premiumIconStyle({required double size}) {
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color: kBackgroundColor.withValues(alpha: 0.5),
      size: size,
    ),
    WidgetState.any: IconThemeData(color: kBackgroundColor, size: size),
  });
}
