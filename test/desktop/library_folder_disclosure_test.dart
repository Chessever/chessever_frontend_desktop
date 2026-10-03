import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/panes/library_pane.dart';

void main() {
  testWidgets(
    'folder row toggles on single click but not on double click or context menu',
    (tester) async {
      var selected = 0;
      var toggled = 0;
      var opened = 0;
      var menus = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: buildLibraryDatabaseCatalogRowForTest(
                title: 'Collections',
                expanded: true,
                onSelect: () => selected++,
                onToggleExpanded: () => toggled++,
                onOpen: () => opened++,
                onContextMenu: (_) => menus++,
              ),
            ),
          ),
        ),
      );
      final title = find.text('Collections');
      await tester.tap(title);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      expect(selected, 1);
      expect(toggled, 1);
      expect(opened, 0);
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(title);
      await tester.pump(kDoubleTapTimeout);
      expect(opened, 1);
      expect(toggled, 1);
      final right = await tester.startGesture(
        tester.getCenter(title),
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pump();
      expect(menus, 1);
      expect(toggled, 1);
    },
  );

  testWidgets(
    'folder keyboard disclosure ignores repeat and key-up and preserves Enter opening',
    (tester) async {
      final states = <bool>[];
      var toggles = 0;
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: buildLibraryDatabaseCatalogRowForTest(
                title: 'Students',
                expanded: false,
                onSelect: () {},
                onToggleExpanded: () => toggles++,
                onSetExpanded: states.add,
                onOpen: () => opens++,
                onContextMenu: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Students'));
      await tester.pump(kDoubleTapTimeout);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(states, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opens, 1);
      expect(toggles, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(toggles, 2);
    },
  );
}
