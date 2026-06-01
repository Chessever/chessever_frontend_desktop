import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopHeaderActionButton extends StatelessWidget {
  const DesktopHeaderActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPress,
    this.tooltip,
    this.accented = false,
    this.fillWidth = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPress;
  final String? tooltip;
  final bool accented;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final button = FButton(
      style: _labelButtonStyle(accented: accented),
      onPress: onPress,
      mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
      prefix: Icon(icon),
      child: Text(label),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: tooltip ?? label,
        child:
            fillWidth
                ? SizedBox(width: double.infinity, child: button)
                : button,
      ),
    );
  }
}

class DesktopHeaderIconButton extends StatelessWidget {
  const DesktopHeaderIconButton({
    super.key,
    required this.icon,
    required this.onPress,
    required this.tooltip,
    this.selectedIcon,
    this.selected = false,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final VoidCallback? onPress;
  final String tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: tooltip,
        child: FButton.icon(
          style: _iconButtonStyle(selected: selected),
          onPress: onPress,
          child: Icon(selected ? (selectedIcon ?? icon) : icon),
        ),
      ),
    );
  }
}

class DesktopFavoriteButton extends StatelessWidget {
  const DesktopFavoriteButton({
    super.key,
    required this.selected,
    required this.onPress,
  });

  final bool selected;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final label = selected ? 'Favorited' : 'Favorite';
    final button = FButton(
      style: _favoriteButtonStyle(selected: selected),
      onPress: onPress,
      mainAxisSize: MainAxisSize.min,
      prefix: Icon(selected ? Icons.favorite : Icons.favorite_border),
      child: Text(label),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: selected ? 'Remove favorite player' : 'Favorite this player',
        child: button,
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _labelButtonStyle({
  required bool accented,
}) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: _buttonDecoration(accented: accented),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            spacing: 7,
            textStyle: _buttonTextStyle(accented: accented),
            iconStyle: _buttonIconStyle(accented: accented),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _iconButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: _buttonDecoration(accented: selected, subtleWhenIdle: true),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(8),
            iconStyle: _buttonIconStyle(accented: selected),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _favoriteButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: _favoriteButtonDecoration(selected: selected),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            spacing: 7,
            textStyle: _favoriteButtonTextStyle(selected: selected),
            iconStyle: _favoriteButtonIconStyle(selected: selected),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _buttonDecoration({
  required bool accented,
  bool subtleWhenIdle = false,
}) {
  final idleBorder =
      accented ? kRedColor.withValues(alpha: 0.34) : kDividerColor;
  final idleFill =
      accented
          ? kRedColor.withValues(alpha: 0.12)
          : (subtleWhenIdle ? Colors.transparent : kBlack2Color);
  final hoverFill = accented ? kRedColor.withValues(alpha: 0.18) : kBlack3Color;
  final hoverBorder =
      accented
          ? kRedColor.withValues(alpha: 0.52)
          : kWhiteColor.withValues(alpha: 0.16);

  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color: kBlack2Color.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: kDividerColor.withValues(alpha: 0.55)),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: hoverFill,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: hoverBorder),
    ),
    WidgetState.any: BoxDecoration(
      color: idleFill,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: idleBorder),
    ),
  });
}

FWidgetStateMap<BoxDecoration> _favoriteButtonDecoration({
  required bool selected,
}) {
  final idleFill = kRedColor.withValues(alpha: selected ? 0.15 : 0.08);
  final idleBorder = kRedColor.withValues(alpha: selected ? 0.54 : 0.32);
  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color: kBlack2Color.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: kDividerColor.withValues(alpha: 0.55)),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: kRedColor.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: kRedColor.withValues(alpha: 0.62)),
    ),
    WidgetState.any: BoxDecoration(
      color: idleFill,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: idleBorder),
    ),
  });
}

FWidgetStateMap<TextStyle> _buttonTextStyle({required bool accented}) {
  final idle = accented ? kLightYellowColor : kWhiteColor70;
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1,
    ),
    WidgetState.any: TextStyle(
      color: idle,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1,
    ),
  });
}

FWidgetStateMap<TextStyle> _favoriteButtonTextStyle({required bool selected}) {
  final idle = selected ? kWhiteColor : kWhiteColor70;
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.hovered | WidgetState.pressed: const TextStyle(
      color: kWhiteColor,
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

FWidgetStateMap<IconThemeData> _buttonIconStyle({required bool accented}) {
  final idle = accented ? kRedColor : kWhiteColor70;
  final hover = accented ? kRedColor : kWhiteColor;
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

FWidgetStateMap<IconThemeData> _favoriteButtonIconStyle({
  required bool selected,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color: kWhiteColor.withValues(alpha: 0.32),
      size: 15,
    ),
    WidgetState.hovered | WidgetState.pressed: const IconThemeData(
      color: kRedColor,
      size: 15,
    ),
    WidgetState.any: const IconThemeData(color: kRedColor, size: 15),
  });
}
