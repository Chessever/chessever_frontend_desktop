import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:chessever/widgets/game_filter/wheel_range_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('game filters show opening-explorer style year range', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                unawaited(
                  showDesktopGameFilterDialog(
                    context: context,
                    currentFilter: GameFilter.defaultFilter(),
                  ),
                );
              },
              child: const Text('Open filters'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open filters'));
    await tester.pumpAndSettle();

    expect(find.text('YEAR RANGE'), findsOneWidget);
    expect(find.byType(WheelRangeFilter), findsOneWidget);
    expect(find.text('any year'), findsOneWidget);
  });
}
