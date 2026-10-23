import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// [DragToMoveArea] for the shell's title-bar surfaces: dragging moves the
/// native window, double-clicking maximizes it.
///
/// A browser tab has no window to move, and window_manager has no web
/// implementation, so the browser build keeps only [child].
class DesktopDragToMoveArea extends StatelessWidget {
  const DesktopDragToMoveArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      kIsWeb ? child : DragToMoveArea(child: child);
}
