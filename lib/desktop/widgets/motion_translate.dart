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

/// [Transform.scale] for animated hover / press scales; the scale twin of
/// [MotionTranslate].
///
/// A spring passing through 1.003, 1.007 ... re-shapes glyphs at a new
/// pixel snap every frame, so a hover grow or press dip shudders
/// (flutter#149652). While the scale is off 1 this rasterizes the child and
/// scales the bitmap with bilinear filtering; at rest it paints crisp
/// vectors with no image-filter layer. The [Transform] always stays in the
/// tree, so crossing rest swaps only the layer type and the child keeps its
/// state.
class MotionScale extends StatelessWidget {
  const MotionScale({
    super.key,
    required this.scale,
    this.alignment = Alignment.center,
    this.child,
  });

  final double scale;
  final AlignmentGeometry alignment;
  final Widget? child;

  /// Scale deltas below this read as rest (0.12 px on a 240 px surface).
  static const double _restEpsilon = 0.0005;

  @override
  Widget build(BuildContext context) {
    final atRest = (scale - 1.0).abs() < _restEpsilon;
    return Transform.scale(
      scale: atRest ? 1.0 : scale,
      alignment: alignment,
      filterQuality: atRest ? null : FilterQuality.medium,
      child: child,
    );
  }
}
