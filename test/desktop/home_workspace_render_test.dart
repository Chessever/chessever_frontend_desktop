import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/panes/desktop_whats_new_home_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Home and workspace editors retain the same elements across activation and final close',
    (tester) async {
      final tabs = DesktopTabsNotifier();
      addTearDown(tabs.dispose);
      final screenshot = GlobalKey();
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWorkspaceStack(
              tabs: tabs.state.tabs,
              activeId: tabs.state.activeId,
              feedbackScreenshotKey: screenshot,
              contentBuilder:
                  (tab) => TextField(key: ValueKey('editor:${tab.id}')),
            ),
          ),
        ),
      );
      await render();
      final home = find.byKey(const ValueKey('editor:tournaments-default'));
      await tester.enterText(home, 'Home filter preserved');
      final homeElement = tester.element(home);
      final library = tabs.open(TabKind.library);
      await render();
      final editor = find.byKey(ValueKey('editor:$library'));
      await tester.enterText(editor, 'Unsaved workspace input');
      final workspaceElement = tester.element(editor);
      tabs.showHome();
      await render();
      expect(tester.element(home), same(homeElement));
      expect(find.text('Home filter preserved'), findsOneWidget);
      expect(find.text('Unsaved workspace input'), findsNothing);
      expect(
        find.byKey(ValueKey('editor:$library'), skipOffstage: false),
        findsOneWidget,
      );
      tabs.activate(library);
      await render();
      expect(tester.element(editor), same(workspaceElement));
      expect(find.text('Unsaved workspace input'), findsOneWidget);
      tabs.close(library);
      await render();
      expect(tester.element(home), same(homeElement));
      expect(find.text('Home filter preserved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual help opens and closes over the unchanged workspace', (
    tester,
  ) async {
    final tabs = DesktopTabsNotifier();
    addTearDown(tabs.dispose);
    final board = tabs.open(TabKind.board);
    final before = tabs.state;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showDesktopHowToUseDialog(
                        context,
                        feedbackScreenshotKey: GlobalKey(),
                      ),
                  child: const Text('Help'),
                ),
              ),
        ),
      ),
    );
    expect(find.byType(DesktopWhatsNewHomePane), findsNothing);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWhatsNewHomePane), findsOneWidget);
    expect(find.text('How to use'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWhatsNewHomePane), findsNothing);
    expect(tabs.state, same(before));
    expect(tabs.state.activeId, board);
    expect(tester.takeException(), isNull);
  });
}
