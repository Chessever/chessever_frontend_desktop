import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/player_profile_view.dart';

// Trello #1409: search results open a player profile on a single click, so the
// second click of a double-click landed on the new Overview's middle rating
// card and silently applied the Rapid filter. The Overview ignores clicks
// until a double-click's gap has passed.
void main() {
  Future<int Function()> pumpGuardedTarget(WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerProfileStrayClickGuard(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    return () => taps;
  }

  testWidgets(
    'the second click of a double-click does not reach the overview',
    (tester) async {
      final taps = await pumpGuardedTarget(tester);

      // A double-click's second click arrives within kDoubleTapTimeout.
      await tester.pump(kDoubleTapTimeout - const Duration(milliseconds: 1));
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      expect(taps(), 0);
      await tester.pump(PlayerProfileStrayClickGuard.settleDuration);
    },
  );

  testWidgets('a deliberate click after the overview settles still works', (
    tester,
  ) async {
    final taps = await pumpGuardedTarget(tester);

    await tester.pump(PlayerProfileStrayClickGuard.settleDuration);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();

    expect(taps(), 1);
  });

  test('the guard outlasts a double-click gap', () {
    expect(
      PlayerProfileStrayClickGuard.settleDuration,
      greaterThan(kDoubleTapTimeout),
    );
  });
}
