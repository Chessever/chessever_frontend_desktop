import 'dart:convert';

import 'package:chessever/desktop/widgets/library/cover_crop_dialog.dart';
import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/widgets/library/library_book_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List? pickedCover;
Uint8List? pickedAuthorPhoto;

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

  final authorPhotos = <Uint8List>[];
  int authorPhotoRemovals = 0;
  List<AuthorSuggestion> suggestions = const [];
  final suggestQueries = <String>[];

  LibraryBookPublication _withAuthorPhoto(String url, {AuthorCredit? credit}) =>
      publication = LibraryBookPublication(
        status: publication.status,
        bookId: publication.bookId,
        gameCount: publication.gameCount,
        hadAuthorCreditKey: true,
        metadata: publication.metadata.copyWith(
          authorCredit: credit ?? AuthorCredit.other,
          authorPhotoUrl: url,
        ),
      );

  @override
  Future<LibraryBookPublication> uploadAuthorPhoto(
    LibraryFolder folder,
    Uint8List image,
  ) async {
    authorPhotos.add(image);
    return _withAuthorPhoto('https://media.example.invalid/author.webp');
  }

  @override
  Future<LibraryBookPublication> removeAuthorPhoto(LibraryFolder folder) async {
    authorPhotoRemovals++;
    return _withAuthorPhoto('');
  }

  @override
  Future<List<AuthorSuggestion>> suggestAuthors(String name) async {
    suggestQueries.add(name);
    return suggestions;
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
        authorPhotoPickerProvider.overrideWithValue(
          (_) async => pickedAuthorPhoto,
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

/// Taps a plain-text target (the Me / Someone else segmented control, a
/// suggestion row) that is NOT an FButton. The segments are GestureDetectors
/// over a Text, so hit the Text directly after scrolling it into view.
Future<void> _tapSegment(WidgetTester tester, String text) async {
  await tester.pump();
  final target = find.text(text).last;
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
      await _tap(tester, 'Unpublish collection');
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

  testWidgets(
    'the editor opens on Me and offers the Someone else credit',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher());
      expect(find.text('Me'), findsOneWidget);
      expect(find.text('Someone else'), findsOneWidget);
      // On Me there is no author-photo tile.
      expect(find.text('Author photo'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Me remembers the author but Someone else does not',
    semanticsEnabled: false,
    (tester) async {
      // 1) A Me collection remembers its author.
      final me =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(title: 'My study'),
            );
      await _pump(tester, me);
      await tester.enterText(find.byType(TextField).at(2), 'Garry Kasparov');
      await tester.pump();
      await _tap(tester, 'Save draft');
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_book.last_author'), 'Garry Kasparov');

      // 2) A Someone-else collection does NOT overwrite the remembered name.
      SharedPreferences.setMockInitialValues({
        'library_book.last_author': 'Garry Kasparov',
      });
      final other =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(title: 'Someone study'),
            );
      await _pump(tester, other);
      await _tapSegment(tester, 'Someone else');
      await tester.enterText(find.byType(TextField).at(2), 'Judit Polgar');
      await tester.pump();
      await _tap(tester, 'Save draft');
      // The save credited "other"...
      expect(other.saves.last.metadata.authorCredit, AuthorCredit.other);
      // ...and the remembered Me author is untouched.
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_book.last_author'), 'Garry Kasparov');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new Me book omits authorCredit; Someone else sends "other"',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(title: 'My study'),
            );
      await _pump(tester, publisher);
      await _tap(tester, 'Save draft');
      // New book, never left Me: the key is absent (old servers 400 on it).
      expect(publisher.saves.last.metadata.authorCredit, isNull);
      await _tapSegment(tester, 'Someone else');
      await _tap(tester, 'Save draft');
      expect(publisher.saves.last.metadata.authorCredit, AuthorCredit.other);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping a suggestion fills the exact spelling and notes the match',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..suggestions = const [
              AuthorSuggestion(
                id: 'credit:1',
                name: 'Magnus Carlsen',
                bookCount: 3,
              ),
            ];
      await _pump(tester, publisher);
      await _tapSegment(tester, 'Someone else');
      await tester.enterText(find.byType(TextField).at(2), 'magnus');
      // Past the 300 ms debounce.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Magnus Carlsen'), findsWidgets);
      await tester.tap(find.text('Magnus Carlsen').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        'Magnus Carlsen',
      );
      expect(
        find.text('Matches an existing ChessEver author.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale suggestion response is ignored',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher();
      await _pump(tester, publisher);
      await _tapSegment(tester, 'Someone else');
      // Two quick keystrokes: only the latest query's result may show.
      await tester.enterText(find.byType(TextField).at(2), 'ma');
      await tester.pump(const Duration(milliseconds: 100));
      publisher.suggestions = const [
        AuthorSuggestion(id: 'credit:stale', name: 'Stale Name'),
      ];
      await tester.enterText(find.byType(TextField).at(2), 'magnus');
      publisher.suggestions = const [
        AuthorSuggestion(id: 'credit:fresh', name: 'Magnus Carlsen'),
      ];
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      // Only the final query actually requested (debounce collapses the first).
      expect(publisher.suggestQueries.last, 'magnus');
      expect(find.text('Stale Name'), findsNothing);
      expect(find.text('Magnus Carlsen'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an author photo is uploaded, never typed, and sets Someone else',
    semanticsEnabled: false,
    (tester) async {
      pickedAuthorPhoto = _onePixelPng;
      addTearDown(() => pickedAuthorPhoto = null);
      final publisher = _Publisher();
      await _pump(tester, publisher);
      await _tapSegment(tester, 'Someone else');
      expect(find.text('Author photo'), findsOneWidget);
      await _tap(tester, 'Choose photo…');
      // Never saved: a private draft is saved first, then the photo uploads.
      expect(publisher.saves.single.publish, isFalse);
      expect(publisher.authorPhotos.single, pickedAuthorPhoto);
      expect(find.text('Author photo saved.'), findsOneWidget);
      await _tap(tester, 'Remove photo');
      expect(publisher.authorPhotoRemovals, 1);
      expect(find.widgetWithText(FButton, 'Choose photo…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching an "other" book with a saved photo to Me warns before saving',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'published',
              hadAuthorCreditKey: true,
              gameCount: 5,
              metadata: LibraryBookMetadata(
                title: 'Credited book',
                author: 'Judit Polgar',
                about: 'A chess study',
                authorCredit: AuthorCredit.other,
                authorPhotoUrl: 'https://media.example.invalid/author.webp',
              ),
            );
      await _pump(tester, publisher);
      // Loaded on Someone else; switch to Me.
      await _tapSegment(tester, 'Me');
      expect(
        find.text('The saved author photo will be removed when you save.'),
        findsOneWidget,
      );
      // The book already carried the key, so Me sends "self" to drop the photo.
      await _tap(tester, 'Submit changes');
      expect(publisher.saves.last.metadata.authorCredit, AuthorCredit.self);
      expect(tester.takeException(), isNull);
    },
  );

  // --- Where the collection stands -------------------------------------------

  LibraryBookPublication staged(
    String status, {
    LibraryBookReview review = LibraryBookReview.none,
  }) => LibraryBookPublication(
    status: status,
    bookId: 'book-1',
    gameCount: 5,
    review: review,
    metadata: const LibraryBookMetadata(
      title: 'My book',
      author: 'Owner',
      about: 'A chess study',
    ),
  );

  testWidgets(
    'a plain draft shows no band, the draft actions and where it is on the road',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher()..publication = staged('draft'));
      expect(find.text('Publish collection'), findsOneWidget);
      expect(find.byKey(const ValueKey('book_stage_inReview')), findsNothing);
      expect(find.byKey(const ValueKey('book_stage_track')), findsOneWidget);
      for (final label in [
        'Private draft',
        'In review',
        'Live in Collections',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.widgetWithText(FButton, 'Save draft'), findsOneWidget);
      expect(
        find.widgetWithText(FButton, 'Submit for approval'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FButton, 'Withdraw from review'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a submission says it is in review and can be withdrawn without losing edits',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = staged(
              'draft',
              review: LibraryBookReview(
                state: LibraryBookReviewState.pending,
                submittedAt: DateTime(2026, 10, 2),
              ),
            );
      await _pump(tester, publisher);
      expect(find.text('Collection in review'), findsOneWidget);
      expect(find.byKey(const ValueKey('book_stage_inReview')), findsOneWidget);
      // A draft is not offered while staff are looking at it.
      expect(find.widgetWithText(FButton, 'Save draft'), findsNothing);
      expect(find.widgetWithText(FButton, 'Submit for approval'), findsNothing);
      expect(find.widgetWithText(FButton, 'Submit changes'), findsOneWidget);

      // Something typed and not yet saved survives the withdrawal.
      await tester.enterText(find.byType(TextField).at(1), 'Unsaved subtitle');
      await tester.pump();
      await _tap(tester, 'Withdraw from review');
      expect(publisher.unpublishCalls, 1);
      expect(
        find.text('Withdrawn from review. This collection is a private draft.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'Unsaved subtitle',
      );
      // Back to a plain draft.
      expect(find.text('Publish collection'), findsOneWidget);
      expect(
        find.widgetWithText(FButton, 'Submit for approval'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a submission sent back shows what ChessEver asked for and resubmits',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = staged(
              'draft',
              review: LibraryBookReview(
                state: LibraryBookReviewState.changesRequested,
                note: 'Replace the cover, then resubmit.',
                decidedAt: DateTime(2026, 10, 3),
              ),
            );
      await _pump(tester, publisher);
      expect(find.text('Changes requested'), findsWidgets);
      expect(
        find.byKey(const ValueKey('book_stage_changesRequested')),
        findsOneWidget,
      );
      expect(find.text('Replace the cover, then resubmit.'), findsOneWidget);
      await _tap(tester, 'Resubmit for approval');
      expect(publisher.saves.single.publish, isTrue);
      expect(publisher.saves.single.refreshGames, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a live collection warns that a change takes it out of Collections',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher()..publication = staged('published'));
      expect(find.text('Edit collection'), findsOneWidget);
      expect(find.byKey(const ValueKey('book_stage_live')), findsOneWidget);
      expect(
        find.textContaining(
          'takes it out of Collections until ChessEver approves',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // Nothing to tick off: it already met the requirements once.
      expect(find.byKey(const ValueKey('book_requirements')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unpublishing keeps what was typed and not yet saved',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher()..publication = staged('published');
      await _pump(tester, publisher);
      await tester.enterText(find.byType(TextField).at(1), 'Unsaved subtitle');
      await tester.pump();
      await _tap(tester, 'Unpublish');
      await _tap(tester, 'Unpublish collection');
      expect(publisher.unpublishCalls, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'Unsaved subtitle',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a collection ChessEver took down offers nothing to change',
    semanticsEnabled: false,
    (tester) async {
      final publisher = _Publisher()..publication = staged('archived');
      await _pump(tester, publisher);
      expect(find.text('Collection taken down'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('book_stage_takenDown')),
        findsOneWidget,
      );
      for (final label in [
        'Save draft',
        'Submit for approval',
        'Submit changes',
        'Unpublish',
      ]) {
        expect(find.widgetWithText(FButton, label), findsNothing);
      }
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        isFalse,
      );
      expect(publisher.saves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  // --- What a submission still needs ------------------------------------------

  testWidgets(
    'the checklist follows the form and takes the cursor to what is missing',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..publication = const LibraryBookPublication(
              status: 'unpublished',
              metadata: LibraryBookMetadata(title: 'My study'),
            );
      await _pump(tester, publisher);
      final list = find.byKey(const ValueKey('book_requirements'));
      expect(list, findsOneWidget);
      // Title is there; author credit and description are not.
      expect(find.text('2 details left'), findsOneWidget);

      // Choosing a missing item puts the cursor in its field.
      await tester.ensureVisible(
        find.descendant(of: list, matching: find.text('Description')),
      );
      await tester.tap(
        find.descendant(of: list, matching: find.text('Description')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byType(TextField).at(4))
            .focusNode!
            .hasFocus,
        isTrue,
      );

      await tester.enterText(find.byType(TextField).at(4), 'Annotated wins.');
      await tester.pump();
      expect(find.text('1 detail left'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(2), 'Garry Kasparov');
      await tester.pump();
      expect(find.text('Ready to submit'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // --- Author credit, as the phone app behaves --------------------------------

  testWidgets(
    'crediting someone else clears a name that was only pre-filled',
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
      String author() =>
          tester
              .widget<TextField>(find.byType(TextField).at(2))
              .controller!
              .text;
      expect(author(), 'Jason Statham');

      // The publisher's own name must not become someone else's credit.
      await _tapSegment(tester, 'Someone else');
      expect(author(), isEmpty);

      // Going back to Me fills it in again.
      await _tapSegment(tester, 'Me');
      await tester.pumpAndSettle();
      expect(author(), 'Jason Statham');

      // A name the user typed is theirs to keep across the switch.
      await tester.enterText(find.byType(TextField).at(2), 'Judit Polgar');
      await tester.pump();
      await _tapSegment(tester, 'Someone else');
      expect(author(), 'Judit Polgar');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'suggestions give way to the match, and the match follows the name',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..suggestions = const [
              AuthorSuggestion(
                id: 'credit:1',
                name: 'Magnus Carlsen',
                bookCount: 3,
              ),
            ];
      await _pump(tester, publisher);
      await _tapSegment(tester, 'Someone else');
      await tester.enterText(find.byType(TextField).at(2), 'magnus');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Already on ChessEver'), findsOneWidget);
      expect(find.text('3 collections'), findsOneWidget);

      await tester.tap(find.text('Magnus Carlsen').last);
      await tester.pumpAndSettle();
      // Matched: the list has done its job and steps aside.
      expect(find.text('Already on ChessEver'), findsNothing);
      expect(
        find.text('Matches an existing ChessEver author.'),
        findsOneWidget,
      );

      // Typing on is no longer that author: the match goes at once, without
      // waiting for the next lookup.
      await tester.enterText(find.byType(TextField).at(2), 'Magnus Carlsen Jr');
      await tester.pump();
      expect(find.text('Matches an existing ChessEver author.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a draft that only changed who is credited is still offered back',
    semanticsEnabled: false,
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'library_book.draft.folder': jsonEncode({
          'title': 'My study',
          'subtitle': '',
          'author': 'Owner',
          'year': '',
          'about': 'A chess study',
          'authorCredit': 'other',
        }),
      });
      await _pump(tester, _Publisher());
      expect(find.text('Continue where you left off?'), findsOneWidget);
      await _tap(tester, 'Continue');
      // Someone else is chosen again: its photo picker is back.
      expect(find.text('Author photo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // --- The preview is the real Collections row --------------------------------

  testWidgets(
    'the list preview is the Collections row: cover frame, credit, tally',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher()..publication = staged('draft'));
      final row = find.byKey(const ValueKey('book_preview_list'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('My book')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('by Owner')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('5 games')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.star_border_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the two-way choices are keyboard reachable: Enter chooses',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher()..publication = staged('draft'));
      // Focus the "Collection page" segment and choose it from the keyboard.
      final segment = find.ancestor(
        of: find.text('Collection page'),
        matching: find.byType(FocusableActionDetector),
      );
      Focus.of(tester.element(find.text('Collection page'))).requestFocus();
      await tester.pump();
      expect(segment, findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book_preview_page')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // --- As the app really opens it -------------------------------------------

  /// Opens the dialog the way the app does: straight over the navigator, with
  /// no Scaffold or Material beneath it, at a real window size.
  Future<void> open(
    WidgetTester tester,
    _Publisher publisher, {
    Size size = const Size(1280, 860),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryBookPublisherProvider.overrideWithValue(publisher),
          collectionCoverPickerProvider.overrideWithValue((_) async => null),
          authorPhotoPickerProvider.overrideWithValue((_) async => null),
        ],
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => Center(
                  child: GestureDetector(
                    onTap:
                        () => showLibraryBookDialog(context, folder: _folder()),
                    child: const Text('open'),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'suggestions work in the real dialog, which has no Material beneath it',
    semanticsEnabled: false,
    (tester) async {
      final publisher =
          _Publisher()
            ..suggestions = const [
              AuthorSuggestion(
                id: 'credit:1',
                name: 'Magnus Carlsen',
                bookCount: 3,
              ),
            ];
      await open(tester, publisher);
      await _tapSegment(tester, 'Someone else');
      await tester.enterText(find.byType(TextField).at(2), 'magnus');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final row = find.byKey(
        const ValueKey('book_author_suggestion_Magnus Carlsen'),
      );
      expect(row, findsOneWidget);
      // Hovering and pressing a row must not need an ink surface.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        'Magnus Carlsen',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in const [Size(1024, 720), Size(1280, 860)]) {
    testWidgets(
      'every stage lays out side by side at ${size.width.toInt()}×${size.height.toInt()}',
      semanticsEnabled: false,
      (tester) async {
        final stages = [
          staged('draft'),
          staged(
            'draft',
            review: LibraryBookReview(
              state: LibraryBookReviewState.pending,
              submittedAt: DateTime(2026, 10, 2),
            ),
          ),
          // The longest note staff can send.
          staged(
            'draft',
            review: LibraryBookReview(
              state: LibraryBookReviewState.changesRequested,
              note: List.filled(125, 'Replace').join(' '),
              decidedAt: DateTime(2026, 10, 3),
            ),
          ),
          staged('published'),
          staged('archived'),
        ];
        for (final publication in stages) {
          await open(
            tester,
            _Publisher()..publication = publication,
            size: size,
          );
          // Form and preview share the row: the preview is not stacked above.
          final preview = tester.getTopLeft(
            find.byKey(const ValueKey('book_preview')),
          );
          final title = tester.getTopLeft(find.byType(TextField).first);
          expect(
            preview.dx,
            greaterThan(title.dx),
            reason: publication.stage.name,
          );
          // The form keeps a usable height under the longest note.
          expect(
            tester.getSize(find.byType(Form)).height,
            greaterThan(200),
            reason: publication.stage.name,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: publication.stage.name,
          );
          Navigator.of(tester.element(find.byType(LibraryBookDialog))).pop();
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets(
    'putting the cursor in a field is not an edit',
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
      // Click into the pre-filled author and move the caret, typing nothing.
      await tester.ensureVisible(find.byType(TextField).at(2));
      await tester.tap(find.byType(TextField).at(2));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 700));
      // Still only pre-filled: crediting someone else clears it, and no
      // lookup was made for the publisher's own name.
      await _tapSegment(tester, 'Someone else');
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        isEmpty,
      );
      expect(publisher.suggestQueries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'looking without typing leaves no draft behind',
    semanticsEnabled: false,
    (tester) async {
      await _pump(tester, _Publisher());
      for (final index in [0, 1, 4]) {
        await tester.ensureVisible(find.byType(TextField).at(index));
        await tester.tap(find.byType(TextField).at(index));
        await tester.pump();
      }
      // Past the stash debounce, then close the dialog.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_book.draft.folder'), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
