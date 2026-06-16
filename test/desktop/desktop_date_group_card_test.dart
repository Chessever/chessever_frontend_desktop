import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('date group card can show non-final loading badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: DesktopDateGroupCard(
            label: 'Today',
            gameCount: 30,
            gameCountLabel: 'Loading…',
          ),
        ),
      ),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('30 games'), findsNothing);
  });
}
