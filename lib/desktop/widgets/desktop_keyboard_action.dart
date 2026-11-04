import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Adds forui keyboard activation and focus styling to bespoke desktop chrome.
/// Child tooltip focus nodes are excluded so a button has one Tab stop.
class DesktopKeyboardAction extends StatelessWidget {
  const DesktopKeyboardAction({
    super.key,
    required this.onPress,
    required this.child,
    this.label,
    this.excludeChildFocus = true,
  });

  final VoidCallback? onPress;
  final Widget child;
  final String? label;

  /// Rows with independently actionable children keep those children reachable.
  final bool excludeChildFocus;

  @override
  Widget build(BuildContext context) => FTheme(
    data: FThemes.zinc.dark,
    child: FTappable.static(
      semanticsLabel: label,
      excludeSemantics: excludeChildFocus,
      onPress: onPress,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: excludeChildFocus ? ExcludeFocus(child: child) : child,
    ),
  );
}
