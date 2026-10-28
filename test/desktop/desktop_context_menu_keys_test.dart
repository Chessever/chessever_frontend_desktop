import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_global_search_intent.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';

/// The open context menu takes keyboard focus so Esc closes it instead of the
/// tab underneath. Its overlay is outside the shell's Actions, so global
/// search (AGENTS.md §7: always available) has to be forwarded.
void main() {
  Future<void> openMenu(
    WidgetTester tester, {
    required VoidCallback onSearch,
    required VoidCallback onShellEscape,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Actions(
          actions: <Type, Action<Intent>>{
            DesktopGlobalSearchIntent:
                CallbackAction<DesktopGlobalSearchIntent>(
                  onInvoke: (_) {
                    onSearch();
                    return null;
                  },
                ),
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): onShellEscape,
            },
            child: Focus(
              autofocus: true,
              debugLabel: 'shell',
              child: Scaffold(
                body: Builder(
                  builder:
                      (context) => TextButton(
                        onPressed:
                            () => showDesktopContextMenu<String>(
                              context: context,
                              position: const Offset(40, 40),
                              entries: const [
                                DesktopContextMenuItem<String>(
                                  value: 'copy',
                                  icon: Icons.copy,
                                  label: 'Copy',
                                ),
                              ],
                            ),
                        child: const Text('open menu'),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open menu'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
  }

  testWidgets('Ctrl+F in an open menu closes it and opens global search', (
    tester,
  ) async {
    var searches = 0;
    var shellEscapes = 0;
    await openMenu(
      tester,
      onSearch: () => searches++,
      onShellEscape: () => shellEscapes++,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(searches, 1);
    expect(find.text('Copy'), findsNothing);
    expect(shellEscapes, 0);
  });

  testWidgets('Esc closes the menu without reaching the shell', (
    tester,
  ) async {
    var searches = 0;
    var shellEscapes = 0;
    await openMenu(
      tester,
      onSearch: () => searches++,
      onShellEscape: () => shellEscapes++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsNothing);
    expect(shellEscapes, 0);
    expect(searches, 0);
    // Focus goes back where it was, so the shell's keys work again.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'shell');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(shellEscapes, 1);
  });
}
