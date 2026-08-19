import 'dart:async';

import 'package:chessever/providers/error_logger_provider.dart';
import 'package:chessever/providers/event_favorite_players_provider.dart';
import 'package:chessever/providers/event_pin_refresh_provider.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/repository/local_storage/tournament/games/pin_games_local_storage.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/group_event/providers/sorting_all_event_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_pin_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_rounds_id_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const int kGamesPerEvent = 4;
const int kDesktopForYouGamesPerEvent = 12;
const int _kPageSize = 20;
const Duration _kForYouStaleThreshold = Duration(minutes: 5);

int get _topGamesPerEventSnapshotLimit {
  if (kIsWeb) return kGamesPerEvent;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => kDesktopForYouGamesPerEvent,
    _ => kGamesPerEvent,
  };
}

/// One bounded realtime key shared by For You membership refresh and every
/// rendered card leaf for the same event.
///
/// Terminal rows remain represented while the snapshot is mounted so a
/// result event cannot detach the channel before a trailing final PGN/FEN or
/// player correction arrives.
LiveGamesBatchKey forYouEventLiveBatchKey({
  required String eventId,
  required String tourId,
  required Iterable<GamesTourModel> games,
}) {
  final boundedGames = games
      .take(_topGamesPerEventSnapshotLimit)
      .toList(growable: false);
  final keysByGame = liveBatchKeysForGames(
    games: boundedGames,
    scopePrefix: 'for_you:$eventId:$tourId',
    includeFinishedGames: true,
  );
  if (keysByGame.isNotEmpty) return keysByGame.values.first;
  return LiveGamesBatchKey(
    scopeId: 'for_you:$eventId:$tourId:empty',
    gameIds: const <String>[],
  );
}

final forYouTopGamesSnapshotCacheProvider =
    StateProvider<Map<String, ForYouEventGamesSnapshot>>((ref) {
      return const <String, ForYouEventGamesSnapshot>{};
    });

@visibleForTesting
Map<String, ForYouEventGamesSnapshot> mergeForYouTopGameSnapshots({
  required Map<String, ForYouEventGamesSnapshot> current,
  required Map<String, ForYouEventGamesSnapshot> incoming,
  required bool replace,
}) {
  var changed =
      replace && !setEquals(current.keys.toSet(), incoming.keys.toSet());
  final merged =
      replace
          ? <String, ForYouEventGamesSnapshot>{}
          : <String, ForYouEventGamesSnapshot>{...current};

  for (final entry in incoming.entries) {
    final existing = current[entry.key];
    // A fetch that comes back with no boards for an event we already have a
    // preview for is a transient — a timed-out batch, a failed RPC whose catch
    // path writes empty snapshots, or a live refresh that raced a round
    // rollover. It is not the server saying the event lost its games. Since an
    // empty snapshot hides the entire row, keep the last good preview until a
    // fetch actually answers with boards.
    if (existing != null && existing.hasGames && !entry.value.hasGames) {
      if (replace) merged[entry.key] = existing;
      continue;
    }
    if (existing != null &&
        areEquivalentForYouSnapshots(existing, entry.value)) {
      if (replace) merged[entry.key] = existing;
      continue;
    }
    merged[entry.key] = entry.value;
    changed = true;
  }

  return changed ? merged : current;
}

// ============================================================================
// FOR YOU EVENTS - PAGINATED WITH SUPABASE QUERIES
// ============================================================================

class ForYouState {
  final List<GroupEventCardModel> events;
  final bool isLoading;
  final bool hasMore;
  final String? error;

  const ForYouState({
    this.events = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.error,
  });

  ForYouState copyWith({
    List<GroupEventCardModel>? events,
    bool? isLoading,
    bool? hasMore,
    String? error,
  }) {
    return ForYouState(
      events: events ?? this.events,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: error,
    );
  }
}

class ForYouNotifier extends StateNotifier<ForYouState> {
  final Ref ref;
  int _offset = 0;
  bool _isFetching = false;
  DateTime? _lastRefreshAt;
  final Map<String, int> _sessionEventOrder = <String, int>{};
  int _nextSessionEventOrder = 0;
  bool _pendingFavoritePlayerOrderHydration = false;
  bool _isRefreshingVisibleTopGameSnapshots = false;
  final Set<String> _handledFinishedTopGameRefreshes = <String>{};
  // In-flight `hydrateEvents` ids, so repeated live-first recomputes cannot
  // stack duplicate fetches for the same event.
  final Set<String> _hydratingEventIds = <String>{};

  ForYouNotifier(this.ref) : super(const ForYouState(isLoading: true)) {
    _setupListeners();
    _loadInitial();
  }

  void _setupListeners() {
    // Match the Current tab's behavior: when a tour transitions ongoing→live
    // (or live→completed), re-derive tourEventCategory on every existing card
    // so the _NextRoundLine flips from "starts in…" to "LIVE" without waiting
    // for a full refetch.
    ref.listen<AsyncValue<List<String>>>(liveGroupBroadcastIdsProvider, (
      _,
      next,
    ) {
      next.whenData((liveIds) {
        // Deferred off the notification callstack. Publishing state from inside
        // another provider's synchronous notification let Riverpod deliver it to
        // a listener list captured before a just-unmounted pane was removed,
        // which asserted `_lifecycleState != defunct` in markNeedsBuild. The
        // live-ids poll then repeated that assert on every tick and left the For
        // You feed stuck on its spinner.
        Future<void>.microtask(() {
          if (!mounted) return;
          _refreshLiveCategories(liveIds);
          _refreshTopGameSnapshotsForLiveSignal();
        });
      });
    });

    ref.listen<AsyncValue<List<String>>>(liveRoundsIdProvider, (
      previous,
      next,
    ) {
      next.whenData((liveRoundIds) {
        if (!shouldRefreshForYouSnapshotsForLiveRoundIds(
          previous?.valueOrNull,
          liveRoundIds,
        )) {
          return;
        }

        _refreshTopGameSnapshotsForLiveSignal();
      });
    });

    ref.listen(favoritePlayersProviderNew, (_, next) {
      final shouldFinalizeOrder =
          _pendingFavoritePlayerOrderHydration &&
          _favoriteFideIdsFrom(
            next.valueOrNull ?? const <FavoritePlayer>[],
          ).isNotEmpty;

      if (next.hasValue && !shouldFinalizeOrder) {
        _pendingFavoritePlayerOrderHydration = false;
      }

      unawaited(
        _refreshVisibleFavoritePlayerCounts(
          finalizeOrderAfterRefresh: shouldFinalizeOrder,
        ),
      );
    });

    ref.listen(favoriteEventsProvider, (_, next) {
      next.whenData((_) => _resortVisibleEventsForFavoriteChange());
    });
  }

  void _refreshLiveCategories(List<String> liveIds) {
    final current = state.events;
    if (current.isEmpty) return;

    final updated = current.map((e) => e.withLiveIds(liveIds)).toList();

    bool changed = false;
    for (var i = 0; i < current.length; i++) {
      if (current[i].tourEventCategory != updated[i].tourEventCategory) {
        changed = true;
        break;
      }
    }
    if (!changed) return;

    if (mounted) state = state.copyWith(events: updated);
  }

  Future<void> _loadInitial() async {
    await _fetchPage(isInitial: true);
  }

  Future<void> refresh() async {
    _offset = 0;
    state = state.copyWith(isLoading: true, error: null);
    ref.read(forYouTopGamesSnapshotCacheProvider.notifier).state =
        const <String, ForYouEventGamesSnapshot>{};
    await _fetchPage(isInitial: true);
    if (mounted) {
      bumpForYouEventsRefreshSignal(ref);
    }
  }

  Future<void> refreshIfStale({
    Duration maxAge = _kForYouStaleThreshold,
  }) async {
    if (_isFetching || state.isLoading) return;
    final lastRefreshAt = _lastRefreshAt;
    if (lastRefreshAt == null ||
        DateTime.now().difference(lastRefreshAt) >= maxAge) {
      await refresh();
    }
  }

  Future<void> loadMore() async {
    if (_isFetching || !state.hasMore || state.isLoading) return;
    await _fetchPage(isInitial: false);
  }

  Future<void> _fetchPage({required bool isInitial}) async {
    if (_isFetching) return;
    _isFetching = true;

    try {
      // Read filter state
      final appliedFilters = ref.read(forYouAppliedFilterProvider);

      // Parse filters
      final formatFilters =
          appliedFilters.formatsAndStates
              .where(
                (f) => ['blitz', 'rapid', 'standard'].contains(f.toLowerCase()),
              )
              .map((f) => f.toLowerCase())
              .toList();

      final statusFilters =
          appliedFilters.formatsAndStates
              .where((f) => ['live', 'completed'].contains(f.toLowerCase()))
              .map((f) => f.toLowerCase())
              .toSet();

      final minElo = appliedFilters.eloRange.start.round();
      final maxElo = appliedFilters.eloRange.end.round();
      final hasEloFilter =
          minElo > defaultFilterPopupState.eloRange.start.round() ||
          maxElo < defaultFilterPopupState.eloRange.end.round();

      // Query Supabase with filters
      final repo = ref.read(groupBroadcastRepositoryProvider);

      // Prefer cached live IDs so For You can render after app resume even
      // while the realtime settings stream is reconnecting.
      final liveIds = await _getLiveIdsSnapshot();

      final broadcasts = await repo.getForYouGroupBroadcasts(
        limit: _kPageSize,
        offset: _offset,
        timeControlFilters: formatFilters.isNotEmpty ? formatFilters : null,
        minElo: hasEloFilter ? minElo : null,
        maxElo: hasEloFilter ? maxElo : null,
        statusFilters: statusFilters.isNotEmpty ? statusFilters.toList() : null,
      );

      debugPrint(
        '[ForYou] RPC fetched ${broadcasts.length} events (offset: $_offset, filters: format=$formatFilters, elo=$hasEloFilter, status=$statusFilters)',
      );

      final dbHasMore = broadcasts.length >= _kPageSize;
      _offset += broadcasts.length;

      // Convert to models
      final models =
          broadcasts
              .map((b) => GroupEventCardModel.fromGroupBroadcast(b, liveIds))
              .toList();

      await _prefetchTopGameSnapshots(models, replace: isInitial);

      if (!mounted) return;

      // Update state
      if (isInitial) {
        final hasGenuinelyNewEvent =
            _sessionEventOrder.isNotEmpty &&
            models.any((event) => !_sessionEventOrder.containsKey(event.id));
        if (hasGenuinelyNewEvent) {
          // Metadata-only refreshes keep the established session order, but a
          // genuinely new card must enter through the personalized sort. If
          // we merely appended it, a newly starred/favorite-player event
          // would be buried below every card that happened to load earlier.
          _sessionEventOrder.clear();
          _nextSessionEventOrder = 0;
        }
        state = ForYouState(
          events: _sortPageOnceForSession(models),
          isLoading: false,
          hasMore: dbHasMore,
        );
        _lastRefreshAt = DateTime.now();
        _maybeFinalizePendingFavoritePlayerOrder();
      } else {
        final existingIds = state.events.map((event) => event.id).toSet();
        final newModels =
            models.where((event) => !existingIds.contains(event.id)).toList();
        state = state.copyWith(
          events: [...state.events, ..._sortPageOnceForSession(newModels)],
          hasMore: dbHasMore,
        );
        _maybeFinalizePendingFavoritePlayerOrder();
      }
    } catch (e, stack) {
      debugPrint('[ForYou] Error: $e');
      debugPrint('[ForYou] Stack: $stack');
      _logErrorToSentry(e, stack);
      state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      _isFetching = false;
    }
  }

  void _logErrorToSentry(dynamic error, StackTrace stackTrace) {
    unawaited(ref.read(errorLoggerProvider).logError(error, stackTrace));
  }

  /// Loads events the paged feed has not fetched yet, by id.
  ///
  /// For You pages 20 events at a time ordered by rating, so an event the user
  /// needs to see — a live one, when Desktop's "Live first" is on — can sit far
  /// below the loaded window. Display-time reordering cannot promote a card
  /// that was never fetched, so pull those events in through the same pipeline
  /// a page uses (card models + top-game snapshots) and append them; the
  /// display order decides where they land.
  Future<void> hydrateEvents(Iterable<String> eventIds) async {
    final requested = eventIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requested.isEmpty) return;

    final loadedIds = state.events.map((event) => event.id).toSet();
    final missing = requested
        .difference(loadedIds)
        .difference(_hydratingEventIds);
    if (missing.isEmpty) return;

    _hydratingEventIds.addAll(missing);
    try {
      final liveIds = await _getLiveIdsSnapshot();
      final broadcasts = await ref
          .read(groupBroadcastRepositoryProvider)
          .getGroupBroadcastsByIdsOrNames(missing.toList(growable: false));
      if (!mounted || broadcasts.isEmpty) return;

      final models =
          broadcasts
              .map((b) => GroupEventCardModel.fromGroupBroadcast(b, liveIds))
              .toList(growable: false);

      await _prefetchTopGameSnapshots(models, replace: false);
      if (!mounted) return;

      final presentIds = state.events.map((event) => event.id).toSet();
      final additions =
          models
              .where((model) => !presentIds.contains(model.id))
              .toList(growable: false);
      if (additions.isEmpty) return;

      debugPrint('[ForYou] Hydrated ${additions.length} off-page event(s)');
      state = state.copyWith(
        events: [...state.events, ..._sortPageOnceForSession(additions)],
      );
    } catch (e, stack) {
      debugPrint('[ForYou] Event hydration failed: $e');
      _logErrorToSentry(e, stack);
    } finally {
      _hydratingEventIds.removeAll(missing);
    }
  }

  Future<List<String>> _getLiveIdsSnapshot() async {
    final cached = ref.read(liveGroupBroadcastIdsProvider).valueOrNull;
    if (cached != null) return cached;

    try {
      return await ref.read(liveGroupBroadcastIdsProvider.future);
    } catch (e, stack) {
      debugPrint(
        '[ForYou] liveGroupBroadcastIdsProvider failed, falling back to empty list: $e',
      );
      debugPrint('[ForYou] Live IDs stack: $stack');
      _logErrorToSentry(e, stack);
      return const <String>[];
    }
  }

  Future<void> _prefetchTopGameSnapshots(
    List<GroupEventCardModel> models, {
    required bool replace,
  }) async {
    final snapshotsNotifier = ref.read(
      forYouTopGamesSnapshotCacheProvider.notifier,
    );

    if (models.isEmpty) {
      if (replace) {
        snapshotsNotifier.state = const <String, ForYouEventGamesSnapshot>{};
      }
      return;
    }

    final eventIds = models
        .map((model) => model.id)
        .where((eventId) => eventId.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (eventIds.isEmpty) {
      if (replace) {
        snapshotsNotifier.state = const <String, ForYouEventGamesSnapshot>{};
      }
      return;
    }

    try {
      final gameRepository = ref.read(gameRepositoryProvider);
      final prefetchResults = await Future.wait<Object?>([
        gameRepository
            .getForYouTopGamesByEventIds(
              eventIds: eventIds,
              boardsPerEvent: _topGamesPerEventSnapshotLimit,
            )
            .timeout(const Duration(seconds: 6)),
        _loadFavoritePlayerMatches(
          gameRepository: gameRepository,
          eventIds: eventIds,
          allowOrderHydrationFinalize: replace && _sessionEventOrder.isEmpty,
        ),
      ]);

      final gamesByEvent = prefetchResults[0]! as Map<String, List<Games>>;
      final favoritePlayerMatchesByEventId =
          prefetchResults[1]! as Map<String, List<int>>;

      _cacheFavoritePlayerMatches(
        eventIds: eventIds,
        matchesByEventId: favoritePlayerMatchesByEventId,
      );
      _writeTopGameSnapshots(
        models: models,
        gamesByEvent: gamesByEvent,
        replace: replace,
      );
    } catch (e, stack) {
      debugPrint('[ForYou] Top-game RPC failed: $e');
      debugPrint('[ForYou] Top-game stack: $stack');
      _logErrorToSentry(e, stack);
      _cacheFavoritePlayerMatches(
        eventIds: eventIds,
        matchesByEventId: const <String, List<int>>{},
      );
      _writeTopGameSnapshots(
        models: models,
        gamesByEvent: const <String, List<Games>>{},
        replace: replace,
      );
    }
  }

  void _refreshTopGameSnapshotsForLiveSignal() {
    if (!ref.read(shouldStreamProvider)) return;

    final visibleEvents = state.events
        .where(isLiveRefreshingForYouEvent)
        .toList(growable: false);
    if (visibleEvents.isEmpty) return;
    unawaited(_refreshVisibleTopGameSnapshots(visibleEvents));
  }

  Future<void> _refreshVisibleTopGameSnapshots(
    List<GroupEventCardModel> visibleEvents,
  ) async {
    if (_isRefreshingVisibleTopGameSnapshots) return;

    _isRefreshingVisibleTopGameSnapshots = true;
    try {
      final eventIds = visibleEvents
          .map((model) => model.id)
          .where((eventId) => eventId.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (eventIds.isEmpty) return;

      final gameRepository = ref.read(gameRepositoryProvider);
      final gamesByEvent = await gameRepository
          .getForYouTopGamesByEventIds(
            eventIds: eventIds,
            boardsPerEvent: _topGamesPerEventSnapshotLimit,
          )
          .timeout(const Duration(seconds: 6));

      _writeTopGameSnapshots(
        models: visibleEvents,
        gamesByEvent: gamesByEvent,
        replace: false,
      );
      if (mounted) {
        bumpForYouEventsRefreshSignal(ref);
      }
    } catch (e, stack) {
      if (!shouldReportForYouLiveTopGameRefreshFailure(e)) {
        return;
      }
      debugPrint('[ForYou] Live top-game refresh failed: $e');
      debugPrint('[ForYou] Live top-game stack: $stack');
      _logErrorToSentry(e, stack);
    } finally {
      _isRefreshingVisibleTopGameSnapshots = false;
    }
  }

  Future<void> refreshTopGamesForEvent(
    String eventId, {
    String? finishedGameId,
    String? finishedStatus,
  }) async {
    if (eventId.isEmpty) return;

    final normalizedFinishedStatus = finishedStatus?.trim();
    if (finishedGameId != null &&
        finishedGameId.isNotEmpty &&
        normalizedFinishedStatus != null &&
        normalizedFinishedStatus.isNotEmpty) {
      final refreshKey = '$eventId:$finishedGameId:$normalizedFinishedStatus';
      if (!_handledFinishedTopGameRefreshes.add(refreshKey)) return;
    }

    GroupEventCardModel? model;
    for (final event in state.events) {
      if (event.id == eventId) {
        model = event;
        break;
      }
    }
    if (model == null) return;
    await _refreshVisibleTopGameSnapshots([model]);
  }

  void _writeTopGameSnapshots({
    required List<GroupEventCardModel> models,
    required Map<String, List<Games>> gamesByEvent,
    required bool replace,
  }) {
    final snapshots = <String, ForYouEventGamesSnapshot>{};
    for (final model in models) {
      snapshots[model.id] = _topGamesSnapshotFromGames(
        eventId: model.id,
        games: gamesByEvent[model.id] ?? const <Games>[],
      );
    }

    final notifier = ref.read(forYouTopGamesSnapshotCacheProvider.notifier);
    final merged = mergeForYouTopGameSnapshots(
      current: notifier.state,
      incoming: snapshots,
      replace: replace,
    );
    if (!identical(merged, notifier.state)) notifier.state = merged;
  }

  List<GroupEventCardModel> _sortLikeCurrentTab(
    List<GroupEventCardModel> models,
  ) {
    return ref
        .read(tournamentSortingServiceProvider)
        .sortAllTours(
          models,
          eventFavoritePlayersMap: ref.read(eventFavoritePlayersCacheProvider),
        );
  }

  List<GroupEventCardModel> _sortPageOnceForSession(
    List<GroupEventCardModel> models,
  ) {
    if (models.isEmpty) return models;

    final knownEvents = <GroupEventCardModel>[];
    final newEvents = <GroupEventCardModel>[];
    for (final model in models) {
      if (_sessionEventOrder.containsKey(model.id)) {
        knownEvents.add(model);
      } else {
        newEvents.add(model);
      }
    }

    knownEvents.sort(
      (a, b) => _sessionEventOrder[a.id]!.compareTo(_sessionEventOrder[b.id]!),
    );

    final sortedNewEvents = _sortLikeCurrentTab(newEvents);
    for (final event in sortedNewEvents) {
      _sessionEventOrder[event.id] = _nextSessionEventOrder++;
    }

    return [...knownEvents, ...sortedNewEvents];
  }

  void _resortVisibleEventsForFavoriteChange() {
    final current = state.events;
    if (current.isEmpty) return;

    final sorted = _sortLikeCurrentTab(current);
    var changed = false;
    for (var i = 0; i < current.length; i++) {
      if (current[i].id != sorted[i].id) {
        changed = true;
        break;
      }
    }
    if (!changed) return;

    _replaceSessionEventOrder(sorted);
    if (mounted) state = state.copyWith(events: sorted);
  }

  void _replaceSessionEventOrder(List<GroupEventCardModel> events) {
    _sessionEventOrder
      ..clear()
      ..addEntries(
        events.indexed.map((entry) => MapEntry(entry.$2.id, entry.$1)),
      );
    _nextSessionEventOrder = events.length;
  }

  Future<void> _refreshVisibleFavoritePlayerCounts({
    bool finalizeOrderAfterRefresh = false,
  }) async {
    final eventIds = state.events
        .map((event) => event.id)
        .where((eventId) => eventId.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (eventIds.isEmpty) return;

    final matchesByEventId = await _loadFavoritePlayerMatches(
      gameRepository: ref.read(gameRepositoryProvider),
      eventIds: eventIds,
    );
    if (!mounted) return;

    _cacheFavoritePlayerMatches(
      eventIds: eventIds,
      matchesByEventId: matchesByEventId,
    );

    if (finalizeOrderAfterRefresh) {
      _finalizeSessionOrderAfterFavoriteHydration();
    }
  }

  Future<Map<String, List<int>>> _loadFavoritePlayerMatches({
    required GameRepository gameRepository,
    required List<String> eventIds,
    bool allowOrderHydrationFinalize = false,
  }) async {
    try {
      final favoriteFideIds = await _favoriteFideIdsSnapshot(
        allowOrderHydrationFinalize: allowOrderHydrationFinalize,
      );
      if (favoriteFideIds.isEmpty) {
        return <String, List<int>>{};
      }

      return await gameRepository.getForYouFavoritePlayerFideIdsByEventIds(
        eventIds: eventIds,
        favoriteFideIds: favoriteFideIds,
      );
    } catch (e, stack) {
      debugPrint('[ForYou] Favorite player count prefetch failed: $e');
      debugPrint('[ForYou] Favorite player count stack: $stack');
      _logErrorToSentry(e, stack);
      return <String, List<int>>{};
    }
  }

  Future<List<int>> _favoriteFideIdsSnapshot({
    bool allowOrderHydrationFinalize = false,
  }) async {
    final favoritePlayersState = ref.read(favoritePlayersProviderNew);
    final loadedFavorites = favoritePlayersState.valueOrNull;
    if (loadedFavorites != null) {
      return _favoriteFideIdsFrom(loadedFavorites);
    }

    final favorites = await ref
        .read(favoritePlayersProviderNew.future)
        .timeout(
          const Duration(milliseconds: 1500),
          onTimeout: () {
            if (allowOrderHydrationFinalize) {
              _pendingFavoritePlayerOrderHydration = true;
            }
            return const <FavoritePlayer>[];
          },
        );

    return _favoriteFideIdsFrom(favorites);
  }

  void _cacheFavoritePlayerMatches({
    required List<String> eventIds,
    required Map<String, List<int>> matchesByEventId,
  }) {
    final cacheEntries = <String, EventFavoritePlayers>{};
    for (final eventId in eventIds) {
      final fideIds = matchesByEventId[eventId] ?? const <int>[];
      cacheEntries[eventId] = EventFavoritePlayers(
        count: fideIds.length,
        fideIds: List<int>.unmodifiable(fideIds),
      );
    }

    ref
        .read(eventFavoritePlayersCacheProvider.notifier)
        .updateCacheBatch(cacheEntries);
  }

  void _finalizeSessionOrderAfterFavoriteHydration() {
    if (!_pendingFavoritePlayerOrderHydration || state.events.isEmpty) return;

    final sortedEvents = _sortLikeCurrentTab(state.events);
    _sessionEventOrder
      ..clear()
      ..addEntries(
        sortedEvents.indexed.map((entry) => MapEntry(entry.$2.id, entry.$1)),
      );
    _nextSessionEventOrder = sortedEvents.length;
    _pendingFavoritePlayerOrderHydration = false;

    if (mounted) {
      state = state.copyWith(events: sortedEvents);
    }
  }

  void _maybeFinalizePendingFavoritePlayerOrder() {
    if (!_pendingFavoritePlayerOrderHydration || state.events.isEmpty) return;

    final favoriteFideIds = _favoriteFideIdsFrom(
      ref.read(favoritePlayersProviderNew).valueOrNull ??
          const <FavoritePlayer>[],
    );
    if (favoriteFideIds.isEmpty) return;

    unawaited(
      _refreshVisibleFavoritePlayerCounts(finalizeOrderAfterRefresh: true),
    );
  }
}

@visibleForTesting
bool isLiveRefreshingForYouEvent(GroupEventCardModel event) {
  return event.tourEventCategory == TourEventCategory.live ||
      event.tourEventCategory == TourEventCategory.ongoing;
}

@visibleForTesting
bool shouldReportForYouLiveTopGameRefreshFailure(Object error) {
  return error is! TimeoutException;
}

List<int> _favoriteFideIdsFrom(Iterable<FavoritePlayer> favorites) {
  final fideIds = <int>{};
  for (final favorite in favorites) {
    final fideId = int.tryParse(favorite.fideId ?? '');
    if (fideId != null && fideId > 0) {
      fideIds.add(fideId);
    }
  }
  return fideIds.toList(growable: false);
}

ForYouEventGamesSnapshot _topGamesSnapshotFromGames({
  required String eventId,
  required List<Games> games,
}) {
  return buildForYouTopGamesSnapshot(
    eventId: eventId,
    games: games,
    maxGames: _topGamesPerEventSnapshotLimit,
  );
}

final forYouEventsProvider =
    StateNotifierProvider.autoDispose<ForYouNotifier, ForYouState>((ref) {
      ref.keepAlive();
      return ForYouNotifier(ref);
    });

abstract class ForYouPinStorage {
  Future<List<String>> getPinnedGameIds(String tourId);

  Future<void> addPinnedGameId(String tourId, String gameId);

  Future<void> removePinnedGameId(String tourId, String gameId);

  Future<List<String>> getUnpinnedGameIds(String tourId);

  Future<void> addUnpinnedGameId(String tourId, String gameId);

  Future<void> removeUnpinnedGameId(String tourId, String gameId);
}

class _RiverpodForYouPinStorage implements ForYouPinStorage {
  const _RiverpodForYouPinStorage(this._ref);

  final Ref _ref;

  @override
  Future<List<String>> getPinnedGameIds(String tourId) {
    return _ref.read(pinGameLocalStorage).getPinnedGameIds(tourId);
  }

  @override
  Future<void> addPinnedGameId(String tourId, String gameId) {
    return _ref.read(pinGameLocalStorage).addPinnedGameId(tourId, gameId);
  }

  @override
  Future<void> removePinnedGameId(String tourId, String gameId) {
    return _ref.read(pinGameLocalStorage).removePinnedGameId(tourId, gameId);
  }

  @override
  Future<List<String>> getUnpinnedGameIds(String tourId) {
    return _ref.read(pinGameLocalStorage).getUnpinnedGameIds(tourId);
  }

  @override
  Future<void> addUnpinnedGameId(String tourId, String gameId) {
    return _ref.read(pinGameLocalStorage).addUnpinnedGameId(tourId, gameId);
  }

  @override
  Future<void> removeUnpinnedGameId(String tourId, String gameId) {
    return _ref.read(pinGameLocalStorage).removeUnpinnedGameId(tourId, gameId);
  }
}

final forYouPinStorageProvider = Provider<ForYouPinStorage>((ref) {
  return _RiverpodForYouPinStorage(ref);
});

abstract class ForYouPinAction {
  Future<void> togglePin({
    required String eventId,
    required String gameId,
    required String tourId,
  });
}

final forYouPinActionProvider = Provider.autoDispose<ForYouPinAction>(
  (ref) => _ForYouPinActionController(ref),
);

class _ForYouPinActionController implements ForYouPinAction {
  const _ForYouPinActionController(this._ref);

  final Ref _ref;

  @override
  Future<void> togglePin({
    required String eventId,
    required String gameId,
    required String tourId,
  }) async {
    final storage = _ref.read(forYouPinStorageProvider);
    final snapshot =
        _ref.read(forYouEventSnapshotProvider(eventId)).valueOrNull;
    final mode = resolvePinToggleMode(
      isManualPinned:
          snapshot?.manualPinnedIds.contains(gameId) ??
          (await storage.getPinnedGameIds(tourId)).contains(gameId),
      isAutoPinned: snapshot?.autoPinnedIds.contains(gameId) ?? false,
      isOverridden:
          snapshot?.unpinnedOverrideIds.contains(gameId) ??
          (await storage.getUnpinnedGameIds(tourId)).contains(gameId),
    );

    switch (mode) {
      case PinToggleMode.unpinManualOnly:
        await storage.removePinnedGameId(tourId, gameId);
        break;
      case PinToggleMode.unpinWithOverride:
        await Future.wait([
          storage.removePinnedGameId(tourId, gameId),
          storage.addUnpinnedGameId(tourId, gameId),
        ]);
        break;
      case PinToggleMode.repin:
        await Future.wait([
          storage.removeUnpinnedGameId(tourId, gameId),
          storage.addPinnedGameId(tourId, gameId),
        ]);
        break;
    }

    final selectedBroadcast = _ref.read(selectedBroadcastModelProvider);
    final selectedTourId =
        _ref.read(tourDetailScreenProvider).valueOrNull?.aboutTourModel.id;

    if (selectedBroadcast?.id == eventId &&
        selectedTourId != null &&
        selectedTourId.isNotEmpty) {
      _ref.invalidate(gamesPinprovider(selectedTourId));
      _ref.invalidate(gamesTourScreenProvider);
    }

    bumpEventPinRefreshSignal(_ref, eventId);
  }
}

// ============================================================================
// LIVE GAME WATCHER - AUTO-REFRESH WHEN GAMES FINISH
// ============================================================================

/// Watches displayed live games while using only the bounded RPC snapshot as
/// the section's membership source.
///
/// The card widgets consume their own live row data, but this wrapper keeps the
/// section subscribed to the same rendered live rows and refreshes the snapshot
/// as soon as a displayed game finishes.
final forYouEventGamesWithAutoRefreshProvider = Provider.autoDispose.family<
  AsyncValue<ForYouEventGamesSnapshot>,
  String
>((ref, eventId) {
  final snapshotAsync = ref.watch(forYouEventSnapshotProvider(eventId));

  return snapshotAsync.when(
    data: (snapshot) {
      final displayedGames = snapshot.visibleGames
          .take(_topGamesPerEventSnapshotLimit)
          .toList(growable: false);

      if (displayedGames.isNotEmpty && ref.watch(shouldStreamProvider)) {
        final liveBatchKey = forYouEventLiveBatchKey(
          eventId: eventId,
          tourId: snapshot.tourId,
          games: displayedGames,
        );
        final representedIds = liveBatchKey.gameIds.toSet();
        final displayedStreamGames = displayedGames
            .where((game) => representedIds.contains(game.gameId))
            .toList(growable: false);
        if (displayedStreamGames.isEmpty) {
          return AsyncValue.data(snapshot);
        }
        final refreshOnFinishedGameIds =
            displayedStreamGames
                .where((game) => game.gameStatus == GameStatus.ongoing)
                .map((game) => game.gameId)
                .toSet();
        final updatesAsync = ref.watch(
          gameUpdatesBatchStreamProvider(liveBatchKey).select(
            (async) => async.whenData(
              (updates) => _ForYouLiveUpdatesProjection.fromUpdates(
                displayedStreamGames.map((game) => game.gameId),
                updates,
              ),
            ),
          ),
        );

        updatesAsync.whenData((projection) {
          if (projection.updates.isNotEmpty) {
            Future.microtask(() {
              try {
                final cacheNotifier = ref.read(
                  forYouTopGamesSnapshotCacheProvider.notifier,
                );
                final updatedCache =
                    mergeLiveUpdatesIntoForYouTopGameSnapshotCache(
                      cacheNotifier.state,
                      eventId,
                      projection.updates,
                    );
                if (!identical(updatedCache, cacheNotifier.state)) {
                  cacheNotifier.state = updatedCache;
                }
              } on StateError {
                // The section can be disposed while a stream event is queued.
              }
            });
          }

          for (final status in projection.statuses) {
            if (refreshOnFinishedGameIds.contains(status.gameId) &&
                status.status != null &&
                _isFinishedStatus(status.status!)) {
              Future.microtask(() {
                try {
                  ref
                      .read(forYouEventsProvider.notifier)
                      .refreshTopGamesForEvent(
                        eventId,
                        finishedGameId: status.gameId,
                        finishedStatus: status.status!,
                      );
                } on StateError {
                  // The section can be disposed while a stream event is queued.
                }
              });
            }
          }
        });
      }

      return AsyncValue.data(snapshot);
    },
    loading: () => const AsyncValue.loading(),
    error: (e, st) => AsyncValue.error(e, st),
  );
});

@immutable
class _ForYouLiveUpdatesProjection {
  const _ForYouLiveUpdatesProjection({
    required this.updates,
    required this.statuses,
  });

  factory _ForYouLiveUpdatesProjection.fromUpdates(
    Iterable<String> gameIds,
    Map<String, LiveGameUpdate> updates,
  ) {
    final relevantUpdates = <String, LiveGameUpdate>{};
    final statuses = <_LiveGameStatus>[];
    for (final gameId in gameIds) {
      final update = updates[gameId];
      if (update != null) {
        relevantUpdates[gameId] = update;
      }
      statuses.add(_LiveGameStatus(gameId, update?.status));
    }

    return _ForYouLiveUpdatesProjection(
      updates: Map<String, LiveGameUpdate>.unmodifiable(relevantUpdates),
      statuses: List<_LiveGameStatus>.unmodifiable(statuses),
    );
  }

  final Map<String, LiveGameUpdate> updates;
  final List<_LiveGameStatus> statuses;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ForYouLiveUpdatesProjection) return false;
    return mapEquals(updates, other.updates) &&
        listEquals(statuses, other.statuses);
  }

  @override
  int get hashCode {
    return Object.hash(
      Object.hashAll(
        updates.entries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
      Object.hashAll(statuses),
    );
  }
}

@immutable
class _LiveGameStatus {
  const _LiveGameStatus(this.gameId, this.status);

  final String gameId;
  final String? status;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveGameStatus &&
            other.gameId == gameId &&
            other.status == status;
  }

  @override
  int get hashCode => Object.hash(gameId, status);
}

/// Read-only snapshot alias for non-rendering code paths.
final forYouEventSnapshotProvider = Provider.autoDispose
    .family<AsyncValue<ForYouEventGamesSnapshot>, String>((ref, eventId) {
      final snapshot = ref.watch(
        forYouTopGamesSnapshotCacheProvider.select((cache) => cache[eventId]),
      );
      return snapshot == null
          ? const AsyncValue.loading()
          : AsyncValue.data(snapshot);
    });

bool _isFinishedStatus(String status) {
  return GameStatus.fromString(status).isFinished;
}

@visibleForTesting
bool shouldRefreshForYouSnapshotsForLiveRoundIds(
  List<String>? previousRoundIds,
  List<String> nextRoundIds,
) {
  if (previousRoundIds == null) {
    return nextRoundIds.isNotEmpty;
  }

  return !setEquals(previousRoundIds.toSet(), nextRoundIds.toSet());
}

@visibleForTesting
Map<String, ForYouEventGamesSnapshot> removeForYouTopGameSnapshotFromCache(
  Map<String, ForYouEventGamesSnapshot> cache,
  String eventId,
) {
  if (eventId.isEmpty || !cache.containsKey(eventId)) {
    return cache;
  }

  return <String, ForYouEventGamesSnapshot>{...cache}..remove(eventId);
}

@visibleForTesting
Map<String, ForYouEventGamesSnapshot>
mergeLiveUpdatesIntoForYouTopGameSnapshotCache(
  Map<String, ForYouEventGamesSnapshot> cache,
  String eventId,
  Map<String, LiveGameUpdate> updates,
) {
  if (eventId.isEmpty || updates.isEmpty) {
    return cache;
  }

  final snapshot = cache[eventId];
  if (snapshot == null) {
    return cache;
  }

  final updatedSnapshot = mergeLiveUpdatesIntoForYouSnapshot(snapshot, updates);
  if (identical(updatedSnapshot, snapshot)) {
    return cache;
  }

  return <String, ForYouEventGamesSnapshot>{...cache, eventId: updatedSnapshot};
}

@visibleForTesting
ForYouEventGamesSnapshot mergeLiveUpdatesIntoForYouSnapshot(
  ForYouEventGamesSnapshot snapshot,
  Map<String, LiveGameUpdate> updates,
) {
  if (updates.isEmpty || snapshot.visibleGames.isEmpty) {
    return snapshot;
  }

  var changed = false;
  final visibleGames = <GamesTourModel>[];
  for (final game in snapshot.visibleGames) {
    final update = updates[game.gameId];
    if (update == null) {
      visibleGames.add(game);
      continue;
    }

    final mergedGame = mergeLiveGameUpdateWithBase(
      baseGame: game,
      update: update,
    );
    if (hasForYouLiveGameChange(game, mergedGame)) {
      changed = true;
      visibleGames.add(mergedGame);
    } else {
      visibleGames.add(game);
    }
  }

  if (!changed) {
    return snapshot;
  }

  return ForYouEventGamesSnapshot(
    eventId: snapshot.eventId,
    tourId: snapshot.tourId,
    visibleGames: visibleGames,
    pinnedIds: snapshot.pinnedIds,
    isGroupEvent: snapshot.isGroupEvent,
    isKnockoutTournament: snapshot.isKnockoutTournament,
    manualPinnedIds: snapshot.manualPinnedIds,
    autoPinnedIds: snapshot.autoPinnedIds,
    unpinnedOverrideIds: snapshot.unpinnedOverrideIds,
  );
}

@visibleForTesting
bool hasForYouLiveGameChange(GamesTourModel current, GamesTourModel incoming) {
  return current.pgn != incoming.pgn ||
      current.fen != incoming.fen ||
      current.lastMove != incoming.lastMove ||
      current.lastMoveTime != incoming.lastMoveTime ||
      current.whiteClockSeconds != incoming.whiteClockSeconds ||
      current.blackClockSeconds != incoming.blackClockSeconds ||
      current.gameStatus != incoming.gameStatus;
}

// ============================================================================
// BACKWARD COMPATIBILITY
// ============================================================================

final convertedForYouGamesProvider = Provider.autoDispose<List<GamesTourModel>>(
  (ref) {
    return const [];
  },
);
