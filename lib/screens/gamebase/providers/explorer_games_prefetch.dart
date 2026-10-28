import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'explorer_games_cache.dart';
import 'gamebase_explorer_state.dart';
import 'gamebase_providers.dart';

// Desktop port of the phone app's explorer games warmer (chessever-frontend,
// lib/screens/gamebase/providers/explorer_games_prefetch.dart).
//
// On the phone a move row's chip opens a games sheet for that move. On
// desktop, clicking a move row plays it, and the games table beside the
// moves then lists the games of the position it leads to; the per-row list
// icon (where a host supports it) pins the table to that move instead. So
// desktop warms the games table's first page for the position each visible
// row leads to, and the pinned page only when the list icon is about to be
// used.

/// Move rows warmed from the network per position, from the top of the
/// visible order.
const int kExplorerGamesPrefetchRows = 6;

/// How long a position must stay on screen before the games behind its move
/// rows are warmed from the server.
///
/// Counted from when the position appeared, not from when its moves arrived.
/// Stepping through a line a few moves a second (arrow keys, the board)
/// never stops this long, so it sends no warm-ups for positions the reader
/// only passes through; stopping to read warms well before a click.
const Duration kExplorerGamesRowWarmDwell = Duration(milliseconds: 450);

/// How long the pointer must rest on a move row (or its list icon) before the
/// games behind it are warmed. A pointer sweeping across the table never
/// waits this long on a row; one heading for a click does.
const Duration kExplorerGamesHoverWarmDelay = Duration(milliseconds: 120);

/// Hover warm-ups ([ExplorerGamesPrefetcher.warmHover]) on the wire at once.
/// A pointer resting on row after row never has more out than this: the row
/// it rests on now waits for the next free one, and a row it has left is
/// dropped from the wait.
const int kExplorerGamesHoverWarmConcurrency = 2;

/// Warm requests allowed in flight at once for the position being read. They
/// share the backend pool with the aggregates the moves table is still
/// drawing, so this stays small. A hover ([kExplorerGamesHoverWarmConcurrency])
/// or pointer-down ([ExplorerGamesPrefetcher.warmNow]) head start does not
/// wait for one of these slots.
const int kExplorerGamesPrefetchConcurrency = 3;

/// Warm requests allowed in flight at once across every position, counting
/// ones still running for positions the reader has left. Those are never
/// cancelled (the server finishes the query and caches it either way), so
/// they do not take the position being read's
/// [kExplorerGamesPrefetchConcurrency] slots, only room under this ceiling.
const int kExplorerGamesPrefetchInFlightCeiling = 6;

/// Warmed entries held before the least recently warmed are released.
const int kExplorerGamesPrefetchRetained = 64;

/// Most requests ever waiting for a slot. Newest first; the oldest fall off.
const int kExplorerGamesPrefetchQueueLimit = 16;

/// A held page warmed longer ago than this is fetched again the next time its
/// position is warmed. Younger ones already answer the click (and the table
/// re-checks anything older than [kExplorerGamesFreshFor] itself).
const Duration kExplorerGamesRewarmAfter = Duration(minutes: 10);

/// The position [uci] leads to from [fen], or null when it is not a legal
/// move there. Castling is accepted in either spelling (`e1g1` / `e1h1`).
String? explorerFenAfterUci(String fen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final alternate = GamebaseRepository.alternateCastlingUci(uci.trim());
    for (final candidate in <String>[
      uci.trim(),
      if (alternate != null) alternate,
    ]) {
      final move = Move.parse(candidate);
      if (move != null && position.isLegal(move)) {
        return position.play(move).fen;
      }
    }
  } catch (_) {
    // Not a position/move pair dartchess can play.
  }
  return null;
}

/// The page a desktop games table lists once the move [uci] is played from
/// [fen] after [moves]: that position's games, with the explorer's filters.
GamebasePositionGamesQuery? desktopExplorerChildGamesQuery({
  required String fen,
  required List<String> moves,
  required String uci,
  required GamebaseFilters filters,
}) {
  final childFen = explorerFenAfterUci(fen, uci);
  if (childFen == null) return null;
  return GamebasePositionGamesQuery.desktopTablePage(
    fen: childFen,
    moves: <String>[...moves, uci.trim()],
    filters: filters,
  );
}

/// The page a desktop games table lists when it is pinned to the move [uci]
/// at [fen] (the per-row list icon).
GamebasePositionGamesQuery desktopExplorerPinnedGamesQuery({
  required String fen,
  required List<String> moves,
  required String uci,
  required GamebaseFilters filters,
}) => GamebasePositionGamesQuery.desktopTablePage(
  fen: fen,
  moves: moves,
  uci: uci.trim(),
  filters: filters,
);

/// Queries to warm for [aggregates] (in the order the table displays them):
/// the games table page each of the top [rows] moves leads to.
List<GamebasePositionGamesQuery> buildExplorerGamesPrefetchQueries({
  required String fen,
  required List<String> moves,
  required List<MoveAggregate> aggregates,
  required GamebaseFilters filters,
  int rows = kExplorerGamesPrefetchRows,
}) {
  if (fen.trim().isEmpty || aggregates.isEmpty) {
    return const <GamebasePositionGamesQuery>[];
  }
  final queries = <GamebasePositionGamesQuery>[];
  for (final aggregate in aggregates.take(rows)) {
    final uci = aggregate.uci.trim();
    if (uci.isEmpty) continue;
    final query = desktopExplorerChildGamesQuery(
      fen: fen,
      moves: moves,
      uci: uci,
      filters: filters,
    );
    if (query != null && !queries.contains(query)) queries.add(query);
  }
  return queries;
}

/// Identity of the move-row warm-up for a position: it changes whenever the
/// rows would warm different queries. The move line is part of it: a
/// transposition onto the same FEN asks with a different line.
int explorerGamesPrefetchSignature({
  required String fen,
  required List<String> moves,
  required GamebaseFilters filters,
  required List<MoveAggregate> aggregates,
}) => Object.hash(
  fen,
  Object.hashAll(moves),
  filters,
  Object.hashAll(
    aggregates
        .take(kExplorerGamesPrefetchRows)
        .map((aggregate) => aggregate.uci),
  ),
);

typedef _WarmSubscription =
    ProviderSubscription<AsyncValue<GamebaseSearchQueryResponse>>;

/// Warms the explorer's games table pages before they are asked for.
///
/// * Every warmed query holds a [ProviderSubscription] until evicted, so the
///   `positionGamesProvider` entry (and the first page [ExplorerGamesCache]
///   keeps under the same wire request) is resident when the click lands.
/// * The warmed query must address the same wire request the table sends, so
///   every caller builds it with
///   [GamebasePositionGamesQuery.desktopTablePage].
/// * The queue only ever serves the position being read: warming a position
///   drops everything still waiting for another one, puts the new work in
///   front, and is capped at [kExplorerGamesPrefetchQueueLimit]. Rows that
///   leave the screen take their waiting work with them ([cancel]).
/// * Slots are counted per position: up to [kExplorerGamesPrefetchConcurrency]
///   for the position being read, within
///   [kExplorerGamesPrefetchInFlightCeiling] overall, so slow requests still
///   running for a position already left do not hold the next position's
///   slots.
/// * The pointer is bounded too: a rested hover ([warmHover]) has its own
///   [kExplorerGamesHoverWarmConcurrency] slots and waits for them, so moving
///   down the rows never fans out a request per row. Only a pointer-down
///   ([warmNow]), a click already under way, starts without waiting.
/// * A failed warm is dropped rather than kept, so a transient error is never
///   pinned in front of the table as an instant error state.
class ExplorerGamesPrefetcher {
  ExplorerGamesPrefetcher(this._ref, {this.enabled = true});

  final Ref _ref;

  /// Off: every call is a no-op (see [explorerGamesWarmUpsEnabledProvider]).
  final bool enabled;

  /// Least recently warmed first.
  final LinkedHashMap<GamebasePositionGamesQuery, _WarmSubscription> _warm =
      LinkedHashMap<GamebasePositionGamesQuery, _WarmSubscription>();
  final Set<GamebasePositionGamesQuery> _inFlight = {};

  /// Next to start first.
  final List<GamebasePositionGamesQuery> _queue = [];

  /// Hover warm-ups on the wire ([warmHover]).
  final Set<GamebasePositionGamesQuery> _hoverInFlight = {};

  /// The row the pointer rests on, waiting for a hover slot.
  GamebasePositionGamesQuery? _hoverWaiting;

  /// The position(s) of the latest [warm]: the one being read.
  Set<String> _reading = const <String>{};

  bool _disposed = false;

  ExplorerGamesCache get _cache => _ref.read(explorerGamesCacheProvider);

  /// Reads whatever the disk saved for [queries] into memory, with no network
  /// request, so a table landing on any of them paints in its first frame.
  void preload(Iterable<GamebasePositionGamesQuery> queries) {
    if (_disposed || !enabled) return;
    unawaited(_cache.preload(queries));
  }

  /// Warm [queries], in order, ahead of anything already waiting.
  ///
  /// Work still queued for any other position is dropped: the reader has left
  /// it. Requests already in flight are left alone (the server finishes them
  /// either way), but they no longer hold this position's slots.
  void warm(List<GamebasePositionGamesQuery> queries) {
    if (_disposed || !enabled || queries.isEmpty) return;
    preload(queries);
    final positions = queries.map(_positionOf).toSet();
    _reading = positions;
    _queue.removeWhere(
      (queued) =>
          !positions.contains(_positionOf(queued)) || queries.contains(queued),
    );
    final wanted = <GamebasePositionGamesQuery>[];
    for (final query in queries) {
      if (wanted.contains(query) || !_needsFetch(query)) continue;
      wanted.add(query);
    }
    _queue.insertAll(0, wanted);
    if (_queue.length > kExplorerGamesPrefetchQueueLimit) {
      _queue.removeRange(kExplorerGamesPrefetchQueueLimit, _queue.length);
    }
    _pump();
  }

  /// The rows behind [queries] left the screen (the reader moved on, the
  /// table closed): whatever of them is still waiting for a slot is dropped.
  /// Requests already on the wire are left to finish.
  void cancel(Iterable<GamebasePositionGamesQuery> queries) {
    if (_disposed || _queue.isEmpty) return;
    final gone = queries.toSet();
    _queue.removeWhere(gone.contains);
  }

  /// Head start for a click that is about to show [query]'s games (pointer
  /// down): starts now, without waiting for a free slot.
  void warmNow(GamebasePositionGamesQuery query) {
    if (_disposed || !enabled) return;
    preload(<GamebasePositionGamesQuery>[query]);
    _queue.remove(query);
    if (!_needsFetch(query)) return;
    unawaited(_fetch(query));
  }

  /// Head start for a row the pointer has rested on
  /// ([kExplorerGamesHoverWarmDelay]). Starts at once while fewer than
  /// [kExplorerGamesHoverWarmConcurrency] hover warm-ups are out; otherwise
  /// it waits for one to finish, replacing any older row still waiting.
  /// Call [cancelHover] when the pointer leaves the row.
  void warmHover(GamebasePositionGamesQuery query) {
    if (_disposed || !enabled) return;
    preload(<GamebasePositionGamesQuery>[query]);
    if (!_needsFetch(query)) {
      if (_hoverWaiting == query) _hoverWaiting = null;
      return;
    }
    if (_hoverInFlight.length >= kExplorerGamesHoverWarmConcurrency) {
      _hoverWaiting = query;
      return;
    }
    if (_hoverWaiting == query) _hoverWaiting = null;
    _queue.remove(query);
    unawaited(_fetch(query, hover: true));
  }

  /// The pointer left the row behind [query]: if its hover warm-up is still
  /// waiting for a slot, it is dropped. One already on the wire finishes.
  void cancelHover(GamebasePositionGamesQuery query) {
    if (_hoverWaiting == query) _hoverWaiting = null;
  }

  /// Whether [query] has already settled and would answer the table at once.
  bool isWarm(GamebasePositionGamesQuery query) {
    final subscription = _warm[query];
    return subscription != null &&
        !_inFlight.contains(query) &&
        subscription.read().hasValue;
  }

  /// Requests waiting for a slot, next first.
  List<GamebasePositionGamesQuery> get queued =>
      List<GamebasePositionGamesQuery>.unmodifiable(_queue);

  /// The rested row waiting for a hover slot, if any.
  GamebasePositionGamesQuery? get hoverWaiting => _hoverWaiting;

  /// The position a query is warmed for: the one being read, never the one a
  /// move leads to, so every row of the position shares one slot budget.
  ///
  /// The filters are part of it: changing them on the same position is
  /// leaving it, so whatever the old filters still had waiting is dropped
  /// and their requests on the wire no longer hold the new filters' slots.
  static String _positionOf(GamebasePositionGamesQuery query) {
    final moves = query.moves;
    final line =
        query.uci == null && moves.isNotEmpty
            ? '${moves.take(moves.length - 1).join(' ')}|parent'
            : '${moves.join(' ')}|${query.fen.trim()}';
    return '$line|${_filtersOf(query)}';
  }

  static String _filtersOf(GamebasePositionGamesQuery query) => <Object?>[
    query.timeControl?.name,
    query.playerId,
    query.color,
    query.result,
    query.isOnline,
    query.minRating,
    query.maxRating,
    query.yearFrom,
    query.yearTo,
    query.sortBy.name,
    query.sortDirection.name,
    query.pageSize,
    query.notationPlies,
    query.useFenEndpoint,
  ].join(',');

  /// False when [query] is on the wire or held with a recent answer. A held
  /// entry that failed or is too old is released and fetched again.
  bool _needsFetch(GamebasePositionGamesQuery query) {
    if (_inFlight.contains(query)) return false;
    final subscription = _warm[query];
    if (subscription == null) return !_cache.isFetching(query);
    final value = subscription.read();
    if (value.isLoading) return false;
    final age = value.hasValue ? _cache.ageOf(value.requireValue) : null;
    if (age != null && age < kExplorerGamesRewarmAfter) return false;
    _warm.remove(query)?.close();
    if (value.hasValue) {
      // Held long enough to be worth asking again: drop the old answer so the
      // listen below starts a real request.
      _ref.invalidate(positionGamesProvider(query));
    }
    return true;
  }

  /// Whether the next queued request (always for the position being read)
  /// may start now.
  bool _hasFreeSlot() {
    if (_inFlight.length >= kExplorerGamesPrefetchInFlightCeiling) {
      return false;
    }
    var reading = 0;
    for (final query in _inFlight) {
      if (_reading.contains(_positionOf(query))) reading++;
    }
    return reading < kExplorerGamesPrefetchConcurrency;
  }

  void _pump() {
    while (!_disposed && _queue.isNotEmpty && _hasFreeSlot()) {
      final query = _queue.removeAt(0);
      if (!_needsFetch(query)) continue;
      unawaited(_fetch(query));
    }
  }

  void _pumpHover() {
    final waiting = _hoverWaiting;
    if (_disposed ||
        waiting == null ||
        _hoverInFlight.length >= kExplorerGamesHoverWarmConcurrency) {
      return;
    }
    _hoverWaiting = null;
    if (!_needsFetch(waiting)) return;
    _queue.remove(waiting);
    unawaited(_fetch(waiting, hover: true));
  }

  Future<void> _fetch(
    GamebasePositionGamesQuery query, {
    bool hover = false,
  }) async {
    _inFlight.add(query);
    if (hover) _hoverInFlight.add(query);
    // The listener is what keeps the autoDispose entry resident; its callback
    // is deliberately empty because the awaited future below is the result.
    final subscription = _ref.listen<AsyncValue<GamebaseSearchQueryResponse>>(
      positionGamesProvider(query),
      (_, _) {},
    );
    _warm.remove(query)?.close();
    _warm[query] = subscription;
    _evict();
    try {
      await _ref.read(positionGamesProvider(query).future);
    } catch (_) {
      // Let the click retry rather than serving it a cached failure.
      if (identical(_warm[query], subscription)) _warm.remove(query);
      subscription.close();
    } finally {
      _inFlight.remove(query);
      if (hover) _hoverInFlight.remove(query);
      _pumpHover();
      _pump();
    }
  }

  void _evict() {
    if (_warm.length <= kExplorerGamesPrefetchRetained) return;
    for (final query in _warm.keys.toList(growable: false)) {
      if (_warm.length <= kExplorerGamesPrefetchRetained) break;
      if (_inFlight.contains(query)) continue;
      _warm.remove(query)?.close();
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _hoverWaiting = null;
    for (final subscription in _warm.values) {
      subscription.close();
    }
    _warm.clear();
  }
}

bool _underFlutterTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Whether the explorer warms games pages ahead of a click. On in the app.
///
/// Off by default under `flutter test`: a warm-up is a request nobody waits
/// for, so a widget test that is not about warming would end with it still
/// on its fake repository's timer. Tests about warming override it to true.
final explorerGamesWarmUpsEnabledProvider = Provider<bool>(
  (ref) => !_underFlutterTest(),
);

/// App-lifetime (per engine) warmer for the explorer games table.
///
/// Deliberately not `autoDispose`: the whole point is to outlive the move-row
/// widget that requested the warm-up and still be holding the result when the
/// table asks for it.
final explorerGamesPrefetchProvider = Provider<ExplorerGamesPrefetcher>((ref) {
  final prefetcher = ExplorerGamesPrefetcher(
    ref,
    enabled: ref.watch(explorerGamesWarmUpsEnabledProvider),
  );
  ref.onDispose(prefetcher.dispose);
  return prefetcher;
});
