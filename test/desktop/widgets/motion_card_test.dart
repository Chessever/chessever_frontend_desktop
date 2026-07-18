import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/motion_card.dart';

void main() {
  testWidgets('MotionCard does not eat the child gesture', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionCard(
              child: GestureDetector(
                key: const Key('inner'),
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 200, height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('inner')));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('MotionCard keeps its text stationary while hovered', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionCard(
              child: SizedBox(
                width: 200,
                height: 100,
                child: Center(child: Text('Stable card text')),
              ),
            ),
          ),
        ),
      ),
    );

    final text = find.text('Stable card text');
    final restingPosition = tester.getTopLeft(text);
    expect(
      find.ancestor(of: text, matching: find.byType(Transform)),
      findsNothing,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(MotionCard)));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.getTopLeft(text), restingPosition);
    expect(
      find.ancestor(of: text, matching: find.byType(Transform)),
      findsNothing,
    );
  });

  testWidgets('MotionCard(enabled: false) returns the child untouched', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MotionCard(
            enabled: false,
            child: SizedBox(key: Key('c'), width: 10, height: 10),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('c')), findsOneWidget);
  });
}
