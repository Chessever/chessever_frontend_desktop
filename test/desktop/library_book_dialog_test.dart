import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/widgets/library/library_book_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Publisher implements LibraryBookPublisher {
  LibraryBookPublication publication = const LibraryBookPublication(
    status: 'unpublished',
    metadata: LibraryBookMetadata(title: 'My study'),
  );
  final saves =
      <({LibraryBookMetadata metadata, bool publish, bool refreshGames})>[];
  int unpublishCalls = 0;
  bool fail = false;

  @override
  Future<LibraryBookPublication> load(LibraryFolder folder) async =>
      publication;
  @override
  Future<LibraryBookPublication> save(
    LibraryFolder folder,
    LibraryBookMetadata metadata, {
    bool publish = false,
    bool refreshGames = false,
  }) async {
    saves.add((
      metadata: metadata,
      publish: publish,
      refreshGames: refreshGames,
    ));
    if (fail) {
      throw const LibraryBookPublicationException(
        'Offline. Retry when connected.',
      );
    }
    return publication = LibraryBookPublication(
      status: publish ? 'published' : 'draft',
      metadata: metadata,
      gameCount: 5,
    );
  }

  @override
  Future<LibraryBookPublication> unpublish(LibraryFolder folder) async {
    unpublishCalls++;
    return publication = LibraryBookPublication(
      status: 'archived',
      metadata: publication.metadata,
    );
  }
}

Future<void> _pump(WidgetTester tester, _Publisher publisher) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [libraryBookPublisherProvider.overrideWithValue(publisher)],
      child: MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: Scaffold(
            body: LibraryBookDialog(
              folder: LibraryFolder(
                id: 'folder',
                userId: 'owner',
                name: 'My study',
                color: '#000000',
                icon: 'folder',
                orderIndex: 0,
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

// forui 0.16's input MergeSemantics hits a known debug framework assertion.
// Match local_database_rename_dialog_test: these verify behavior, not semantics.
// Screen-reader validation remains a reviewer/device check.
void main() {
  testWidgets(
    'saving a private draft never publishes it',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher();
      await _pump(tester, publisher);
      await tester.tap(find.text('Save draft'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(publisher.saves.single.publish, isFalse);
      expect(find.text('Draft saved. This book is private.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed publish keeps the entered metadata for retry',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher()..fail = true;
      await _pump(tester, publisher);
      await tester.enterText(find.byType(EditableText).first, 'New book title');
      await tester.tap(find.text('Publish book'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Offline. Retry when connected.'), findsOneWidget);
      expect(find.text('New book title'), findsOneWidget);
      expect(publisher.saves.single.publish, isTrue);
      publisher.fail = false;
      await tester.tap(find.text('Publish book'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Your book is public in Collections.'), findsOneWidget);
      expect(publisher.saves.last.metadata.title, 'New book title');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unpublish requires explicit confirmation and retains metadata',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'published',
              metadata: LibraryBookMetadata(title: 'My book'),
              gameCount: 5,
            );
      await _pump(tester, publisher);
      await tester.tap(find.text('Unpublish'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(publisher.unpublishCalls, 0);
      await tester.tap(find.text('Unpublish book'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(publisher.unpublishCalls, 1);
      expect(find.text('My book'), findsOneWidget);
      expect(find.text('Publish book'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
