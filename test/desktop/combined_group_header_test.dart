import 'package:chessever/desktop/combined/combined_group_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'source heading folds its own boards and supports keyboard activation',
    (tester) async {
      var expanded = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: [
                      CombinedGroupHeader(
                        label: 'Online Qualifiers | Finals',
                        expanded: expanded,
                        onToggle: () => setState(() => expanded = !expanded),
                      ),
                      if (expanded) const Text('Group A board'),
                      const Text('Group B board'),
                    ],
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Online Qualifiers | Finals'));
      await tester.pump();
      expect(find.text('Group A board'), findsNothing);
      expect(find.text('Group B board'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Group A board'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );
}
