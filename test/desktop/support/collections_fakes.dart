import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A favorites list a test controls, with no backend behind it.
class FakeFavoriteEvents extends FavoriteEventsNotifier {
  FakeFavoriteEvents([this.initial = const <FavoriteEvent>[]]);

  final List<FavoriteEvent> initial;
  final List<String> toggled = [];

  @override
  Future<List<FavoriteEvent>> build() async => initial;

  @override
  Future<bool> toggleFavorite({
    required String eventId,
    required String eventName,
    String? timeControl,
    int? maxAvgElo,
    String? dates,
    Map<String, dynamic>? extraMetadata,
  }) async {
    toggled.add(eventId);
    // The first read has to land before a toggle, or it would overwrite it.
    final current = await future;
    final had = current.any((e) => e.eventId == eventId);
    state = AsyncData(
      had
          ? [
            for (final e in current)
              if (e.eventId != eventId) e,
          ]
          : [
            ...current,
            FavoriteEvent(
              id: 'fav-$eventId',
              userId: 'user-1',
              eventId: eventId,
              eventName: eventName,
              metadata: extraMetadata ?? const <String, dynamic>{},
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          ],
    );
    return !had;
  }
}

class FakeSubscription extends SubscriptionNotifier {
  FakeSubscription(super.initialState) : super.stub();

  void set(SubscriptionState next) => state = next;
}

SubscriptionState get freeSubscription => SubscriptionState();
SubscriptionState get premiumSubscription => SubscriptionState(
  isSubscribed: true,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

String samplePgn({
  String white = 'Fischer, Robert James',
  String black = 'Larsen, Bent',
  String result = '1-0',
  String eco = 'B90',
  String date = '1962.05.03',
}) => '''
[Event "Candidates Tournament"]
[Site "Curacao"]
[Date "$date"]
[Round "3"]
[White "$white"]
[Black "$black"]
[Result "$result"]
[ECO "$eco"]

1. e4 {Best by test.} c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 $result
''';

CollectionGameCard sampleCard(
  int index, {
  String white = 'Fischer, Robert James',
  String black = 'Larsen, Bent',
  String result = '1-0',
  String? sectionId,
}) => CollectionGameCard(
  id: 'g$index',
  orderIndex: index,
  sectionId: sectionId,
  white: CollectionPlayerSide(
    name: white,
    key: 'name:${white.toLowerCase()}',
    elo: 2690,
    title: 'GM',
    fed: 'USA',
    fideId: '2000024',
  ),
  black: CollectionPlayerSide(
    name: black,
    key: 'name:${black.toLowerCase()}',
    elo: 2610,
    title: 'GM',
    fed: 'DEN',
  ),
  result: result,
  eco: 'B90',
  opening: 'Sicilian Najdorf',
  playedOn: DateTime.utc(1962, 5, 3),
  pgn: samplePgn(white: white, black: black, result: result),
);

const Collection freeBook = Collection(
  id: 'c1',
  slug: 'my-60-memorable-games',
  kind: CollectionKind.book,
  title: 'My 60 Memorable Games',
  author: 'Bobby Fischer',
  authorId: 'account:0123456789abcdef0123456789abcdef',
  publisher: 'Simon & Schuster',
  publishedYear: 1969,
  gameCount: 3,
  viewCount: 1284,
  starCount: 37,
  access: CollectionAccess.free,
);

const Collection premiumBook = Collection(
  id: 'c2',
  slug: 'zurich-1953',
  kind: CollectionKind.book,
  title: 'Zurich 1953',
  author: 'David Bronstein',
  gameCount: 210,
  viewCount: 902,
  starCount: 21,
);

const Collection eventCollection = Collection(
  id: 'c3',
  slug: 'candidates-1962',
  kind: CollectionKind.event,
  title: 'Candidates Tournament 1962',
  location: 'Curacao',
  gameCount: 2,
  access: CollectionAccess.free,
);

/// A reader over fixed data, recording what was asked of it.
class FakeCollectionsReader implements CollectionsReader {
  FakeCollectionsReader({
    List<Collection>? books,
    this.authors = const [
      CollectionAuthor(
        id: 'account:0123456789abcdef0123456789abcdef',
        name: 'Bobby Fischer',
        bookCount: 1,
        gameCount: 60,
        about: 'Eleventh World Chess Champion.',
      ),
      CollectionAuthor(
        id: 'David Bronstein',
        name: 'David Bronstein',
        bookCount: 1,
      ),
    ],
    this.lockedSlugs = const {'zurich-1953'},
  }) : books = books ?? const [freeBook, premiumBook, eventCollection];

  final List<Collection> books;
  final List<CollectionAuthor> authors;

  /// Slugs the server reports locked for this viewer.
  Set<String> lockedSlugs;

  final List<CollectionSearchQuery> bookQueries = [];
  final List<String> detailReads = [];
  final List<String> gameReads = [];
  final List<String> playerReads = [];
  final List<String> views = [];
  final List<(String, bool)> stars = [];
  Object? booksError;
  Object? gamesError;
  int freshReads = 0;
  final Map<String, int> _holds = {};

  @override
  VoidCallback holdFreshAccess(String slug) {
    _holds[slug] = (_holds[slug] ?? 0) + 1;
    return () => _holds.remove(slug);
  }

  @override
  bool isFreshAccess(String slug) => _holds.containsKey(slug);

  @override
  Future<CollectionsPage> searchBooks(
    CollectionSearchQuery query,
    int offset,
  ) async {
    bookQueries.add(query);
    final error = booksError;
    if (error != null) throw error;
    final matching = [
      for (final book in books)
        if ((query.text.isEmpty ||
                book.title.toLowerCase().contains(query.text.toLowerCase())) &&
            (query.authorId.isEmpty || book.authorId == query.authorId) &&
            (query.author.isEmpty || book.author == query.author))
          book,
    ];
    return CollectionsPage(
      items: offset == 0 ? matching : const [],
      total: matching.length,
      limit: 40,
      offset: offset,
    );
  }

  @override
  Future<({List<CollectionAuthor> items, int total})> searchAuthors(
    CollectionSearchQuery query,
    int offset, {
    int limit = 40,
  }) async => (
    items: offset == 0 ? authors : const <CollectionAuthor>[],
    total: authors.length,
  );

  @override
  Future<Collection> fetchCollection(String slug) async {
    detailReads.add(slug);
    if (isFreshAccess(slug)) freshReads++;
    final base = books.firstWhere((book) => book.slug == slug);
    return Collection(
      id: base.id,
      slug: base.slug,
      kind: base.kind,
      title: base.title,
      author: base.author,
      authorId: base.authorId,
      publisher: base.publisher,
      publishedYear: base.publishedYear,
      location: base.location,
      gameCount: base.gameCount,
      viewCount: base.viewCount,
      starCount: base.starCount,
      access: base.access,
      contentLocked:
          base.access == CollectionAccess.premium
              ? lockedSlugs.contains(slug)
              : null,
      about: 'Sixty games, annotated by the player.\n\nWins and losses alike.',
      foreword: 'Chosen for what they taught me.',
      players: const ['Fischer, Robert James', 'Larsen, Bent', 'Tal, Mikhail'],
      sections:
          base.kind == CollectionKind.book
              ? const [
                CollectionSection(
                  id: 's1',
                  kind: CollectionSectionKind.chapter,
                  label: 'Chapter 1',
                  title: 'Openings',
                  gameCount: 2,
                ),
                CollectionSection(
                  id: 's2',
                  kind: CollectionSectionKind.chapter,
                  label: 'Chapter 2',
                  gameCount: 1,
                ),
              ]
              : const [
                CollectionSection(
                  id: 'r1',
                  kind: CollectionSectionKind.round,
                  label: 'Round 1',
                  gameCount: 1,
                ),
                CollectionSection(
                  id: 'r2',
                  kind: CollectionSectionKind.round,
                  label: 'Round 2',
                  gameCount: 1,
                ),
              ],
      events: const [
        CollectionEventRef(
          linkId: 'l1',
          title: 'Mar del Plata 1960',
          location: 'Argentina',
        ),
      ],
    );
  }

  @override
  Future<List<CollectionGame>> fetchGames(String slug) => searchGames(slug);

  @override
  Future<List<CollectionGame>> searchGames(
    String slug, {
    CollectionSearchQuery search = const CollectionSearchQuery(),
    String? playerKey,
  }) async {
    gameReads.add(slug);
    final error = gamesError;
    if (error != null) throw error;
    if (lockedSlugs.contains(slug)) {
      throw const CollectionsRequestException(
        'Premium required',
        statusCode: 402,
        code: 'premium_required',
      );
    }
    final book = slug != 'candidates-1962';
    final cards = [
      sampleCard(0, sectionId: book ? 's1' : 'r1'),
      sampleCard(
        1,
        white: 'Tal, Mikhail',
        black: 'Fischer, Robert James',
        result: '1/2-1/2',
        sectionId: book ? 's1' : 'r2',
      ),
      if (book)
        sampleCard(
          2,
          white: 'Larsen, Bent',
          black: 'Tal, Mikhail',
          result: '0-1',
          sectionId: 's2',
        ),
    ];
    final matching = [
      for (final card in cards)
        if (search.text.isEmpty ||
            card.white.name.toLowerCase().contains(search.text.toLowerCase()) ||
            card.black.name.toLowerCase().contains(search.text.toLowerCase()))
          card,
    ];
    return [
      for (var i = 0; i < matching.length; i++)
        collectionGameFromCard(matching[i], i)!,
    ];
  }

  @override
  Future<List<CollectionPlayer>> fetchPlayers(String slug) async {
    playerReads.add(slug);
    return const [
      CollectionPlayer(
        key: 'name:fischer, robert james',
        name: 'Fischer, Robert James',
        title: 'GM',
        fed: 'USA',
        bestElo: 2690,
        games: 2,
        wins: 1,
        draws: 1,
      ),
      CollectionPlayer(
        key: 'name:tal, mikhail',
        name: 'Tal, Mikhail',
        title: 'GM',
        fed: 'LAT',
        bestElo: 2705,
        games: 2,
        wins: 1,
        draws: 1,
      ),
      CollectionPlayer(
        key: 'name:larsen, bent',
        name: 'Larsen, Bent',
        title: 'GM',
        fed: 'DEN',
        bestElo: 2610,
        games: 2,
        losses: 2,
      ),
    ];
  }

  @override
  Future<List<Collection>> fetchBooksForEvent(
    CollectionEventAnchors anchors,
  ) async => const [];

  @override
  Future<Map<String, dynamic>> recordView(String slug, String viewerId) async {
    views.add(slug);
    return {'viewCount': 1285, 'starCount': 37};
  }

  @override
  Future<Map<String, dynamic>> recordStar(String slug, bool starred) async {
    stars.add((slug, starred));
    return {'viewCount': 1285, 'starCount': starred ? 38 : 36};
  }
}
