import 'package:flutter/widgets.dart';

/// Fixed neutral reference over a rail, with optional label clearance.
/// Horizontal rails rotate the reference with the evaluation axis.
class DesktopEvalMidpoint extends StatelessWidget {
  const DesktopEvalMidpoint({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.labelBounds,
  });

  final Widget child;
  final Axis axis;

  /// Actual label geometry in rail coordinates, including animated placement.
  final Rect? labelBounds;

  static Widget behindLabel(BuildContext context, Rect? labelBounds) =>
      DesktopEvalMidpoint(
        labelBounds: labelBounds,
        child: const SizedBox.expand(),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRect(
              child: ClipPath(
                clipper: DesktopEvalLabelClearance(labelBounds),
                clipBehavior: Clip.hardEdge,
                child: Center(
                  child: SizedBox(
                    width: axis == Axis.vertical ? double.infinity : 3,
                    height: axis == Axis.vertical ? 3 : double.infinity,
                    child: const ColoredBox(color: Color(0xFF808080)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Remove only reference paint, never move the midpoint, badge or fill.
/// Two logical pixels of underlying rail separate nearby cyan/grey edges.
class DesktopEvalLabelClearance extends CustomClipper<Path> {
  const DesktopEvalLabelClearance(this.labelBounds);

  final Rect? labelBounds;
  static const gap = 2.0;

  @override
  Path getClip(Size size) {
    final railRect = Offset.zero & size;
    final rail = Path()..addRect(railRect);
    final label = labelBounds;
    if (label == null) return rail;
    final hole = label.inflate(gap).intersect(railRect);
    if (hole.width <= 0 || hole.height <= 0) return rail;
    // The badge moves on every frame of the eval spring, so this runs at the
    // display rate while the engine streams. A rail with the clamped hole
    // under even-odd fill is the same region as `Path.combine(difference)`
    // without a boolean path operation per frame.
    return rail
      ..fillType = PathFillType.evenOdd
      ..addRect(hole);
  }

  @override
  bool shouldReclip(DesktopEvalLabelClearance oldClipper) =>
      labelBounds != oldClipper.labelBounds;
}
