import 'dart:ui';

import 'package:chessever/desktop/widgets/desktop_eval_midpoint.dart';
import 'package:flutter_test/flutter_test.dart';

/// The label clearance is recomputed on every frame of the eval spring, so it
/// avoids a boolean path operation. It must still cover exactly the region
/// `Path.combine(difference)` described.
void main() {
  const size = Size(24, 401);

  Path reference(Rect? label) {
    final rail = Path()..addRect(Offset.zero & size);
    if (label == null) return rail;
    return Path.combine(
      PathOperation.difference,
      rail,
      Path()..addRect(label.inflate(DesktopEvalLabelClearance.gap)),
    );
  }

  final labels = <String, Rect?>{
    'none': null,
    'centered': const Rect.fromLTWH(0, 191.5, 24, 18),
    'fractional': const Rect.fromLTRB(0, 180.8, 24, 198.8),
    'clamped at top': const Rect.fromLTWH(0, 0, 24, 18),
    'clamped at bottom': const Rect.fromLTWH(0, 383, 24, 18),
    'partly outside': const Rect.fromLTWH(-6, -9, 40, 18),
    'narrow and inset': const Rect.fromLTWH(6, 100, 8, 10),
    'fully outside': const Rect.fromLTWH(0, 500, 24, 18),
  };

  for (final MapEntry(key: name, value: label) in labels.entries) {
    test('clearance matches the difference region: $name', () {
      final actual = DesktopEvalLabelClearance(label).getClip(size);
      final expected = reference(label);
      for (var y = -4.0; y <= size.height + 4; y += 0.5) {
        for (final x in const <double>[-1, 0.5, 5.9, 12, 18.1, 23.5, 25]) {
          final point = Offset(x, y);
          expect(
            actual.contains(point),
            expected.contains(point),
            reason: 'at $point',
          );
        }
      }
    });
  }
}
