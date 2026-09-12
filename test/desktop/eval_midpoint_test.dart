import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('neutral midpoint is fixed across scores and orientation', (
    tester,
  ) async {
    for (final flipped in [false, true]) {
      for (final score in <double?>[null, -20, -3, 0, 3, 20]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: DesktopEvalBar(
                width: 24,
                height: 401,
                isFlipped: flipped,
                evaluation: score,
                mate: null,
                isEvaluating: score != null,
              ),
            ),
          ),
        );
        final rail = find.byType(DesktopEvalBar);
        final marker = find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFF808080),
        );
        expect(marker, findsOneWidget);
        expect(tester.getSize(marker), const Size(24, 3));
        expect(tester.getCenter(marker), tester.getCenter(rail));
        expect(
          find.ancestor(of: marker, matching: find.byType(IgnorePointer)),
          findsOneWidget,
        );
        expect(
          find.ancestor(of: marker, matching: find.byType(ClipRect)),
          findsOneWidget,
        );
      }
    }
  });
}
