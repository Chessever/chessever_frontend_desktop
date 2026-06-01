import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/library/library_actions_toolbar.dart';

void main() {
  testWidgets('Import PGN toolbar action delegates to local database opener', (
    tester,
  ) async {
    var openedLocalFiles = false;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LibraryActionsToolbar(
              onNewFolder: () {},
              onOpenLocalFiles: () => openedLocalFiles = true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.file_upload_rounded));
    await tester.pump(const Duration(milliseconds: 400));

    expect(openedLocalFiles, isTrue);
  });
}
