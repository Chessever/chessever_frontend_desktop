import 'package:chessever/desktop/panes/collections_pane.dart';
import 'package:chessever/desktop/panes/library_pane.dart'
    show libraryReadOnlyGamesFit;
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/collections/collection_catalog_row.dart';
import 'package:chessever/desktop/widgets/collections/collection_reading_views.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/collections_fakes.dart';

/// Wide enough for the Library's games table to lay out all its columns.
const Size _window = Size(2600, 1400);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  required FakeCollectionsReader reader,
  bool premium = true,
  List<Override> overrides = const [],
  Size window = _window,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      collectionsReaderProvider.overrideWithValue(reader),
      favoriteEventsProvider.overrideWith(FakeFavoriteEvents.new),
      subscriptionProvider.overrideWith(
        (ref) =>
            FakeSubscription(premium ? premiumSubscription : freeSubscription),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await _settle(tester);
  return container;
}

/// Spinners never settle, so the tests pump a fixed while instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(finder);
  await _settle(tester);
}

Finder _row(String title) => find.ancestor(
  of: find.textContaining(title, findRichText: true),
  matching: find.byType(CollectionCatalogRow),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the catalog', () {
    testWidgets('lists published collections on the Library row frame', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
      expect(find.byType(LibraryCatalogRowFrame), findsNWidgets(3));
      expect(find.text('COLLECTION'), findsOneWidget);
      expect(find.text('60 games'), findsNothing);
      expect(find.text('3 games'), findsOneWidget);
      expect(
        find.text('Bobby Fischer'),
        findsNWidgets(2),
        reason: 'row + rail',
      );
      // Nothing is selected yet: the preview says what Collections is.
      expect(find.text('About collections'), findsOneWidget);
      expect(reader.gameReads, isEmpty);
    });

    testWidgets('the rail lists the catalog and its authors', (tester) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
      );

      expect(find.text('All collections'), findsOneWidget);
      expect(find.text('CATALOG'), findsOneWidget);
      expect(find.text('AUTHORS'), findsOneWidget);
      expect(find.text('David Bronstein'), findsNWidgets(2));
    });

    testWidgets('selecting a collection previews its games in the table', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(_row('My 60 Memorable Games'));
      await _settle(tester);

      expect(reader.gameReads, ['my-60-memorable-games']);
      expect(find.text('About collections'), findsNothing);
      // The Library's own table: abbreviated names, no "Saved" column.
      expect(find.text('Larsen, B.'), findsWidgets);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('a locked collection shows its contents, never its games', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        premium: false,
      );

      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);

      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(find.text('Chapter 1: Openings'), findsOneWidget);
      expect(find.text('2 games'), findsWidgets);
      expect(
        reader.gameReads,
        isEmpty,
        reason: 'games are not asked for while the collection is locked',
      );
    });

    testWidgets('a subscriber the server still reports locked sees the lock', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);

      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(reader.gameReads, isEmpty);
    });

    testWidgets('search narrows the catalog after a beat', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.enterText(find.byType(TextField).first, 'zurich');
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        reader.bookQueries.where((q) => q.text == 'zurich'),
        isEmpty,
        reason: 'not asked for on every keystroke',
      );
      await _settle(tester);

      expect(reader.bookQueries.last.text, 'zurich');
      expect(find.byType(CollectionCatalogRow), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'nothing like this');
      await _settle(tester);

      expect(find.text('No matches'), findsOneWidget);
      expect(find.text('Try another search or clear filters.'), findsOneWidget);
    });

    testWidgets('an author in the rail narrows the catalog and can be left', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(find.text('Bobby Fischer').first);
      await _settle(tester);

      expect(
        reader.bookQueries.last.authorId,
        'account:0123456789abcdef0123456789abcdef',
      );
      expect(find.byType(CollectionCatalogRow), findsOneWidget);
      expect(find.text('Eleventh World Chess Champion.'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      await tester.tap(find.text('All collections'));
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('an author without a catalog identity is matched by name', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(find.text('David Bronstein').first);
      await _settle(tester);

      expect(reader.bookQueries.last.authorId, isEmpty);
      expect(reader.bookQueries.last.author, 'David Bronstein');
      expect(find.text('No author description available yet.'), findsOneWidget);
    });

    testWidgets('a failed catalog offers a retry that works', (tester) async {
      final reader =
          FakeCollectionsReader()..booksError = StateError('offline');
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text("Couldn't load collections."), findsOneWidget);

      reader.booksError = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
    });

    testWidgets('a bad search explains itself instead of failing', (
      tester,
    ) async {
      final reader =
          FakeCollectionsReader()
            ..booksError = const CollectionsRequestException(
              'Invalid eco',
              statusCode: 400,
            );
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text('Check your search'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a server that predates collections says so, with no retry', (
      tester,
    ) async {
      final reader =
          FakeCollectionsReader()
            ..booksError = const CollectionsRequestException(
              'Collections are not available here yet',
              statusCode: 403,
              code: kCollectionsNotAvailable,
            );
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text('Collections are not available yet'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a double click opens the collection in its own tab', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
      );

      await _doubleTap(tester, _row('My 60 Memorable Games'));

      final tabs = container.read(desktopTabsProvider).tabs;
      final opened = tabs.singleWhere(
        (tab) => tab.kind == TabKind.collectionWorkspace,
      );
      expect(opened.title, 'My 60 Memorable Games');
      expect(
        container.read(collectionWorkspaceArgsByTabIdProvider)[opened.id]?.slug,
        'my-60-memorable-games',
      );

      // Opening it again brings that tab forward instead of a second one.
      await _doubleTap(tester, _row('My 60 Memorable Games'));
      expect(
        container
            .read(desktopTabsProvider)
            .tabs
            .where((tab) => tab.kind == TabKind.collectionWorkspace),
        hasLength(1),
      );
    });
  });

  group('an opened collection', () {
    List<Override> opened(String slug, String title) => [
      collectionWorkspaceArgsByTabIdProvider.overrideWith(
        (ref) => {'t1': CollectionWorkspaceArgs(slug: slug, title: title)},
      ),
    ];

    testWidgets('opens on its games and counts one read', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text('Larsen, B.'), findsWidgets);
      expect(
        find.text('by Bobby Fischer · 3 games · Simon & Schuster · 1969'),
        findsOneWidget,
      );
      expect(find.text('Collection'), findsOneWidget);
      expect(reader.views, ['my-60-memorable-games']);
      // The count the server answered replaces the catalog's.
      expect(find.text('1285'), findsOneWidget);
    });

    testWidgets('an event collection is not counted as a read', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('candidates-1962', 'Candidates Tournament 1962'),
      );

      expect(reader.views, isEmpty);
      expect(find.text('Event collection'), findsOneWidget);
      // Its rounds can be picked from.
      expect(find.text('All games'), findsOneWidget);
    });

    testWidgets('a round narrows the games and All games restores them', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('candidates-1962', 'Candidates Tournament 1962'),
      );
      expect(find.text('2'), findsOneWidget, reason: 'two games are listed');

      await tester.tap(find.text('All games'));
      await _settle(tester);
      await tester.tap(find.text('Round 2').last);
      await _settle(tester);

      expect(
        find.widgetWithText(DesktopToolbarPillButton, 'Round 2'),
        findsOneWidget,
      );
      expect(find.text('2'), findsNothing, reason: 'one game is left');
      expect(find.text('Tal, M.'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(DesktopToolbarPillButton, 'Round 2'),
      );
      await _settle(tester);
      await tester.tap(find.text('All games').last);
      await _settle(tester);

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('About shows the credits, the prose and the bound events', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await tester.tap(find.text('About'));
      await _settle(tester);

      expect(find.text('by Bobby Fischer'), findsOneWidget);
      expect(find.text('Simon & Schuster · 1969'), findsOneWidget);
      expect(find.text('About this collection'), findsOneWidget);
      expect(
        find.text('Sixty games, annotated by the player.'),
        findsOneWidget,
      );
      expect(find.text('Wins and losses alike.'), findsOneWidget);
      expect(find.text('Foreword'), findsOneWidget);
      expect(find.text('Events'), findsOneWidget);
      expect(
        find.textContaining('Mar del Plata 1960', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('3 games · 3 players'), findsOneWidget);
    });

    testWidgets('a player\'s games are one double click away, and back', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await tester.tap(find.text('Players'));
      await _settle(tester);
      expect(find.text('Larsen, Bent'), findsOneWidget);
      expect(find.text('PLAYER'), findsOneWidget);

      await _doubleTap(tester, find.text('Larsen, Bent'));

      // Back on Games, narrowed to the two games Larsen played, with a pill
      // that names him and clears the scope.
      final scope = find.widgetWithText(
        DesktopToolbarPillButton,
        'Larsen, Bent',
      );
      expect(scope, findsOneWidget);
      expect(find.text('Larsen, B.'), findsNWidgets(2));
      expect(
        find.text('3'),
        findsNothing,
        reason: 'only two rows are numbered',
      );

      await tester.tap(scope);
      await _settle(tester);

      expect(scope, findsNothing);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('search inside a collection is answered by the server', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );
      final readsBefore = reader.gameReads.length;

      await tester.enterText(find.byType(TextField).first, 'no such player');
      await _settle(tester);

      expect(reader.gameReads.length, readsBefore + 1);
      expect(find.text('No games match this search.'), findsOneWidget);
    });

    testWidgets('a locked collection opens on About with the way in', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        premium: false,
        overrides: opened('zurich-1953', 'Zurich 1953'),
      );

      expect(find.text('Premium'), findsOneWidget);
      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(find.text('About this collection'), findsOneWidget);

      await tester.tap(find.text('Games'));
      await _settle(tester);
      expect(find.text('Chapter 1: Openings'), findsOneWidget);

      await tester.tap(find.text('Players'));
      await _settle(tester);
      expect(find.text('Chapter 1: Openings'), findsOneWidget);
      expect(reader.gameReads, isEmpty);
      expect(reader.playerReads, isEmpty);
    });

    testWidgets('games the server refuses show the lock, not an error', (
      tester,
    ) async {
      // The detail read came back open, the games read did not.
      final reader = FakeCollectionsReader(lockedSlugs: const {})
        ..gamesError = const CollectionsRequestException(
          'Premium required',
          statusCode: 402,
          code: 'premium_required',
        );
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text('Read all 3 games in this collection'), findsOneWidget);
      expect(find.text("Couldn't load the games."), findsNothing);
    });

    testWidgets('a failed games read can be asked for again', (tester) async {
      final reader =
          FakeCollectionsReader()..gamesError = StateError('offline');
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text("Couldn't load the games."), findsOneWidget);

      reader.gamesError = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);

      expect(find.text('Larsen, B.'), findsWidgets);
    });

    testWidgets('a tab whose collection is gone says so', (tester) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 'missing'),
        reader: FakeCollectionsReader(),
      );

      expect(find.text('This collection is no longer open'), findsOneWidget);
    });

    testWidgets('a game opens on the board as the collection published it', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await _doubleTap(tester, find.text('Larsen, B.').first);

      final boards = container.read(boardTabGameArgsByTabIdProvider);
      expect(boards, hasLength(1));
      final args = boards.values.single;
      expect(args.pgn, sampleCard(0).pgn!.trim());
      expect(args.databaseTitle, 'My 60 Memorable Games');
      // Previous and next walk the three games the table listed.
      expect(args.databaseGames.map((g) => g.id), ['g0', 'g1', 'g2']);
      expect(args.databaseGames.first.pgn, sampleCard(0).pgn!.trim());
      expect(args.accessContext?.isCollectionContent, isTrue);
      // Not the reader's record: Save has nothing to write back to.
      expect(args.librarySaveOrigin, isNull);
    });
  });

  group('under real use', () {
    testWidgets(
      'a starred row moves up and its star still reaches the server',
      (tester) async {
        final reader = FakeCollectionsReader();
        await _pump(
          tester,
          const CollectionsPane(),
          reader: reader,
          overrides: [
            collectionStarAccountProvider.overrideWithValue(() => true),
          ],
        );
        final last = _row('Candidates Tournament 1962');
        expect(
          tester.getTopLeft(last).dy,
          greaterThan(tester.getTopLeft(_row('Zurich 1953')).dy),
        );

        await tester.tap(
          find.descendant(
            of: last,
            matching: find.byIcon(Icons.star_outline_rounded),
          ),
        );
        await _settle(tester);

        // Pinned to the top: the row that was pressed has been rebuilt.
        expect(
          tester.getTopLeft(_row('Candidates Tournament 1962')).dy,
          lessThan(tester.getTopLeft(_row('My 60 Memorable Games')).dy),
        );
        expect(reader.stars, [('candidates-1962', true)]);
      },
    );

    testWidgets('re-reading a locked collection keeps its way in on screen', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        premium: false,
      );
      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);
      expect(find.byType(CollectionLockedContents), findsOneWidget);

      // What confirming a purchase does, read after read.
      container.invalidate(collectionDetailProvider('zurich-1953'));
      await tester.pump();

      expect(
        find.byType(CollectionLockedContents),
        findsOneWidget,
        reason: 'the unlock button started the re-read and must outlive it',
      );
      await _settle(tester);
    });

    testWidgets(
      'the confirm loop holds the collection with nothing on screen',
      (tester) async {
        final reader = FakeCollectionsReader();
        final container = await _pump(
          tester,
          const SizedBox.shrink(),
          reader: reader,
        );
        var looks = 0;
        final confirmed = confirmCollectionPremium(
          container,
          'zurich-1953',
          waits: const [Duration.zero, Duration.zero, Duration.zero],
        );
        // The purchase lands after the second look.
        final watch = container.listen(
          collectionDetailProvider('zurich-1953'),
          (_, next) {
            if (next.hasValue && !next.isLoading && ++looks == 2) {
              reader.lockedSlugs = {};
            }
          },
        );
        addTearDown(watch.close);

        expect(await tester.runAsync(() => confirmed), isTrue);
        expect(reader.detailReads.length, 3);
        expect(container.read(collectionConfirmingProvider), isEmpty);
      },
    );

    testWidgets('a credit opens the author as the catalog knows them', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
      );

      // All an opened collection's credit carries: an id and a name.
      container
          .read(collectionsAuthorRequestProvider.notifier)
          .state = const CollectionAuthor(
        id: 'account:0123456789abcdef0123456789abcdef',
        name: 'Bobby Fischer',
      );
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsOneWidget);
      expect(find.text('1 collection · 60 games'), findsOneWidget);
      expect(find.text('Eleventh World Chess Champion.'), findsOneWidget);
      expect(find.text('0 collections'), findsNothing);
    });

    test('an author is matched by id, then by name, else kept as given', () {
      const known = [
        CollectionAuthor(id: 'account:a', name: 'Bobby Fischer', bookCount: 2),
        CollectionAuthor(id: 'David Bronstein', name: 'David Bronstein'),
      ];
      expect(
        resolveCollectionAuthor(
          const CollectionAuthor(id: 'account:a', name: 'R. Fischer'),
          known,
        )?.bookCount,
        2,
      );
      expect(
        resolveCollectionAuthor(
          const CollectionAuthor(id: 'x', name: ' bobby fischer '),
          known,
        )?.id,
        'account:a',
      );
      const stranger = CollectionAuthor(id: 'x', name: 'Nobody');
      expect(resolveCollectionAuthor(stranger, known), same(stranger));
      expect(resolveCollectionAuthor(null, known), isNull);
    });

    test('a part stands for the chapters under it', () {
      final games = [
        collectionGameFromCard(sampleCard(0, sectionId: 'c1'), 0)!,
        collectionGameFromCard(sampleCard(1, sectionId: 'c2'), 1)!,
        collectionGameFromCard(sampleCard(2, sectionId: 'c3'), 2)!,
      ];
      const part = CollectionSection(
        id: 'p1',
        kind: CollectionSectionKind.part,
        label: 'Part I',
        children: [
          CollectionSection(
            id: 'c1',
            kind: CollectionSectionKind.chapter,
            label: 'Chapter 1',
            gameCount: 1,
            children: [
              CollectionSection(
                id: 'c2',
                kind: CollectionSectionKind.chapter,
                label: 'Chapter 1.1',
                gameCount: 1,
              ),
            ],
          ),
        ],
      );

      expect(
        scopeCollectionGames(games, section: part).map((game) => game.id),
        ['g0', 'g1'],
      );
      expect(
        scopeCollectionGames(
          games,
          section: part.children.single.children.single,
        ).map((game) => game.id),
        ['g1'],
      );
      expect(scopeCollectionGames(games), same(games));
    });

    test(
      'the games table gives up columns as it narrows, never the players',
      () {
        // Collections beside the rail on a 1440 window.
        expect(libraryReadOnlyGamesFit(508).columns, [
          'number',
          'white',
          'result',
          'black',
          'eco',
        ]);
        // An opened collection on the same window has room for the date.
        expect(libraryReadOnlyGamesFit(643).columns, [
          'number',
          'white',
          'result',
          'black',
          'eco',
          'date',
        ]);
        expect(libraryReadOnlyGamesFit(900).columns.length, 9);
        // The split's own minimum.
        final narrowest = libraryReadOnlyGamesFit(361);
        expect(narrowest.columns, ['number', 'white', 'result', 'black']);
        expect(narrowest.playerWidth, greaterThanOrEqualTo(104));
        // The players take up what the columns left.
        expect(libraryReadOnlyGamesFit(508).playerWidth, closeTo(142.5, 0.01));
      },
    );

    testWidgets('the games fit a 1440 window without running off the table', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: const Size(1440, 900),
      );

      await tester.tap(_row('My 60 Memorable Games'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);
      expect(find.text('Event'), findsNothing);
    });
  });

  group('the catalog query', () {
    test('untouched filters send nothing', () {
      final query = collectionQueryFor(text: '  ', filter: GameFilter());

      expect(query.isActive, isFalse);
      expect(query.parameters, isEmpty);
    });

    test('filters map onto the API\'s own names', () {
      final query = collectionQueryFor(
        text: ' carlsen ',
        filter: GameFilter(
          result: GameResultFilter.draw,
          eco: GameEcoFilter.forCode('b90'),
          minYear: 1990,
          maxYear: 2000,
        ),
        now: DateTime(2026),
      );

      expect(query.parameters, {
        'q': 'carlsen',
        'eco': 'B90',
        'result': '1/2-1/2',
        'minYear': 1990,
        'maxYear': 2000,
      });
    });
  });
}
