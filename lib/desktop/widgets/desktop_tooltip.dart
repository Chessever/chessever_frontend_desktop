import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Hover/long-press tooltip for desktop chrome.
///
/// Per AGENTS.md §7, desktop chrome (sidebar, dialogs, dropdowns, tooltips)
/// must use forui — not Material. Material's `Tooltip` was rebuilt on top of
/// the new internal `RawTooltip` in Flutter 3.41.9 and asserts on
/// `SingleTickerProviderStateMixin` when widgets are reparented during tab
/// switches. Routing chrome tooltips through `FTooltip` sidesteps that and
/// keeps us aligned with the documented UI direction.
///
/// An empty [message] renders [child] alone (mirrors the prior call sites
/// that suppressed the tooltip when the sidebar was expanded).
class DesktopTooltip extends StatelessWidget {
  const DesktopTooltip({
    super.key,
    required this.message,
    required this.child,
    this.hoverEnterDuration = const Duration(milliseconds: 350),
    this.tipAnchor = Alignment.bottomCenter,
    this.childAnchor = Alignment.topCenter,
    this.shift = FPortalShift.flip,
    this.style,
    this.tipBuilder,
  });

  final String message;
  final Widget child;
  final Duration hoverEnterDuration;
  final AlignmentGeometry tipAnchor;
  final AlignmentGeometry childAnchor;

  /// Places the tip: its offset from [child]'s top left (see [FPortalShift]).
  final Offset Function(Size view, FPortalChildBox child, FPortalBox tip) shift;

  /// Adjusts the theme's tooltip style.
  final FTooltipStyle Function(FTooltipStyle style)? style;

  /// Builds the tip's content, in place of [message] set as text.
  final WidgetBuilder? tipBuilder;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return child;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTooltip(
        hoverEnterDuration: hoverEnterDuration,
        tipAnchor: tipAnchor,
        childAnchor: childAnchor,
        shift: shift,
        style: style,
        // Desktop chrome is mouse-driven, and FTooltip's long-press support
        // wraps the child in an ancestor `GestureDetector(onLongPressStart:)`.
        // That recognizer shares the gesture arena with the button's own tap
        // recognizer and wins outright once the press passes
        // `kLongPressTimeout` (500ms), so a slow click on any tooltipped
        // control is swallowed and the button looks dead. Hover already covers
        // the desktop affordance, so drop the long-press path entirely.
        longPress: false,
        tipBuilder: (context, _) => tipBuilder?.call(context) ?? Text(message),
        child: child,
      ),
    );
  }
}
