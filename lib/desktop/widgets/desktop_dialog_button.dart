import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

enum DesktopDialogButtonTone { primary, secondary, ghost, danger }

class DesktopDialogButton extends StatelessWidget {
  const DesktopDialogButton({
    super.key,
    required this.label,
    required this.onPress,
    this.tone = DesktopDialogButtonTone.secondary,
    this.icon,
    this.prefix,
    this.child,
    this.tooltip,
    this.fillWidth = false,
  });

  final String label;
  final VoidCallback? onPress;
  final DesktopDialogButtonTone tone;
  final IconData? icon;
  final Widget? prefix;
  final Widget? child;
  final String? tooltip;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final button = FButton(
      style: desktopDialogButtonStyle(tone: tone),
      onPress: onPress,
      mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
      prefix: prefix ?? (icon == null ? null : Icon(icon)),
      child: child ?? Text(label),
    );

    final wrapped =
        fillWidth ? SizedBox(width: double.infinity, child: button) : button;

    return FTheme(
      data: FThemes.zinc.dark,
      child:
          tooltip == null
              ? wrapped
              : DesktopTooltip(message: tooltip!, child: wrapped),
    );
  }
}

class DesktopDialogIconButton extends StatelessWidget {
  const DesktopDialogIconButton({
    super.key,
    required this.icon,
    required this.onPress,
    required this.tooltip,
    this.tone = DesktopDialogButtonTone.ghost,
  });

  final IconData icon;
  final VoidCallback? onPress;
  final String tooltip;
  final DesktopDialogButtonTone tone;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: tooltip,
        child: FButton.icon(
          style: desktopDialogIconButtonStyle(tone: tone),
          onPress: onPress,
          child: Icon(icon),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) desktopDialogButtonStyle({
  DesktopDialogButtonTone tone = DesktopDialogButtonTone.secondary,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: 13,
    vertical: 9,
  ),
  double radius = 8,
}) {
  final palette = _paletteFor(tone);
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _dialogButtonDecoration(
        fill: palette.fill,
        hoverFill: palette.hoverFill,
        border: palette.border,
        hoverBorder: palette.hoverBorder,
        radius: radius,
      ),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 7,
            textStyle: _dialogButtonTextStyle(
              idle: palette.foreground,
              hover: palette.hoverForeground,
            ),
            iconStyle: _dialogButtonIconStyle(
              idle: palette.foreground,
              hover: palette.hoverForeground,
            ),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) desktopDialogIconButtonStyle({
  DesktopDialogButtonTone tone = DesktopDialogButtonTone.ghost,
  EdgeInsetsGeometry padding = const EdgeInsets.all(8),
  double radius = 8,
}) {
  final palette = _paletteFor(tone);
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _dialogButtonDecoration(
        fill: palette.fill,
        hoverFill: palette.hoverFill,
        border: palette.border,
        hoverBorder: palette.hoverBorder,
        radius: radius,
      ),
      iconContentStyle:
          (content) => content.copyWith(
            padding: padding,
            iconStyle: _dialogButtonIconStyle(
              idle: palette.foreground,
              hover: palette.hoverForeground,
            ),
          ),
    ),
  );
}

typedef _DialogButtonPalette =
    ({
      Color fill,
      Color hoverFill,
      Color border,
      Color hoverBorder,
      Color foreground,
      Color hoverForeground,
    });

_DialogButtonPalette _paletteFor(DesktopDialogButtonTone tone) {
  switch (tone) {
    case DesktopDialogButtonTone.primary:
      return (
        fill: kPrimaryColor.withValues(alpha: 0.16),
        hoverFill: kPrimaryColor.withValues(alpha: 0.24),
        border: kPrimaryColor.withValues(alpha: 0.58),
        hoverBorder: kLightYellowColor.withValues(alpha: 0.82),
        foreground: kLightYellowColor,
        hoverForeground: kWhiteColor,
      );
    case DesktopDialogButtonTone.secondary:
      return (
        fill: kBlack3Color,
        hoverFill: kBlack2Color,
        border: kWhiteColor.withValues(alpha: 0.14),
        hoverBorder: kWhiteColor.withValues(alpha: 0.26),
        foreground: kWhiteColor70,
        hoverForeground: kWhiteColor,
      );
    case DesktopDialogButtonTone.ghost:
      return (
        fill: Colors.transparent,
        hoverFill: kBlack3Color,
        border: Colors.transparent,
        hoverBorder: kWhiteColor.withValues(alpha: 0.12),
        foreground: kWhiteColor70,
        hoverForeground: kWhiteColor,
      );
    case DesktopDialogButtonTone.danger:
      return (
        fill: kRedColor.withValues(alpha: 0.11),
        hoverFill: kRedColor.withValues(alpha: 0.18),
        border: kRedColor.withValues(alpha: 0.38),
        hoverBorder: kRedColor.withValues(alpha: 0.66),
        foreground: kRedColor,
        hoverForeground: kWhiteColor,
      );
  }
}

FWidgetStateMap<BoxDecoration> _dialogButtonDecoration({
  required Color fill,
  required Color hoverFill,
  required Color border,
  required Color hoverBorder,
  required double radius,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color: kBlack2Color.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kDividerColor.withValues(alpha: 0.55)),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: hoverFill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: hoverBorder),
      boxShadow: [
        BoxShadow(
          color: hoverBorder.withValues(alpha: 0.12),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    WidgetState.any: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border),
    ),
  });
}

FWidgetStateMap<TextStyle> _dialogButtonTextStyle({
  required Color idle,
  required Color hover,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: hover,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.any: TextStyle(
      color: idle,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
  });
}

FWidgetStateMap<IconThemeData> _dialogButtonIconStyle({
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
