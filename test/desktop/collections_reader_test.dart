import 'dart:async';
import 'dart:math';

import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/state/collections_catalog.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'support/collections_fakes.dart';

FavoriteEvent _favorite(
  String eventId, [
  Map<String, dynamic> metadata = const {},
]) => FavoriteEvent(
  id: eventId,
  userId: 'u',
  eventId: eventId,
  eventName: eventId,
  metadata: metadata,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  group('a collection game as a Library row', () {
    test('keeps the published PGN and takes verified facts from the card', () {
      final game = collectionGameFromCard(sampleCard(0), 0)!;

      expect(
        game.pgn,
        sampleCard(0).pgn,
        reason: 'the board replays this text',
      );
      final tags = game.row.chessGame.metadata;
      expect(tags['White'], 'Fischer, Robert James');
      expect(tags['WhiteElo'], '2690');
      expect(tags['WhiteTitle'], 'GM');
      expect(tags['WhiteFederation'], 'USA');
      expect(tags['WhiteFideId'], '2000024');
      expect(tags['BlackFederation'], 'DEN');
      expect(tags['ECO'], 'B90');
      expect(tags['Opening'], 'Sicilian Najdorf');
      // The PGN's own tags stay where it has them.
      expect(tags['Event'], 'Candidates Tournament');
      expect(tags['Date'], '1962.05.03');
      expect(game.row.title, 'Fischer, Robert James vs Larsen, Bent');
      expect(game.row.chessGame.mainline, isNotEmpty);
    });

    test('a placeholder name on the card never replaces the PGN name', () {
      final tags = collectionGameMetadata(
        CollectionGameCard(
          id: 'g',
          white: const CollectionPlayerSide(name: 'White', key: 'name:white'),
          black: const CollectionPlayerSide(name: '?', key: 'name:?'),
        ),
        {'White': 'Carlsen, Magnus', 'Black': 'Caruana, Fabiano'},
      );

      expect(tags['White'], 'Carlsen, Magnus');
      expect(tags['Black'], 'Caruana, Fabiano');
    });

    test('fills what the PGN left unknown', () {
      final tags = collectionGameMetadata(
        CollectionGameCard(
          id: 'g',
          white: const CollectionPlayerSide(name: 'A', key: 'name:a'),
          black: const CollectionPlayerSide(name: 'B', key: 'name:b'),
          result: '0-1',
          event: 'Wijk aan Zee',
          roundTag: '7',
          playedOn: DateTime.utc(2024, 1, 20),
        ),
        {'Date': '????.??.??', 'Result': '*', 'Event': '?'},
      );

      expect(tags['Date'], '2024.01.20');
      expect(tags['Result'], '0-1');
      expect(tags['Event'], 'Wijk aan Zee');
      expect(tags['Round'], '7');
    });

    test('rows keep the collection order under the table\'s # column', () {
      final first = collectionGameFromCard(sampleCard(0), 0)!;
      final second = collectionGameFromCard(sampleCard(1), 1)!;

      expect(first.row.createdAt.isBefore(second.row.createdAt), isTrue);
    });

    test('a card without a readable PGN is left out, not thrown', () {
      expect(
        collectionGameFromCard(
          const CollectionGameCard(
            id: 'g',
            white: CollectionPlayerSide(name: 'A', key: 'name:a'),
            black: CollectionPlayerSide(name: 'B', key: 'name:b'),
          ),
          0,
        ),
        isNull,
      );
    });
  });

  group('who reads a collection', () {
    test('a free collection is never locked', () {
      expect(
        isCollectionLocked(
          freeBook,
          isSubscribed: false,
          subscriptionLoading: false,
        ),
        isFalse,
      );
    });

    test('the server verdict wins over what the app believes', () {
      const lockedForSubscriber = Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.book,
        title: 't',
        contentLocked: true,
      );
      const openForStranger = Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.book,
        title: 't',
        contentLocked: false,
      );

      expect(
        isCollectionLocked(
          lockedForSubscriber,
          isSubscribed: true,
          subscriptionLoading: false,
        ),
        isTrue,
      );
      expect(
        isCollectionLocked(
          openForStranger,
          isSubscribed: false,
          subscriptionLoading: false,
        ),
        isFalse,
      );
    });

    test('before a verdict, a known non-subscriber sees the lock', () {
      expect(
        isCollectionLocked(
          premiumBook,
          isSubscribed: false,
          subscriptionLoading: false,
        ),
        isTrue,
      );
      // No lock flash while the membership is still being read.
      expect(
        isCollectionLocked(
          premiumBook,
          isSubscribed: false,
          subscriptionLoading: true,
        ),
        isFalse,
      );
      expect(
        isCollectionLocked(
          premiumBook,
          isSubscribed: true,
          subscriptionLoading: false,
        ),
        isFalse,
      );
    });

    test(
      'the paywall and a server that predates collections are told apart',
      () {
        const gate = CollectionsRequestException('x', code: 'premium_required');
        const missing = CollectionsRequestException(
          'x',
          code: kCollectionsNotAvailable,
        );

        expect(isCollectionPremiumGate(gate), isTrue);
        expect(isCollectionsNotAvailable(gate), isFalse);
        expect(isCollectionsNotAvailable(missing), isTrue);
        expect(isCollectionPremiumGate(missing), isFalse);
      },
    );
  });

  group('stars and reader id', () {
    test('a star is the same favorites row the phone writes', () {
      expect(collectionFavoriteId('endgames'), 'collection:endgames');
      expect(
        collectionIsStarred([_favorite('collection:endgames')], 'endgames'),
        isTrue,
      );
      expect(
        collectionIsStarred([
          _favorite('legacy', {'kind': 'collection', 'slug': 'endgames'}),
        ], 'endgames'),
        isTrue,
      );
      expect(collectionIsStarred([_favorite('gb_123')], 'endgames'), isFalse);
    });

    test('the reader id is a version 4 UUID', () {
      final id = newCollectionReaderId(Random(7));

      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('starred collections lead the catalog, order otherwise kept', () {
      const books = [freeBook, premiumBook, eventCollection];

      expect(
        pinStarredCollections(
          books,
          (c) => c.slug == 'candidates-1962',
        ).map((c) => c.slug),
        ['candidates-1962', 'my-60-memorable-games', 'zurich-1953'],
      );
      expect(
        identical(pinStarredCollections(books, (_) => false), books),
        isTrue,
      );
    });
  });

  group('catalog paging', () {
    test('pages append, repeats are dropped and the end is reached', () async {
      final asked = <int>[];
      final notifier = CollectionCatalogNotifier<Collection>((offset) async {
        asked.add(offset);
        return offset == 0
            ? (items: const [freeBook, premiumBook], total: 3)
            : (items: const [premiumBook, eventCollection], total: 3);
      }, idOf: (c) => c.id);
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state.items.length, 2);
      expect(notifier.state.hasMore, isTrue);

      await notifier.loadMore();

      expect(asked, [0, 2]);
      expect(notifier.state.items.map((c) => c.id), ['c1', 'c2', 'c3']);
      expect(notifier.state.hasMore, isFalse);

      await notifier.loadMore();
      expect(asked, [0, 2], reason: 'nothing left to ask for');
    });

    test('a failed page keeps the rows and can be asked for again', () async {
      var fail = true;
      final notifier = CollectionCatalogNotifier<Collection>((offset) async {
        if (offset == 0) return (items: const [freeBook], total: 2);
        if (fail) throw StateError('offline');
        return (items: const [premiumBook], total: 2);
      }, idOf: (c) => c.id);
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      await notifier.loadMore();
      expect(notifier.state.items.length, 1);
      expect(notifier.state.moreError, isNotNull);
      expect(notifier.state.error, isNull);

      fail = false;
      await notifier.loadMore();
      expect(notifier.state.items.length, 2);
      expect(notifier.state.moreError, isNull);
    });

    test('a first page that fails is the error, with nothing listed', () async {
      final notifier = CollectionCatalogNotifier<Collection>(
        (_) async => throw StateError('offline'),
        idOf: (c) => c.id,
      );
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state.isLoading, isFalse);
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.items, isEmpty);
    });

    test('no page is asked for while the list is read from the top', () async {
      final asked = <int>[];
      Completer<void>? gate;
      final notifier = CollectionCatalogNotifier<Collection>((offset) async {
        asked.add(offset);
        await gate?.future;
        return (items: const [freeBook, premiumBook], total: 3);
      }, idOf: (c) => c.id);
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.hasMore, isTrue);

      // A refresh keeps the rows on screen, so nothing else says "busy".
      gate = Completer<void>();
      final refresh = notifier.refresh();
      expect(notifier.state.isLoading, isFalse);
      await notifier.loadMore();
      expect(asked, [0, 0], reason: 'the offset would belong to the old list');

      gate.complete();
      await refresh;
      gate = null;
      await notifier.loadMore();
      expect(asked, [0, 0, 2]);
    });

    test(
      'a page that adds nothing ends the list whatever the total says',
      () async {
        final notifier = CollectionCatalogNotifier<Collection>(
          (offset) async => (items: const [freeBook], total: 99),
          idOf: (c) => c.id,
        );
        addTearDown(notifier.dispose);
        await Future<void>.delayed(Duration.zero);

        await notifier.loadMore();

        expect(notifier.state.items.length, 1);
        expect(notifier.state.hasMore, isFalse);
      },
    );
  });

  group('whose answer it is', () {
    test('another account reads the collection again', () async {
      final reader = FakeCollectionsReader();
      final account = StateProvider<String?>((_) => 'account-a');
      final container = ProviderContainer(
        overrides: [
          collectionsReaderProvider.overrideWithValue(reader),
          desktopEntitlementProvider.overrideWith(
            (ref) => DesktopEntitlementSnapshot(accountId: ref.watch(account)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final detail = collectionDetailProvider('zurich-1953');
      final games = collectionGamesProvider('my-60-memorable-games');
      container.listen(detail, (_, _) {});
      container.listen(games, (_, _) {});
      await container.read(detail.future);
      await container.read(games.future);
      expect(reader.detailReads, ['zurich-1953']);
      expect(reader.gameReads, ['my-60-memorable-games']);

      // The next account is entitled; the previous answer is not theirs.
      reader.lockedSlugs = {};
      container.read(account.notifier).state = 'account-b';
      final opened = await container.read(detail.future);
      await container.read(games.future);

      expect(reader.detailReads, ['zurich-1953', 'zurich-1953']);
      expect(reader.gameReads.length, 2);
      expect(opened.contentLocked, isFalse);

      // Signing out reads again too.
      container.read(account.notifier).state = null;
      await container.read(detail.future);
      expect(reader.detailReads.length, 3);
    });
  });

  group('the words for a collection', () {
    test('games are counted in the singular and the plural', () {
      expect(collectionGamesLabel(1), '1 game');
      expect(collectionGamesLabel(0), '0 games');
      expect(collectionGamesLabel(24), '24 games');
    });

    test('the unlock label follows the kind and the count', () {
      Collection book(int games) => Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.book,
        title: 't',
        gameCount: games,
      );
      Collection event(int games) => Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.event,
        title: 't',
        gameCount: games,
      );

      expect(collectionUnlockLabel(book(0)), 'Read this collection');
      expect(
        collectionUnlockLabel(book(1)),
        'Read the game in this collection',
      );
      expect(
        collectionUnlockLabel(book(60)),
        'Read all 60 games in this collection',
      );
      expect(collectionUnlockLabel(event(0)), 'Replay these games');
      expect(collectionUnlockLabel(event(1)), 'Replay the game');
      expect(collectionUnlockLabel(event(12)), 'Replay all 12 games');
    });

    test('the credit is the author, else the annotator', () {
      expect(collectionCredit(freeBook), 'Bobby Fischer');
      expect(
        collectionCredit(
          const Collection(
            id: 'c',
            slug: 's',
            kind: CollectionKind.book,
            title: 't',
            annotator: 'Jan Timman',
          ),
        ),
        'Jan Timman',
      );
      expect(collectionCredit(eventCollection), isNull);
    });

    test('date ranges read as the phone prints them', () {
      expect(
        collectionDateRange(
          DateTime.utc(2025, 10, 2),
          DateTime.utc(2025, 10, 2),
        ),
        'Oct 2, 2025',
      );
      expect(
        collectionDateRange(
          DateTime.utc(2025, 10, 2),
          DateTime.utc(2025, 10, 14),
        ),
        'Oct 2-14, 2025',
      );
      expect(
        collectionDateRange(
          DateTime.utc(2025, 9, 28),
          DateTime.utc(2025, 10, 3),
        ),
        'Sep 28 - Oct 3, 2025',
      );
      expect(collectionDateRange(null, null), isNull);
    });

    test('the caption is the note, else the bound events', () {
      const withNote = Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.book,
        title: 't',
        note: 'Annotated for the match',
      );
      const withEvents = Collection(
        id: 'c',
        slug: 's',
        kind: CollectionKind.book,
        title: 't',
        events: [
          CollectionEventRef(linkId: 'a', title: 'Norway Chess 2025'),
          CollectionEventRef(linkId: 'b', title: 'Tata Steel 2025'),
          CollectionEventRef(linkId: 'c', title: 'Candidates 2024'),
        ],
      );

      expect(collectionCaption(withNote), 'Annotated for the match');
      expect(collectionCaption(withEvents), 'Norway Chess 2025 and 2 more');
      expect(collectionCaption(freeBook), isNull);
    });

    test('prose splits into paragraphs on blank lines', () {
      expect(collectionParagraphs('One.\n\nTwo.\n \nThree.'), [
        'One.',
        'Two.',
        'Three.',
      ]);
      expect(collectionParagraphs(null), isEmpty);
      expect(collectionParagraphs('  '), isEmpty);
    });
  });
}
