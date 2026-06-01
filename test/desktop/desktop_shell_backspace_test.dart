import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/desktop_shell.dart';

void main() {
  group('desktop global search shortcut', () {
    testWidgets('handles Ctrl+F outside pane-local shortcuts', (tester) async {
      var searchCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => handleDesktopShellSearchKeyEvent(
                event: event,
                onSearch: () => searchCount += 1,
              ),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();

      expect(searchCount, 1);
    });

    testWidgets('handles Meta+F for macOS search', (tester) async {
      var searchCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => handleDesktopShellSearchKeyEvent(
                event: event,
                onSearch: () => searchCount += 1,
              ),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();

      expect(searchCount, 1);
    });

    testWidgets('ignores plain F so Board flip can still use it', (
      tester,
    ) async {
      var searchCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => handleDesktopShellSearchKeyEvent(
                event: event,
                onSearch: () => searchCount += 1,
              ),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();

      expect(searchCount, 0);
    });
  });

  group('desktop Backspace navigation shortcut guard', () {
    test('does nothing when the active tab has no back route', () {
      expect(
        shouldHandleDesktopBackspaceNavigation(
          canGoBack: false,
          primaryFocus: null,
        ),
        isFalse,
      );
    });

    test('allows Backspace route navigation outside text editing', () {
      expect(
        shouldHandleDesktopBackspaceNavigation(
          canGoBack: true,
          primaryFocus: null,
        ),
        isTrue,
      );
    });

    testWidgets('keeps Backspace for focused text fields', (tester) async {
      final focusNode = FocusNode(debugLabel: 'search field');
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(focusNode: focusNode)),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(
        shouldHandleDesktopBackspaceNavigation(
          canGoBack: true,
          primaryFocus: FocusManager.instance.primaryFocus,
        ),
        isFalse,
      );
    });
    testWidgets('does not consume Backspace before focused text fields', (
      tester,
    ) async {
      var backNavigationCount = 0;
      final focusNode = FocusNode(debugLabel: 'search field');
      final controller = TextEditingController(text: 'key');
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              onKeyEvent: (node, event) => handleDesktopShellBackspaceKeyEvent(
                event: event,
                canGoBack: true,
                primaryFocus: FocusManager.instance.primaryFocus,
                onBack: () => backNavigationCount += 1,
              ),
              child: TextField(focusNode: focusNode, controller: controller),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.text, 'ke');
      expect(backNavigationCount, 0);
    });

    testWidgets('handles Backspace as route navigation outside text fields', (
      tester,
    ) async {
      var backNavigationCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => handleDesktopShellBackspaceKeyEvent(
                event: event,
                canGoBack: true,
                primaryFocus: FocusManager.instance.primaryFocus,
                onBack: () => backNavigationCount += 1,
              ),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(backNavigationCount, 1);
    });
  });
}
