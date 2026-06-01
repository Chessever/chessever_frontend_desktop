import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Converts vertical mouse-wheel input over the chessboard into notation
/// navigation steps. Positive means forward, negative means backward.
class BoardWheelNavigation extends StatelessWidget {
  const BoardWheelNavigation({
    super.key,
    required this.onStep,
    required this.child,
  });

  final ValueChanged<int> onStep;
  final Widget child;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final step = boardWheelStepForDelta(event.scrollDelta);
    if (step == null) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      onStep(step);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: child,
    );
  }
}

int? boardWheelStepForDelta(Offset scrollDelta) {
  final dy = scrollDelta.dy;
  if (dy == 0) return null;
  if (dy.abs() < scrollDelta.dx.abs()) return null;
  return dy > 0 ? 1 : -1;
}
