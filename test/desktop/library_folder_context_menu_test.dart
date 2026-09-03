import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_folder_context_menu.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  testWidgets('folder context menu pins and unpins the catalog folder', (
    tester,
  ) async {
    bool? requestedPin;
    await _pumpFolderMenu(
      tester,
      isPinned: false,
      onPinnedChanged: (value) => requestedPin = value,
    );

    await _openMenu(tester);
    expect(find.text('Pin folder'), findsOneWidget);
    await tester.tap(find.text('Pin folder'));
    await tester.pumpAndSettle();
    expect(requestedPin, isTrue);

    await _pumpFolderMenu(
      tester,
      isPinned: true,
      onPinnedChanged: (value) => requestedPin = value,
    );
    await _openMenu(tester);
    expect(find.text('Unpin folder'), findsOneWidget);
    await tester.tap(find.text('Unpin folder'));
    await tester.pumpAndSettle();
    expect(requestedPin, isFalse);
  });

  testWidgets('permanent system folder cannot be unpinned', (tester) async {
    await _pumpFolderMenu(
      tester,
      folder: _folder(id: 'liked', name: 'Liked Games'),
      isPinned: true,
      onPinnedChanged: (_) {},
    );

    await _openMenu(tester);
    expect(find.text('Pin folder'), findsNothing);
    expect(find.text('Unpin folder'), findsNothing);
  });
}

Future<void> _pumpFolderMenu(
  WidgetTester tester, {
  LibraryFolder? folder,
  required bool isPinned,
  required ValueChanged<bool> onPinnedChanged,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 48,
            child: LibraryFolderContextMenu(
              folder: folder ?? _folder(id: 'prep', name: 'Opening Prep'),
              isPinned: isPinned,
              onPinnedChanged: onPinnedChanged,
              onAction: (_) {},
              child: const Center(child: Text('Folder row')),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.text('Folder row')),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

LibraryFolder _folder({required String id, required String name}) {
  final now = DateTime(2026);
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: name,
    color: '#0FB4E5',
    icon: 'folder',
    orderIndex: 0,
    createdAt: now,
    updatedAt: now,
  );
}
