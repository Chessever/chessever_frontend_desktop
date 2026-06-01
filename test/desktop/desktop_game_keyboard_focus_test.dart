import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nextDesktopGameKeyboardIndex', () {
    test('selects first item when current index is invalid', () {
      // ArrowDown with no prior selection (currentIndex=-1) must land on
      // index 0, matching the "Favorites/Countrymen start directly on first
      // game" spec. Previously this helper skipped to 1 because it clamped
      // -1 to 0 and then added the arrow's +1 step.
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: -1,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowDown,
        ),
        0,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: -1,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowUp,
        ),
        0,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: -1,
          itemCount: 5,
          key: LogicalKeyboardKey.pageDown,
        ),
        0,
      );
    });

    test('moves forward with down and right arrows', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 1,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowDown,
        ),
        2,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 1,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowRight,
        ),
        2,
      );
    });

    test('moves backward with up and left arrows', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 2,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowUp,
        ),
        1,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 2,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowLeft,
        ),
        1,
      );
    });

    test('page up and page down jump by page stride and clamp', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 1,
          itemCount: 20,
          key: LogicalKeyboardKey.pageDown,
          pageStride: 8,
        ),
        9,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 18,
          itemCount: 20,
          key: LogicalKeyboardKey.pageDown,
          pageStride: 8,
        ),
        19,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 9,
          itemCount: 20,
          key: LogicalKeyboardKey.pageUp,
          pageStride: 8,
        ),
        1,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 4,
          itemCount: 20,
          key: LogicalKeyboardKey.pageUp,
          pageStride: 8,
        ),
        0,
      );
    });

    test('home and end jump to edges', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 3,
          itemCount: 5,
          key: LogicalKeyboardKey.home,
        ),
        0,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 3,
          itemCount: 5,
          key: LogicalKeyboardKey.end,
        ),
        4,
      );
    });
  });
}
