import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('date group card shows the count badge when counts are final', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: DesktopDateGroupCard(label: 'Today', gameCount: 30),
        ),
      ),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('30 games'), findsOneWidget);
  });

  testWidgets('date group card hides the count badge while still loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: DesktopDateGroupCard(
            label: 'Today',
            gameCount: 30,
            showCount: false,
          ),
        ),
      ),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('30 games'), findsNothing);
    expect(find.text('Loading…'), findsNothing);
    expect(find.text('Loading...'), findsNothing);
  });
}
