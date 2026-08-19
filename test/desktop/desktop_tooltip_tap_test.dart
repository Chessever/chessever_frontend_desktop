import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// forui's `FTooltip` wraps its child in an ancestor
/// `GestureDetector(onLongPressStart:)` when long-press is enabled. That
/// recognizer shares the gesture arena with the button's own tap recognizer and
/// wins outright once the press passes `kLongPressTimeout`, so a slow click on
/// any tooltipped desktop control was swallowed and the control looked dead.
void main() {
  Future<int> clickPill(
    WidgetTester tester, {
    required Duration hoverBeforeClick,
    required Duration holdDuration,
  }) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DesktopToolbarPillButton(
              label: 'Live first',
              icon: Icons.bolt_rounded,
              tooltip: 'Live events are shown first',
              onPress: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.text('Live first'));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(1, 1));
    await tester.pump();
    await gesture.moveTo(center);
    await tester.pump();
    await tester.pump(hoverBeforeClick);

    await gesture.down(center);
    await tester.pump();
    await tester.pump(holdDuration);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
    return taps;
  }

  testWidgets('a quick mouse click presses a tooltipped pill', (tester) async {
    expect(
      await clickPill(
        tester,
        hoverBeforeClick: const Duration(milliseconds: 10),
        holdDuration: const Duration(milliseconds: 20),
      ),
      1,
    );
  });

  testWidgets('a click with the tooltip already open presses the pill', (
    tester,
  ) async {
    expect(
      await clickPill(
        tester,
        hoverBeforeClick: const Duration(milliseconds: 500),
        holdDuration: const Duration(milliseconds: 20),
      ),
      1,
    );
  });

  testWidgets('a slow click is not eaten by the tooltip long-press', (
    tester,
  ) async {
    expect(
      await clickPill(
        tester,
        hoverBeforeClick: const Duration(milliseconds: 10),
        holdDuration: const Duration(milliseconds: 900),
      ),
      1,
    );
  });
}
