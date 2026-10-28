import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:motor/motor.dart';

/// Canonical 28×28 icon button for board/engine pane header chrome
/// (engine quick toggle, picture-in-picture, engine gear, board
/// more-actions). Every header icon button renders through this one
/// widget so they sit side by side at exactly the same size, radius,
/// icon weight and vertical centre, following the sidebar button
/// vocabulary per AGENTS.md §3 instead of squeezing a forui button's
/// intrinsic padding into a 28 px box.
class DesktopHeaderIconButton extends StatefulWidget {
  const DesktopHeaderIconButton({
    super.key,
    required this.message,
    required this.icon,
    this.onPress,
    this.selected = false,
    this.disabled = false,
  });

  /// Tooltip shown on hover (doubles as the accessibility label).
  final String message;
  final IconData icon;
  final VoidCallback? onPress;

  /// Primary/active state: primary-tinted fill, border and foreground.
  final bool selected;

  /// Greyed-out, non-interactive state (e.g. engine not yet active).
  final bool disabled;

  @override
  State<DesktopHeaderIconButton> createState() =>
      _DesktopHeaderIconButtonState();
}

class _DesktopHeaderIconButtonState extends State<DesktopHeaderIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final interactive = !widget.disabled && widget.onPress != null;
    final Color foreground;
    final Color background;
    final Color borderColor;
    if (widget.selected) {
      foreground = kPrimaryColor;
      background = kPrimaryColor.withValues(alpha: _hovered ? 0.20 : 0.12);
      borderColor = kPrimaryColor.withValues(alpha: _hovered ? 0.52 : 0.36);
    } else if (widget.disabled) {
      foreground = kWhiteColor.withValues(alpha: 0.45);
      background = Colors.transparent;
      borderColor = kDividerColor;
    } else {
      foreground = _hovered ? kWhiteColor : kWhiteColor70;
      background = _hovered ? kBlack3Color : Colors.transparent;
      borderColor = _hovered
          ? kWhiteColor.withValues(alpha: 0.20)
          : kDividerColor;
    }

    return DesktopTooltip(
      message: widget.message,
      child: Semantics(
        button: true,
        toggled: widget.selected,
        label: widget.message,
        child: ClickCursor(
          enabled: interactive,
          child: MouseRegion(
            onEnter: interactive
                ? (_) => setState(() => _hovered = true)
                : null,
            onExit: interactive
                ? (_) => setState(() {
                    _hovered = false;
                    _pressed = false;
                  })
                : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: interactive ? widget.onPress : null,
              onTapDown: interactive
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapUp: interactive
                  ? (_) => setState(() => _pressed = false)
                  : null,
              onTapCancel: interactive
                  ? () => setState(() => _pressed = false)
                  : null,
              child: SingleMotionBuilder(
                value: _pressed ? 0.97 : (_hovered ? 1.012 : 1.0),
                motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                builder:
                    (context, scale, child) => Transform.scale(
                      scale: scale,
                      filterQuality: FilterQuality.medium,
                      child: child,
                    ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 110),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: borderColor),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    size: 16,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
