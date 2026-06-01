import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopSidebarPremiumButton extends StatelessWidget {
  const DesktopSidebarPremiumButton({
    super.key,
    required this.expanded,
    required this.onPress,
  });

  final bool expanded;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final button =
        expanded
            ? FButton(
              style: _premiumButtonStyle(),
              onPress: onPress,
              mainAxisSize: MainAxisSize.max,
              prefix: const Icon(Icons.workspace_premium_rounded),
              child: const Text('Get Premium'),
            )
            : SizedBox(
              width: 44,
              height: 44,
              child: FButton.icon(
                style: _premiumIconButtonStyle(),
                onPress: onPress,
                child: const Icon(Icons.workspace_premium_rounded),
              ),
            );

    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DesktopTooltip(
          message: expanded ? '' : 'Get Premium',
          child: button,
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _premiumButtonStyle() {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _premiumDecoration(radius: 8),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            spacing: 8,
            textStyle: _premiumTextStyle(),
            iconStyle: _premiumIconStyle(size: 16),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _premiumIconButtonStyle() {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _premiumDecoration(radius: 8),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(11),
            iconStyle: _premiumIconStyle(size: 18),
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
