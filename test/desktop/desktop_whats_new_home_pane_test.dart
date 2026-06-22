import 'package:chessever/desktop/panes/desktop_whats_new_home_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
