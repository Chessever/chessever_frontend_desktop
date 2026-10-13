/// Reading published collections on desktop.
///
/// The phone app's Collections feature, on the same Gamebase endpoints. The
/// one desktop-specific step is the shape of a game: the Library's games
/// table and board preview draw [SavedAnalysis] rows, so a collection's game
/// becomes one (never stored, never writable) and Collections reuses those
/// widgets unchanged.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/gamebase/collections/collection_search_query.dart';
import 'package:chessever/repository/gamebase/collections/collections_models.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

export 'package:chessever/repository/gamebase/collections/collection_search_query.dart';
export 'package:chessever/repository/gamebase/collections/collections_models.dart';

/// A collection's game: how the API lists it, the Library row that draws it,
/// and its PGN exactly as published (comments, NAGs, variations and clocks),
/// which is what the board replays.
@immutable
class CollectionGame {
  const CollectionGame({
    required this.card,
    required this.row,
    required this.pgn,
  });

  final CollectionGameCard card;
  final SavedAnalysis row;
  final String pgn;

  String get id => card.id;
  String? get sectionId => card.sectionId;
}

/// Row timestamps count up from here by one second per game, so the
/// Library table's "#" order is the order the collection lists its games in.
final DateTime _rowEpoch = DateTime.utc(2000);

final RegExp _placeholderName = RegExp(
  r'^(white|black|\?|nn|n\.\s?n\.?)?$',
  caseSensitive: false,
);

String _pgnDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.'
    '${day.day.toString().padLeft(2, '0')}';

/// The PGN's own tags, completed by what the structured card knows better:
/// verified names, titles, ratings, federations and FIDE ids, the opening and
/// the day. The table and the board header read these tags.
@visibleForTesting
Map<String, dynamic> collectionGameMetadata(
  CollectionGameCard card,
  Map<String, dynamic> parsed,
) {
  final tags = Map<String, dynamic>.of(parsed);
  String tag(String key) => (tags[key]?.toString() ?? '').trim();
  void fill(String key, String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return;
    final current = tag(key);
    if (current.isEmpty || current == '?') tags[key] = text;
  }

  void side(String color, CollectionPlayerSide data) {
    if (!_placeholderName.hasMatch(data.name.trim())) {
      tags[color] = data.name.trim();
    }
    final elo = data.elo;
    if (elo != null && elo > 0) tags['${color}Elo'] = '$elo';
    if (data.title?.trim().isNotEmpty ?? false) {
      tags['${color}Title'] = data.title!.trim();
    }
    if (data.fed?.trim().isNotEmpty ?? false) {
      tags['${color}Federation'] = data.fed!.trim();
    }
    if (data.fideId?.trim().isNotEmpty ?? false) {
      tags['${color}FideId'] = data.fideId!.trim();
    }
  }

  side('White', card.white);
  side('Black', card.black);
  if (card.eco?.trim().isNotEmpty ?? false) tags['ECO'] = card.eco!.trim();
  fill('Opening', card.opening);
  fill('Event', card.event);
  fill('Site', card.site);
  fill('Round', card.roundTag);
  final day = card.playedOn;
  if (day != null) {
    final current = tag('Date');
    if (current.isEmpty || current.startsWith('?')) {
      tags['Date'] = _pgnDate(day);
    }
  }
  final result = tag('Result');
  if ((result.isEmpty || result == '*') && card.result.trim().isNotEmpty) {
    tags['Result'] = card.result.trim();
  }
  return tags;
}

/// [card] as a Library row, [index] being its place in the collection. Null
/// when the card has no PGN or the PGN cannot be read at all.
CollectionGame? collectionGameFromCard(CollectionGameCard card, int index) {
  final pgn = card.pgn;
  if (card.id.isEmpty || pgn == null || pgn.trim().isEmpty) return null;
  try {
    final parsed = ChessGame.fromPgn(card.id, pgn);
    final game = parsed.copyWith(
      metadata: collectionGameMetadata(card, parsed.metadata),
    );
    final white = (game.metadata['White']?.toString() ?? '').trim();
    final black = (game.metadata['Black']?.toString() ?? '').trim();
    final at = _rowEpoch.add(Duration(seconds: index));
    return CollectionGame(
      card: card,
      pgn: pgn,
      row: SavedAnalysis(
        id: card.id,
        userId: '',
        title:
            '${white.isEmpty ? 'White' : white} vs '
            '${black.isEmpty ? 'Black' : black}',
        chessGame: game,
        analysisState: const <String, dynamic>{},
        variationComments: const <String, String>{},
        lastViewedPosition: -1,
        tags: const <String>[],
        isFavorite: false,
        createdAt: at,
        updatedAt: at,
      ),
    );
  } catch (e) {
    debugPrint('[Collections] game ${card.id} unreadable: $e');
    return null;
  }
}

/// The day [game] was played: the card's, else the PGN's own `Date` tag
/// with an unknown month or day read as its first.
DateTime? _collectionGameDay(CollectionGame game) {
  final known = game.card.playedOn ?? game.card.playedAt?.toUtc();
  if (known != null) return DateTime(known.year, known.month, known.day);
  final parts =
      (game.row.chessGame.metadata['Date']?.toString() ?? '').trim().split('.');
  final year = int.tryParse(parts.first);
  if (year == null) return null;
  int part(int index) =>
      (index < parts.length ? int.tryParse(parts[index]) : null) ?? 1;
  return DateTime(year, part(1), part(2));
}

/// A book's games with the most recently played first. A book lists what its
/// author filed, in filing order; the reader wants the latest game on top.
/// Games on one day keep the later start first, then the book's own order.
/// A game with no known day goes last. Rows are renumbered, so the Library
/// table's "#" order is this order.
List<CollectionGame> collectionGamesNewestFirst(List<CollectionGame> games) {
  if (games.length < 2) return games;
  final indexed = [
    for (var i = 0; i < games.length; i++)
      (i, _collectionGameDay(games[i]), games[i]),
  ];
  indexed.sort((a, b) {
    final dayA = a.$2;
    final dayB = b.$2;
    if (dayA == null || dayB == null) {
      if (dayA != null) return -1;
      if (dayB != null) return 1;
      return a.$1.compareTo(b.$1);
    }
    final byDay = dayB.compareTo(dayA);
    if (byDay != 0) return byDay;
    final atA = a.$3.card.playedAt;
    final atB = b.$3.card.playedAt;
    if (atA != null && atB != null) {
      final byStart = atB.compareTo(atA);
      if (byStart != 0) return byStart;
    }
    return a.$1.compareTo(b.$1);
  });
  return [
    for (var i = 0; i < indexed.length; i++)
      () {
        final game = indexed[i].$3;
        final at = _rowEpoch.add(Duration(seconds: i));
        return CollectionGame(
          card: game.card,
          pgn: game.pgn,
          row: game.row.copyWith(createdAt: at, updatedAt: at),
        );
      }(),
  ];
}

/// Reads published collections. Everyone may read the catalog, the covers
/// and the tables of contents; a Premium collection's games and players are
/// answered only for an entitled account (the proxy forwards this account's
/// token). Nothing here writes a collection.
class CollectionsReader {
  CollectionsReader(this._api);

  final GamebaseRepository _api;

  /// The catalog endpoints' page size, as the phone app asks for.
  static const int catalogPageSize = 40;

  /// The games endpoint's page cap.
  static const int gamesPageSize = 200;

  /// Pages fetched at once after the first one tells the total.
  static const int _parallelPages = 4;

  /// A ceiling on pages, so a server that keeps reporting more never loops.
  static const int _maxPages = 100;

  /// Games turned into rows before the UI gets a frame.
  static const int _rowsPerSlice = 12;

  /// Slugs whose reads ask the server to judge the viewer's Premium anew,
  /// with how many holds each has (see [holdFreshAccess]).
  final Map<String, int> _freshHolds = {};

  /// Makes [slug]'s reads skip the "not Premium" answer the server keeps for
  /// a few seconds, until the returned release runs (once). The Premium
  /// confirm holds it around each re-check, so a purchase opens the
  /// collection on the first read that can see it.
  VoidCallback holdFreshAccess(String slug) {
    _freshHolds[slug] = (_freshHolds[slug] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final left = (_freshHolds[slug] ?? 1) - 1;
      if (left > 0) {
        _freshHolds[slug] = left;
      } else {
        _freshHolds.remove(slug);
      }
    };
  }

  @visibleForTesting
  bool isFreshAccess(String slug) => _freshHolds.containsKey(slug);

  Future<CollectionsPage> searchBooks(
    CollectionSearchQuery query,
    int offset,
  ) => _api.searchCollectionBooks(
    search: query,
    offset: offset,
    limit: catalogPageSize,
  );

  Future<({List<CollectionAuthor> items, int total})> searchAuthors(
    CollectionSearchQuery query,
    int offset, {
    int limit = catalogPageSize,
  }) =>
      _api.searchCollectionAuthors(search: query, offset: offset, limit: limit);

  /// One collection with its About text, section tree, bound events and, for
  /// a Premium one, the server's verdict for this viewer.
  Future<Collection> fetchCollection(String slug) =>
      _api.getCollection(slug, fresh: isFreshAccess(slug));

  /// All of a collection's games with their PGN, in the API's order. A
  /// Premium collection the viewer is not entitled to throws a
  /// [CollectionsRequestException] whose
  /// [CollectionsRequestException.isPremiumGate] is true.
  Future<List<CollectionGame>> fetchGames(String slug) => searchGames(slug);

  /// The games of [slug] a search (and optionally one player) matches, in
  /// the server's order.
  Future<List<CollectionGame>> searchGames(
    String slug, {
    CollectionSearchQuery search = const CollectionSearchQuery(),
    String? playerKey,
  }) async {
    final fresh = isFreshAccess(slug);
    final cards = await _allPages<CollectionGameCard>(
      pageSize: gamesPageSize,
      fetch: (offset) async {
        final page = await _api.getCollectionGames(
          slug,
          search: search,
          playerKey: playerKey,
          includePgn: true,
          limit: gamesPageSize,
          offset: offset,
          fresh: fresh,
        );
        return (page.items, page.total);
      },
    );
    return _rows(cards);
  }

  /// Everyone in a collection, most games first. Gated like [fetchGames].
  Future<List<CollectionPlayer>> fetchPlayers(String slug) =>
      _api.getCollectionPlayers(slug, fresh: isFreshAccess(slug));

  /// The published books bound to the event [anchors] name, each carrying
  /// the team's note for the binding.
  Future<List<Collection>> fetchBooksForEvent(CollectionEventAnchors anchors) {
    if (anchors.isEmpty) return Future.value(const []);
    return _api.getCollectionsForEvent(anchors);
  }

  /// Counts one read of [slug] for the anonymous reader [viewerId].
  Future<Map<String, dynamic>> recordView(String slug, String viewerId) =>
      _api.recordCollectionEngagement(slug, {'viewerId': viewerId});

  /// Sets this account's star on [slug].
  Future<Map<String, dynamic>> recordStar(String slug, bool starred) =>
      _api.recordCollectionEngagement(slug, {'starred': starred}, star: true);

  /// Parsing a PGN is synchronous work; a few hundred annotated games in one
  /// go would hold a frame for a long time, so the UI gets a turn between
  /// slices.
  static Future<List<CollectionGame>> _rows(
    List<CollectionGameCard> cards,
  ) async {
    final seen = <String>{};
    final rows = <CollectionGame>[];
    var sinceYield = 0;
    for (final card in cards) {
      if (!seen.add(card.id)) continue;
      final game = collectionGameFromCard(card, rows.length);
      if (game != null) rows.add(game);
      if (++sinceYield >= _rowsPerSlice) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return rows;
  }

  /// Reads the first page, then the rest (a few at a time) until the total
  /// the first page reported.
  static Future<List<T>> _allPages<T>({
    required int pageSize,
    required Future<(List<T> items, int total)> Function(int offset) fetch,
  }) async {
    final (first, total) = await fetch(0);
    if (first.isEmpty || first.length >= total) return first;
    // Step by what a page actually returned, in case the server caps lower.
    final step = first.length;
    final offsets = <int>[
      for (var o = step; o < total && o ~/ step < _maxPages; o += step) o,
    ];
    final pages = <int, List<T>>{0: first};
    for (var i = 0; i < offsets.length; i += _parallelPages) {
      final batch = offsets.skip(i).take(_parallelPages).toList();
      final results = await Future.wait([
        for (final o in batch) fetch(o).then((r) => r.$1),
      ]);
      for (var j = 0; j < batch.length; j++) {
        pages[batch[j]] = results[j];
      }
      if (results.any((r) => r.isEmpty)) break;
    }
    final keys = pages.keys.toList()..sort();
    return [for (final k in keys) ...pages[k]!];
  }
}

final collectionsReaderProvider = Provider<CollectionsReader>(
  (ref) => CollectionsReader(ref.watch(gamebaseRepositoryProvider)),
);

/// The account these reads are made for. What is locked depends on who
/// asks, so a sign-in, a sign-out or a switch of account reads again instead
/// of showing the previous account's answer.
final _collectionViewerProvider = Provider<String?>(
  (ref) => ref.watch(
    desktopEntitlementProvider.select((entitlement) => entitlement.accountId),
  ),
);

/// One collection by slug, with its About text and section tree.
final collectionDetailProvider = FutureProvider.autoDispose
    .family<Collection, String>((ref, slug) {
      ref.watch(_collectionViewerProvider);
      return ref.watch(collectionsReaderProvider).fetchCollection(slug);
    });

/// One collection's games (with PGN), by slug.
final collectionGamesProvider = FutureProvider.autoDispose
    .family<List<CollectionGame>, String>((ref, slug) {
      ref.watch(_collectionViewerProvider);
      return ref.watch(collectionsReaderProvider).fetchGames(slug);
    });

/// The games of one collection a search or one player narrows it to.
typedef CollectionGamesFilter =
    ({String slug, CollectionSearchQuery query, String? player});

final collectionFilteredGamesProvider = FutureProvider.autoDispose
    .family<List<CollectionGame>, CollectionGamesFilter>((ref, key) {
      ref.watch(_collectionViewerProvider);
      return ref
          .watch(collectionsReaderProvider)
          .searchGames(key.slug, search: key.query, playerKey: key.player);
    });

/// One collection's players, by slug.
final collectionPlayersProvider = FutureProvider.autoDispose
    .family<List<CollectionPlayer>, String>((ref, slug) {
      ref.watch(_collectionViewerProvider);
      return ref.watch(collectionsReaderProvider).fetchPlayers(slug);
    });

/// The published books bound to one event page. An event with no books, or a
/// request that fails, is an empty list: the books are a companion to the
/// event, never a reason for it to show an error.
final collectionBooksForEventProvider = FutureProvider.autoDispose
    .family<List<Collection>, CollectionEventAnchors>((ref, anchors) async {
      if (anchors.isEmpty) return const [];
      try {
        return await ref
            .watch(collectionsReaderProvider)
            .fetchBooksForEvent(anchors);
      } catch (e) {
        debugPrint('[Collections] books for event unavailable: $e');
        return const [];
      }
    });

/// Whether [error] is the server keeping a Premium collection's games from
/// this viewer (the paywall, not an error).
bool isCollectionPremiumGate(Object? error) =>
    error is CollectionsRequestException && error.isPremiumGate;

/// Whether [error] says this server cannot serve collections to the app yet.
bool isCollectionsNotAvailable(Object? error) =>
    error is CollectionsRequestException && error.isNotAvailable;

/// Whether this viewer reads [collection]'s games, or sees its preview and
/// the paywall.
///
/// The server decides: once a detail read carries its verdict
/// ([Collection.contentLocked]) that is the answer, whatever the app believes
/// about the membership. Until then (a catalog row) a Premium collection is
/// locked for a viewer the app knows is not subscribed, and open while the
/// membership is still loading, so a subscriber never sees a lock flash.
bool isCollectionLocked(
  Collection collection, {
  required bool isSubscribed,
  required bool subscriptionLoading,
}) {
  if (collection.access != CollectionAccess.premium) return false;
  final verdict = collection.contentLocked;
  if (verdict != null) return verdict;
  return !isSubscribed && !subscriptionLoading;
}

/// [isCollectionLocked] against the live membership.
bool watchCollectionLocked(WidgetRef ref, Collection collection) {
  final subscription = ref.watch(subscriptionProvider);
  return isCollectionLocked(
    collection,
    isSubscribed: subscription.isSubscribed,
    subscriptionLoading: subscription.isLoading,
  );
}

// ---------------------------------------------------------------------------
// Counters and the star

/// The latest view and star counts the server answered for a slug, so rows
/// and headers update without re-reading the catalog.
final collectionEngagementCountsProvider =
    StateProvider.family<Map<String, dynamic>?, String>((ref, slug) => null);

/// [collection]'s view count, as last heard from the server.
int collectionViewCount(WidgetRef ref, Collection collection) {
  final live = ref.watch(collectionEngagementCountsProvider(collection.slug));
  final value = live?['viewCount'];
  return value is num ? value.toInt() : collection.viewCount;
}

/// [collection]'s star count, as last heard from the server.
int collectionStarCount(WidgetRef ref, Collection collection) {
  final live = ref.watch(collectionEngagementCountsProvider(collection.slug));
  final value = live?['starCount'];
  return value is num ? value.toInt() : collection.starCount;
}

const String _readerIdKey = 'collection_reader_id';

/// An anonymous id for this install, the same key the phone app keeps, so a
/// read is counted once per reader and never tied to an account.
final _collectionReaderIdProvider = FutureProvider<String>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  final previous = preferences.getString(_readerIdKey);
  if (previous != null && previous.isNotEmpty) return previous;
  final id = newCollectionReaderId(Random.secure());
  await preferences.setString(_readerIdKey, id);
  return id;
});

/// A random version-4 UUID.
@visibleForTesting
String newCollectionReaderId(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Counts opening [collection] as a read. Books only, as on the phone;
/// counts never interrupt reading.
///
/// Takes the container, not a widget's ref: the page that asked may be gone
/// by the time the server answers, and the count still belongs in the store.
Future<void> trackCollectionRead(
  ProviderContainer container,
  Collection collection,
) => container.read(collectionEngagementProvider).trackRead(collection);

/// The favorites identity of a collection. A starred collection is a plain
/// favorite-events row, like a starred event, so it syncs with the phone;
/// `metadata.kind` tells it apart.
String collectionFavoriteId(String slug) => 'collection:$slug';

bool collectionIsStarred(Iterable<FavoriteEvent> favorites, String slug) {
  final id = collectionFavoriteId(slug);
  return favorites.any(
    (e) =>
        e.eventId == id ||
        (e.metadata['kind'] == 'collection' && e.metadata['slug'] == slug),
  );
}

/// The slugs of every collection this account starred.
final favoriteCollectionSlugsProvider = Provider<Set<String>>((ref) {
  final favorites = ref.watch(favoriteEventsProvider).valueOrNull;
  if (favorites == null) return const <String>{};
  const prefix = 'collection:';
  return {
    for (final favorite in favorites)
      if (favorite.eventId.startsWith(prefix))
        favorite.eventId.substring(prefix.length)
      else if (favorite.metadata['kind'] == 'collection' &&
          favorite.metadata['slug'] is String)
        favorite.metadata['slug'] as String,
  };
});

/// Whether this account starred the collection with [slug].
final collectionStarredProvider = Provider.family<bool, String>((ref, slug) {
  final favorites = ref.watch(favoriteEventsProvider).valueOrNull;
  return favorites != null && collectionIsStarred(favorites, slug);
});

/// What a star press came to.
enum CollectionStarOutcome { starred, unstarred, needsAccount, failed }

/// Whether the signed-in session is a permanent account. A guest cannot own
/// a star: the server refuses one.
bool _hasPermanentAccount() {
  try {
    final user = Supabase.instance.client.auth.currentUser;
    return user != null && !user.isAnonymous;
  } catch (_) {
    return false;
  }
}

/// Whether a permanent account is signed in: a star belongs to one. A
/// provider so a test can stand in for the session.
final collectionStarAccountProvider = Provider<bool Function()>(
  (_) => _hasPermanentAccount,
);

/// The signed-in permanent account's id.
String? _collectionStarAccountId() {
  try {
    final user = Supabase.instance.client.auth.currentUser;
    return user == null || user.isAnonymous ? null : user.id;
  } catch (_) {
    return null;
  }
}

/// View and star counts as the server holds them, the phone app's
/// `CollectionEngagement`.
///
/// Lives with the container, not a widget: a count answered after its page
/// closed still belongs in the store, and a star the server has not yet
/// confirmed waits here (and on disk) until it is.
class CollectionEngagement {
  CollectionEngagement(this._ref);

  final Ref _ref;

  /// When this device last heard a slug's counts from its own write. A
  /// catalog read that started before then is older and must not win.
  final _lastWrite = <String, DateTime>{};
  bool _refreshing = false;
  Future<void>? _flush;

  /// The queue when this device has no storage to keep it in.
  final _unsaved = <String, Map<String, bool>>{};

  Future<SharedPreferences?> _preferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static String _pendingKey(String account) =>
      'collection_star_pending_$account';
  static String _backfilledKey(String account) =>
      'collection_star_backfilled_$account';

  /// The key this account's queue is stored under, or null when no
  /// permanent account is signed in.
  String? _account({bool? signedIn}) {
    if (!(signedIn ?? _ref.read(collectionStarAccountProvider)())) return null;
    return _collectionStarAccountId() ?? 'account';
  }

  void _apply(String slug, Map<String, dynamic> counts) {
    _lastWrite[slug] = DateTime.now();
    _ref.read(collectionEngagementCountsProvider(slug).notifier).state = counts;
  }

  /// Counts opening [collection] as a read. Books only, as on the phone;
  /// counts never interrupt reading.
  Future<void> trackRead(Collection collection) async {
    if (collection.kind != CollectionKind.book) return;
    try {
      final id = await _ref.read(_collectionReaderIdProvider.future);
      final counts = await _ref
          .read(collectionsReaderProvider)
          .recordView(collection.slug, id);
      _apply(collection.slug, counts);
    } catch (_) {
      // A missed count is not the reader's problem.
    }
  }

  /// Records this account's star on [slug] and sends it. A star the server
  /// did not confirm stays queued and is sent again on the next refresh.
  Future<void> setStar(String slug, bool starred, {bool? signedIn}) async {
    final account = _account(signedIn: signedIn);
    if (account == null) return;
    final preferences = await _preferences();
    final pending = _pending(preferences, account)..[slug] = starred;
    await _store(preferences, account, pending);
    await flushStars(account: account);
  }

  /// Sends every star the server has not confirmed yet.
  Future<void> flushStars({String? account}) =>
      _flush ??= _sendPendingStars(account).whenComplete(() => _flush = null);

  Future<void> _sendPendingStars(String? known) async {
    try {
      final account = known ?? _account();
      if (account == null) return;
      final preferences = await _preferences();
      await _queueEarlierStars(preferences, account);
      final reader = _ref.read(collectionsReaderProvider);
      final failed = <String>{};
      // Re-read each round: a star pressed while this runs joins the queue.
      while (true) {
        final next =
            _pending(
              preferences,
              account,
            ).entries.where((e) => !failed.contains(e.key)).firstOrNull;
        if (next == null) return;
        var settled = false;
        try {
          _apply(next.key, await reader.recordStar(next.key, next.value));
          settled = true;
        } catch (e) {
          // A collection that is gone, or a body the server will never
          // take, is dropped. Anything else is tried again later.
          final status = e is CollectionsRequestException ? e.statusCode : null;
          settled = status == 400 || status == 404;
        }
        if (!settled) {
          failed.add(next.key);
          continue;
        }
        // Only what was sent is settled: a newer press stays queued.
        final pending = _pending(preferences, account);
        if (pending[next.key] == next.value) {
          pending.remove(next.key);
          await _store(preferences, account, pending);
        }
      }
    } catch (_) {
      // The queue is on disk; the next refresh sends it.
    }
  }

  /// Stars made before the server counted them, queued once per account.
  Future<void> _queueEarlierStars(
    SharedPreferences? preferences,
    String account,
  ) async {
    if (preferences == null) return;
    if (preferences.getBool(_backfilledKey(account)) ?? false) return;
    if (_ref.read(favoriteEventsProvider).valueOrNull == null) return;
    final pending = _pending(preferences, account);
    for (final slug in _ref.read(favoriteCollectionSlugsProvider)) {
      if (slug.isNotEmpty) pending.putIfAbsent(slug, () => true);
    }
    await _store(preferences, account, pending);
    await preferences.setBool(_backfilledKey(account), true);
  }

  Map<String, bool> _pending(SharedPreferences? preferences, String account) {
    if (preferences == null) return {...?_unsaved[account]};
    try {
      final raw = preferences.getString(_pendingKey(account));
      if (raw == null) return {};
      return {
        for (final entry in (jsonDecode(raw) as Map).entries)
          if (entry.value is bool) entry.key as String: entry.value as bool,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _store(
    SharedPreferences? preferences,
    String account,
    Map<String, bool> pending,
  ) async {
    if (preferences == null) {
      _unsaved[account] = pending;
    } else if (pending.isEmpty) {
      await preferences.remove(_pendingKey(account));
    } else {
      await preferences.setString(_pendingKey(account), jsonEncode(pending));
    }
  }

  /// Reads every book's counts fresh. The catalog search is the one public
  /// read the server never caches, so this is what other readers did since.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await flushStars();
      final started = DateTime.now();
      final reader = _ref.read(collectionsReaderProvider);
      var offset = 0;
      while (true) {
        final page = await reader.searchBooks(
          const CollectionSearchQuery(),
          offset,
        );
        for (final book in page.items) {
          final written = _lastWrite[book.slug];
          if (written != null && written.isAfter(started)) continue;
          final counts = _ref.read(
            collectionEngagementCountsProvider(book.slug).notifier,
          );
          final current = counts.state;
          if (current?['viewCount'] == book.viewCount &&
              current?['starCount'] == book.starCount) {
            continue;
          }
          counts.state = {
            'viewCount': book.viewCount,
            'starCount': book.starCount,
          };
        }
        offset += page.items.length;
        if (page.items.isEmpty || offset >= page.total) break;
      }
    } catch (_) {
      // The counts on screen stay until the next refresh.
    } finally {
      _refreshing = false;
    }
  }
}

final collectionEngagementProvider = Provider<CollectionEngagement>(
  CollectionEngagement.new,
);

/// Stars or unstars [collection]: the same favorite row and the same counter
/// call as the phone app, so the star follows the account.
///
/// Takes the container, not a widget's ref: starring moves the row to the
/// top of the catalog, which rebuilds it, and the public count still has to
/// be sent after that.
Future<CollectionStarOutcome> toggleCollectionStar(
  ProviderContainer container,
  Collection collection, {
  bool Function()? hasPermanentAccount,
}) async {
  final bool Function() signedIn =
      hasPermanentAccount ?? container.read(collectionStarAccountProvider);
  if (!signedIn()) return CollectionStarOutcome.needsAccount;
  final bool starred;
  try {
    starred = await container
        .read(favoriteEventsProvider.notifier)
        .toggleFavorite(
          eventId: collectionFavoriteId(collection.slug),
          eventName: collection.title,
          extraMetadata: {
            'kind': 'collection',
            'slug': collection.slug,
            'collectionKind': collection.kind.name,
          },
        );
  } catch (e) {
    debugPrint('[Collections] star failed: $e');
    return CollectionStarOutcome.failed;
  }
  await container
      .read(collectionEngagementProvider)
      .setStar(collection.slug, starred, signedIn: true);
  return starred
      ? CollectionStarOutcome.starred
      : CollectionStarOutcome.unstarred;
}
