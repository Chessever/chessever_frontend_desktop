import 'package:flutter/widgets.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/spring_tokens.dart';

/// Wraps any tappable surface with a near-imperceptible spring-based
/// press feedback: a small scale-down on pointer-down, scale-up to a
/// hint on hover, back to identity on release.
///
/// The amplitudes are intentionally tiny — `pressedScale: 0.97`,
/// `hoveredScale: 1.015` — so the effect reads as physical responsiveness,
/// not as "the UI is bouncing." On a 32-px chip a 0.97 press only moves
/// edges by ~½ px; on a 240-px sidebar item by ~3 px. The user feels it,
/// rarely consciously sees it.
///
/// Plays well around chessground / images / cards / chips. The motion
/// always lands precisely on whatever the user is interacting with,
/// because the scale pivot is the widget's own centre.
///
/// This widget intentionally does NOT eat the pointer events — it
/// installs a [Listener] (raw pointer) so the wrapped child can still
/// receive its own taps, secondary taps, drag callbacks, etc. through a
/// [GestureDetector] of its own.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressedScale = 0.97,
    this.hoveredScale = 1.015,
  });

  final Widget child;
  final bool enabled;
  final double pressedScale;
  final double hoveredScale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _hovered = false;
  bool _pressed = false;

  double get _target {
    if (!widget.enabled) return 1.0;
    if (_pressed) return widget.pressedScale;
    if (_hovered) return widget.hoveredScale;
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: SingleMotionBuilder(
          value: _target,
          motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
          builder: (context, scale, child) => Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
