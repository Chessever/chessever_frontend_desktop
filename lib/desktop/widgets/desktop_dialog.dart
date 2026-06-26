import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Desktop replacement for Material's `showDialog`, routed through forui's
/// [showFDialog] so dialog chrome (barrier, transitions) lives in the same
/// design system as the rest of the desktop port instead of next to it.
///
/// Per AGENTS.md §7, desktop chrome (sidebar, dialogs, dropdowns, tooltips)
/// must use forui — not Material. forui resolves its dialog route + style
/// from the nearest [FTheme]; most desktop call sites sit under Material
/// with no [FTheme] ancestor, so [FTheme.of] would silently fall back to
/// `FThemes.zinc.light`, whose barrier is a near-transparent `0x33` dim
/// rather than the `0x7A` dim the dark chrome expects. This helper pins the
/// route style to [FThemes.zinc.dark] and wraps the body in a local
/// dark [FTheme] — the same trick [DesktopTooltip]/[DesktopDialogButton]
/// use — so the look is correct regardless of the call site's theme.
///
/// [useRootNavigator] defaults to `true` to match Material's `showDialog`,
/// keeping dialogs above the whole shell (the export progress dialog also
/// pops itself via the root navigator).
///
/// Bodies are expected to lay themselves out — most existing dialogs wrap
/// their content in `Center(Container(...))`. Pass [width] or [constraints]
/// to size a body that does not.
Future<T?> showDesktopDialog<T>(
  BuildContext context, {
  WidgetBuilder? builder,
  Widget? child,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  double? width,
  BoxConstraints? constraints,
}) {
  assert(
    (builder == null) != (child == null),
    'showDesktopDialog requires exactly one of builder or child.',
  );
  return showFDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    routeStyle: (_) => FThemes.zinc.dark.dialogRouteStyle,
    builder: (dialogContext, style, animation) {
      Widget content = child ?? Builder(builder: builder!);
      if (width != null) {
        content = SizedBox(width: width, child: content);
      } else if (constraints != null) {
        content = ConstrainedBox(constraints: constraints, child: content);
      }
      return FTheme(data: FThemes.zinc.dark, child: content);
    },
  );
}
