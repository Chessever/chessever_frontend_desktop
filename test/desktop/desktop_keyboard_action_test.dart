import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_keyboard_action.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';

class _SearchIntent extends Intent {
  const _SearchIntent();
}

void main() {
  testWidgets('bespoke toolbar actions have one focus stop and activate once', (
    tester,
  ) async {
    var presses = 0;
    var searches = 0;
    void press() => presses++;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
                  _SearchIntent(),
              SingleActivator(
                    LogicalKeyboardKey.keyF,
                    control: true,
                    shift: true,
                  ):
                  _SearchIntent(),
            },
            child: Actions(
              actions: {
                _SearchIntent: CallbackAction<_SearchIntent>(
                  onInvoke: (_) {
                    searches++;
                    return null;
                  },
                ),
              },
              child: Center(
                child: DesktopKeyboardAction(
                  label: 'Games',
                  onPress: press,
                  child: DesktopToolbarPillButton(
                    label: 'Games',
                    icon: Icons.grid_view_rounded,
                    onPress: press,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(presses, 2);
    await tester.tap(find.text('Games'));
    await tester.pump();
    expect(presses, 3);

    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
    }
    expect(searches, 2);
    expect(presses, 3);
    await tester.pump(const Duration(seconds: 1));
  });
}
