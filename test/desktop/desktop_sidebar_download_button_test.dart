import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_sidebar_download_button.dart';

void main() {
  test('points at the chessever.com/mobile download page', () {
    expect(
      kDesktopDownloadPageUri.toString(),
      'https://chessever.com/mobile',
    );
  });

  for (final expanded in [true, false]) {
    testWidgets(
      'opens the download page (${expanded ? 'expanded' : 'collapsed'})',
      (tester) async {
        var opened = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: expanded ? 240 : 72,
                  child: DesktopSidebarDownloadButton(
                    expanded: expanded,
                    onPress: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          find.text(DesktopSidebarDownloadButton.label),
          expanded ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.byIcon(DesktopSidebarDownloadButton.icon));
        await tester.pumpAndSettle();
        expect(opened, 1);
        // Let the hover tooltip's show/dismiss timers run out.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }
}
