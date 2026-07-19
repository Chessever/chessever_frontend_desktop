import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('embedded game grid centers an incomplete final row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: DesktopGameCardsFlow(
              layout: DesktopCardLayout.grid,
              itemCount: 4,
              embedded: true,
              columnCountOverride: 3,
              centerIncompleteRow: true,
              itemBuilder:
                  (context, index) => ColoredBox(
                    key: ValueKey('card-$index'),
                    color: Colors.black,
                  ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.getCenter(find.byKey(const ValueKey('card-3'))).dx, 300);
    expect(tester.takeException(), isNull);
  });
}
