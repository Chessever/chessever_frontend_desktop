import 'package:chessever/desktop/services/shared_books.dart';
import 'package:chessever/desktop/widgets/library/library_folder_context_menu.dart';
import 'package:chessever/repository/api_utils/api_exceptions.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryFolder _folder({
  String id = 'db-1',
  String name = 'Najdorf prep',
  String? parentId,
  bool isSubscribed = false,
  String? shareToken,
}) {
  final now = DateTime.utc(2026, 9, 1);
  return LibraryFolder(
    id: id,
    userId: 'owner-1',
    name: name,
    color: '#0FB4E5',
    icon: 'database',
    orderIndex: 0,
    createdAt: now,
    updatedAt: now,
    parentId: parentId,
    isSubscribed: isSubscribed,
    shareToken: shareToken,
  );
}

Future<List<String>> _menuLabels(
  WidgetTester tester,
  LibraryFolder folder, {
  required bool canShare,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: LibraryFolderContextMenu(
            folder: folder,
            canShare: canShare,
            onAction: (_) {},
            child: const SizedBox(width: 120, height: 40, child: Text('row')),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('row'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
  final labels = <String>[
    for (final label in [
      'Share database...',
      'Export as PGN...',
      'Remove from my library',
      'Rename...',
      'Delete from Cloud',
    ])
      if (find.text(label).evaluate().isNotEmpty) label,
  ];
  return labels;
}

void main() {
  group('libraryFolderIsShareable', () {
    test('only an owned root database is shareable', () {
      expect(libraryFolderIsShareable(_folder(), isDatabase: true), isTrue);
      expect(
        libraryFolderIsShareable(_folder(parentId: 'parent'), isDatabase: true),
        isFalse,
        reason: 'nested databases are not shareable',
      );
      expect(
        libraryFolderIsShareable(_folder(), isDatabase: false),
        isFalse,
        reason: 'folders are not shareable',
      );
      expect(
        libraryFolderIsShareable(_folder(isSubscribed: true), isDatabase: true),
        isFalse,
        reason: 'a subscribed book belongs to someone else',
      );
      expect(
        libraryFolderIsShareable(_folder(id: kTwicBookId), isDatabase: true),
        isFalse,
      );
    });
  });

  test('canonical link shape', () {
    expect(sharedBookUrl('aB3dE5fG7h'), 'https://chessever.com/books/aB3dE5fG7h');
  });

  group('addSharedBookToLibrary', () {
    test('a duplicate subscription means it is already in the library', () async {
      final outcome = await addSharedBookToLibrary(
        folderId: 'db-1',
        findOwnedFolder: (_) async => null,
        subscribe: (_) async => throw GenericApiException('Duplicate entry'),
      );
      expect(outcome, SharedBookAddOutcome.alreadyInLibrary);
    });

    test('a new subscription is added', () async {
      final subscribed = <String>[];
      final outcome = await addSharedBookToLibrary(
        folderId: 'db-1',
        findOwnedFolder: (_) async => null,
        subscribe: (id) async => subscribed.add(id),
      );
      expect(outcome, SharedBookAddOutcome.added);
      expect(subscribed, ['db-1']);
    });

    test('your own book is never subscribed to', () async {
      var subscribeCalls = 0;
      final outcome = await addSharedBookToLibrary(
        folderId: 'db-1',
        findOwnedFolder: (_) async => _folder(),
        subscribe: (_) async => subscribeCalls++,
      );
      expect(outcome, SharedBookAddOutcome.ownBook);
      expect(subscribeCalls, 0);
    });

    test('other failures still surface', () async {
      await expectLater(
        addSharedBookToLibrary(
          folderId: 'db-1',
          findOwnedFolder: (_) async => null,
          subscribe: (_) async => throw NetworkException('offline'),
        ),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('folder menu', () {
    testWidgets('a subscribed book can be exported and removed but not '
        'shared or edited', (tester) async {
      final labels = await _menuLabels(
        tester,
        _folder(isSubscribed: true),
        canShare: true,
      );
      expect(labels, ['Export as PGN...', 'Remove from my library']);
    });

    testWidgets('an owned root database offers sharing', (tester) async {
      final labels = await _menuLabels(tester, _folder(), canShare: true);
      expect(labels, contains('Share database...'));
      expect(labels, contains('Export as PGN...'));
      expect(labels, isNot(contains('Remove from my library')));
    });
  });
}
