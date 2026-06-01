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
  });

  final String message;
  final Widget child;
  final Duration hoverEnterDuration;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return child;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTooltip(
        hoverEnterDuration: hoverEnterDuration,
        tipBuilder: (_, _) => Text(message),
        child: child,
      ),
    );
  }
}
