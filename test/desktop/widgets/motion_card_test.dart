import 'dart:math' as math;

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

  testWidgets('MotionCard scales up while hovered (spring actually runs)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionCard(child: SizedBox(width: 200, height: 100)),
          ),
        ),
      ),
    );

    double maxScale() => tester
        .widgetList<Transform>(find.byType(Transform))
        .map((t) => t.transform.getMaxScaleOnAxis())
        .fold<double>(0, math.max);

    expect(maxScale(), closeTo(1.0, 0.001)); // at rest

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(MotionCard)));
    await tester.pump(); // hover registered → spring starts
    await tester.pump(const Duration(milliseconds: 200)); // let it travel
    expect(maxScale(), greaterThan(1.01)); // clearly docked, not a whisper
  });

  testWidgets('MotionCard magnifies more when the cursor is nearer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CursorProximityScope(
            child: Center(
              child: MotionCard(child: SizedBox(width: 120, height: 120)),
            ),
          ),
        ),
      ),
    );

    double maxScale() => tester
        .widgetList<Transform>(find.byType(Transform))
        .map((t) => t.transform.getMaxScaleOnAxis())
        .fold<double>(0, math.max);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(2, 2)); // far corner
    addTearDown(() => gesture.removePointer());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final farScale = maxScale();

    await gesture.moveTo(tester.getCenter(find.byType(MotionCard)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final nearScale = maxScale();

    expect(nearScale, greaterThan(farScale));
    expect(nearScale, greaterThan(1.01));
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

  // The reported "board shifts before navigation" bug: a hovered card sits
  // lifted (Transform.translate y = -hoverLift); pressing collapses the lift
  // back to 0, dropping the card a few px in the frame before a navigating
  // tap fires. Lift is read straight off the Transform matrix.
  double minLiftY(WidgetTester tester) => tester
      .widgetList<Transform>(find.byType(Transform))
      .map((t) => t.transform.getTranslation().y)
      .fold<double>(0, math.min);

  Future<TestGesture> hoverCenter(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(find.byType(MotionCard)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // settle hover lift
    return gesture;
  }

  testWidgets('MotionCard drops its hover lift on press by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionCard(child: SizedBox(width: 200, height: 100)),
          ),
        ),
      ),
    );

    final gesture = await hoverCenter(tester);
    final hoverLift = minLiftY(tester);
    expect(hoverLift, lessThan(-3)); // hover clearly raises the card

    await gesture.down(tester.getCenter(find.byType(MotionCard)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // settle press

    // Press collapses the lift toward the surface — the visible board drop.
    expect(minLiftY(tester), greaterThan(hoverLift + 3));
  });

  testWidgets('MotionCard(depressOnPress: false) keeps its lift on press', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionCard(
              depressOnPress: false,
              child: SizedBox(width: 200, height: 100),
            ),
          ),
        ),
      ),
    );

    final gesture = await hoverCenter(tester);
    final hoverLift = minLiftY(tester);
    expect(hoverLift, lessThan(-3)); // hover still raises the card

    await gesture.down(tester.getCenter(find.byType(MotionCard)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // No press depression: the card holds its lift, so nothing shifts in the
    // frame before a navigating tap fires.
    expect(minLiftY(tester), closeTo(hoverLift, 1.0));
  });
}
