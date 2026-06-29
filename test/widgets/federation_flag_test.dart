import 'package:chessever/widgets/federation_flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpFlag(WidgetTester tester, String? federation) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FederationFlag(
              federation: federation,
              width: 22,
              height: 16,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('does not render a placeholder for empty federation', (
    tester,
  ) async {
    await pumpFlag(tester, '');

    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
  });

  testWidgets('does not render a placeholder for FIDE federation values', (
    tester,
  ) async {
    for (final value in const ['FID', 'FIDE', '?']) {
      await pumpFlag(tester, value);

      expect(find.byType(Image), findsNothing);
      expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
    }
  });

  testWidgets('does not render a placeholder for unresolvable federation', (
    tester,
  ) async {
    await pumpFlag(tester, 'Atlantis');

    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
  });
}
