import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Converts vertical mouse-wheel input over the chessboard into notation
/// navigation steps. Positive means forward, negative means backward.
class BoardWheelNavigation extends StatefulWidget {
  const BoardWheelNavigation({
    super.key,
    required this.onStep,
    required this.child,
  });

  final ValueChanged<int> onStep;
  final Widget child;

  @override
  State<BoardWheelNavigation> createState() => _BoardWheelNavigationState();
}

class _BoardWheelNavigationState extends State<BoardWheelNavigation> {
  Duration? _lastStepTime;
  Duration? _lastEventTime;
  double _distance = 0;
  int? _direction;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final step = boardWheelStepForDelta(event.scrollDelta);
    if (step == null) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      event.respond(allowPlatformDefault: false);
      final now = event.timeStamp;
      final previous = _lastEventTime;
      if (_direction != step ||
          previous == null ||
          now - previous > const Duration(milliseconds: 180)) {
        _distance = 0;
        _lastStepTime = null;
      }
      _direction = step;
      _lastEventTime = now;
      _distance += event.scrollDelta.dy.abs();
      // A high-resolution wheel/trackpad emits many tiny packets. Accumulate
      // distance and bound navigation work; never queue stale moves to replay
      // after the user has lifted their fingers.
      if (_distance < 18 ||
          (_lastStepTime != null &&
              now - _lastStepTime! < const Duration(milliseconds: 80))) {
        return;
      }
      _distance = 0;
      _lastStepTime = now;
      widget.onStep(step);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: widget.child,
    );
  }
}

int? boardWheelStepForDelta(Offset scrollDelta) {
  final dy = scrollDelta.dy;
  if (dy == 0) return null;
  if (dy.abs() < scrollDelta.dx.abs()) return null;
  return dy > 0 ? 1 : -1;
}
