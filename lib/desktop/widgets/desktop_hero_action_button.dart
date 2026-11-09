import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/desktop/widgets/motion_translate.dart';

enum DesktopHeroActionTone { primary, secondary }

class DesktopHeroActionButton extends StatefulWidget {
  const DesktopHeroActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPress,
    this.tooltip,
    this.tone = DesktopHeroActionTone.secondary,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPress;
  final String? tooltip;
  final DesktopHeroActionTone tone;

  @override
  State<DesktopHeroActionButton> createState() =>
      _DesktopHeroActionButtonState();
}

class _DesktopHeroActionButtonState extends State<DesktopHeroActionButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      if (!hovered) _pressed = false;
    });
  }

  void _setStates(FWidgetStatesDelta delta) {
    final pressed = delta.current.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPress == null;
    final scale = disabled ? 1.0 : (_pressed ? 0.96 : (_hovered ? 1.015 : 1.0));

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: widget.tooltip ?? widget.label,
        // One hover spring drives the fill, border, shadow, label and icon
        // colour together, so the surface no longer snaps to its hover look
        // while the scale is still springing beside it.
        child: SingleMotionBuilder(
          value: !disabled && _hovered ? 1.0 : 0.0,
          motion: DesktopMotion.hover,
          builder:
              (context, hover, _) => SingleMotionBuilder(
                value: scale,
                motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                builder:
                    (context, value, child) => MotionScale(
                      scale: value,
                      alignment: Alignment.center,
                      // Bitmap-scale so Impeller keeps the label steady
                      // through the press/hover scale instead of re-shaping
                      // glyphs (flutter#149652).
                      child: child,
                    ),
                child: FButton(
                  style: _heroButtonStyle(widget.tone, hover.clamp(0.0, 1.0)),
                  onPress: widget.onPress,
                  onHoverChange: disabled ? null : _setHovered,
                  onStateChange: disabled ? null : _setStates,
                  mainAxisSize: MainAxisSize.min,
                  prefix: Icon(widget.icon),
                  child: Text(widget.label),
                ),
              ),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _heroButtonStyle(
  DesktopHeroActionTone tone,
  double hover,
) {
  final base =
      tone == DesktopHeroActionTone.primary
          ? FButtonStyle.primary
          : FButtonStyle.outline;

  return base(
    (style) => style.copyWith(
      decoration: _heroDecoration(tone, hover),
      // The press scale above is the only press motion: forui's own
      // unfiltered 0.97 tappable bounce would stack on it and re-shape the
      // label glyphs every frame.
      tappableStyle:
          (tappable) => tappable.copyWith(motion: (_) => FTappableMotion.none),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            spacing: 8,
            textStyle: _heroTextStyle(tone, hover),
            iconStyle: _heroIconStyle(tone, hover),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _heroDecoration(
  DesktopHeroActionTone tone,
  double hover,
) {
  final primary = tone == DesktopHeroActionTone.primary;
  final hovered = BoxDecoration(
    color: primary ? kPrimaryColor : kBlack3Color,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color:
          primary
              ? kLightYellowColor.withValues(alpha: 0.62)
              : kPrimaryColor.withValues(alpha: 0.42),
    ),
    boxShadow: [
      BoxShadow(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.20)
                : Colors.black.withValues(alpha: 0.28),
        blurRadius: primary ? 18 : 14,
        offset: const Offset(0, 5),
      ),
    ],
  );
  final rest = BoxDecoration(
    color: primary ? kPrimaryColor.withValues(alpha: 0.92) : kBlack2Color,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: primary ? kPrimaryColor.withValues(alpha: 0.50) : kDividerColor,
    ),
    boxShadow: [
      BoxShadow(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.18),
        blurRadius: primary ? 12 : 10,
        offset: const Offset(0, 3),
      ),
    ],
  );
  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color:
          primary
              ? kPrimaryColor.withValues(alpha: 0.36)
              : kBlack2Color.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.24)
                : kDividerColor.withValues(alpha: 0.55),
      ),
    ),
    // Keyboard presses (no pointer hover) still show the full hover look.
    WidgetState.pressed: hovered,
    WidgetState.any: BoxDecoration.lerp(rest, hovered, hover)!,
  });
}

FWidgetStateMap<TextStyle> _heroTextStyle(
  DesktopHeroActionTone tone,
  double hover,
) {
  final primary = tone == DesktopHeroActionTone.primary;
  final hovered = TextStyle(
    color: primary ? kBackgroundColor : kWhiteColor,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    height: 1,
  );
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.32),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.pressed: hovered,
    // Only the colour moves; size, weight and height stay fixed so the
    // label never re-lays out mid-hover.
    WidgetState.any: hovered.copyWith(
      color: Color.lerp(
        primary ? kBackgroundColor : kWhiteColor70,
        hovered.color,
        hover,
      ),
    ),
  });
}

FWidgetStateMap<IconThemeData> _heroIconStyle(
  DesktopHeroActionTone tone,
  double hover,
) {
  final primary = tone == DesktopHeroActionTone.primary;
  final hovered = IconThemeData(
    color: primary ? kBackgroundColor : kPrimaryColor,
    size: 16,
  );
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.32),
      size: 16,
    ),
    WidgetState.pressed: hovered,
    WidgetState.any: IconThemeData(
      color: Color.lerp(
        primary ? kBackgroundColor : kWhiteColor70,
        hovered.color,
        hover,
      ),
      size: 16,
    ),
  });
}
