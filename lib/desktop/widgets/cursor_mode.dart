import 'package:flutter/widgets.dart';

/// Hover-cursor hints used by interactive desktop widgets.
///
/// Originally backed a custom in-app cursor overlay; now a thin layer over
/// `MouseRegion` + `SystemMouseCursors` so the OS pointer is what users see.
/// Kept as named modes so call sites can express intent (`hover`, `text`,
/// `grab`, …) without leaking `SystemMouseCursor` everywhere.
enum CursorMode {
  pointer,
  hover,
  pressing,
  grab,
  text,
  wait,
}

extension _CursorModeSystem on CursorMode {
  MouseCursor get systemCursor {
    switch (this) {
      case CursorMode.pointer:
        return SystemMouseCursors.basic;
      case CursorMode.hover:
      case CursorMode.pressing:
        return SystemMouseCursors.click;
      case CursorMode.grab:
        return SystemMouseCursors.grab;
      case CursorMode.text:
        return SystemMouseCursors.text;
      case CursorMode.wait:
        return SystemMouseCursors.wait;
    }
  }
}

/// Apply the OS cursor that matches [mode] while [child] is hovered.
class CursorAware extends StatelessWidget {
  const CursorAware({
    super.key,
    required this.mode,
    required this.child,
    this.enabled = true,
  });

  final CursorMode mode;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return MouseRegion(cursor: mode.systemCursor, child: child);
  }
}

/// "This widget is clickable" — shows the system click cursor on hover.
class ClickCursor extends StatelessWidget {
  const ClickCursor({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return CursorAware(
      mode: CursorMode.hover,
      enabled: enabled,
      child: child,
    );
  }
}
