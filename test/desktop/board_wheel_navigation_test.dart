import 'package:chessever/desktop/widgets/board_wheel_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps vertical wheel down/up to notation forward/back', () {
    expect(boardWheelStepForDelta(const Offset(0, 20)), 1);
    expect(boardWheelStepForDelta(const Offset(0, -20)), -1);
  });

  test('ignores horizontal-dominant and empty wheel deltas', () {
    expect(boardWheelStepForDelta(Offset.zero), isNull);
    expect(boardWheelStepForDelta(const Offset(24, 8)), isNull);
  });

  testWidgets('emits one step for a mouse wheel signal over the child', (
    tester,
  ) async {
    final steps = <int>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: BoardWheelNavigation(
              onStep: steps.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 20)));

    expect(steps, [1]);
  });

  testWidgets(
    'trackpad packets are accumulated and navigation bursts bounded',
    (tester) async {
      final steps = <int>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BoardWheelNavigation(
            onStep: steps.add,
            child: const SizedBox.expand(),
          ),
        ),
      );
      Future<void> packet(int ms, double delta) => tester.sendEventToBinding(
        PointerScrollEvent(
          timeStamp: Duration(milliseconds: ms),
          position: const Offset(300, 200),
          kind: PointerDeviceKind.mouse,
          scrollDelta: Offset(0, delta),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await packet(i * 8, 3);
      }
      expect(steps, isEmpty);
      await packet(40, 3);
      expect(steps, [1]);
      for (var i = 6; i < 15; i++) {
        await packet(i * 8, 5);
      }
      expect(steps, [1]);
      await packet(120, 5);
      expect(steps, [1, 1]);
      // A deliberate reversal is never held behind the forward throttle.
      await packet(128, -20);
      expect(steps, [1, 1, -1]);
      await tester.pump(const Duration(seconds: 1));
      expect(steps, [1, 1, -1]);
    },
  );
}
