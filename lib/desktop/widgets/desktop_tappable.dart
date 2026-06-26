import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// InkWell-equivalent tap target for desktop chrome, backed by forui's
/// [FTappable] instead of Material ink.
///
/// Per AGENTS.md §7, desktop chrome must use forui, not Material. Material's
/// [InkWell] also needs a [Material] ancestor to paint its hover/splash,
/// which is brittle inside this forui-based shell. This wrapper reproduces
/// the bits the chrome actually relies on:
///  - a click cursor while enabled, the default arrow while disabled
///    ([FTappable]'s default cursor is `MouseCursor.defer`, so it must be
///    overridden to behave like [InkWell]);
///  - an optional translucent hover highlight clipped to [borderRadius],
///    painted behind the child like an ink highlight (omit [hoverColor] to
///    match InkWells that did not define one);
///  - button semantics and a disabled state when [onPress] is `null`.
///
/// forui resolves the tappable style from the nearest [FTheme]; this wraps a
/// local [FThemes.zinc.dark] so it is correct even with no ancestor theme —
/// the same local-theme trick [DesktopTooltip] uses.
class DesktopTappable extends StatelessWidget {
  const DesktopTappable({
    super.key,
    required this.onPress,
    required this.child,
    this.borderRadius,
    this.hoverColor,
    this.semanticsLabel,
  });

  /// Tap callback. When `null`, the tappable is disabled: no click cursor,
  /// no hover highlight, and semantics report it as disabled.
  final VoidCallback? onPress;

  /// The radius applied to both the hit region's cursor target and the
  /// hover highlight, mirroring [InkWell.borderRadius].
  final BorderRadius? borderRadius;

  /// Subtle overlay painted behind [child] while hovered and enabled. When
  /// `null`, no hover highlight is shown.
  final Color? hoverColor;

  final String? semanticsLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable.static(
        onPress: onPress,
        semanticsLabel: semanticsLabel,
        style: (style) => style.copyWith(
          cursor: const FWidgetStateMap({
            WidgetState.disabled: SystemMouseCursors.basic,
            WidgetState.any: SystemMouseCursors.click,
          }),
        ),
        builder: (context, states, child) {
          final hover = hoverColor;
          if (hover == null ||
              states.contains(WidgetState.disabled) ||
              !states.contains(WidgetState.hovered)) {
            return child!;
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              color: hover,
              borderRadius: borderRadius,
            ),
            child: child,
          );
        },
        child: child,
      ),
    );
  }
}
