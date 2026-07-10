import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'My Databases board can grow beyond the old 220px cap while preview stays usable',
    (tester) async {
      final controller = ResizableSplitViewController();

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 900,
              height: 720,
              child: buildLibraryMyDatabasesHomeSplit(
                controller: controller,
                storageKey: null,
                board: const SizedBox(key: ValueKey<String>('database-board')),
                preview: const SizedBox(
                  key: ValueKey<String>('database-preview'),
                ),
              ),
            ),
          ),
        ),
      );

      final applied = controller.setSize(0, 300, persist: false);
      await tester.pump();

      expect(applied, closeTo(300, 1));
      expect(
        tester.getSize(find.byKey(const ValueKey('database-board'))).height,
        closeTo(300, 1),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('database-preview'))).height,
        greaterThanOrEqualTo(debugLibraryDatabasePreviewMinHeight),
      );
    },
  );

  test('My Databases tile metrics stay compact and dense', () {
    expect(debugLibraryDatabaseTileWidth, lessThanOrEqualTo(172));
    expect(debugLibraryDatabaseTileHeight, lessThanOrEqualTo(64));
    expect(debugLibraryDatabaseTileSpacing, lessThanOrEqualTo(6));
    expect(debugLibraryDatabaseTileRunSpacing, lessThanOrEqualTo(6));
  });
}
