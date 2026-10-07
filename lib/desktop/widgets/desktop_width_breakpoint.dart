import 'package:flutter/widgets.dart';

/// Publishes whether the available width is below [breakpoint] without
/// rebuilding [child] on every constraint change.
///
/// A plain `LayoutBuilder` re-runs its builder, and so rebuilds everything it
/// returns, on every frame of a window resize or a sidebar animation. Here the
/// LayoutBuilder only rebuilds this scope; [child] is the same widget instance
/// each time, so Flutter skips it. Descendants that read [isBelow] rebuild only
/// when the side of the breakpoint actually changes.
class DesktopWidthBreakpoint extends StatelessWidget {
  const DesktopWidthBreakpoint({
    super.key,
    required this.breakpoint,
    required this.child,
  });

  final double breakpoint;
  final Widget child;

  /// Whether the nearest scope's width is below its breakpoint. Registers a
  /// dependency that only fires when that answer changes.
  static bool isBelow(BuildContext context) {
    final scope =
        context
            .dependOnInheritedWidgetOfExactType<_DesktopWidthBreakpointScope>();
    assert(scope != null, 'No DesktopWidthBreakpoint above this context.');
    return scope?.below ?? false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, constraints) => _DesktopWidthBreakpointScope(
          below: constraints.maxWidth < breakpoint,
          child: child,
        ),
  );
}

class _DesktopWidthBreakpointScope extends InheritedWidget {
  const _DesktopWidthBreakpointScope({
    required this.below,
    required super.child,
  });

  final bool below;

  @override
  bool updateShouldNotify(_DesktopWidthBreakpointScope oldWidget) =>
      below != oldWidget.below;
}
