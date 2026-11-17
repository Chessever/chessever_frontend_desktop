import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

/// Adds forui keyboard activation and focus styling to bespoke desktop chrome.
/// Child tooltip focus nodes are excluded so a button has one Tab stop.
class DesktopKeyboardAction extends StatelessWidget {
  const DesktopKeyboardAction({
    super.key,
    required this.onPress,
    required this.child,
    this.label,
    this.excludeChildFocus = true,
    this.focusRingRadius,
  });

  final VoidCallback? onPress;
  final Widget child;
  final String? label;

  /// Rows with independently actionable children keep those children reachable.
  final bool excludeChildFocus;

  /// When set, keyboard focus draws a [kPrimaryColor] ring on this corner
  /// radius around [child]. Unboxed glyphs need it: with no fill or edge of
  /// their own, nothing else shows where focus is. Null keeps the previous
  /// look for existing callers.
  final double? focusRingRadius;

  @override
  Widget build(BuildContext context) => FTheme(
    data: FThemes.zinc.dark,
    child: FTappable.static(
      semanticsLabel: label,
      excludeSemantics: excludeChildFocus,
      onPress: onPress,
      focusedOutlineStyle: switch (focusRingRadius) {
        final radius? =>
          (_) => FFocusedOutlineStyle(
            color: kPrimaryColor.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(radius),
            spacing: 0,
          ),
        null => null,
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: excludeChildFocus ? ExcludeFocus(child: child) : child,
    ),
  );
}
