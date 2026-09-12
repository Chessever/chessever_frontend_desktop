import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';

void main() {
  testWidgets(
    'board gauge retains a real mate while retargeting and clears on failure',
    (tester) async {
      Widget bar(String fen, double? score, int? mate, bool loading) =>
          MaterialApp(
            home: Center(
              child: DesktopEvalBar(
                width: 24,
                height: 300,
                isFlipped: false,
                evaluation: score,
                mate: mate,
                isEvaluating: loading,
                positionKey: fen,
                retainWhileRetargeting: true,
              ),
            ),
          );
      await tester.pumpWidget(bar('A', 10, 3, false));
      expect(find.text('#3'), findsOneWidget);
      await tester.pumpWidget(bar('B', null, null, true));
      expect(find.text('#3'), findsOneWidget);
      expect(find.text('…'), findsNothing);
      await tester.pumpWidget(bar('B', null, null, false));
      expect(find.text('#3'), findsNothing);
      expect(find.text('…'), findsNothing);
      await tester.pumpWidget(bar('C', null, null, true));
      expect(find.text('…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
