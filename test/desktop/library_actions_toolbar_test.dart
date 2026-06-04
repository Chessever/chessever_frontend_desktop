import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/library/library_actions_toolbar.dart';

void main() {
  testWidgets('Import PGN toolbar action is labeled as PGN import', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: LibraryActionsToolbar(onNewFolder: () {})),
        ),
      ),
    );

    expect(find.byIcon(Icons.file_upload_rounded), findsOneWidget);
    expect(find.byIcon(Icons.create_new_folder_rounded), findsOneWidget);
    expect(find.byIcon(Icons.content_paste_go_rounded), findsOneWidget);
  });
}
