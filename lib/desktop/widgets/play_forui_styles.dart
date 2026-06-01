import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

FBaseButtonStyle Function(FButtonStyle style) playPrimaryActionButtonStyle({
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 11,
  ),
  double radius = 7,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _actionDecoration(
        fill: kPrimaryColor.withValues(alpha: 0.13),
        hoverFill: kPrimaryColor.withValues(alpha: 0.22),
        border: kPrimaryColor.withValues(alpha: 0.45),
        hoverBorder: kPrimaryColor.withValues(alpha: 0.85),
        radius: radius,
      ),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 8,
            textStyle: _actionTextStyle(idle: kPrimaryColor, hover: kWhiteColor),
            iconStyle: _actionIconStyle(idle: kPrimaryColor, hover: kWhiteColor),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) playSecondaryActionButtonStyle({
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 11,
  ),
  double radius = 7,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _actionDecoration(
        fill: kBlack2Color,
        hoverFill: kPrimaryColor.withValues(alpha: 0.13),
        border: kDividerColor,
        hoverBorder: kPrimaryColor.withValues(alpha: 0.42),
        radius: radius,
      ),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 8,
            textStyle: _actionTextStyle(idle: kWhiteColor, hover: kWhiteColor),
            iconStyle: _actionIconStyle(idle: kLightGreyColor, hover: kPrimaryColor),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) playDangerActionButtonStyle({
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 11,
  ),
  double radius = 7,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _actionDecoration(
        fill: kRedColor.withValues(alpha: 0.10),
        hoverFill: kRedColor.withValues(alpha: 0.18),
        border: kRedColor.withValues(alpha: 0.42),
        hoverBorder: kRedColor.withValues(alpha: 0.78),
        radius: radius,
      ),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 8,
            textStyle: _actionTextStyle(idle: kRedColor, hover: kWhiteColor),
            iconStyle: _actionIconStyle(idle: kRedColor, hover: kWhiteColor),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _actionDecoration({
  required Color fill,
  required Color hoverFill,
  required Color border,
  required Color hoverBorder,
  required double radius,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color: kBlack2Color.withValues(alpha: 0.42),
      border: Border.all(color: kDividerColor.withValues(alpha: 0.45)),
      borderRadius: BorderRadius.circular(radius),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: hoverFill,
      border: Border.all(color: hoverBorder),
      borderRadius: BorderRadius.circular(radius),
    ),
    WidgetState.any: BoxDecoration(
      color: fill,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(radius),
    ),
  });
}

FWidgetStateMap<TextStyle> _actionTextStyle({
  required Color idle,
  required Color hover,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      height: 1.15,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: hover,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
      height: 1.15,
    ),
    WidgetState.any: TextStyle(
      color: idle,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      height: 1.15,
    ),
  });
}

FWidgetStateMap<IconThemeData> _actionIconStyle({
  required Color idle,
  required Color hover,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color: kWhiteColor.withValues(alpha: 0.32),
      size: 15,
    ),
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color: hover,
      size: 15,
    ),
    WidgetState.any: IconThemeData(color: idle, size: 15),
  });
}
