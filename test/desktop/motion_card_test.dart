import 'dart:ui' show PointerDeviceKind;

import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('survives proximity cursor tick while sliver card is removed', (
    tester,
  ) async {
    final cardKey = UniqueKey();
    var showCard = true;

    Widget buildHarness() {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: CursorProximityScope(
          child: CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate([
                  if (showCard)
                    MotionCard(
                      key: cardKey,
                      child: const SizedBox(width: 120, height: 80),
                    ),
                  const SizedBox(width: 120, height: 80),
                ]),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(buildHarness());

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(find.byKey(cardKey)));
    await tester.pump();

    showCard = false;
    await tester.pumpWidget(buildHarness());
    await gesture.moveTo(const Offset(20, 20));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

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
