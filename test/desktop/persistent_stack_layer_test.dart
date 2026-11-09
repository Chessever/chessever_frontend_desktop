import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A repaint in the visible tab must re-record that tab's layer only, not
  // the window around it (sidebar, tab bar), which on web and Impeller is a
  // full re-raster.
  testWidgets('each tab paints into its own layer', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PersistentIndexedStack(
          index: 0,
          children: [
            SizedBox(key: ValueKey('a'), child: Text('A')),
            SizedBox(key: ValueKey('b'), child: Text('B')),
          ],
        ),
      ),
    );
    for (final key in const ['a', 'b']) {
      final boundary = find.ancestor(
        of: find.byKey(ValueKey(key), skipOffstage: false),
        matching: find.byType(RepaintBoundary, skipOffstage: false),
      );
      expect(boundary, findsWidgets);
    }
  });
}
