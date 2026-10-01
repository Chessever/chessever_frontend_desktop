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
    final rail = Path()..addRect(Offset.zero & size);
    final label = labelBounds;
    if (label == null) return rail;
    return Path.combine(
      PathOperation.difference,
      rail,
      Path()..addRect(label.inflate(gap)),
    );
  }

  @override
  bool shouldReclip(DesktopEvalLabelClearance oldClipper) =>
      labelBounds != oldClipper.labelBounds;
}
