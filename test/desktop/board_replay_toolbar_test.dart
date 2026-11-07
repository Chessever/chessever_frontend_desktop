import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'notation replay controls use forty-four-pixel targets and larger arrows',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              child: explorerNavigationClusterForTesting(
                canGoForward: true,
                onNext: () {},
                onLast: () {},
              ),
            ),
          ),
        ),
      );
      final next = find.byIcon(Icons.chevron_right_rounded);
      final target = tester.widget<Container>(
        find.ancestor(of: next, matching: find.byType(Container)).first,
      );
      expect(target.constraints?.minHeight, 44);
      expect(tester.widget<Icon>(next).size, 26);
    },
  );
}
