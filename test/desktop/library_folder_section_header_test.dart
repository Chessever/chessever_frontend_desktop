import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';

void main() {
  testWidgets(
    'Folders heading toggles its content without hiding sibling sections',
    (tester) async {
      var expanded = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: [
                      const Text('Pinned database'),
                      LibraryCatalogSectionLabel(
                        label: 'Folders',
                        expanded: expanded,
                        onToggle: () => setState(() => expanded = !expanded),
                      ),
                      if (expanded) const Text('Folder contents'),
                      const Text('Standalone database'),
                    ],
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Folders'));
      await tester.pump();
      expect(expanded, isFalse);
      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Folder contents'), findsNothing);
      expect(find.text('Pinned database'), findsOneWidget);
      expect(find.text('Standalone database'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(expanded, isTrue);
      expect(find.text('Folder contents'), findsOneWidget);
    },
  );
}
