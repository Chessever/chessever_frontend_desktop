import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

enum DesktopPaywallButtonTone { primary, secondary, ghost }

class DesktopPaywallButton extends StatelessWidget {
  const DesktopPaywallButton({
    super.key,
    required this.label,
    required this.onPress,
    this.tone = DesktopPaywallButtonTone.secondary,
    this.prefix,
    this.suffix,
    this.fillWidth = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPress;
  final DesktopPaywallButtonTone tone;
  final Widget? prefix;
  final Widget? suffix;
  final bool fillWidth;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final button = FButton(
      style: desktopPaywallButtonStyle(tone),
      onPress: loading ? null : onPress,
      mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
      prefix:
          loading
              ? FCircularProgress(
                style:
                    (style) => style.copyWith(
                      iconStyle: _paywallProgressIconStyle(tone),
                    ),
              )
              : prefix,
      suffix: suffix,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child:
          fillWidth ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) desktopPaywallButtonStyle(
  DesktopPaywallButtonTone tone,
) {
  final ghost = tone == DesktopPaywallButtonTone.ghost;
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _paywallButtonDecoration(tone),
      contentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.symmetric(
              horizontal: ghost ? 14 : 16,
              vertical: ghost ? 10 : 12,
            ),
            spacing: 8,
            textStyle: _paywallButtonTextStyle(tone),
            iconStyle: _paywallButtonIconStyle(tone),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _paywallButtonDecoration(
  DesktopPaywallButtonTone tone,
) {
  final primary = tone == DesktopPaywallButtonTone.primary;
  final ghost = tone == DesktopPaywallButtonTone.ghost;
  final radius = BorderRadius.circular(7);

  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color:
          primary
              ? kPrimaryColor.withValues(alpha: 0.22)
              : (ghost ? Colors.transparent : kBlack2Color.withValues(alpha: 0.5)),
      borderRadius: radius,
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.18)
                : (ghost
                    ? kWhiteColor.withValues(alpha: 0.04)
                    : kDividerColor.withValues(alpha: 0.45)),
      ),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color:
          primary
              ? const Color(0xFF22C4F4)
              : (ghost
                  ? kPrimaryColor.withValues(alpha: 0.10)
                  : kPrimaryColor.withValues(alpha: 0.13)),
      borderRadius: radius,
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.85)
                : kPrimaryColor.withValues(alpha: 0.42),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color:
          primary
              ? kPrimaryColor
              : (ghost ? Colors.transparent : kBlack2Color),
      borderRadius: radius,
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.7)
                : (ghost
                    ? kWhiteColor.withValues(alpha: 0.06)
                    : kDividerColor),
      ),
    ),
  });
}

FWidgetStateMap<TextStyle> _paywallButtonTextStyle(
  DesktopPaywallButtonTone tone,
) {
  final primary = tone == DesktopPaywallButtonTone.primary;
  final ghost = tone == DesktopPaywallButtonTone.ghost;

  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.55)
              : kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      height: 1.15,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: primary ? kBackgroundColor : kWhiteColor,
      fontSize: 13,
      fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
      height: 1.15,
    ),
    WidgetState.any: TextStyle(
      color: primary ? kBackgroundColor : (ghost ? kWhiteColor70 : kWhiteColor),
      fontSize: 13,
      fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
      height: 1.15,
    ),
  });
}

FWidgetStateMap<IconThemeData> _paywallButtonIconStyle(
  DesktopPaywallButtonTone tone,
) {
  final primary = tone == DesktopPaywallButtonTone.primary;
  final ghost = tone == DesktopPaywallButtonTone.ghost;
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.55)
              : kWhiteColor.withValues(alpha: 0.32),
      size: 15,
    ),
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color: primary ? kBackgroundColor : kPrimaryColor,
      size: 15,
    ),
    WidgetState.any: IconThemeData(
      color:
          primary
              ? kBackgroundColor
              : (ghost ? kLightGreyColor : kPrimaryColor),
      size: 15,
    ),
  });
}

IconThemeData _paywallProgressIconStyle(DesktopPaywallButtonTone tone) {
  final primary = tone == DesktopPaywallButtonTone.primary;
  return IconThemeData(
    color: primary ? kBackgroundColor : kPrimaryColor,
    size: 15,
  );
}
