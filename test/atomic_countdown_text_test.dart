import 'package:chessever/widgets/atomic_countdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('missing clock source renders placeholder instead of 00:00', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AtomicCountdownText(
            clockCentiseconds: 0,
            lastMoveTime: null,
            isActive: false,
            style: TextStyle(),
          ),
        ),
      ),
    );

    expect(find.text('--:--'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
  });

  testWidgets('explicit zero clock still renders 00:00', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AtomicCountdownText(
            clockSeconds: 0,
            clockCentiseconds: 0,
            lastMoveTime: null,
            isActive: false,
            style: TextStyle(),
          ),
        ),
      ),
    );

    expect(find.text('00:00'), findsOneWidget);
  });
}
