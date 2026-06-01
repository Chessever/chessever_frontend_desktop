import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';

void main() {
  testWidgets('supports text-only segmented tabs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopSegmentedTabs<int>(
            selected: 0,
            onChanged: (_) {},
            tabs: const [
              DesktopSegmentedTab(value: 0, label: 'Notation'),
              DesktopSegmentedTab(value: 1, label: 'Tree'),
              DesktopSegmentedTab(value: 2, label: 'Games'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Notation'), findsOneWidget);
    expect(find.text('Tree'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });
}
