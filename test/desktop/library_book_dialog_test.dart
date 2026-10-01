import 'dart:convert';
import 'dart:typed_data';

import 'package:chessever/desktop/widgets/library/cover_crop_dialog.dart';
import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/widgets/library/library_book_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List? pickedCover;

/// A valid 1×1 PNG, so the instant preview can decode it.
final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Publisher implements LibraryBookPublisher {
  @override
  bool get isConfigured => true;

  @override
  Future<void> unpublishTree(LibraryFolder folder) async {}

  LibraryBookPublication publication = const LibraryBookPublication(
    status: 'unpublished',
    metadata: LibraryBookMetadata(
      title: 'My study',
      author: 'Owner',
      about: 'A chess study',
    ),
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
      // As Gamebase does: a submission waits for review, and any change to
      // a live book returns it to review.
      status: 'draft',
      metadata: metadata,
      bookId: 'book-1',
      gameCount: 5,
    );
  }

  final covers = <Uint8List>[];
  int coverRemovals = 0;
  LibraryBookPublication _withCover(String coverUrl) =>
      publication = LibraryBookPublication(
        status: publication.status,
        bookId: publication.bookId,
        gameCount: publication.gameCount,
        metadata: LibraryBookMetadata(
          title: publication.metadata.title,
          author: publication.metadata.author,
          about: publication.metadata.about,
          coverUrl: coverUrl,
        ),
      );
  @override
  Future<LibraryBookPublication> uploadCover(
    LibraryFolder folder,
    Uint8List image,
  ) async {
    covers.add(image);
    return _withCover('https://media.example.invalid/cover.webp');
  }

  @override
  Future<LibraryBookPublication> removeCover(LibraryFolder folder) async {
    coverRemovals++;
    return _withCover('');
  }

  @override
  Future<LibraryBookPublication> unpublish(LibraryFolder folder) async {
    unpublishCalls++;
    return publication = LibraryBookPublication(
      status: 'draft',
      metadata: publication.metadata,
    );
  }
}

LibraryFolder _folder() => LibraryFolder(
  id: 'folder',
  userId: 'owner',
  name: 'My study',
  color: '#000000',
  icon: 'folder',
  orderIndex: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<void> _pump(
  WidgetTester tester,
  _Publisher publisher, {
  Size size = const Size(1100, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryBookPublisherProvider.overrideWithValue(publisher),
        collectionCoverPickerProvider.overrideWithValue(
          (_) async => pickedCover,
        ),
      ],
      child: MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: Scaffold(body: LibraryBookDialog(folder: _folder())),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// Scroll an action/button into view before tapping it. The two-column dialog
/// puts the form (including the action row) in a scroll view, so a button can
/// sit below the fold on a short window. Target the FButton itself: tapping the
/// bare label Text does not reliably hit the forui button's tap region.
Future<void> _tap(WidgetTester tester, String text) async {
  await tester.pump();
  final target = find.widgetWithText(FButton, text).last;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

// forui 0.16's input MergeSemantics hits a known debug framework assertion.
// Match local_database_rename_dialog_test: these verify behavior, not semantics.
// Screen-reader validation remains a reviewer/device check.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'saving a private draft never publishes it',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher();
      await _pump(tester, publisher);
      await _tap(tester, 'Save draft');
      expect(publisher.saves.single.publish, isFalse);
      expect(publisher.saves.single.refreshGames, isFalse);
      expect(
        find.text('Draft saved. This collection is private.'),
        findsOneWidget,
      );
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
      await _tap(tester, 'Submit for approval');
      expect(find.text('Offline. Retry when connected.'), findsOneWidget);
      expect(find.text('New book title'), findsWidgets);
      expect(publisher.saves.single.publish, isTrue);
      expect(publisher.saves.single.refreshGames, isTrue);
      publisher.fail = false;
      await _tap(tester, 'Submit for approval');
      expect(
        find.text(
          'Submitted for ChessEver approval. It appears in Collections once approved.',
        ),
        findsOneWidget,
      );
      expect(publisher.saves.last.metadata.title, 'New book title');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unpublish confirms and republish refreshes the saved source snapshot',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'published',
              metadata: LibraryBookMetadata(
                title: 'My book',
                author: 'Owner',
                about: 'A chess study',
              ),
              gameCount: 5,
            );
      await _pump(tester, publisher);
      await _tap(tester, 'Unpublish');
      expect(publisher.unpublishCalls, 0);
      await _tap(tester, 'Unpublish book');
      expect(publisher.unpublishCalls, 1);
      expect(
        find.widgetWithText(FButton, 'Submit for approval'),
        findsOneWidget,
      );
      await _tap(tester, 'Submit for approval');
      expect(publisher.saves.single.publish, isTrue);
      expect(publisher.saves.single.refreshGames, isTrue);
      expect(publisher.saves.single.metadata.title, 'My book');
      expect(tester.takeException(), isNull);
    },
  );

  for (final (label, refresh) in [
    ('Submit changes', false),
    ('Submit with latest games', true),
  ]) {
    testWidgets(
      'a live book never saves privately: "$label" resubmits for review',
      semanticsEnabled: false,
      (tester) async {
        final publisher =
            _Publisher()
              ..publication = const LibraryBookPublication(
                status: 'published',
                metadata: LibraryBookMetadata(
                  title: 'My book',
                  author: 'Owner',
                  about: 'A chess study',
                ),
                gameCount: 5,
              );
        await _pump(tester, publisher);
        expect(find.widgetWithText(FButton, 'Save draft'), findsNothing);
        await _tap(tester, label);
        expect(publisher.saves.single.publish, isTrue);
        expect(publisher.saves.single.refreshGames, refresh);
        expect(
          find.text(
            'Submitted for ChessEver approval. It appears in Collections once approved.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'foreword and publisher are not asked for but survive a save',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(
                title: 'My study',
                author: 'Owner',
                about: 'A chess study',
                foreword: 'Kept foreword',
                publisher: 'ChessEver',
              ),
            );
      await _pump(tester, publisher);
      // Field labels for Foreword and Publisher are gone from the editor.
      expect(find.text('Foreword'), findsNothing);
      expect(find.text('Publisher'), findsNothing);
      // Three optional fields: Subtitle, Year, Cover image link.
      expect(find.text('Optional'), findsNWidgets(3));
      await _tap(tester, 'Save draft');
      expect(publisher.saves.single.metadata.foreword, 'Kept foreword');
      expect(publisher.saves.single.metadata.publisher, 'ChessEver');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview follows what is typed', semanticsEnabled: false, (
    tester,
  ) async {
    final publisher = _Publisher();
    await _pump(tester, publisher);
    final preview = find.byKey(const ValueKey('book_preview'));
    // The list row credits the author it loaded.
    expect(
      find.descendant(of: preview, matching: find.text('by Owner')),
      findsOneWidget,
    );
    // Typing the title updates the list row immediately.
    await tester.enterText(find.byType(EditableText).first, 'Endgame Gems');
    await tester.pump();
    expect(
      find.descendant(of: preview, matching: find.text('Endgame Gems')),
      findsWidgets,
    );
    // Editing the subtitle (a page-only field) turns the preview to the page.
    await tester.enterText(find.byType(EditableText).at(1), 'Forty wins');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book_preview_page')), findsOneWidget);
    expect(
      find.descendant(of: preview, matching: find.text('Forty wins')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'author capitalizes every word, stays tidy and only allows letters',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher();
      await _pump(tester, publisher);
      // Order: title, subtitle, author, year, about, cover.
      final titleField = find.byType(TextField).at(0);
      final authorField = find.byType(TextField).at(2);
      expect(
        tester.widget<TextField>(authorField).textCapitalization,
        TextCapitalization.words,
      );
      await tester.enterText(authorField, '  Jason   Statham 42');
      await tester.enterText(titleField, ' Endgame   Gems');
      await tester.pump();
      // Digits are rejected and spacing is collapsed/trimmed.
      expect(
        tester.widget<TextField>(authorField).controller!.text,
        'Jason Statham ',
      );
      expect(
        tester.widget<TextField>(titleField).controller!.text,
        'Endgame Gems',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a saved author pre-fills the next fresh collection',
    semanticsEnabled: false,
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'library_book.last_author': 'Jason Statham',
      });
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'draft',
              metadata: LibraryBookMetadata(title: 'Fresh'),
            );
      await _pump(tester, publisher);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        'Jason Statham',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a successful save remembers the author for next time',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(title: 'My study'),
            );
      await _pump(tester, publisher);
      await tester.enterText(find.byType(TextField).at(2), 'Garry Kasparov');
      await tester.pump();
      await _tap(tester, 'Save draft');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_book.last_author'), 'Garry Kasparov');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsubmitted edits are offered back on the next visit and clear on save',
    semanticsEnabled: false,
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'library_book.draft.folder':
            '{"title":"Half-done study","author":"Owner","about":"A chess study"}',
      });
      final publisher = _Publisher();
      await _pump(tester, publisher);
      await tester.pumpAndSettle();
      expect(find.text('Continue where you left off?'), findsOneWidget);
      await _tap(tester, 'Continue');
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Half-done study',
      );
      await _tap(tester, 'Save draft');
      expect(publisher.saves.single.metadata.title, 'Half-done study');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_book.draft.folder'), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no resume prompt when the stored draft matches the saved details',
    semanticsEnabled: false,
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'library_book.draft.folder':
            '{"title":"My study","author":"Owner","about":"A chess study"}',
      });
      await _pump(tester, _Publisher());
      await tester.pumpAndSettle();
      expect(find.text('Continue where you left off?'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a chosen cover is uploaded, never typed as a link',
    semanticsEnabled: false,
    (tester) async {
      pickedCover = _onePixelPng;
      addTearDown(() => pickedCover = null);
      final publisher = _Publisher();
      await _pump(tester, publisher);
      expect(find.text('Cover image link'), findsNothing);
      await _tap(tester, 'Choose image…');
      // Never saved: details are saved privately first, then the cover.
      expect(publisher.saves.single.publish, isFalse);
      expect(publisher.covers.single, pickedCover);
      expect(find.text('Cover saved.'), findsOneWidget);
      await _tap(tester, 'Save draft');
      expect(
        publisher.saves.last.metadata.coverUrl,
        'https://media.example.invalid/cover.webp',
      );
      await _tap(tester, 'Remove cover');
      expect(publisher.coverRemovals, 1);
      expect(find.widgetWithText(FButton, 'Choose image…'), findsOneWidget);
    },
  );
}
