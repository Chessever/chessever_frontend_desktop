import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/browser_safe_shortcuts.dart';

class _Close extends Intent {
  const _Close();
}

void main() {
  testWidgets('Option+W closes a tab even when it types another character', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      Shortcuts(
        shortcuts: browserSafeTabShortcuts(
          closeTab: const _Close(),
          newTab: const _Close(),
          nextTab: const _Close(),
          previousTab: const _Close(),
        ),
        child: Actions(
          actions: {
            _Close: CallbackAction<_Close>(onInvoke: (_) => closed++),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );

    // macOS reports ⌥W as the character "∑" on the W key.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.keyW,
      physicalKey: PhysicalKeyboardKey.keyW,
      character: '∑',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(closed, 1);

    // Plain W, and ⌘⌥W, are not the chord.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(closed, 1);
  });
}
