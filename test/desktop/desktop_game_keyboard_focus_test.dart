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

    test('down/up travel a full row in a multi-column grid', () {
      // 3 columns: index 1 (row0 col1) -> down lands on index 4 (row1 col1),
      // not the adjacent index 2 that a flat list would step to.
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 1,
          itemCount: 9,
          key: LogicalKeyboardKey.arrowDown,
          columnCount: 3,
        ),
        4,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 7,
          itemCount: 9,
          key: LogicalKeyboardKey.arrowUp,
          columnCount: 3,
        ),
        4,
      );
    });

    test('left/right still step one card regardless of column count', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 4,
          itemCount: 9,
          key: LogicalKeyboardKey.arrowRight,
          columnCount: 3,
        ),
        5,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 4,
          itemCount: 9,
          key: LogicalKeyboardKey.arrowLeft,
          columnCount: 3,
        ),
        3,
      );
    });

    test('up clamps onto the first card from the top row', () {
      // Row0 (col1) has no row above; ArrowUp lands on index 0.
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 1,
          itemCount: 9,
          key: LogicalKeyboardKey.arrowUp,
          columnCount: 3,
        ),
        0,
      );
    });

    test('down clamps onto the last card so a partial final row is reachable', () {
      // 7 items, 3 cols: rows [0,1,2] [3,4,5] [6]. From index 4 the row below
      // has no col1, so ArrowDown clamps onto the last real card (index 6)
      // instead of trapping focus on the last full row.
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 4,
          itemCount: 7,
          key: LogicalKeyboardKey.arrowDown,
          columnCount: 3,
        ),
        6,
      );
    });

    test('column count of 1 keeps the original flat-list behavior', () {
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 2,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowDown,
          columnCount: 1,
        ),
        3,
      );
      expect(
        nextDesktopGameKeyboardIndex(
          currentIndex: 2,
          itemCount: 5,
          key: LogicalKeyboardKey.arrowUp,
          columnCount: 1,
        ),
        1,
      );
    });
  });
}
