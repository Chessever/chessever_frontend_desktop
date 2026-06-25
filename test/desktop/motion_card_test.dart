import 'dart:ui' show PointerDeviceKind;

import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ignores late pointer callbacks after disposal', (tester) async {
    final cardKey = UniqueKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: MotionCard(
            key: cardKey,
            child: const SizedBox(width: 120, height: 80),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tester.getCenter(find.byKey(cardKey)));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await gesture.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
