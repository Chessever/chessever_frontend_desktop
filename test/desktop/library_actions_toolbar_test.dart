import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/library/library_actions_toolbar.dart';

void main() {
  testWidgets('Import PGN toolbar action opens the local PGN callback', (
    tester,
  ) async {
    var importCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LibraryActionsToolbar(
              onNewFolder: () {},
              onImportPgnFiles: () => importCalls++,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.file_upload_rounded), findsOneWidget);
    expect(find.byIcon(Icons.create_new_folder_rounded), findsOneWidget);
    expect(find.byIcon(Icons.content_paste_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.file_upload_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));

    expect(importCalls, 1);
  });

  testWidgets('compact toolbar shows and invokes the Paste action', (
    tester,
  ) async {
    var pasteCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LibraryActionsToolbar(
              onNewFolder: () {},
              onImportPgnFiles: () {},
              onPastePgn: () => pasteCalls++,
              showLabels: true,
              compactLabels: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Paste'), findsOneWidget);
    expect(find.byIcon(Icons.content_paste_rounded), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Paste')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Paste PGN'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Paste'));
    await tester.pump();

    expect(pasteCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('disabled New folder toolbar action does not fire', (
    tester,
  ) async {
    var importCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LibraryActionsToolbar(
              onNewFolder: null,
              disabledNewFolderTooltip:
                  'Player folders can contain databases only, not subfolders.',
              onImportPgnFiles: () => importCalls++,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.create_new_folder_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.create_new_folder_rounded));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.file_upload_rounded));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));

    expect(importCalls, 1);
  });
}
