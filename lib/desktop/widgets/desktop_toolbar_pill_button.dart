import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:motor/motor.dart';

/// Visual weight of a [DesktopToolbarPillButton].
///
/// The desktop chrome only has two: a [neutral] pill (the default, calm
/// affordance) and a [primary] pill that carries the [kPrimaryColor] brand
/// tint for the single most important action in a toolbar. We deliberately do
/// NOT expose forui's stock `FButtonStyle.primary()` here — that style is
/// near-white in our dark shell, which reads as a foreign element against the
/// board-dark chrome. "Primary" in this app means brand-tinted, not white.
enum DesktopToolbarPillTone { neutral, primary }

/// The one bespoke toolbar button for panes that sit above / beside the board.
///
/// It is the sidebar-button vocabulary distilled into a reusable primitive so
/// that every pill in a row is guaranteed the same size and the same motion:
///
///  * rounded-8 pill, height 34, symmetric 12px horizontal padding
///  * [neutral]: transparent → [kBlack3Color] hover fill, [kWhiteColor70] →
///    [kWhiteColor] label, thin [kDividerColor] resting border
///  * [primary]: [kPrimaryColor]-tinted fill (0.10 → 0.16 on hover), 0.35
///    border, accent foreground — the exact "selected sidebar item" treatment
///  * disabled: muted [kLightGreyColor] on a transparent pill
///  * a [SingleMotionBuilder] spring nudge: content reaches toward the cursor
///    on hover, dips on press; the pill itself stays put
///
/// Reference vocabulary: `lib/desktop/shell/desktop_sidebar.dart`
/// (`_SidebarItem`). Prefer this over a raw `FButton` for any custom desktop
/// toolbar control.
class DesktopToolbarPillButton extends StatefulWidget {
  const DesktopToolbarPillButton({
    super.key,
    required this.label,
    required this.onPress,
    this.icon,
    this.leading,
    this.tone = DesktopToolbarPillTone.neutral,
    this.tooltip,
    this.tabularFigures = false,
    this.busy = false,
    this.height = 34,
    this.trailing,
  }) : assert(
         icon != null || leading != null,
         'Provide either an icon or a leading widget',
       );

  /// Text shown on the pill. Keep it a verb + object ("Save to cloud").
  final String label;

  /// `null` renders the disabled (muted) state and swallows taps.
  final VoidCallback? onPress;

  /// Leading glyph. Ignored when [leading] is supplied.
  final IconData? icon;

  /// Overrides [icon] when non-null — used for a progress spinner while [busy].
  final Widget? leading;

  final DesktopToolbarPillTone tone;

  /// Tooltip text; falls back to [label] when omitted.
  final String? tooltip;

  /// Tabular figures on the label — keep percentages / counts from reflowing.
  final bool tabularFigures;

  /// Renders with the enabled (non-muted) look while remaining non-interactive.
  /// Used for the "building…" state where the action is in flight.
  final bool busy;

  /// Override for rows whose peer controls use another established height.
  final double height;

  /// Optional content after the label, such as an active-filter count badge.
  final Widget? trailing;

  @override
  State<DesktopToolbarPillButton> createState() =>
      _DesktopToolbarPillButtonState();
}

class _DesktopToolbarPillButtonState extends State<DesktopToolbarPillButton>
    with DeferredPointerStateMixin<DesktopToolbarPillButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final muted = !enabled && !widget.busy;
    final isPrimary = widget.tone == DesktopToolbarPillTone.primary;

    // Foreground / background mirror the sidebar item state machine.
    final Color fg;
    final Color bg;
    final Border border;
    if (muted) {
      fg = kLightGreyColor;
      bg = Colors.transparent;
      border = Border.all(color: kDividerColor);
    } else if (isPrimary) {
      fg = kPrimaryColor;
      bg = kPrimaryColor.withValues(alpha: _hovered ? 0.16 : 0.10);
      border = Border.all(color: kPrimaryColor.withValues(alpha: 0.35));
    } else {
      fg = _hovered ? kWhiteColor : kWhiteColor70;
      bg = _hovered ? kBlack3Color : Colors.transparent;
      border = Border.all(
        color: _hovered ? kWhiteColor.withValues(alpha: 0.10) : kDividerColor,
      );
    }

    // Same spring nudge as the sidebar: content reaches toward the cursor on
    // hover, dips back on press; the pill itself stays put.
    final nudgeX = _pressed ? -1.0 : (_hovered ? 2.0 : 0.0);

    final pill = Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border,
      ),
      child: SingleMotionBuilder(
        value: nudgeX,
        motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
        builder:
            (context, x, child) =>
                Transform.translate(offset: Offset(x, 0), child: child),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.leading ?? Icon(widget.icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures:
                    widget.tabularFigures
                        ? const [FontFeature.tabularFigures()]
                        : null,
              ),
            ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 8),
              widget.trailing!,
            ],
          ],
        ),
      ),
    );

    return DesktopTooltip(
      message: widget.tooltip ?? widget.label,
      child: CursorAware(
        mode: CursorMode.hover,
        enabled: enabled,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit:
              (_) => setStateAfterPointerEvent(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPress,
            onTapDown:
                enabled
                    ? (_) => setStateAfterPointerEvent(() => _pressed = true)
                    : null,
            onTapUp:
                enabled
                    ? (_) => setStateAfterPointerEvent(() => _pressed = false)
                    : null,
            onTapCancel:
                enabled
                    ? () => setStateAfterPointerEvent(() => _pressed = false)
                    : null,
            child: pill,
          ),
        ),
      ),
    );
  }
}
