import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';

/// The event rail deliberately stays below the live-stream batch size's third
/// chunk while still covering substantially more rows than fit on screen.
const int kEventRailGamesPageSize = 64;
const Duration _eventRailSafetyRefreshInterval = Duration(seconds: 5);

String _tournamentIdentity(String tourId, String tourSlug) {
  final slug = tourSlug.trim();
  return slug.isNotEmpty ? 'slug:$slug' : 'id:${tourId.trim()}';
}

String _eventTournamentIdentity(BoardTabEventGamesKey key) {
  return _tournamentIdentity(key.tourId, key.tourSlug);
}

@immutable
class EventRailGamesState {
  const EventRailGamesState({
    this.games = const <TournamentGameSummary>[],
    this.nextOffset = 0,
    this.totalCount,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  final List<TournamentGameSummary> games;

  /// Offset into the canonical tour-wide query. The selected-round window is
  /// merged separately and therefore never advances this cursor.
  final int nextOffset;
  final int? totalCount;
  final bool hasMore;
  final bool isLoadingMore;
  final String? loadMoreError;

  EventRailGamesState copyWith({
    List<TournamentGameSummary>? games,
    int? nextOffset,
    int? totalCount,
    bool? hasMore,
    bool? isLoadingMore,
    String? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return EventRailGamesState(
      games: games ?? this.games,
      nextOffset: nextOffset ?? this.nextOffset,
      totalCount: totalCount ?? this.totalCount,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError:
          clearLoadMoreError ? null : loadMoreError ?? this.loadMoreError,
    );
  }
}

/// Identifies one retained Board tab's lightweight tournament rail.
///
/// Separate tabs can intentionally open the same game. Keeping [ownerId] out
/// of [BoardTabEventGamesKey] preserves the serialized continuation payload,
/// while preventing one hidden duplicate tab from pausing another tab's
/// periodic metadata refresh.
@immutable
class EventRailGamesProviderKey {
  const EventRailGamesProviderKey({
    required this.ownerId,
    required this.eventKey,
  });

  final String ownerId;
  final BoardTabEventGamesKey eventKey;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EventRailGamesProviderKey &&
            other.ownerId == ownerId &&
            _eventTournamentIdentity(other.eventKey) ==
                _eventTournamentIdentity(eventKey);
  }

  @override
  int get hashCode => Object.hash(ownerId, _eventTournamentIdentity(eventKey));

  @override
  String toString() => '$ownerId:${_eventTournamentIdentity(eventKey)}';
}

/// Per-Board-tab tournament continuation.
///
/// The first state is published atomically after four bounded operations run
/// concurrently: an exact count, one tour page, one page around the selected
/// board's round, and the selected metadata row itself. Rows contain
/// metadata/FEN only; PGN hydration remains the existing on-open
/// responsibility of the active game.
final eventRailGamesProvider = AutoDisposeAsyncNotifierProvider.family<
  EventRailGamesNotifier,
  EventRailGamesState,
  EventRailGamesProviderKey
>(EventRailGamesNotifier.new);

/// Authoritative round headings for a tournament rail.
///
/// This query is O(round count) and deliberately independent from paginated
/// game hydration. A round therefore remains representable even when none of
/// its games are present in the bounded event-game seed.
@immutable
class EventRailRoundCatalogKey {
  const EventRailRoundCatalogKey({
    required this.ownerId,
    required this.tourId,
    this.tourSlug = '',
  });

  final String ownerId;
  final String tourId;
  final String tourSlug;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EventRailRoundCatalogKey &&
            other.ownerId == ownerId &&
            _tournamentIdentity(other.tourId, other.tourSlug) ==
                _tournamentIdentity(tourId, tourSlug);
  }

  @override
  int get hashCode =>
      Object.hash(ownerId, _tournamentIdentity(tourId, tourSlug));
}

final eventRailRoundCatalogProvider = AutoDisposeAsyncNotifierProvider.family<
  EventRailRoundCatalogNotifier,
  List<EventRailRoundMetadata>,
  EventRailRoundCatalogKey
>(EventRailRoundCatalogNotifier.new);

class EventRailRoundCatalogNotifier
    extends
        AutoDisposeFamilyAsyncNotifier<
          List<EventRailRoundMetadata>,
          EventRailRoundCatalogKey
        > {
  Timer? _refreshTimer;
  bool _disposed = false;
  bool _refreshing = false;
  bool _foreground = true;
  int _requestEpoch = 0;
  late String _tourId;
  late String _tourSlug;

  @override
  Future<List<EventRailRoundMetadata>> build(
    EventRailRoundCatalogKey key,
  ) async {
    _disposed = false;
    _foreground = true;
    _requestEpoch = 0;
    _tourId = key.tourId.trim();
    _tourSlug = key.tourSlug.trim();
    ref.onDispose(() {
      _disposed = true;
      _refreshTimer?.cancel();
      _refreshTimer = null;
    });
    if (_tourId.isEmpty) return const <EventRailRoundMetadata>[];
    _refreshing = true;
    final requestEpoch = _requestEpoch;
    try {
      final catalog = await ref
          .watch(gameRepositoryProvider)
          .getEventRailRoundsByTournamentIdentity(
            tourId: _tourId,
            tourSlug: _tourSlug,
          );
      if (_disposed || !_foreground || requestEpoch != _requestEpoch) {
        return state.valueOrNull ?? const <EventRailRoundMetadata>[];
      }
      return catalog;
    } finally {
      _refreshing = false;
      if (!_disposed && _foreground) _scheduleRefresh();
    }
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _requestEpoch++;
      _refreshTimer?.cancel();
      _refreshTimer = null;
      return;
    }
    _scheduleRefresh();
    unawaited(refreshCatalog());
  }

  void _scheduleRefresh() {
    if (_disposed || !_foreground || _tourId.isEmpty) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      _eventRailSafetyRefreshInterval,
      (_) => unawaited(refreshCatalog()),
    );
  }

  Future<void> refreshCatalog() async {
    if (_disposed || !_foreground || _refreshing || _tourId.isEmpty) return;
    _refreshing = true;
    final requestEpoch = _requestEpoch;
    try {
      final catalog = await ref
          .read(gameRepositoryProvider)
          .getEventRailRoundsByTournamentIdentity(
            tourId: _tourId,
            tourSlug: _tourSlug,
          );
      if (!_disposed && _foreground && requestEpoch == _requestEpoch) {
        state = AsyncData(catalog);
      }
    } catch (error, stackTrace) {
      // Preserve a previously successful catalog during transient outages.
      if (!_disposed &&
          _foreground &&
          requestEpoch == _requestEpoch &&
          state.valueOrNull == null) {
        state = AsyncError(error, stackTrace);
      }
    } finally {
      _refreshing = false;
      if (!_disposed && _foreground && requestEpoch != _requestEpoch) {
        scheduleMicrotask(refreshCatalog);
      }
    }
  }
}

/// Identifies one player's complete lightweight history inside one event.
///
/// Unlike [EventRailGamesProviderKey], this query is immutable and can be
/// shared by duplicate Board tabs. It contains metadata only and is requested
/// lazily after the player-name hover intent succeeds.
@immutable
class EventRailPlayerGamesKey {
  const EventRailPlayerGamesKey({
    required this.tourId,
    required this.playerName,
    this.fideId,
  });

  final String tourId;
  final String playerName;
  final int? fideId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EventRailPlayerGamesKey &&
            other.tourId.trim() == tourId.trim() &&
            other.playerName.trim() == playerName.trim() &&
            other.fideId == fideId;
  }

  @override
  int get hashCode => Object.hash(tourId.trim(), playerName.trim(), fideId);
}

final eventRailPlayerGamesProvider = FutureProvider.autoDispose.family<
  List<TournamentGameSummary>,
  EventRailPlayerGamesKey
>((ref, key) async {
  final rows = await ref
      .read(gameRepositoryProvider)
      .getEventGamesByPlayer(
        tourId: key.tourId,
        fideId: key.fideId,
        playerName: key.playerName,
      );
  final games = <TournamentGameSummary>[];
  for (final row in rows) {
    try {
      games.add(TournamentGameSummary.fromGame(row));
    } catch (_) {
      // A malformed legacy row must not hide the player's other valid rounds.
    }
  }
  return List<TournamentGameSummary>.unmodifiable(games);
});

class EventRailGamesNotifier
    extends
        AutoDisposeFamilyAsyncNotifier<
          EventRailGamesState,
          EventRailGamesProviderKey
        > {
  Timer? _safetyRefreshTimer;
  bool _refreshInFlight = false;
  bool _selectionRefreshInFlight = false;
  bool _navigationHydrationInFlight = false;
  Completer<void>? _selectionRefreshCompletion;
  Completer<bool>? _loadMoreCompletion;
  Completer<bool>? _refreshCompletion;
  Completer<bool>? _navigationHydrationCompletion;
  int? _navigationHydrationActivityEpoch;
  int? _navigationHydrationSelectionEpoch;
  Completer<void>? _initialLoadCompletion;
  Future<void> _roundHydrationTail = Future<void>.value();
  final Map<String, Future<bool>> _roundHydrationFutures =
      <String, Future<bool>>{};
  final Set<String> _hydratedRoundKeys = <String>{};
  final Set<String> _emptyHydratedRoundKeys = <String>{};
  bool _disposed = false;
  bool _tabForeground = true;
  bool _lifecycleAllowsStreaming = true;
  bool _refreshRequested = false;
  bool _fullRefreshRequested = false;
  bool _selectionRefreshNeeded = false;
  int _activityEpoch = 0;
  int _selectionEpoch = 0;
  int? _selectedContextHydratedSelectionEpoch;
  late BoardTabEventGamesKey _eventKey;
  final Map<int, List<String>> _canonicalPageIdsByOffset =
      <int, List<String>>{};
  int _nextSafetyPageOffset = kEventRailGamesPageSize;
  List<String> _selectedRoundPageIds = const <String>[];
  Games? _selectedGameSeed;
  bool _selectedRoundBaselineInitialized = false;
  String? _navigationTargetGameId;
  List<String> _navigationTargetRoundIds = const <String>[];

  bool get _isActive => _tabForeground && _lifecycleAllowsStreaming;
  String? get navigationTargetGameId => _navigationTargetGameId;
  List<String> get navigationTargetRoundIds => _navigationTargetRoundIds;

  @override
  Future<EventRailGamesState> build(EventRailGamesProviderKey arg) async {
    _disposed = false;
    _tabForeground = true;
    _lifecycleAllowsStreaming = ref.read(liveGameStreamingLifecycleProvider);
    _refreshRequested = false;
    _fullRefreshRequested = false;
    _selectionRefreshNeeded = false;
    _selectionRefreshInFlight = false;
    _navigationHydrationInFlight = false;
    _loadMoreCompletion = null;
    _refreshCompletion = null;
    _navigationHydrationCompletion = null;
    _navigationHydrationActivityEpoch = null;
    _navigationHydrationSelectionEpoch = null;
    _roundHydrationFutures.clear();
    _roundHydrationTail = Future<void>.value();
    _hydratedRoundKeys.clear();
    _emptyHydratedRoundKeys.clear();
    _activityEpoch++;
    _selectionEpoch++;
    _eventKey = arg.eventKey;
    _stopSafetyRefresh();
    _canonicalPageIdsByOffset.clear();
    _nextSafetyPageOffset = kEventRailGamesPageSize;
    _selectedRoundPageIds = const <String>[];
    _selectedGameSeed = null;
    _selectedRoundBaselineInitialized = false;
    _navigationTargetGameId = null;
    _navigationTargetRoundIds = const <String>[];
    _selectedContextHydratedSelectionEpoch = null;
    final initialLoadCompletion = Completer<void>();
    _initialLoadCompletion = initialLoadCompletion;
    ref.listen<bool>(liveGameStreamingLifecycleProvider, (_, next) {
      _setLifecycleAllowsStreaming(next);
    });
    ref.onDispose(() {
      _disposed = true;
      _activityEpoch++;
      _selectionEpoch++;
      _stopSafetyRefresh();
      if (!initialLoadCompletion.isCompleted) {
        initialLoadCompletion.complete();
      }
    });

    try {
      final eventKey = _eventKey;
      final buildSelectionEpoch = _selectionEpoch;
      final tourId = eventKey.tourId.trim();
      if (tourId.isEmpty) return const EventRailGamesState();

      final repository = ref.watch(gameRepositoryProvider);
      final tourPageFuture = _loadInitialTourPage(repository, eventKey);
      final roundPageFuture = _loadSelectedRoundWindowOrEmpty(
        repository,
        eventKey,
      );
      final selectedGameFuture = _loadSelectedGameOrEmpty(repository, eventKey);
      final totalCountFuture = _loadTotalCount(repository, eventKey);

      final auxiliaryPagesFuture = Future.wait(<Future<List<Games>>>[
        roundPageFuture,
        selectedGameFuture,
      ]);
      final tourPageResult = await tourPageFuture;
      final auxiliaryPages = await auxiliaryPagesFuture;
      final tourPage = tourPageResult.games;
      final selectedRoundPage = auxiliaryPages[0];
      final selectedGamePage = auxiliaryPages[1];
      final totalCount = await totalCountFuture;
      final nextOffset = tourPage.length;
      final pageCanContinue = tourPage.length >= kEventRailGamesPageSize;
      _canonicalPageIdsByOffset[0] = _gameIds(tourPage);
      if (buildSelectionEpoch == _selectionEpoch) {
        _selectedRoundPageIds = _gameIds(selectedRoundPage);
        _selectedRoundBaselineInitialized = true;
        if (selectedRoundPage.isNotEmpty ||
            eventKey.selectedRoundId.trim().isEmpty) {
          _selectedContextHydratedSelectionEpoch = buildSelectionEpoch;
        }
        _selectedGameSeed =
            selectedGamePage.isEmpty ? null : selectedGamePage.first;
      }

      final initial = EventRailGamesState(
        games: _mergeMetadataPages(<Games>[
          ...selectedGamePage,
          ...selectedRoundPage,
        ], tourPage),
        nextOffset: nextOffset,
        totalCount: totalCount,
        hasMore:
            tourPageResult.error != null
                ? totalCount == null || totalCount > 0
                : pageCanContinue &&
                    (totalCount == null || nextOffset < totalCount),
        loadMoreError: tourPageResult.error,
      );
      if (!_disposed) {
        _startSafetyRefresh();
        if (_selectionRefreshNeeded && _isActive) {
          _refreshRequested = true;
          scheduleMicrotask(_runRequestedRefresh);
        }
      }
      return initial;
    } finally {
      if (identical(_initialLoadCompletion, initialLoadCompletion)) {
        _initialLoadCompletion = null;
      }
      if (!initialLoadCompletion.isCompleted) {
        initialLoadCompletion.complete();
      }
    }
  }

  /// Keeps a mounted background Board tab's cached rail intact while stopping
  /// its periodic REST work. The visible tab refreshes once on reactivation,
  /// then resumes the normal safety cadence.
  void setForeground(bool foreground) {
    if (_disposed || _tabForeground == foreground) return;
    final wasActive = _isActive;
    _tabForeground = foreground;
    _handleActivityTransition(wasActive);
  }

  void _setLifecycleAllowsStreaming(bool allowsStreaming) {
    if (_disposed || _lifecycleAllowsStreaming == allowsStreaming) return;
    final wasActive = _isActive;
    _lifecycleAllowsStreaming = allowsStreaming;
    _handleActivityTransition(wasActive);
  }

  void _handleActivityTransition(bool wasActive) {
    final isActive = _isActive;
    if (wasActive == isActive) return;
    _activityEpoch++;
    if (!isActive) {
      _refreshRequested = false;
      _fullRefreshRequested = false;
      _stopSafetyRefresh();
      final current = state.valueOrNull;
      if (current?.isLoadingMore == true) {
        state = AsyncData(current!.copyWith(isLoadingMore: false));
      }
      return;
    }
    _startSafetyRefresh();
    _refreshRequested = true;
    _fullRefreshRequested = true;
    unawaited(_runRequestedRefresh());
  }

  /// Updates the selected game without replacing the retained canonical
  /// pages for this Board tab and tournament.
  ///
  /// The provider family is intentionally identified only by owner+event.
  /// Selection is mutable context: navigating within a tournament must not
  /// throw away the cursor and re-download count/first-page metadata.
  void updateSelection(BoardTabEventGamesKey selection) {
    if (_disposed ||
        _eventTournamentIdentity(selection) !=
            _eventTournamentIdentity(_eventKey) ||
        selection == _eventKey) {
      return;
    }

    final previousRoundId = _eventKey.selectedRoundId.trim();
    _eventKey = selection;
    _selectionEpoch++;
    _navigationTargetGameId = null;
    _navigationTargetRoundIds = const <String>[];
    if (selection.selectedRoundId.trim() != previousRoundId) {
      _selectedRoundPageIds = const <String>[];
      _selectedRoundBaselineInitialized = false;
    }

    final selectedId = selection.selectedGameId.trim();
    final current = state.valueOrNull;
    final alreadyLoaded =
        selectedId.isEmpty ||
        (current?.games.any((game) => game.id == selectedId) ?? false);
    _selectionRefreshNeeded = !alreadyLoaded;
    if (_selectionRefreshNeeded && _isActive) {
      _refreshRequested = true;
      unawaited(_runRequestedRefresh());
    }
  }

  /// Ensures keyboard navigation has a contiguous bounded window on both sides
  /// of the current selection.
  ///
  /// The rail intentionally merges canonical page zero with a selected-round
  /// window. That union can be sparse (for example boards 1-64 plus 468-531).
  /// Before index-based navigation, re-center the one-page round window when
  /// the selected row is absent or touches either edge, so +/-1 cannot jump
  /// across an unloaded gap. The operation stays bounded to one metadata page.
  Future<bool> ensureSelectionWindow() async {
    if (_disposed || !_isActive) return false;
    final selectedId = _eventKey.selectedGameId.trim();
    final roundId = _eventKey.selectedRoundId.trim();
    if (selectedId.isEmpty || roundId.isEmpty) return false;

    final selectedIndex = _selectedRoundPageIds.indexOf(selectedId);
    final hasBothNeighbors =
        selectedIndex > 0 && selectedIndex < _selectedRoundPageIds.length - 1;
    if (hasBothNeighbors) return false;
    if (_selectedContextHydratedSelectionEpoch == _selectionEpoch) return false;

    var attempted = false;
    // One pass may only await an older in-flight selection refresh. Retry once
    // if that request was invalidated by [_selectionEpoch] and therefore did
    // not hydrate the selection navigation is currently anchored to.
    for (var attempt = 0; attempt < 2; attempt++) {
      _selectionRefreshNeeded = true;
      await _refreshSelectedContext();
      attempted = true;
      if (_selectedContextHydratedSelectionEpoch == _selectionEpoch ||
          _disposed ||
          !_isActive) {
        break;
      }
    }
    return attempted;
  }

  /// Proves that the row in [delta]'s direction is genuinely adjacent before
  /// index-based keyboard navigation uses the merged rail.
  ///
  /// A selected-round window is sufficient while the selection has another
  /// board in that same round. At a round edge, load the small round catalog and
  /// only the adjacent round's boundary page. This proves display adjacency
  /// without draining every game in a 1,000-board event. The exceptional
  /// fallback still walks canonical metadata if the round catalog is missing,
  /// preserving navigation rather than guessing.
  Future<bool> ensureNavigationAdjacency(int delta) async {
    if (_disposed || !_isActive || delta == 0) return false;
    final eventKey = _eventKey;
    final activityEpoch = _activityEpoch;
    final selectionEpoch = _selectionEpoch;
    final selectedId = eventKey.selectedGameId.trim();
    if (selectedId.isEmpty) return false;

    final pendingNavigation = _navigationHydrationCompletion;
    if (pendingNavigation != null) {
      if (_navigationHydrationActivityEpoch == activityEpoch &&
          _navigationHydrationSelectionEpoch == selectionEpoch) {
        return pendingNavigation.future;
      }
      return false;
    }
    _navigationTargetGameId = null;
    _navigationTargetRoundIds = const <String>[];

    await _awaitPendingRailMutation();
    if (!_navigationContextIsCurrent(
      eventKey: eventKey,
      activityEpoch: activityEpoch,
      selectionEpoch: selectionEpoch,
    )) {
      return false;
    }
    final loadedNeighborId = _loadedPlainRoundNeighborId(eventKey, delta);
    if (loadedNeighborId != null) {
      _navigationTargetGameId = loadedNeighborId;
      return true;
    }

    if (eventKey.selectedRoundId.trim().isNotEmpty) {
      await ensureSelectionWindow();
      if (!_navigationContextIsCurrent(
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
      )) {
        return false;
      }

      final selectedSummary =
          state.valueOrNull?.games
              .where((game) => game.id.trim() == selectedId)
              .firstOrNull;
      final isMultiLegMatch =
          selectedSummary != null &&
          _isEventRailMatchSlug(selectedSummary.roundSlug);
      final roundIndex = _selectedRoundPageIds.indexOf(selectedId);
      final hasSameRoundNeighbor =
          !isMultiLegMatch &&
          (delta < 0
              ? roundIndex > 0
              : roundIndex >= 0 &&
                  roundIndex < _selectedRoundPageIds.length - 1);
      if (hasSameRoundNeighbor) {
        _navigationTargetGameId =
            _selectedRoundPageIds[roundIndex + (delta < 0 ? -1 : 1)];
        return true;
      }
    }

    _navigationHydrationInFlight = true;
    final completion = Completer<bool>();
    _navigationHydrationCompletion = completion;
    _navigationHydrationActivityEpoch = activityEpoch;
    _navigationHydrationSelectionEpoch = selectionEpoch;
    var result = false;
    try {
      result = await _hydrateAdjacentStageMetadata(
        delta,
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
      );
      return result;
    } finally {
      if (identical(_navigationHydrationCompletion, completion)) {
        _navigationHydrationInFlight = false;
        _navigationHydrationCompletion = null;
        _navigationHydrationActivityEpoch = null;
        _navigationHydrationSelectionEpoch = null;
      }
      if (!completion.isCompleted) completion.complete(result);
      if (_refreshRequested && _isActive && !_disposed) {
        scheduleMicrotask(_runRequestedRefresh);
      }
    }
  }

  bool _navigationContextIsCurrent({
    required BoardTabEventGamesKey eventKey,
    required int activityEpoch,
    required int selectionEpoch,
  }) {
    return !_disposed &&
        _isActive &&
        activityEpoch == _activityEpoch &&
        selectionEpoch == _selectionEpoch &&
        eventKey == _eventKey;
  }

  String? _loadedPlainRoundNeighborId(
    BoardTabEventGamesKey eventKey,
    int delta,
  ) {
    final selectedId = eventKey.selectedGameId.trim();
    final selectedRoundId = eventKey.selectedRoundId.trim();
    if (selectedId.isEmpty || selectedRoundId.isEmpty) return null;
    final rows = state.valueOrNull?.games
        .where((game) => game.roundId.trim() == selectedRoundId)
        .toList(growable: false);
    if (rows == null || rows.isEmpty) return null;
    final selected =
        rows.where((game) => game.id.trim() == selectedId).firstOrNull;
    if (selected == null || _isEventRailMatchSlug(selected.roundSlug)) {
      return null;
    }
    rows.sort((a, b) {
      final boardCompare = (a.boardNumber ?? (1 << 30)).compareTo(
        b.boardNumber ?? (1 << 30),
      );
      if (boardCompare != 0) return boardCompare;
      return a.id.compareTo(b.id);
    });
    final index = rows.indexWhere((game) => game.id.trim() == selectedId);
    final targetIndex = index + (delta < 0 ? -1 : 1);
    if (index < 0 || targetIndex < 0 || targetIndex >= rows.length) return null;
    final selectedBoard = rows[index].boardNumber;
    final targetBoard = rows[targetIndex].boardNumber;
    if (selectedBoard == null ||
        targetBoard == null ||
        targetBoard != selectedBoard + (delta < 0 ? -1 : 1)) {
      return null;
    }
    return rows[targetIndex].id;
  }

  Future<void> _awaitPendingRailMutation({
    bool waitForRoundHydrations = true,
  }) async {
    while (!_disposed && _isActive) {
      final load = _loadMoreCompletion;
      if (load != null) {
        await load.future;
        continue;
      }
      final selection = _selectionRefreshCompletion;
      if (selection != null) {
        await selection.future;
        continue;
      }
      final refresh = _refreshCompletion;
      if (refresh != null) {
        await refresh.future;
        continue;
      }
      if (waitForRoundHydrations && _roundHydrationFutures.isNotEmpty) {
        await _roundHydrationTail;
        continue;
      }
      return;
    }
  }

  Future<bool> _hydrateAdjacentStageMetadata(
    int delta, {
    required BoardTabEventGamesKey eventKey,
    required int activityEpoch,
    required int selectionEpoch,
  }) async {
    final repository = ref.read(gameRepositoryProvider);
    final tourId = eventKey.tourId.trim();
    final selectedRoundId = eventKey.selectedRoundId.trim();
    if (tourId.isEmpty || selectedRoundId.isEmpty) return false;

    try {
      // Always refresh this catalog at a round edge. Live broadcasts can append
      // rounds while a Board tab remains retained for hours.
      final catalog = await repository.getEventRailRoundsByTourId(tourId);
      if (!_navigationContextIsCurrent(
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
      )) {
        return false;
      }
      final stages = _orderedNavigationStages(catalog);
      final currentIndex = stages.indexWhere(
        (stage) => stage.roundIds.contains(selectedRoundId),
      );
      // Catalog metadata is the only bounded proof of cross-round adjacency.
      // When it is unavailable, one canonical continuation page may still
      // prove the adjacent row. Never loop through the remaining event.
      if (currentIndex < 0) {
        return _loadOneCanonicalNavigationPage(
          eventKey: eventKey,
          activityEpoch: activityEpoch,
          selectionEpoch: selectionEpoch,
          delta: delta,
        );
      }

      final currentStage = stages[currentIndex];
      final currentRows =
          currentStage.roundIds.length > 1
              ? await _loadNavigationMatchup(
                repository,
                currentStage,
                eventKey: eventKey,
              )
              : await _loadNavigationStageBoundary(
                repository,
                currentStage,
                boundaryDelta: -delta,
              );
      if (!_navigationContextIsCurrent(
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
      )) {
        return false;
      }
      _mergeNavigationMetadata(currentRows);
      final currentNeighborId = _directionalNeighborId(
        currentRows,
        selectedId: eventKey.selectedGameId,
        delta: delta,
      );
      if (currentNeighborId != null) {
        _navigationTargetGameId = currentNeighborId;
        return true;
      }

      final targetIndex = currentIndex + (delta < 0 ? -1 : 1);
      if (targetIndex < 0 || targetIndex >= stages.length) return false;
      final targetStage = stages[targetIndex];
      final rows = await _loadNavigationStageBoundary(
        repository,
        targetStage,
        boundaryDelta: delta,
      );
      if (!_navigationContextIsCurrent(
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
      )) {
        return false;
      }
      _mergeNavigationMetadata(rows);
      final targetId = _boundaryRepresentableGameId(rows, delta: delta);
      if (targetId == null) return false;
      _navigationTargetGameId = targetId;
      _navigationTargetRoundIds = List<String>.unmodifiable(
        targetStage.roundIds,
      );
      return true;
    } catch (_) {
      return _loadOneCanonicalNavigationPage(
        eventKey: eventKey,
        activityEpoch: activityEpoch,
        selectionEpoch: selectionEpoch,
        delta: delta,
      );
    }
  }

  Future<bool> _loadOneCanonicalNavigationPage({
    required BoardTabEventGamesKey eventKey,
    required int activityEpoch,
    required int selectionEpoch,
    required int delta,
  }) async {
    if (state.valueOrNull?.hasMore != true) return false;
    final loaded = await _loadMorePage(forNavigation: true);
    if (!loaded ||
        !_navigationContextIsCurrent(
          eventKey: eventKey,
          activityEpoch: activityEpoch,
          selectionEpoch: selectionEpoch,
        )) {
      return false;
    }

    final canonicalIds = <String>[];
    final offsets = _canonicalPageIdsByOffset.keys.toList()..sort();
    for (final offset in offsets) {
      for (final id in _canonicalPageIdsByOffset[offset] ?? const <String>[]) {
        if (id.trim().isNotEmpty && !canonicalIds.contains(id)) {
          canonicalIds.add(id);
        }
      }
    }
    final selectedIndex = canonicalIds.indexOf(eventKey.selectedGameId.trim());
    final targetIndex = selectedIndex + (delta < 0 ? -1 : 1);
    if (selectedIndex < 0 ||
        targetIndex < 0 ||
        targetIndex >= canonicalIds.length) {
      return false;
    }
    final targetId = canonicalIds[targetIndex];
    final target =
        state.valueOrNull?.games
            .where((game) => game.id.trim() == targetId)
            .firstOrNull;
    if (target == null ||
        !_isResolvedEventRailPlayer(target.whitePlayer) ||
        !_isResolvedEventRailPlayer(target.blackPlayer)) {
      return false;
    }
    _navigationTargetGameId = targetId;
    return true;
  }

  Future<List<Games>> _loadNavigationStageBoundary(
    GameRepository repository,
    _EventRailNavigationStage stage, {
    required int boundaryDelta,
  }) async {
    final roundIds = stage.roundIds;
    final count = await repository.countEventRailGamesByRoundIds(roundIds);
    if (count <= 0) return const <Games>[];
    final offset =
        boundaryDelta < 0 ? math.max(0, count - kEventRailGamesPageSize) : 0;
    return repository.getEventRailGamesByRoundIds(
      roundIds,
      limit: kEventRailGamesPageSize,
      offset: offset,
    );
  }

  Future<List<Games>> _loadNavigationMatchup(
    GameRepository repository,
    _EventRailNavigationStage stage, {
    required BoardTabEventGamesKey eventKey,
  }) async {
    final selectedId = eventKey.selectedGameId.trim();
    final selected =
        state.valueOrNull?.games
            .where((game) => game.id.trim() == selectedId)
            .firstOrNull;
    if (selected == null) return const <Games>[];

    var playerName = selected.whitePlayer.trim();
    var fideId = selected.whiteFideId;
    if (playerName.isEmpty) {
      playerName = selected.blackPlayer.trim();
      fideId = selected.blackFideId;
    }
    if (playerName.isEmpty) return const <Games>[];

    final selectedPair = _eventRailPairKey(
      selected.whitePlayer,
      selected.blackPlayer,
    );
    final roundIds = stage.roundIds.toSet();
    final rows = await repository.getEventGamesByPlayer(
      tourId: eventKey.tourId.trim(),
      fideId: fideId,
      playerName: playerName,
    );
    final matchup = rows
        .where((game) {
          if (!roundIds.contains(game.roundId.trim())) return false;
          final players = game.players;
          if (players == null || players.length < 2) return false;
          return _eventRailPairKey(players[0].name, players[1].name) ==
              selectedPair;
        })
        .toList(growable: false);
    matchup.sort((a, b) {
      final slugCompare = compareEventRailMatchGameSlugs(
        a.roundSlug,
        b.roundSlug,
      );
      if (slugCompare != 0) return slugCompare;
      final boardCompare = (a.boardNr ?? 1 << 30).compareTo(
        b.boardNr ?? 1 << 30,
      );
      if (boardCompare != 0) return boardCompare;
      return a.id.compareTo(b.id);
    });
    return matchup;
  }

  void _mergeNavigationMetadata(List<Games> rows) {
    if (rows.isEmpty) return;
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore) return;
    final games = _mergeSelectedContextMetadata(current.games, rows);
    if (!_eventRailGameListsEqual(current.games, games)) {
      state = AsyncData(current.copyWith(games: games));
    }
  }

  Future<void> _runRequestedRefresh() async {
    if (_disposed ||
        !_isActive ||
        !_refreshRequested ||
        _refreshInFlight ||
        _selectionRefreshInFlight ||
        _navigationHydrationInFlight ||
        state.valueOrNull?.isLoadingMore == true) {
      return;
    }

    _refreshRequested = false;
    final shouldRefreshAllMetadata = _fullRefreshRequested;
    _fullRefreshRequested = false;

    if (_selectionRefreshNeeded) {
      await _refreshSelectedContext();
    }
    if (_disposed || !_isActive) return;

    final currentAfterSelection = state.valueOrNull;
    if (currentAfterSelection?.loadMoreError != null &&
        currentAfterSelection?.hasMore == true) {
      await loadMore();
    }
    if (_disposed || !_isActive || !shouldRefreshAllMetadata) return;
    await refreshLoadedMetadata();
  }

  Future<void> _refreshSelectedContext() async {
    if (_selectionRefreshInFlight) {
      await _selectionRefreshCompletion?.future;
      return;
    }
    final initial = state.valueOrNull;
    if (initial == null || initial.isLoadingMore || _disposed || !_isActive) {
      return;
    }

    _selectionRefreshInFlight = true;
    final completion = Completer<void>();
    _selectionRefreshCompletion = completion;
    final eventKey = _eventKey;
    final activityEpoch = _activityEpoch;
    final selectionEpoch = _selectionEpoch;
    try {
      final repository = ref.read(gameRepositoryProvider);
      final pages = await Future.wait(<Future<List<Games>>>[
        _loadSelectedRoundWindowOrEmpty(repository, eventKey),
        _loadSelectedGameOrEmpty(repository, eventKey),
      ]);
      if (_disposed ||
          !_isActive ||
          activityEpoch != _activityEpoch ||
          selectionEpoch != _selectionEpoch) {
        return;
      }

      final latest = state.valueOrNull;
      if (latest == null || latest.isLoadingMore) return;
      final roundPage = pages[0];
      final selectedPage = pages[1];
      if (selectedPage.isNotEmpty) _selectedGameSeed = selectedPage.first;
      if (roundPage.isNotEmpty || eventKey.selectedRoundId.trim().isEmpty) {
        _selectedRoundPageIds = _gameIds(roundPage);
        _selectedRoundBaselineInitialized = true;
        _selectedContextHydratedSelectionEpoch = selectionEpoch;
      }
      final games = _mergeSelectedContextMetadata(latest.games, <Games>[
        ...selectedPage,
        ...roundPage,
      ]);
      final selectedId = eventKey.selectedGameId.trim();
      _selectionRefreshNeeded =
          selectedId.isNotEmpty && !games.any((game) => game.id == selectedId);
      if (!_eventRailGameListsEqual(latest.games, games)) {
        state = AsyncData(latest.copyWith(games: games));
      }
    } finally {
      _selectionRefreshInFlight = false;
      _selectionRefreshCompletion = null;
      if (!completion.isCompleted) completion.complete();
      if (_refreshRequested && _isActive && !_disposed) {
        scheduleMicrotask(_runRequestedRefresh);
      }
    }
  }

  Future<bool> loadMore() => _loadMorePage();

  /// Hydrates one expanded catalog round without draining tour-wide pages.
  ///
  /// The first round-local metadata page is enough for normal tournaments and
  /// remains bounded for very large opens. Round existence itself comes from
  /// [eventRailRoundCatalogProvider], not from this game query.
  Future<bool> ensureRoundLoaded(List<String> rawRoundIds) {
    if (_disposed || !_isActive) return Future<bool>.value(false);

    final roundIds = rawRoundIds
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toSet()
      .toList(growable: false)..sort();
    if (roundIds.isEmpty) return Future<bool>.value(false);
    final hydrationKey = roundIds.join('|');
    if (_hydratedRoundKeys.contains(hydrationKey)) {
      return Future<bool>.value(true);
    }
    final pending = _roundHydrationFutures[hydrationKey];
    if (pending != null) return pending;

    final previous = _roundHydrationTail;
    final activityEpoch = _activityEpoch;
    late final Future<bool> hydration;
    hydration = () async {
      try {
        await previous;
        final initialLoad = _initialLoadCompletion;
        if (initialLoad != null) await initialLoad.future;
        await _awaitPendingRailMutation(waitForRoundHydrations: false);
        if (_disposed || !_isActive || activityEpoch != _activityEpoch) {
          return false;
        }

        final repository = ref.read(gameRepositoryProvider);
        final page = await repository.getEventRailGamesByRoundIds(
          roundIds,
          limit: kEventRailGamesPageSize,
          offset: 0,
        );
        if (_disposed || !_isActive || activityEpoch != _activityEpoch) {
          return false;
        }

        final current = state.valueOrNull;
        if (current == null) return false;
        if (page.isNotEmpty) {
          state = AsyncData(
            current.copyWith(
              games: _mergeMetadataPages(
                page,
                const <Games>[],
                existing: current.games,
              ),
              clearLoadMoreError: true,
            ),
          );
        }
        // Empty success is cached until bounded safety metadata proves that
        // event membership changed. This keeps immediate reopen free while
        // allowing a future round to hydrate after games are published.
        _hydratedRoundKeys.add(hydrationKey);
        if (page.isEmpty) {
          _emptyHydratedRoundKeys.add(hydrationKey);
        } else {
          _emptyHydratedRoundKeys.remove(hydrationKey);
        }
        return true;
      } catch (_) {
        // Keep failed requests retryable on the next collapse/expand.
        return false;
      } finally {
        if (identical(_roundHydrationFutures[hydrationKey], hydration)) {
          _roundHydrationFutures.remove(hydrationKey);
        }
      }
    }();
    _roundHydrationFutures[hydrationKey] = hydration;
    _roundHydrationTail = hydration.then<void>((_) {});
    return hydration;
  }

  Future<bool> _loadMorePage({bool forNavigation = false}) async {
    final pending = _loadMoreCompletion;
    if (pending != null) return pending.future;
    final current = state.valueOrNull;
    if (current == null ||
        current.isLoadingMore ||
        !current.hasMore ||
        _refreshInFlight ||
        _selectionRefreshInFlight ||
        _roundHydrationFutures.isNotEmpty ||
        (_navigationHydrationInFlight && !forNavigation) ||
        !_isActive ||
        _disposed) {
      return false;
    }

    final completion = Completer<bool>();
    _loadMoreCompletion = completion;
    var result = false;
    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    final activityEpoch = _activityEpoch;

    try {
      final repository = ref.read(gameRepositoryProvider);
      final eventKey = _eventKey;
      final page = await repository.getEventRailGamesByTournamentIdentity(
        tourId: eventKey.tourId.trim(),
        tourSlug: eventKey.tourSlug.trim(),
        limit: kEventRailGamesPageSize,
        offset: current.nextOffset,
      );
      if (_disposed || !_isActive || activityEpoch != _activityEpoch) {
        return false;
      }
      final nextOffset = current.nextOffset + page.length;
      final pageCanContinue = page.length >= kEventRailGamesPageSize;
      final hasMore =
          pageCanContinue &&
          (current.totalCount == null || nextOffset < current.totalCount!);
      var games = _mergeMetadataPages(
        const <Games>[],
        page,
        existing: current.games,
      );
      _rememberSelectedGameSeed(page);
      _canonicalPageIdsByOffset[current.nextOffset] = _gameIds(page);
      if (!hasMore) {
        _canonicalPageIdsByOffset.removeWhere(
          (offset, _) => offset >= nextOffset,
        );
        games = _retainAuthoritativeCompletedCursorRows(games);
      }
      state = AsyncData(
        EventRailGamesState(
          games: games,
          nextOffset: nextOffset,
          totalCount: current.totalCount,
          hasMore: hasMore,
        ),
      );
      result = true;
      return result;
    } catch (error) {
      if (_disposed || !_isActive || activityEpoch != _activityEpoch) {
        return result;
      }
      state = AsyncData(
        current.copyWith(
          isLoadingMore: false,
          loadMoreError: error.toString().replaceFirst('Exception: ', ''),
        ),
      );
      return result;
    } finally {
      _loadMoreCompletion = null;
      if (!completion.isCompleted) completion.complete(result);
      if (_refreshRequested && _isActive && !_disposed) {
        scheduleMicrotask(_runRequestedRefresh);
      }
    }
  }

  /// Refreshes the first lightweight canonical page, one rotating loaded
  /// page, the selected-round window, and the exact count.
  ///
  /// This replaces the former full-tour safety poll for For You boards. A
  /// changed count or page boundary atomically resets the lightweight cursor,
  /// preventing mutable offset pages from skipping or retaining games. Stable
  /// refreshes keep later pages in memory and never download PGNs.
  Future<bool> refreshLoadedMetadata() async {
    final pending = _refreshCompletion;
    if (pending != null) return pending.future;
    final current = state.valueOrNull;
    if (current == null ||
        current.isLoadingMore ||
        _refreshInFlight ||
        _selectionRefreshInFlight ||
        _navigationHydrationInFlight ||
        _roundHydrationFutures.isNotEmpty ||
        !_isActive ||
        _disposed) {
      return false;
    }

    final eventKey = _eventKey;
    final activityEpoch = _activityEpoch;
    final selectionEpoch = _selectionEpoch;
    final tourId = eventKey.tourId.trim();
    if (tourId.isEmpty) return false;

    _refreshInFlight = true;
    final completion = Completer<bool>();
    _refreshCompletion = completion;
    var result = false;
    try {
      final repository = ref.read(gameRepositoryProvider);
      final canonicalFuture = repository.getEventRailGamesByTournamentIdentity(
        tourId: tourId,
        tourSlug: eventKey.tourSlug.trim(),
        limit: kEventRailGamesPageSize,
        offset: 0,
      );
      final sampledPageOffset = _safetyPageOffset(current.nextOffset);
      final sampledPageFuture =
          sampledPageOffset == null
              ? Future<List<Games>>.value(const <Games>[])
              : repository.getEventRailGamesByTournamentIdentity(
                tourId: tourId,
                tourSlug: eventKey.tourSlug.trim(),
                limit: kEventRailGamesPageSize,
                offset: sampledPageOffset,
              );
      final roundFuture = _loadSelectedRoundWindowStrict(repository, eventKey);
      final totalCountFuture = _loadTotalCount(repository, eventKey);
      final pages = await Future.wait(<Future<List<Games>>>[
        canonicalFuture,
        roundFuture,
        sampledPageFuture,
      ]);
      final canonicalGames = pages[0];
      final selectedRoundGames = pages[1];
      final sampledPageGames = pages[2];
      final fetchedTotalCount = await totalCountFuture;
      if (_disposed ||
          !_isActive ||
          activityEpoch != _activityEpoch ||
          selectionEpoch != _selectionEpoch) {
        return false;
      }
      final totalCount = fetchedTotalCount ?? current.totalCount;
      final canonicalFirstPageIds = _gameIds(canonicalGames);
      final selectedRoundPageIds = _gameIds(selectedRoundGames);
      final sampledPageIds = _gameIds(sampledPageGames);
      final gameSetChanged =
          !listEquals(
            canonicalFirstPageIds,
            _canonicalPageIdsByOffset[0] ?? const <String>[],
          ) ||
          (_selectedRoundBaselineInitialized &&
              !listEquals(selectedRoundPageIds, _selectedRoundPageIds)) ||
          (sampledPageOffset != null &&
              !listEquals(
                sampledPageIds,
                _canonicalPageIdsByOffset[sampledPageOffset] ??
                    const <String>[],
              )) ||
          (fetchedTotalCount != null &&
              current.totalCount != null &&
              fetchedTotalCount != current.totalCount) ||
          (fetchedTotalCount != null &&
              current.totalCount == null &&
              current.nextOffset > kEventRailGamesPageSize) ||
          (totalCount != null && current.nextOffset > totalCount);
      final nextOffset =
          gameSetChanged ? canonicalGames.length : current.nextOffset;
      final pageCanContinue = canonicalGames.length >= kEventRailGamesPageSize;
      _rememberSelectedGameSeed(<Games>[
        ...canonicalGames,
        ...selectedRoundGames,
        ...sampledPageGames,
      ]);
      final resetHasMore =
          pageCanContinue && (totalCount == null || nextOffset < totalCount);
      var refreshedGames =
          gameSetChanged
              ? _resetCursorMetadataPreservingLoaded(
                existing: current.games,
                selectedRoundPage: <Games>[
                  if (_selectedGameSeed != null) _selectedGameSeed!,
                  ...selectedRoundGames,
                ],
                canonicalPage: canonicalGames,
              )
              : _overlayRefreshedMetadata(
                existing: current.games,
                selectedRoundPage: selectedRoundGames,
                refreshedTourPages: <Games>[
                  ...canonicalGames,
                  ...sampledPageGames,
                ],
              );
      if (gameSetChanged && !resetHasMore) {
        refreshedGames = _retainAuthoritativeRows(
          refreshedGames,
          canonicalIds: canonicalFirstPageIds.toSet(),
          selectedRoundIds: selectedRoundPageIds.toSet(),
          selectedGameId: _eventKey.selectedGameId.trim(),
        );
      }
      final refreshed = EventRailGamesState(
        games: refreshedGames,
        nextOffset: nextOffset,
        totalCount: totalCount,
        hasMore:
            gameSetChanged
                ? resetHasMore
                : totalCount == null
                ? current.hasMore
                : nextOffset < totalCount,
      );
      if (gameSetChanged) {
        _hydratedRoundKeys.removeAll(_emptyHydratedRoundKeys);
        _emptyHydratedRoundKeys.clear();
        // Retain old page membership while the reset cursor re-downloads it.
        // Those rows stay represented in the rail instead of blinking away;
        // [loadMore] reconciles the complete authoritative id set once it
        // reaches the new end of the event.
        _canonicalPageIdsByOffset[0] = canonicalFirstPageIds;
        _nextSafetyPageOffset = kEventRailGamesPageSize;
      } else {
        _canonicalPageIdsByOffset[0] = canonicalFirstPageIds;
        if (sampledPageOffset != null) {
          _canonicalPageIdsByOffset[sampledPageOffset] = sampledPageIds;
          _advanceSafetyPageOffset(
            sampledPageOffset: sampledPageOffset,
            nextOffset: current.nextOffset,
          );
        }
      }
      _selectedRoundPageIds = selectedRoundPageIds;
      _selectedRoundBaselineInitialized = true;
      if (!_eventRailStatesEqual(current, refreshed)) {
        state = AsyncData(refreshed);
      }
      result = true;
      return result;
    } catch (_) {
      // Realtime continues to own visible rows. A failed safety refresh keeps
      // the last complete atomic page instead of blanking or partially
      // replacing the rail.
      return result;
    } finally {
      _refreshInFlight = false;
      _refreshCompletion = null;
      if (!completion.isCompleted) completion.complete(result);
      if (_refreshRequested && _isActive && !_disposed) {
        scheduleMicrotask(_runRequestedRefresh);
      }
    }
  }

  void _startSafetyRefresh() {
    _stopSafetyRefresh();
    if (!_isActive || _disposed) return;
    _safetyRefreshTimer = Timer.periodic(_eventRailSafetyRefreshInterval, (_) {
      final current = state.valueOrNull;
      if (_selectionRefreshNeeded || current?.loadMoreError != null) {
        _refreshRequested = true;
        unawaited(_runRequestedRefresh());
        return;
      }
      unawaited(refreshLoadedMetadata());
    });
  }

  void _stopSafetyRefresh() {
    _safetyRefreshTimer?.cancel();
    _safetyRefreshTimer = null;
  }

  @visibleForTesting
  bool get safetyRefreshScheduled => _safetyRefreshTimer?.isActive ?? false;

  int? _safetyPageOffset(int nextOffset) {
    if (nextOffset <= kEventRailGamesPageSize) return null;
    if (_nextSafetyPageOffset >= nextOffset) {
      return kEventRailGamesPageSize;
    }
    return _nextSafetyPageOffset;
  }

  void _advanceSafetyPageOffset({
    required int sampledPageOffset,
    required int nextOffset,
  }) {
    final followingOffset = sampledPageOffset + kEventRailGamesPageSize;
    _nextSafetyPageOffset =
        followingOffset < nextOffset
            ? followingOffset
            : kEventRailGamesPageSize;
  }

  Future<List<Games>> _loadSelectedRoundWindowOrEmpty(
    GameRepository repository,
    BoardTabEventGamesKey key,
  ) async {
    try {
      return await _loadSelectedRoundWindowStrict(repository, key);
    } catch (_) {
      // The selected game remains present in the Board tab's fallback seed;
      // an auxiliary initial-window failure must not discard the tour page.
      return const <Games>[];
    }
  }

  Future<({List<Games> games, String? error})> _loadInitialTourPage(
    GameRepository repository,
    BoardTabEventGamesKey eventKey,
  ) async {
    try {
      return (
        games: await repository.getEventRailGamesByTournamentIdentity(
          tourId: eventKey.tourId.trim(),
          tourSlug: eventKey.tourSlug.trim(),
          limit: kEventRailGamesPageSize,
          offset: 0,
        ),
        error: null,
      );
    } catch (error) {
      return (
        games: const <Games>[],
        error: error.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  Future<List<Games>> _loadSelectedGameOrEmpty(
    GameRepository repository,
    BoardTabEventGamesKey key,
  ) async {
    final gameId = key.selectedGameId.trim();
    if (gameId.isEmpty) return const <Games>[];
    try {
      return <Games>[await repository.getEventRailGameById(gameId)];
    } catch (_) {
      // The Board args already retain the tapped row as a fallback. A failed
      // exact metadata lookup must not block the atomic tour/round page.
      return const <Games>[];
    }
  }

  void _rememberSelectedGameSeed(Iterable<Games> games) {
    final selectedId = _eventKey.selectedGameId.trim();
    if (selectedId.isEmpty) return;
    for (final game in games) {
      if (game.id.trim() == selectedId) {
        _selectedGameSeed = game;
        return;
      }
    }
  }

  List<TournamentGameSummary> _retainAuthoritativeCompletedCursorRows(
    List<TournamentGameSummary> games,
  ) {
    final canonicalIds = <String>{
      for (final ids in _canonicalPageIdsByOffset.values) ...ids,
    };
    return _retainAuthoritativeRows(
      games,
      canonicalIds: canonicalIds,
      selectedRoundIds: _selectedRoundPageIds.toSet(),
      selectedGameId: _eventKey.selectedGameId.trim(),
    );
  }

  Future<List<Games>> _loadSelectedRoundWindowStrict(
    GameRepository repository,
    BoardTabEventGamesKey key,
  ) async {
    final roundId = key.selectedRoundId.trim();
    if (roundId.isEmpty) return const <Games>[];

    final selectedId = key.selectedGameId.trim();
    final selectedIndex =
        selectedId.isEmpty
            ? math.max(0, (key.selectedBoardNumber ?? 1) - 1)
            : await repository.countEventRailGamesBeforeSelectedInRound(
              roundId: roundId,
              selectedGameId: selectedId,
              selectedBoardNumber: key.selectedBoardNumber,
            );
    final offset = math.max(0, selectedIndex - kEventRailGamesPageSize ~/ 2);
    return repository.getEventRailGamesByRoundId(
      roundId,
      limit: kEventRailGamesPageSize,
      offset: offset,
    );
  }

  Future<int?> _loadTotalCount(
    GameRepository repository,
    BoardTabEventGamesKey eventKey,
  ) async {
    try {
      return await repository.countEventRailGamesByTournamentIdentity(
        tourId: eventKey.tourId.trim(),
        tourSlug: eventKey.tourSlug.trim(),
      );
    } catch (_) {
      // Pagination remains correct using the page-length fallback. A failed
      // count must not hide the already available selected-game rail seed.
      return null;
    }
  }
}

@immutable
class _EventRailNavigationStage {
  const _EventRailNavigationStage({
    required this.name,
    required this.roundIds,
    required this.startsAt,
    required this.createdAt,
    required this.ongoing,
  });

  final String name;
  final List<String> roundIds;
  final DateTime? startsAt;
  final DateTime? createdAt;
  final bool ongoing;
}

List<_EventRailNavigationStage> _orderedNavigationStages(
  List<EventRailRoundMetadata> catalog, {
  DateTime? now,
}) {
  final grouped = <String, List<EventRailRoundMetadata>>{};
  for (final round in catalog) {
    final id = round.id.trim();
    if (id.isEmpty) continue;
    final name = round.name.trim();
    final key =
        name.isEmpty ? 'round-id:$id' : 'round-name:${name.toLowerCase()}';
    grouped.putIfAbsent(key, () => <EventRailRoundMetadata>[]).add(round);
  }

  final stages = <_EventRailNavigationStage>[
    for (final rounds in grouped.values)
      _EventRailNavigationStage(
        name: rounds.first.name.trim(),
        roundIds: List<String>.unmodifiable(
          rounds.map((round) => round.id.trim()),
        ),
        startsAt: _earliestMetadataDate(rounds.map((round) => round.startsAt)),
        createdAt: _earliestMetadataDate(
          rounds.map((round) => round.createdAt),
        ),
        ongoing: rounds.any((round) => round.ongoing),
      ),
  ];
  final effectiveNow = now ?? DateTime.now();
  final upcoming = <_EventRailNavigationStage>[];
  final started = <_EventRailNavigationStage>[];
  for (final stage in stages) {
    final startsAt = stage.startsAt;
    if (!stage.ongoing && startsAt != null && startsAt.isAfter(effectiveNow)) {
      upcoming.add(stage);
    } else {
      started.add(stage);
    }
  }
  upcoming.sort((a, b) => _compareNavigationStageDates(a, b, ascending: true));

  final genericRoundNumbers = <_EventRailNavigationStage, int>{};
  for (final stage in started) {
    final match = RegExp(
      r'^round\s+(\d+)$',
      caseSensitive: false,
    ).firstMatch(stage.name);
    final number = match == null ? null : int.tryParse(match.group(1)!);
    if (number != null) genericRoundNumbers[stage] = number;
  }
  if (started.isNotEmpty && genericRoundNumbers.length == started.length) {
    started.sort(
      (a, b) => genericRoundNumbers[b]!.compareTo(genericRoundNumbers[a]!),
    );
  } else {
    started.sort(
      (a, b) => _compareNavigationStageDates(a, b, ascending: false),
    );
  }
  return <_EventRailNavigationStage>[...upcoming, ...started];
}

DateTime? _earliestMetadataDate(Iterable<DateTime?> values) {
  DateTime? earliest;
  for (final value in values) {
    if (value != null && (earliest == null || value.isBefore(earliest))) {
      earliest = value;
    }
  }
  return earliest;
}

int _compareNavigationStageDates(
  _EventRailNavigationStage a,
  _EventRailNavigationStage b, {
  required bool ascending,
}) {
  final aDate = a.startsAt ?? a.createdAt;
  final bDate = b.startsAt ?? b.createdAt;
  var result = 0;
  if (aDate == null && bDate == null) {
    result = a.name.compareTo(b.name);
  } else if (aDate == null) {
    result = 1;
  } else if (bDate == null) {
    result = -1;
  } else {
    result = aDate.compareTo(bDate);
    if (result == 0) result = a.name.compareTo(b.name);
  }
  return ascending ? result : -result;
}

String? _boundaryRepresentableGameId(List<Games> rows, {required int delta}) {
  final candidates = delta < 0 ? rows.reversed : rows;
  for (final game in candidates) {
    final players = game.players;
    if (players == null || players.length < 2) continue;
    if (_isResolvedEventRailPlayer(players[0].name) &&
        _isResolvedEventRailPlayer(players[1].name)) {
      return game.id;
    }
  }
  return null;
}

String _eventRailPairKey(String a, String b) {
  final pair = [a.trim().toLowerCase(), b.trim().toLowerCase()]..sort();
  return '${pair[0]}|${pair[1]}';
}

bool _isEventRailMatchSlug(String slug) {
  final lower = slug.trim().toLowerCase();
  return RegExp(r'^game-\d+$').hasMatch(lower) || lower.contains('tiebreak');
}

/// Shared ordering for games inside one knockout matchup.
int compareEventRailMatchGameSlugs(String a, String b) {
  final aInfo = _parseEventRailMatchSlugInfo(a);
  final bInfo = _parseEventRailMatchSlugInfo(b);
  if (aInfo.$1 != bInfo.$1) return aInfo.$1.compareTo(bInfo.$1);
  if (aInfo.$2 != bInfo.$2) return aInfo.$2.compareTo(bInfo.$2);
  return aInfo.$3.compareTo(bInfo.$3);
}

(int, int, int) _parseEventRailMatchSlugInfo(String slug) {
  final lower = slug.trim().toLowerCase();
  if (lower.startsWith('game-')) {
    final number = int.tryParse(lower.replaceAll('game-', '')) ?? 0;
    return (0, number, 0);
  }
  if (lower.contains('tiebreak')) {
    final tiebreakMatch = RegExp(r'tiebreak-(\d+)').firstMatch(lower);
    final rapidMatch = RegExp(r'rapid-(\d+)').firstMatch(lower);
    final blitzMatch = RegExp(r'blitz-(\d+)').firstMatch(lower);
    final tiebreakNumber = int.tryParse(tiebreakMatch?.group(1) ?? '1') ?? 1;
    final subNumber =
        int.tryParse(rapidMatch?.group(1) ?? blitzMatch?.group(1) ?? '1') ?? 1;
    var typePriority = 10;
    if (blitzMatch != null) typePriority = 20;
    if (lower.contains('armageddon')) typePriority = 30;
    return (typePriority + tiebreakNumber, tiebreakNumber, subNumber);
  }
  return (999, 0, 0);
}

String? _directionalNeighborId(
  List<Games> rows, {
  required String selectedId,
  required int delta,
}) {
  final normalizedId = selectedId.trim();
  if (normalizedId.isEmpty || delta == 0) return null;
  final selectedIndex = rows.indexWhere(
    (game) => game.id.trim() == normalizedId,
  );
  if (selectedIndex < 0) return null;
  final targetIndex = selectedIndex + (delta < 0 ? -1 : 1);
  if (targetIndex < 0 || targetIndex >= rows.length) return null;
  final targetId = rows[targetIndex].id.trim();
  return targetId.isEmpty ? null : targetId;
}

bool _isResolvedEventRailPlayer(String name) {
  final normalized = name.trim().toLowerCase();
  return normalized.isNotEmpty &&
      normalized != '?' &&
      normalized != '??' &&
      normalized != 'tbd' &&
      normalized != 'tba' &&
      normalized != 'unknown';
}

bool _eventRailStatesEqual(
  EventRailGamesState current,
  EventRailGamesState incoming,
) {
  if (current.nextOffset != incoming.nextOffset ||
      current.totalCount != incoming.totalCount ||
      current.hasMore != incoming.hasMore ||
      current.isLoadingMore != incoming.isLoadingMore ||
      current.loadMoreError != incoming.loadMoreError ||
      current.games.length != incoming.games.length) {
    return false;
  }

  for (var index = 0; index < current.games.length; index++) {
    if (!_eventRailSummariesEqual(
      current.games[index],
      incoming.games[index],
    )) {
      return false;
    }
  }
  return true;
}

bool _eventRailSummariesEqual(
  TournamentGameSummary current,
  TournamentGameSummary incoming,
) {
  return current.id == incoming.id &&
      current.name == incoming.name &&
      current.whitePlayer == incoming.whitePlayer &&
      current.blackPlayer == incoming.blackPlayer &&
      current.hasPgn == incoming.hasPgn &&
      current.tourId == incoming.tourId &&
      current.tourSlug == incoming.tourSlug &&
      current.whiteFederation == incoming.whiteFederation &&
      current.blackFederation == incoming.blackFederation &&
      current.whiteTitle == incoming.whiteTitle &&
      current.blackTitle == incoming.blackTitle &&
      current.whiteRating == incoming.whiteRating &&
      current.blackRating == incoming.blackRating &&
      current.whiteFideId == incoming.whiteFideId &&
      current.blackFideId == incoming.blackFideId &&
      current.fen == incoming.fen &&
      current.roundId == incoming.roundId &&
      current.roundSlug == incoming.roundSlug &&
      current.roundLabel == incoming.roundLabel &&
      current.roundName == incoming.roundName &&
      current.boardNumber == incoming.boardNumber &&
      current.status == incoming.status &&
      current.openingName == incoming.openingName &&
      current.lastMoveTime == incoming.lastMoveTime &&
      current.startsAt == incoming.startsAt &&
      current.roundStartsAt == incoming.roundStartsAt &&
      current.hasStarted == incoming.hasStarted &&
      current.pgn == incoming.pgn &&
      current.whiteTeam == incoming.whiteTeam &&
      current.blackTeam == incoming.blackTeam;
}

List<TournamentGameSummary> _mergeMetadataPages(
  List<Games> selectedRoundPage,
  List<Games> tourPage, {
  List<TournamentGameSummary> existing = const <TournamentGameSummary>[],
}) {
  final byId = <String, TournamentGameSummary>{
    for (final game in existing)
      if (game.id.trim().isNotEmpty) game.id: game,
  };
  for (final game in <Games>[...selectedRoundPage, ...tourPage]) {
    final id = game.id.trim();
    if (id.isEmpty) continue;
    byId[id] = _preserveRicherEventRailSnapshot(
      TournamentGameSummary.fromGame(game),
      byId[id],
    );
  }
  return List<TournamentGameSummary>.unmodifiable(byId.values);
}

List<TournamentGameSummary> _retainAuthoritativeRows(
  List<TournamentGameSummary> games, {
  required Set<String> canonicalIds,
  required Set<String> selectedRoundIds,
  required String selectedGameId,
}) {
  return List<TournamentGameSummary>.unmodifiable(
    games.where((game) {
      final id = game.id.trim();
      return canonicalIds.contains(id) ||
          selectedRoundIds.contains(id) ||
          (selectedGameId.isNotEmpty && id == selectedGameId);
    }),
  );
}

List<TournamentGameSummary> _mergeSelectedContextMetadata(
  List<TournamentGameSummary> existing,
  List<Games> freshRows,
) {
  final merged = existing.toList(growable: true);
  final indexById = <String, int>{
    for (var index = 0; index < merged.length; index++)
      if (merged[index].id.trim().isNotEmpty) merged[index].id: index,
  };
  for (final row in freshRows) {
    final id = row.id.trim();
    if (id.isEmpty) continue;
    final fresh = TournamentGameSummary.fromGame(row);
    final index = indexById[id];
    if (index == null) {
      indexById[id] = merged.length;
      merged.add(fresh);
    } else {
      merged[index] = _preserveRicherEventRailSnapshot(fresh, merged[index]);
    }
  }
  return List<TournamentGameSummary>.unmodifiable(merged);
}

bool _eventRailGameListsEqual(
  List<TournamentGameSummary> current,
  List<TournamentGameSummary> incoming,
) {
  if (current.length != incoming.length) return false;
  for (var index = 0; index < current.length; index++) {
    if (!_eventRailSummariesEqual(current[index], incoming[index])) {
      return false;
    }
  }
  return true;
}

List<String> _gameIds(List<Games> games) {
  return <String>[
    for (final game in games)
      if (game.id.trim().isNotEmpty) game.id.trim(),
  ];
}

List<TournamentGameSummary> _overlayRefreshedMetadata({
  required List<TournamentGameSummary> existing,
  required List<Games> selectedRoundPage,
  required List<Games> refreshedTourPages,
}) {
  // The selected-round page remains first, matching the initial atomic seed.
  // Populate the map in reverse priority so its copy wins when the same game
  // is also present in the canonical first page.
  final freshById = <String, TournamentGameSummary>{};
  for (final game in <Games>[...refreshedTourPages, ...selectedRoundPage]) {
    final id = game.id.trim();
    if (id.isEmpty) continue;
    freshById[id] = TournamentGameSummary.fromGame(game);
  }

  return List<TournamentGameSummary>.unmodifiable(
    existing.map((previous) {
      final fresh = freshById[previous.id];
      return fresh == null
          ? previous
          : _preserveRicherEventRailSnapshot(fresh, previous);
    }),
  );
}

List<TournamentGameSummary> _resetCursorMetadataPreservingLoaded({
  required List<TournamentGameSummary> existing,
  required List<Games> selectedRoundPage,
  required List<Games> canonicalPage,
}) {
  final existingById = <String, TournamentGameSummary>{
    for (final game in existing)
      if (game.id.trim().isNotEmpty) game.id: game,
  };
  final merged = <TournamentGameSummary>[];
  final seen = <String>{};
  for (final row in <Games>[...selectedRoundPage, ...canonicalPage]) {
    final id = row.id.trim();
    if (id.isEmpty || !seen.add(id)) continue;
    merged.add(
      _preserveRicherEventRailSnapshot(
        TournamentGameSummary.fromGame(row),
        existingById[id],
      ),
    );
  }
  for (final previous in existing) {
    if (previous.id.trim().isEmpty || seen.add(previous.id)) {
      merged.add(previous);
    }
  }
  return List<TournamentGameSummary>.unmodifiable(merged);
}

TournamentGameSummary _preserveRicherEventRailSnapshot(
  TournamentGameSummary fresh,
  TournamentGameSummary? existing,
) {
  if (existing == null) return fresh;

  final existingIsNewer =
      existing.lastMoveTime != null &&
      (fresh.lastMoveTime == null ||
          existing.lastMoveTime!.isAfter(fresh.lastMoveTime!));
  return fresh.copyWith(
    pgn: (fresh.pgn ?? '').trim().isNotEmpty ? fresh.pgn : existing.pgn,
    fen:
        existingIsNewer || (fresh.fen ?? '').trim().isEmpty
            ? existing.fen
            : fresh.fen,
    lastMoveTime:
        existingIsNewer
            ? existing.lastMoveTime
            : fresh.lastMoveTime ?? existing.lastMoveTime,
    status: mergeEventGameStatus(
      current: existing.status,
      incoming: fresh.status,
      currentSnapshotIsNewer: existingIsNewer,
    ),
    hasStarted: existingIsNewer ? existing.hasStarted : fresh.hasStarted,
    localPgnSource: existing.localPgnSource,
  );
}
