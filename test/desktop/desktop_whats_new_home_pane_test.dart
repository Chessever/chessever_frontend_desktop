import 'package:chessever/desktop/panes/desktop_whats_new_home_pane.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('How to use tab resolves to the existing welcome pane', () {
    final pane = resolveDesktopTabContent(
      const DesktopTab(
        id: 'how-to-use-test',
        kind: TabKind.howToUse,
        title: 'How to use',
      ),
      feedbackScreenshotKey: GlobalKey(),
    );

    expect(pane, isA<DesktopWhatsNewHomePane>());
  });

  testWidgets(
    'Open Explorer power tip shows O while Explorer row Enter remains',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWhatsNewHomePane(feedbackScreenshotKey: GlobalKey()),
          ),
        ),
      );

      expect(find.text('Ctrl/Cmd + right-click'), findsOneWidget);
      expect(find.text('Open the board/game context menu.'), findsOneWidget);
      expect(find.text('O'), findsOneWidget);
      expect(find.text('Open Explorer from the board.'), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
      expect(
        find.text('Insert/open the selected Explorer game.'),
        findsOneWidget,
      );
    },
  );
}
