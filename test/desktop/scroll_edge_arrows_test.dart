import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';

Widget _strip(int count) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 300,
      height: 60,
      child: ScrollEdgeArrows(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < count; i++)
              SizedBox(width: 100, child: Text('item $i')),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('no arrows when everything fits', (tester) async {
    await tester.pumpWidget(_strip(2));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.byType(Scrollbar), findsNothing);
  });

  testWidgets('an arrow shows where there is more and scrolls there', (
    tester,
  ) async {
    await tester.pumpWidget(_strip(10));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, closeTo(240, 0.5));
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });
}
