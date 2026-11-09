import 'package:flutter/widgets.dart';

/// [Transform.translate] for animated hover / press nudges.
///
/// A spring-driven offset passes through fractional pixel positions
/// (-0.37, -0.81, -1.24 ...). Painted as vectors, Impeller snaps text and
/// icon glyphs to whole pixels on every frame, so a 1-2 px lift shudders
/// up in visible steps instead of gliding (flutter#149652, the same cause
/// as the press "titreme" fixed in `PressableScale`).
///
/// While the offset is non-zero this rasterizes the child and moves the
/// bitmap with bilinear filtering, which keeps the motion continuous. At
/// rest it paints as plain vectors, so idle chrome stays pixel-crisp and
/// carries no image-filter layer. Scale animations get the same treatment
/// by passing `filterQuality: FilterQuality.medium` to [Transform.scale].
class MotionTranslate extends StatelessWidget {
  const MotionTranslate({super.key, required this.offset, this.child});

  final Offset offset;
  final Widget? child;

  /// Offsets smaller than this are treated as rest. Springs approach their
  /// target asymptotically; this keeps the last imperceptible tail of the
  /// settle on the crisp vector path.
  static const double _restEpsilon = 0.01;

  @override
  Widget build(BuildContext context) {
    final atRest =
        offset.dx.abs() < _restEpsilon && offset.dy.abs() < _restEpsilon;
    // Always a Transform (never the bare child) so crossing rest swaps only
    // the layer type, not the element tree: the child keeps its state.
    return Transform.translate(
      offset: atRest ? Offset.zero : offset,
      filterQuality: atRest ? null : FilterQuality.medium,
      child: child,
    );
  }
}
