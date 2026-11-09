import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/motion_translate.dart';
import 'package:chessever/desktop/widgets/pressable_scale.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

/// The chessever.com/mobile page. Its hero already holds every desktop
/// download (macOS Apple Silicon and Intel, Windows, Linux), so no
/// fragment is needed to scroll anywhere.
final Uri kDesktopDownloadPageUri = Uri.parse('https://chessever.com/mobile');

/// Whether the sidebar offers the desktop download. Only the browser build
/// at app.chessever.com shows it: the desktop builds already are the app.
bool get showSidebarDownloadButton => kIsWeb;

/// "Download app" call to action pinned above Settings in the web sidebar.
///
/// Same solid cyan surface as the "New update available" chip so it reads
/// as the one action on the rail worth a look. On hover the surface eases
/// brighter on the shared hover spring and the install glyph dips 1.5 px,
/// the "it goes down to your machine" gesture. The button itself never
/// grows on hover; only a press dip.
class DesktopSidebarDownloadButton extends StatefulWidget {
  const DesktopSidebarDownloadButton({
    super.key,
    required this.expanded,
    this.collapsedSize = 44,
    this.expandedHeight = 36,
    this.topPadding = 8,
    this.bottomPadding = 8,
    this.onPress,
  });

  final bool expanded;

  /// Edge of the square icon button on the collapsed rail.
  final double collapsedSize;

  /// Height of the labelled button on the expanded rail.
  final double expandedHeight;

  final double topPadding;
  final double bottomPadding;

  /// Overrides opening [kDesktopDownloadPageUri] (tests).
  final VoidCallback? onPress;

  static const String label = 'Download app';
  static const String collapsedTooltip = 'Download the desktop app';
  static const IconData icon = Icons.install_desktop_rounded;

  static const double _expandedIconSize = 16;
  static const double _collapsedIconSize = 18;

  @override
  State<DesktopSidebarDownloadButton> createState() =>
      _DesktopSidebarDownloadButtonState();
}

class _DesktopSidebarDownloadButtonState
    extends State<DesktopSidebarDownloadButton>
    with DeferredPointerStateMixin<DesktopSidebarDownloadButton> {
  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setStateAfterPointerEvent(() => _hovered = hovered);
  }

  void _open() {
    final override = widget.onPress;
    if (override != null) {
      override();
      return;
    }
    unawaited(launchDesktopWebUrl(kDesktopDownloadPageUri));
  }

  @override
  Widget build(BuildContext context) {
    final expanded = widget.expanded;
    final iconSize =
        expanded
            ? DesktopSidebarDownloadButton._expandedIconSize
            : DesktopSidebarDownloadButton._collapsedIconSize;

    final button = SingleMotionBuilder(
      value: _hovered ? 1.0 : 0.0,
      motion: DesktopMotion.hover,
      builder: (context, h, _) {
        final t = h.clamp(0.0, 1.0);
        // The glyph dips 1.5 px on hover; MotionTranslate keeps the
        // sub-pixel travel smooth.
        final glyph = MotionTranslate(
          offset: Offset(0, 1.5 * t),
          child: const Icon(DesktopSidebarDownloadButton.icon),
        );
        if (expanded) {
          return FButton(
            style: _downloadButtonStyle(
              hover: t,
              iconSize: iconSize,
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: math.max(0, (widget.expandedHeight - iconSize) / 2),
              ),
            ),
            onPress: _open,
            onHoverChange: _setHovered,
            mainAxisSize: MainAxisSize.max,
            prefix: glyph,
            child: const Text(DesktopSidebarDownloadButton.label),
          );
        }
        return FButton.icon(
          style: _downloadIconButtonStyle(
            hover: t,
            iconSize: iconSize,
            padding: math.max(0, (widget.collapsedSize - iconSize) / 2),
          ),
          onPress: _open,
          onHoverChange: _setHovered,
          child: glyph,
        );
      },
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          widget.topPadding,
          12,
          widget.bottomPadding,
        ),
        child: DesktopTooltip(
          message:
              expanded ? '' : DesktopSidebarDownloadButton.collapsedTooltip,
          child: Semantics(
            link: true,
            child: PressableScale(
              hoveredScale: 1.0,
              pressedScale: 0.97,
              child: SizedBox(
                width: expanded ? null : widget.collapsedSize,
                height: expanded ? widget.expandedHeight : widget.collapsedSize,
                child: button,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rest and hovered surfaces of the update chip, without its glow: a solid
/// [kPrimaryColor] fill that brightens and picks up a warm edge on hover.
FWidgetStateMap<BoxDecoration> _downloadDecoration(double hover) {
  final rest = BoxDecoration(
    color: kPrimaryColor,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: kPrimaryColor.withValues(alpha: 0.65)),
  );
  final hovered = BoxDecoration(
    color: const Color(0xFF22C4F4),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: kLightYellowColor.withValues(alpha: 0.58)),
  );
  return FWidgetStateMap({
    // Keyboard presses (no pointer hover) still show the full hover look.
    WidgetState.pressed: hovered,
    WidgetState.any: BoxDecoration.lerp(rest, hovered, hover)!,
  });
}

FBaseButtonStyle Function(FButtonStyle style) _downloadButtonStyle({
  required double hover,
  required double iconSize,
  required EdgeInsets padding,
}) {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _downloadDecoration(hover),
      // PressableScale's filtered spring is the only press motion.
      tappableStyle:
          (tappable) => tappable.copyWith(motion: (_) => FTappableMotion.none),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 8,
            textStyle: FWidgetStateMap.all(
              const TextStyle(
                color: kBackgroundColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
            iconStyle: FWidgetStateMap.all(
              IconThemeData(color: kBackgroundColor, size: iconSize),
            ),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _downloadIconButtonStyle({
  required double hover,
  required double iconSize,
  required double padding,
}) {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: _downloadDecoration(hover),
      tappableStyle:
          (tappable) => tappable.copyWith(motion: (_) => FTappableMotion.none),
      iconContentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.all(padding),
            iconStyle: FWidgetStateMap.all(
              IconThemeData(color: kBackgroundColor, size: iconSize),
            ),
          ),
    ),
  );
}
