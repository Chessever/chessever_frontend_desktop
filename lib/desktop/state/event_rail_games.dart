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

@immutable
class EventRailGamesState {
  const EventRailGamesState({
    this.games = const <TournamentGameSummary>[],
    this.nextOffset = 0,
    this.totalCount,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.roundCatalog = const <EventRailRoundMetadata>[],
  });

  final List<TournamentGameSummary> games;

  /// Every round the tournament has, independent of which rows are loaded.
  /// Headings come from this, so the full round list is present at first paint
  /// and its order never re-shuffles as rows stream in.
  final List<EventRailRoundMetadata> roundCatalog;

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
    List<EventRailRoundMetadata>? roundCatalog,
  }) {
    return EventRailGamesState(
      games: games ?? this.games,
      nextOffset: nextOffset ?? this.nextOffset,
      totalCount: totalCount ?? this.totalCount,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError:
          clearLoadMoreError ? null : loadMoreError ?? this.loadMoreError,
      roundCatalog: roundCatalog ?? this.roundCatalog,
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
            other.eventKey.tourId.trim() == eventKey.tourId.trim();
  }

  @override
  int get hashCode => Object.hash(ownerId, eventKey.tourId.trim());

  @override
  String toString() => '$ownerId:${eventKey.tourId.trim()}';
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

  bool get _isActive => _tabForeground && _lifecycleAllowsStreaming;

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
    _activityEpoch++;
    _selectionEpoch++;
    _eventKey = arg.eventKey;
    _stopSafetyRefresh();
    _canonicalPageIdsByOffset.clear();
    _nextSafetyPageOffset = kEventRailGamesPageSize;
    _selectedRoundPageIds = const <String>[];
    _selectedGameSeed = null;
    _selectedRoundBaselineInitialized = false;
    _selectedContextHydratedSelectionEpoch = null;
    ref.listen<bool>(liveGameStreamingLifecycleProvider, (_, next) {
      _setLifecycleAllowsStreaming(next);
    });
    ref.onDispose(() {
      _disposed = true;
      _activityEpoch++;
      _selectionEpoch++;
      _stopSafetyRefresh();
    });

    final eventKey = _eventKey;
    final buildSelectionEpoch = _selectionEpoch;
    final tourId = eventKey.tourId.trim();
    if (tourId.isEmpty) return const EventRailGamesState();

    final repository = ref.watch(gameRepositoryProvider);
    final tourPageFuture = _loadInitialTourPage(repository, tourId);
    final roundPageFuture = _loadSelectedRoundWindowOrEmpty(
      repository,
      eventKey,
    );
    final selectedGameFuture = _loadSelectedGameOrEmpty(repository, eventKey);
    final totalCountFuture = _loadTotalCount(repository, tourId);
    final roundCatalogFuture = _loadRoundCatalogOrEmpty(repository, tourId);

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
    final roundCatalog = await roundCatalogFuture;
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
      roundCatalog: roundCatalog,
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
  /// The provider family is intentionally identified only by owner+tour.
  /// Selection is mutable context: navigating within a tournament must not
  /// throw away the cursor and re-download count/first-page metadata.
  void updateSelection(BoardTabEventGamesKey selection) {
    if (_disposed ||
        selection.tourId.trim() != _eventKey.tourId.trim() ||
        selection == _eventKey) {
      return;
    }

    final previousRoundId = _eventKey.selectedRoundId.trim();
    _eventKey = selection;
    _selectionEpoch++;
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
    if (_disposed || delta == 0) return false;
    final selectedId = _eventKey.selectedGameId.trim();
    if (selectedId.isEmpty) return false;

    // When the rail cannot hydrate (background tab, paused lifecycle), still
    // report success if a neighbor is already present in memory so keyboard /
    // button prev-next can advance without waiting on network work.
    if (!_isActive) {
      return _hasInMemoryDirectionalNeighbor(delta, selectedId: selectedId);
    }

    final pendingNavigation = _navigationHydrationCompletion;
    if (pendingNavigation != null) return pendingNavigation.future;

    await _awaitPendingRailMutation();
    if (_disposed) return false;
    if (!_isActive) {
      return _hasInMemoryDirectionalNeighbor(delta, selectedId: selectedId);
    }

    if (_eventKey.selectedRoundId.trim().isNotEmpty) {
      await ensureSelectionWindow();
      if (_disposed) return false;
      if (!_isActive) {
        return _hasInMemoryDirectionalNeighbor(delta, selectedId: selectedId);
      }

      if (_hasSelectedRoundPageNeighbor(delta, selectedId: selectedId)) {
        return true;
      }
      // The merged rail can already hold a same-round neighbor even when the
      // selected-round page id list is incomplete (e.g. only the tour page
      // seed loaded). Treat that as adjacency so navigation does not demand
      // a network hop for a jump that is already safe in memory.
      if (_hasInMemoryDirectionalNeighbor(delta, selectedId: selectedId)) {
        return true;
      }
    } else if (_hasInMemoryDirectionalNeighbor(delta, selectedId: selectedId)) {
      return true;
    }

    _navigationHydrationInFlight = true;
    final completion = Completer<bool>();
    _navigationHydrationCompletion = completion;
    var result = false;
    try {
      result = await _hydrateAdjacentStageMetadata(delta);
      return result;
    } finally {
      _navigationHydrationInFlight = false;
      _navigationHydrationCompletion = null;
      if (!completion.isCompleted) completion.complete(result);
      if (_refreshRequested && _isActive && !_disposed) {
        scheduleMicrotask(_runRequestedRefresh);
      }
    }
  }

  bool _hasSelectedRoundPageNeighbor(int delta, {required String selectedId}) {
    final roundIndex = _selectedRoundPageIds.indexOf(selectedId);
    if (delta < 0) return roundIndex > 0;
    return roundIndex >= 0 && roundIndex < _selectedRoundPageIds.length - 1;
  }

  /// True when the retained rail metadata already contains a neighbor in
  /// [delta]'s direction for [selectedId], without starting network work.
  bool _hasInMemoryDirectionalNeighbor(
    int delta, {
    required String selectedId,
  }) {
    if (_hasSelectedRoundPageNeighbor(delta, selectedId: selectedId)) {
      return true;
    }
    final games = state.valueOrNull?.games ?? const <TournamentGameSummary>[];
    if (games.isEmpty) return false;

    final selectedRoundId = _eventKey.selectedRoundId.trim();
    final scoped =
        selectedRoundId.isEmpty
            ? games
            : [
              for (final game in games)
                if (game.roundId.trim() == selectedRoundId) game,
            ];
    if (scoped.isEmpty) return false;

    // Prefer board-number order within the round so sparse merge order does
    // not invent a false neighbor across an unloaded gap of board numbers.
    final ordered = List<TournamentGameSummary>.of(scoped)..sort((a, b) {
      final boardA = a.boardNumber ?? 1 << 30;
      final boardB = b.boardNumber ?? 1 << 30;
      final byBoard = boardA.compareTo(boardB);
      if (byBoard != 0) return byBoard;
      return a.id.compareTo(b.id);
    });
    final selectedIndex = ordered.indexWhere(
      (game) => game.id.trim() == selectedId,
    );
    if (selectedIndex < 0) return false;
    if (delta < 0) {
      if (selectedIndex <= 0) return false;
      return _areAdjacentBoards(
        ordered[selectedIndex - 1],
        ordered[selectedIndex],
      );
    }
    if (selectedIndex >= ordered.length - 1) return false;
    return _areAdjacentBoards(
      ordered[selectedIndex],
      ordered[selectedIndex + 1],
    );
  }

  bool _areAdjacentBoards(
    TournamentGameSummary left,
    TournamentGameSummary right,
  ) {
    final leftBoard = left.boardNumber;
    final rightBoard = right.boardNumber;
    if (leftBoard == null || rightBoard == null) {
      // Without board numbers, list adjacency is the best available signal.
      return true;
    }
    return rightBoard - leftBoard == 1;
  }

  Future<void> _awaitPendingRailMutation() async {
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
      return;
    }
  }

  /// Headings are presentation-only, so a catalog failure degrades the rail to
  /// row-derived headings instead of failing the whole load.
  Future<List<EventRailRoundMetadata>> _loadRoundCatalogOrEmpty(
    GameRepository repository,
    String tourId,
  ) async {
    try {
      return await repository.getEventRailRoundsByTourId(tourId);
    } catch (_) {
      return const <EventRailRoundMetadata>[];
    }
  }

  Future<List<Games>> _loadNewestStartedRoundPage(
    GameRepository repository,
    List<EventRailRoundMetadata> catalog,
    List<TournamentGameSummary> loadedGames,
  ) async {
    if (catalog.isEmpty) return const <Games>[];
    try {
      final now = DateTime.now();
      final orderedStages = _orderedNavigationStages(catalog);
      if (orderedStages.every(
        (stage) => _eventRailGenericRoundNumber(stage.name) != null,
      )) {
        orderedStages.sort(
          (a, b) => _eventRailGenericRoundNumber(
            b.name,
          )!.compareTo(_eventRailGenericRoundNumber(a.name)!),
        );
      }
      final startedStages = orderedStages
          .where(
            (stage) => stage.startsAt == null || !stage.startsAt!.isAfter(now),
          )
          .toList(growable: false);
      if (startedStages.isEmpty) return const <Games>[];

      final loadedRoundIds = <String>{
        for (final game in loadedGames)
          if (game.roundId.trim().isNotEmpty) game.roundId.trim(),
      };
      final newestLoadedIndex = startedStages.indexWhere(
        (stage) => stage.roundIds.any(loadedRoundIds.contains),
      );
      if (newestLoadedIndex == 0) return const <Games>[];
      final candidates =
          newestLoadedIndex < 0
              ? startedStages
              : startedStages.take(newestLoadedIndex).toList(growable: false);
      if (candidates.isEmpty) return const <Games>[];

      final newest = await _findNewestStageWithGames(repository, candidates);
      if (newest == null) return const <Games>[];
      return repository.getEventRailGamesByRoundIds(
        newest.roundIds,
        limit: kEventRailGamesPageSize,
        offset: 0,
      );
    } catch (_) {
      // This probe only fills a newer round that lies outside retained pages.
      // A transient failure must not block the normal clock/result refresh.
      return const <Games>[];
    }
  }

  Future<_EventRailNavigationStage?> _findNewestStageWithGames(
    GameRepository repository,
    List<_EventRailNavigationStage> candidates,
  ) async {
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) {
      final count = await repository.countEventRailGamesByRoundIds(
        candidates.single.roundIds,
      );
      return count > 0 ? candidates.single : null;
    }

    final split = (candidates.length + 1) ~/ 2;
    final newer = candidates.sublist(0, split);
    final newerCount = await repository.countEventRailGamesByRoundIds(<String>[
      for (final stage in newer) ...stage.roundIds,
    ]);
    if (newerCount > 0) {
      return _findNewestStageWithGames(repository, newer);
    }
    return _findNewestStageWithGames(repository, candidates.sublist(split));
  }

  Future<bool> _hydrateAdjacentStageMetadata(int delta) async {
    final repository = ref.read(gameRepositoryProvider);
    final tourId = _eventKey.tourId.trim();
    final selectedRoundId = _eventKey.selectedRoundId.trim();
    if (tourId.isEmpty || selectedRoundId.isEmpty) return false;

    try {
      // Always refresh this catalog at a round edge. Live broadcasts can append
      // rounds while a Board tab remains retained for hours.
      final catalog = await repository.getEventRailRoundsByTourId(tourId);
      if (_disposed || !_isActive) return false;
      final stages = _orderedNavigationStages(catalog);
      final currentIndex = stages.indexWhere(
        (stage) => stage.roundIds.contains(selectedRoundId),
      );
      if (currentIndex < 0) {
        return await _hydrateCanonicalNavigationFallback(
          selectedId: _eventKey.selectedGameId,
        );
      }

      final currentStage = stages[currentIndex];
      final currentRows = await _loadNavigationStage(
        repository,
        currentStage,
        // A multi-round knockout stage still needs its complete lightweight
        // matchup ordering. For a normal one-round stage, load only the
        // boundary in the direction of the selected row. This proves whether
        // a same-round neighbor exists before crossing into another stage.
        boundaryDelta: currentStage.roundIds.length > 1 ? null : -delta,
      );
      if (_disposed || !_isActive) return false;
      _mergeNavigationMetadata(currentRows);
      if (_rowsContainDirectionalNeighbor(
        currentRows,
        selectedId: _eventKey.selectedGameId,
        delta: delta,
      )) {
        return true;
      }

      var targetIndex = currentIndex + (delta < 0 ? -1 : 1);
      while (targetIndex >= 0 && targetIndex < stages.length) {
        final rows = await _loadNavigationStage(
          repository,
          stages[targetIndex],
          boundaryDelta: delta,
        );
        if (_disposed || !_isActive) return false;
        _mergeNavigationMetadata(rows);
        if (_containsRepresentableGame(rows)) return true;
        targetIndex += delta < 0 ? -1 : 1;
      }

      // Reaching the catalog edge is an exact no-op. Returning false stops the
      // caller from waking unrelated canonical pages after the final board.
      return false;
    } catch (_) {
      return _hydrateCanonicalNavigationFallback(
        selectedId: _eventKey.selectedGameId,
      );
    }
  }

  Future<List<Games>> _loadNavigationStage(
    GameRepository repository,
    _EventRailNavigationStage stage, {
    required int? boundaryDelta,
  }) async {
    final roundIds = stage.roundIds;
    final count = await repository.countEventRailGamesByRoundIds(roundIds);
    if (count <= 0) return const <Games>[];

    // A named knockout stage can span game-1/game-2/tiebreak DB rounds. Its
    // exact matchup ordering depends on all of those lightweight rows, so load
    // that stage only. Plain rounds need just the entering boundary page.
    final loadWholeStage = roundIds.length > 1 || boundaryDelta == null;
    if (!loadWholeStage) {
      final offset =
          boundaryDelta < 0 ? math.max(0, count - kEventRailGamesPageSize) : 0;
      return repository.getEventRailGamesByRoundIds(
        roundIds,
        limit: kEventRailGamesPageSize,
        offset: offset,
      );
    }

    final rows = <Games>[];
    for (var offset = 0; offset < count; offset += kEventRailGamesPageSize) {
      rows.addAll(
        await repository.getEventRailGamesByRoundIds(
          roundIds,
          limit: kEventRailGamesPageSize,
          offset: offset,
        ),
      );
      if (_disposed || !_isActive) return const <Games>[];
    }
    return rows;
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

  Future<bool> _hydrateCanonicalNavigationFallback({
    required String selectedId,
  }) async {
    while (state.valueOrNull?.hasMore == true) {
      final previousOffset = state.valueOrNull?.nextOffset;
      if (!await _loadMorePage(forNavigation: true)) return false;
      final current = state.valueOrNull;
      if (current == null ||
          (current.hasMore && current.nextOffset == previousOffset)) {
        return false;
      }
    }
    return _canonicalPageIdsByOffset.values.any(
      (ids) => ids.contains(selectedId.trim()),
    );
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

  Future<bool> _loadMorePage({bool forNavigation = false}) async {
    final pending = _loadMoreCompletion;
    if (pending != null) return pending.future;
    final current = state.valueOrNull;
    if (current == null ||
        current.isLoadingMore ||
        !current.hasMore ||
        _refreshInFlight ||
        _selectionRefreshInFlight ||
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
      final tourId = _eventKey.tourId.trim();
      final page = await repository.getEventRailGamesByTourId(
        tourId,
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
          // Carried forward. Dropping it here reset the round catalog to empty
          // on every page load, which made the rail fall back to headings
          // derived from loaded rows — rounds vanished and the order reshuffled
          // mid-scroll.
          roundCatalog: current.roundCatalog,
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
      final newestStartedRoundFuture = _loadNewestStartedRoundPage(
        repository,
        current.roundCatalog,
        current.games,
      );
      final canonicalFuture = repository.getEventRailGamesByTourId(
        tourId,
        limit: kEventRailGamesPageSize,
        offset: 0,
      );
      final sampledPageOffset = _safetyPageOffset(current.nextOffset);
      final sampledPageFuture =
          sampledPageOffset == null
              ? Future<List<Games>>.value(const <Games>[])
              : repository.getEventRailGamesByTourId(
                tourId,
                limit: kEventRailGamesPageSize,
                offset: sampledPageOffset,
              );
      final roundFuture = _loadSelectedRoundWindowStrict(repository, eventKey);
      final totalCountFuture = _loadTotalCount(repository, tourId);
      final pages = await Future.wait(<Future<List<Games>>>[
        canonicalFuture,
        roundFuture,
        sampledPageFuture,
      ]);
      final canonicalGames = pages[0];
      final selectedRoundGames = pages[1];
      final sampledPageGames = pages[2];
      final newestStartedRoundGames = await newestStartedRoundFuture;
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
        ...newestStartedRoundGames,
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
      refreshedGames = _mergeMetadataPages(
        newestStartedRoundGames,
        const <Games>[],
        existing: refreshedGames,
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
        // Same reason as in loadMore: the periodic refresh must not erase the
        // round catalog, or the rail reshuffles on its own timer.
        roundCatalog: current.roundCatalog,
        hasMore:
            gameSetChanged
                ? resetHasMore
                : totalCount == null
                ? current.hasMore
                : nextOffset < totalCount,
      );
      if (gameSetChanged) {
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
    String tourId,
  ) async {
    try {
      return (
        games: await repository.getEventRailGamesByTourId(
          tourId,
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

  Future<int?> _loadTotalCount(GameRepository repository, String tourId) async {
    try {
      return await repository.countGamesByTourId(tourId);
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
  });

  final String name;
  final List<String> roundIds;
  final DateTime? startsAt;
  final DateTime? createdAt;
}

int? _eventRailGenericRoundNumber(String name) {
  final match = RegExp(
    r'^round\s+(\d+)$',
    caseSensitive: false,
  ).firstMatch(name.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

List<_EventRailNavigationStage> _orderedNavigationStages(
  List<EventRailRoundMetadata> catalog,
) {
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
      ),
  ];
  final now = DateTime.now();
  final started = <_EventRailNavigationStage>[];
  final upcoming = <_EventRailNavigationStage>[];
  for (final stage in stages) {
    final startsAt = stage.startsAt;
    if (startsAt != null && startsAt.isAfter(now)) {
      upcoming.add(stage);
    } else {
      started.add(stage);
    }
  }
  started.sort((a, b) => _compareNavigationStageDates(a, b, ascending: false));
  upcoming.sort((a, b) => _compareNavigationStageDates(a, b, ascending: true));
  // Match the catalog-backed rendered rail exactly: started rounds newest
  // first, followed by upcoming rounds oldest first.
  return <_EventRailNavigationStage>[...started, ...upcoming];
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

bool _containsRepresentableGame(List<Games> rows) {
  return rows.any((game) {
    final players = game.players;
    if (players == null || players.length < 2) return false;
    return _isResolvedEventRailPlayer(players[0].name) &&
        _isResolvedEventRailPlayer(players[1].name);
  });
}

bool _rowsContainDirectionalNeighbor(
  List<Games> rows, {
  required String selectedId,
  required int delta,
}) {
  final normalizedId = selectedId.trim();
  if (normalizedId.isEmpty || delta == 0) return false;
  final selectedIndex = rows.indexWhere(
    (game) => game.id.trim() == normalizedId,
  );
  if (selectedIndex < 0) return false;
  return delta < 0 ? selectedIndex > 0 : selectedIndex < rows.length - 1;
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
      current.whiteClockSeconds == incoming.whiteClockSeconds &&
      current.blackClockSeconds == incoming.blackClockSeconds &&
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
    whiteClockSeconds:
        existingIsNewer
            ? existing.whiteClockSeconds
            : fresh.whiteClockSeconds ?? existing.whiteClockSeconds,
    blackClockSeconds:
        existingIsNewer
            ? existing.blackClockSeconds
            : fresh.blackClockSeconds ?? existing.blackClockSeconds,
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
