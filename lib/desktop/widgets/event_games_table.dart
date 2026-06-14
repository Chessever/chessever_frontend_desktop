import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/adaptive_games_table.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/favorites/player_games/provider/favorites_combined_games_provider.dart';
import 'package:chessever/screens/library/providers/gamebase_database_games_provider.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show buildPgnFromGamebaseData, pgnHasMoves;
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/time_utils.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

const Duration _kSidebarLiveActivityWindow = Duration(minutes: 120);

final _eventRoundExpandedProvider = StateProvider.autoDispose
    .family<bool, String>((ref, key) => true);

final _eventUpcomingVisibleProvider = StateProvider.autoDispose
    .family<bool, String>((ref, key) => false);

final _gameRailTabProvider = StateProvider.autoDispose
    .family<_GameRailTab?, String>((ref, tabId) => null);

@visibleForTesting
List<String> eventRailRangeSelectionIds({
  required List<TournamentGameSummary> orderedGames,
  required String? anchorGameId,
  required String targetGameId,
}) {
  if (orderedGames.isEmpty) return const <String>[];
  final targetIndex = orderedGames.indexWhere(
    (game) => game.id == targetGameId,
  );
  if (targetIndex < 0) return const <String>[];
  final anchorIndex =
      anchorGameId == null
          ? -1
          : orderedGames.indexWhere((game) => game.id == anchorGameId);
  final start =
      anchorIndex < 0 ? targetIndex : math.min(anchorIndex, targetIndex);
  final end =
      anchorIndex < 0 ? targetIndex : math.max(anchorIndex, targetIndex);
  return [for (var i = start; i <= end; i++) orderedGames[i].id];
}

/// Board-pane companion table for the event that produced the active game.
///
/// The source of truth is the active Board tab's [BoardTabGameArgs]. The
/// legacy [tournamentGamesProvider] is kept as a fallback for older flows
/// that still load a tournament into the scratch board through PGN intake.
class EventGamesTable extends ConsumerStatefulWidget {
  const EventGamesTable({super.key, required this.tabId, this.onClose});

  static const double width = 360;

  final String tabId;

  /// Optional dismissal hook. When supplied, the rail renders a close
  /// affordance in its header that invokes this. Hosts wire it to the
  /// outer split-view controller's `collapse(...)` so the rail's
  /// collapsed-state restore button takes over.
  final VoidCallback? onClose;

  @override
  ConsumerState<EventGamesTable> createState() => _EventGamesTableState();
}

class _EventGamesTableState extends ConsumerState<EventGamesTable> {
  static const double _databaseScrollPrefetchExtent = 360;

  final ScrollController _scrollController = ScrollController();
  final FocusNode _railFocusNode = FocusNode(debugLabel: 'event-games-rail');
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  String? _lastScrollSignature;
  String? _loadingDatabaseTabId;
  String? _databaseLoadErrorTabId;
  String? _highlightedGameId;
  String? _rangeAnchorGameId;
  Set<String> _highlightedGameIds = const <String>{};
  String? _databaseLoadError;
  String? _loadingContinuationKey;
  String? _continuationLoadErrorKey;
  String? _continuationLoadError;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _railFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    unawaited(_maybeLoadMoreDatabaseGames());
    unawaited(_maybeLoadMoreContinuedGames());
  }

  GlobalKey _rowKeyFor(String id) {
    return _rowKeys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: 'event-games-row-$id'),
    );
  }

  void _pruneRowKeys(Iterable<TournamentGameSummary> games) {
    final liveIds = games.map((game) => game.id).toSet();
    _rowKeys.removeWhere((id, _) => !liveIds.contains(id));
  }

  void _highlightGame(TournamentGameSummary game) {
    _railFocusNode.requestFocus();
    if (_highlightedGameId == game.id && _highlightedGameIds.isEmpty) return;
    setState(() {
      _highlightedGameId = game.id;
      _rangeAnchorGameId = game.id;
      _highlightedGameIds = const <String>{};
    });
  }

  void _highlightGameRange(
    List<TournamentGameSummary> orderedGames,
    TournamentGameSummary target, {
    String? fallbackAnchorGameId,
  }) {
    _railFocusNode.requestFocus();
    final anchorId =
        _rangeAnchorGameId ??
        _highlightedGameId ??
        fallbackAnchorGameId ??
        target.id;
    final nextIds =
        eventRailRangeSelectionIds(
          orderedGames: orderedGames,
          anchorGameId: anchorId,
          targetGameId: target.id,
        ).toSet();
    setState(() {
      _rangeAnchorGameId = anchorId;
      _highlightedGameId = target.id;
      _highlightedGameIds = nextIds;
    });
  }

  bool _moveHighlightedGame(
    List<TournamentGameSummary> orderedGames, {
    required int delta,
    String? fallbackSelectedGameId,
  }) {
    if (orderedGames.isEmpty || delta == 0) return false;

    final activeId = _highlightedGameId ?? fallbackSelectedGameId;
    final currentIdx =
        activeId == null
            ? -1
            : orderedGames.indexWhere((game) => game.id == activeId);
    final anchor =
        currentIdx >= 0 ? currentIdx : (delta > 0 ? -1 : orderedGames.length);
    final nextIdx = (anchor + delta).clamp(0, orderedGames.length - 1);
    final nextGame = orderedGames[nextIdx];
    if (nextGame.id == _highlightedGameId && _highlightedGameIds.isEmpty) {
      return true;
    }
    setState(() {
      _highlightedGameId = nextGame.id;
      _rangeAnchorGameId = nextGame.id;
      _highlightedGameIds = const <String>{};
    });
    return true;
  }

  KeyEventResult _handleRailKeyEvent(
    KeyEvent event,
    List<TournamentGameSummary> orderedGames, {
    required _GameListKind kind,
    required List<TournamentGameSummary> eventGames,
    required String tournamentTitle,
    required String? selectedGameId,
    required BoardTabGameArgs? activeArgs,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final copyModifierPressed =
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        !HardwareKeyboard.instance.isAltPressed;
    if (copyModifierPressed && event.logicalKey == LogicalKeyboardKey.keyC) {
      if (event is KeyDownEvent) {
        unawaited(
          _copyHighlightedGamesAsPgn(
            orderedGames,
            selectedGameId: selectedGameId,
          ),
        );
      }
      return KeyEventResult.handled;
    }

    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return _moveHighlightedGame(
            orderedGames,
            delta: 1,
            fallbackSelectedGameId: selectedGameId,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return _moveHighlightedGame(
            orderedGames,
            delta: -1,
            fallbackSelectedGameId: selectedGameId,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (orderedGames.isEmpty) return KeyEventResult.ignored;
      final activeId = _highlightedGameId ?? selectedGameId;
      final index =
          activeId == null
              ? 0
              : orderedGames.indexWhere((game) => game.id == activeId);
      final game = orderedGames[index < 0 ? 0 : index];
      if (_highlightedGameId != game.id) {
        setState(() => _highlightedGameId = game.id);
      }
      unawaited(
        _openEventGame(
          ref: ref,
          container: ProviderScope.containerOf(context, listen: false),
          kind: kind,
          game: game,
          eventGames: eventGames,
          tournamentTitle: tournamentTitle,
          activeArgs: activeArgs,
        ),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _copyHighlightedGamesAsPgn(
    List<TournamentGameSummary> orderedGames, {
    required String? selectedGameId,
  }) async {
    final games = eventRailGamesForCopy(
      orderedGames: orderedGames,
      selectedIds: _highlightedGameIds,
      highlightedGameId: _highlightedGameId,
      selectedGameId: selectedGameId,
    );
    await _copyEventGameSummariesAsPgn(
      context: context,
      ref: ref,
      games: games,
    );
  }

  void _scheduleSelectedScroll({
    required String? selectedGameId,
    required String signature,
  }) {
    if (selectedGameId == null || selectedGameId.isEmpty) return;
    if (_lastScrollSignature == signature) return;
    _lastScrollSignature = signature;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[selectedGameId]?.currentContext;
      if (rowContext == null) return;
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.34,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  Future<void> _maybeLoadMoreDatabaseGames({bool force = false}) async {
    if (!mounted) return;
    final activeTabId = widget.tabId;
    if (_loadingDatabaseTabId == activeTabId) return;
    if (!force && _databaseLoadErrorTabId == activeTabId) return;

    final activeArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
    final pagination = activeArgs?.databaseGamesPagination;
    if (activeArgs == null || pagination == null || !pagination.hasMore) {
      return;
    }

    final rail = _resolveGameRail(
      activeArgs,
      ref.read(tournamentGamesProvider),
    );
    final selectedTab = _normalizeRailTab(
      ref.read(_gameRailTabProvider(activeTabId)),
      rail,
    );
    if (rail.resolve(selectedTab)?.kind != _GameListKind.database) return;

    if (!force) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final nearBottom =
          position.maxScrollExtent <= 0 ||
          position.pixels >=
              position.maxScrollExtent - _databaseScrollPrefetchExtent;
      if (!nearBottom) return;
    }

    setState(() {
      _loadingDatabaseTabId = activeTabId;
      _databaseLoadErrorTabId = null;
      _databaseLoadError = null;
    });

    try {
      final pageQuery = gamebasePositionGamesQueryWithPage(
        pagination.query,
        pagination.nextPageNumber,
      );
      final page = await fetchDesktopPositionGamesPage(
        ref,
        pageQuery,
        exactFenSearch: pagination.exactFenSearch,
        resolvedApi: pagination.resolvedApi,
      );
      if (!mounted) return;

      final latestArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
      final latestPagination = latestArgs?.databaseGamesPagination;
      if (latestArgs == null || latestPagination == null) {
        setState(() {
          if (_loadingDatabaseTabId == activeTabId) {
            _loadingDatabaseTabId = null;
          }
        });
        return;
      }

      final fallbackFen =
          (latestArgs.initialFen ?? latestArgs.fenSeed ?? pageQuery.fen).trim();
      final merged = List<TournamentGameSummary>.of(latestArgs.databaseGames);
      final existingIds = <String>{
        for (final game in merged)
          if (game.id.trim().isNotEmpty) game.id.trim(),
      };
      var added = 0;
      for (final row in page.response.data) {
        final summary = gamebasePositionGameSummaryFromRow(
          row,
          fallbackFen: fallbackFen,
        );
        if (summary.id.trim().isEmpty) continue;
        if (!existingIds.add(summary.id.trim())) continue;
        merged.add(summary);
        added += 1;
      }

      final updatedPagination = latestPagination.copyWith(
        nextPageNumber: pageQuery.pageNumber + 1,
        hasMore: page.response.metadata.hasMore && added > 0,
        resolvedApi: page.resolvedApi ?? latestPagination.resolvedApi,
        totalCount:
            page.response.metadata.totalCount ?? latestPagination.totalCount,
      );

      ref.read(boardTabGameArgsByTabIdProvider.notifier).update((argsByTab) {
        final latest = argsByTab[activeTabId];
        if (latest == null) return argsByTab;
        return <String, BoardTabGameArgs>{
          ...argsByTab,
          activeTabId: latest.copyWith(
            databaseGames: merged,
            databaseGamesPagination: updatedPagination,
          ),
        };
      });

      if (!mounted) return;
      setState(() {
        if (_loadingDatabaseTabId == activeTabId) _loadingDatabaseTabId = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_loadingDatabaseTabId == activeTabId) _loadingDatabaseTabId = null;
        _databaseLoadErrorTabId = activeTabId;
        _databaseLoadError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _maybeLoadMoreContinuedGames({bool force = false}) async {
    if (!mounted) return;
    final activeTabId = widget.tabId;

    final activeArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
    if (activeArgs == null) return;

    final rail = _resolveGameRail(
      activeArgs,
      ref.read(tournamentGamesProvider),
    );
    final selectedTab = _normalizeRailTab(
      ref.read(_gameRailTabProvider(activeTabId)),
      rail,
    );
    final resolved = rail.resolve(selectedTab);
    if (resolved == null) return;

    final continuation = _continuationForKind(activeArgs, resolved.kind);
    if (continuation == null) return;
    final loadKey = _continuationKey(activeTabId, continuation);
    if (_loadingContinuationKey == loadKey) return;
    if (!force && _continuationLoadErrorKey == loadKey) return;
    if (!_canLoadMoreContinuation(continuation)) return;

    if (!force) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final nearBottom =
          position.maxScrollExtent <= 0 ||
          position.pixels >=
              position.maxScrollExtent - _databaseScrollPrefetchExtent;
      if (!nearBottom) return;
    }

    setState(() {
      _loadingContinuationKey = loadKey;
      _continuationLoadErrorKey = null;
      _continuationLoadError = null;
    });

    try {
      await _loadMoreContinuation(continuation);
      if (!mounted) return;
      setState(() {
        if (_loadingContinuationKey == loadKey) _loadingContinuationKey = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_loadingContinuationKey == loadKey) _loadingContinuationKey = null;
        _continuationLoadErrorKey = loadKey;
        _continuationLoadError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  _ContinuationSnapshot? _watchContinuationSnapshot(
    BoardTabGamesContinuation? continuation, {
    required List<TournamentGameSummary> fallbackGames,
  }) {
    if (continuation == null) return null;

    switch (continuation.kind) {
      case BoardTabGamesContinuationKind.favorites:
        final state = ref.watch(favoritesCombinedGamesProvider);
        return _ContinuationSnapshot(
          games: _mergeGameSummaries(
            fallbackGames,
            _summariesFromGameModels(state.filteredGames),
          ),
          isLoading: state.isLoading,
          hasMore: state.hasMore,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.countrymen:
        final state = ref.watch(countrymenCombinedGamesProvider);
        return _ContinuationSnapshot(
          games: _mergeGameSummaries(
            fallbackGames,
            _summariesFromGameModels(state.filteredGames),
          ),
          isLoading: state.isLoading,
          hasMore: state.hasMore,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.playerProfile:
        final argument = continuation.argument;
        if (argument is! PlayerProfileKey) return null;
        final state = ref.watch(playerProfileGamesKeyProvider(argument));
        return _ContinuationSnapshot(
          games: _mergeGameSummaries(
            fallbackGames,
            _summariesFromGameModels(state.filteredGames),
          ),
          isLoading: state.isLoading || state.isLoadingMore,
          hasMore: state.hasMorePages,
          totalCount: state.totalCount,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.twicDatabase:
        final state = ref.watch(gamebaseDatabaseGamesPaginatedProvider);
        return _ContinuationSnapshot(
          games: _mergeGameSummaries(
            fallbackGames,
            _summariesFromGameModels(state.games),
          ),
          isLoading: state.isLoading,
          hasMore: state.hasMore,
          totalCount: state.totalCount > 0 ? state.totalCount : null,
          error: state.error,
        );
    }
  }

  bool _canLoadMoreContinuation(BoardTabGamesContinuation continuation) {
    switch (continuation.kind) {
      case BoardTabGamesContinuationKind.favorites:
        final state = ref.read(favoritesCombinedGamesProvider);
        return state.hasMore && !state.isLoading;
      case BoardTabGamesContinuationKind.countrymen:
        final state = ref.read(countrymenCombinedGamesProvider);
        return state.hasMore && !state.isLoading;
      case BoardTabGamesContinuationKind.playerProfile:
        final argument = continuation.argument;
        if (argument is! PlayerProfileKey) return false;
        final state = ref.read(playerProfileGamesKeyProvider(argument));
        return state.hasMorePages && !state.isLoading && !state.isLoadingMore;
      case BoardTabGamesContinuationKind.twicDatabase:
        final state = ref.read(gamebaseDatabaseGamesPaginatedProvider);
        return state.hasMore && !state.isLoading;
    }
  }

  Future<void> _loadMoreContinuation(
    BoardTabGamesContinuation continuation,
  ) async {
    switch (continuation.kind) {
      case BoardTabGamesContinuationKind.favorites:
        final state = ref.read(favoritesCombinedGamesProvider);
        final notifier = ref.read(favoritesCombinedGamesProvider.notifier);
        if (state.isSearching) {
          await notifier.loadMoreSearchResults();
        } else {
          await notifier.loadMoreGames();
        }
      case BoardTabGamesContinuationKind.countrymen:
        final state = ref.read(countrymenCombinedGamesProvider);
        final notifier = ref.read(countrymenCombinedGamesProvider.notifier);
        if (state.isSearching) {
          await notifier.loadMoreSearchResults();
        } else {
          await notifier.loadMoreGames();
        }
      case BoardTabGamesContinuationKind.playerProfile:
        final argument = continuation.argument;
        if (argument is! PlayerProfileKey) return;
        await ref
            .read(playerProfileGamesKeyProvider(argument).notifier)
            .loadMore();
      case BoardTabGamesContinuationKind.twicDatabase:
        await ref
            .read(gamebaseDatabaseGamesPaginatedProvider.notifier)
            .loadNextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeTabId = widget.tabId;
    final activeArgs = ref.watch(
      boardTabGameArgsByTabIdProvider.select((m) => m[activeTabId]),
    );
    final routeContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.routeGamesContinuation,
      fallbackGames: activeArgs?.routeGames ?? const <TournamentGameSummary>[],
    );
    final eventContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.eventGamesContinuation,
      fallbackGames: activeArgs?.eventGames ?? const <TournamentGameSummary>[],
    );
    final databaseContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.databaseGamesContinuation,
      fallbackGames:
          activeArgs?.databaseGames ?? const <TournamentGameSummary>[],
    );
    final effectiveArgs = activeArgs?.copyWith(
      routeGames: routeContinuationSnapshot?.games,
      eventGames: eventContinuationSnapshot?.games,
      databaseGames: databaseContinuationSnapshot?.games,
    );
    final legacy = ref.watch(tournamentGamesProvider);
    final rail = _resolveGameRail(effectiveArgs, legacy);
    if (rail.isEmpty) {
      return const SizedBox.shrink();
    }
    final railKey = activeTabId;
    final selectedTab = _normalizeRailTab(
      ref.watch(_gameRailTabProvider(railKey)),
      rail,
    );
    final resolved = rail.resolve(selectedTab);
    if (resolved == null || resolved.games.isEmpty) {
      return const SizedBox.shrink();
    }

    final allRoundGroups =
        resolved.kind == _GameListKind.favorites
            ? _buildDateGroups(resolved.games)
            : _buildRoundGroups(
              resolved.games,
              groupByRound: resolved.kind == _GameListKind.event,
            );
    final showUpcoming =
        resolved.kind == _GameListKind.event &&
        ref.watch(_eventUpcomingVisibleProvider(railKey));
    final upcomingGames =
        resolved.kind == _GameListKind.event
            ? resolved.games.where(_isUpcomingGameForRail).toList()
            : const <TournamentGameSummary>[];
    final upcomingGroups =
        upcomingGames.isEmpty
            ? const <_EventRoundGroup>[]
            : _buildRoundGroups(upcomingGames, groupByRound: true);
    final roundGroups =
        resolved.kind == _GameListKind.event && !showUpcoming
            ? _buildRoundGroups(
              resolved.games
                  .where((game) => !_isUpcomingGameForRail(game))
                  .toList(growable: false),
              groupByRound: true,
            )
            : allRoundGroups;
    final showBoardColumn = resolved.kind == _GameListKind.event;
    final expandedByGroup = <String, bool>{
      for (final group in roundGroups)
        group.id: ref.watch(_eventRoundExpandedProvider(group.id)),
    };
    final visibleRoundGroups = [
      for (final group in roundGroups)
        if (expandedByGroup[group.id] == true) group,
    ];
    final allOrderedGames = allRoundGroups
        .expand((round) => round.games)
        .toList(growable: false);
    final orderedGames = visibleRoundGroups
        .expand((round) => round.games)
        .toList(growable: false);
    final selectedGameId = resolved.selectedGameId;
    final activeSelectionId = _highlightedGameId ?? selectedGameId;
    _pruneRowKeys(orderedGames);
    final liveBatchKey =
        resolved.kind == _GameListKind.database || orderedGames.isEmpty
            ? null
            : LiveGamesBatchKey(
              scopeId: 'desktop-event-rail:$activeTabId:${resolved.kind.index}',
              gameIds: orderedGames.map((game) => game.id),
            );
    final liveSummaries =
        liveBatchKey == null
            ? _EventLiveSummaries.empty
            : ref.watch(
              gameUpdatesBatchStreamProvider(
                liveBatchKey,
              ).select((async) => _EventLiveSummaries.from(async.valueOrNull)),
            );

    final scrollSignature = [
      activeSelectionId ?? '',
      for (final group in roundGroups)
        '${resolved.kind.index}:${group.id}:${expandedByGroup[group.id] == true}:${group.games.map((game) => game.id).join(',')}',
    ].join('|');
    _scheduleSelectedScroll(
      selectedGameId: activeSelectionId,
      signature: scrollSignature,
    );

    final databasePagination =
        resolved.kind == _GameListKind.database
            ? effectiveArgs?.databaseGamesPagination
            : null;
    final activeContinuation =
        effectiveArgs == null
            ? null
            : _continuationForKind(effectiveArgs, resolved.kind);
    final continuationSnapshot = _continuationSnapshotForKind(
      resolved.kind,
      routeSnapshot: routeContinuationSnapshot,
      eventSnapshot: eventContinuationSnapshot,
      databaseSnapshot: databaseContinuationSnapshot,
    );
    final continuationKey =
        activeContinuation != null
            ? _continuationKey(activeTabId, activeContinuation)
            : null;
    final isLoadingMoreDatabase = _loadingDatabaseTabId == activeTabId;
    final isLoadingMoreContinuation =
        continuationKey != null &&
        (_loadingContinuationKey == continuationKey ||
            (continuationSnapshot?.isLoading ?? false));
    final databaseLoadError =
        _databaseLoadErrorTabId == activeTabId ? _databaseLoadError : null;
    final continuationLoadError =
        continuationKey != null && _continuationLoadErrorKey == continuationKey
            ? _continuationLoadError
            : null;
    if (databasePagination?.hasMore == true &&
        !isLoadingMoreDatabase &&
        databaseLoadError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeLoadMoreDatabaseGames());
      });
    }
    if (activeContinuation != null &&
        continuationSnapshot?.hasMore == true &&
        !isLoadingMoreContinuation &&
        continuationLoadError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeLoadMoreContinuedGames());
      });
    }

    final countGames =
        resolved.kind == _GameListKind.event ? allOrderedGames : orderedGames;
    final countText = _railCountText(
      resolved: resolved,
      loadedCount: countGames.length,
      pagination: databasePagination,
      continuation: continuationSnapshot,
      isLoadingMore: isLoadingMoreDatabase || isLoadingMoreContinuation,
    );

    final railActivationGames =
        resolved.kind == _GameListKind.event ? allOrderedGames : orderedGames;

    return Focus(
      focusNode: _railFocusNode,
      onKeyEvent:
          (_, event) => _handleRailKeyEvent(
            event,
            orderedGames,
            kind: resolved.kind,
            eventGames: railActivationGames,
            tournamentTitle: resolved.title,
            selectedGameId: selectedGameId,
            activeArgs: effectiveArgs,
          ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _railFocusNode.requestFocus(),
        child: Container(
          decoration: const BoxDecoration(color: kBlack2Color),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 4,
                          height: 20,
                          margin: const EdgeInsets.only(top: 1),
                          decoration: BoxDecoration(
                            color: kPrimaryColor,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DesktopTooltip(
                            message:
                                resolved.title.isNotEmpty
                                    ? resolved.title
                                    : _railHeading(resolved.kind),
                            child: Text(
                              resolved.title.isNotEmpty
                                  ? resolved.title
                                  : _railHeading(resolved.kind),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                            ),
                          ),
                        ),
                        if (countText.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            countText,
                            style: const TextStyle(
                              color: kWhiteColor70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                        if (widget.onClose != null) ...[
                          const SizedBox(width: 8),
                          _GameRailCloseButton(onClose: widget.onClose!),
                        ],
                      ],
                    ),
                    if (rail.hasTabs) ...[
                      const SizedBox(height: 8),
                      DesktopSegmentedTabs<_GameRailTab>(
                        expand: true,
                        selected: selectedTab,
                        onChanged:
                            (tab) =>
                                ref
                                    .read(
                                      _gameRailTabProvider(railKey).notifier,
                                    )
                                    .state = tab,
                        tabs: const [
                          DesktopSegmentedTab(
                            value: _GameRailTab.source,
                            label: 'Source',
                            icon: Icons.route_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: _GameRailTab.event,
                            label: 'Event',
                            icon: Icons.event_note_rounded,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  physics: const DesktopScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                  children: [
                    if (upcomingGroups.isNotEmpty)
                      _UpcomingRoundsToggle(
                        expanded: showUpcoming,
                        roundCount: upcomingGroups.length,
                        gameCount: upcomingGames.length,
                        onToggle:
                            () =>
                                ref
                                    .read(
                                      _eventUpcomingVisibleProvider(
                                        railKey,
                                      ).notifier,
                                    )
                                    .state = !showUpcoming,
                      ),
                    for (final group in roundGroups)
                      _EventRoundSection(
                        group: group,
                        selectedGameId: selectedGameId,
                        selectedGameIds: _highlightedGameIds,
                        highlightedGameId: _highlightedGameId,
                        selectedRowKey:
                            (_highlightedGameId ?? selectedGameId) == null
                                ? null
                                : _rowKeyFor(
                                  _highlightedGameId ?? selectedGameId!,
                                ),
                        liveSummaries: liveSummaries,
                        eventGames:
                            resolved.kind == _GameListKind.event
                                ? allOrderedGames
                                : orderedGames,
                        tournamentTitle: resolved.title,
                        kind: resolved.kind,
                        activeArgs: effectiveArgs,
                        showBoardColumn: showBoardColumn,
                        onHighlightGame: _highlightGame,
                        onRangeHighlightGame:
                            (game) => _highlightGameRange(
                              orderedGames,
                              game,
                              fallbackAnchorGameId: selectedGameId,
                            ),
                      ),
                    if (resolved.kind == _GameListKind.database &&
                        (isLoadingMoreDatabase ||
                            databasePagination?.hasMore == true ||
                            databaseLoadError != null))
                      _GamesPaginationSection(
                        isLoading: isLoadingMoreDatabase,
                        error: databaseLoadError,
                      ),
                    if (activeContinuation != null &&
                        (isLoadingMoreContinuation ||
                            continuationSnapshot?.hasMore == true ||
                            continuationLoadError != null))
                      _GamesPaginationSection(
                        isLoading: isLoadingMoreContinuation,
                        error: continuationLoadError,
                      ),
                    if (resolved.isLoading) const _EventGamesLoadingSection(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
List<TournamentGameSummary> eventRailGamesForCopy({
  required List<TournamentGameSummary> orderedGames,
  required Set<String> selectedIds,
  required String? highlightedGameId,
  required String? selectedGameId,
  TournamentGameSummary? fallbackGame,
}) {
  if (orderedGames.isEmpty) {
    return fallbackGame == null
        ? const <TournamentGameSummary>[]
        : <TournamentGameSummary>[fallbackGame];
  }

  if (selectedIds.isNotEmpty) {
    final selected = orderedGames
        .where((game) => selectedIds.contains(game.id))
        .toList(growable: false);
    if (selected.isNotEmpty) return selected;
  }

  final activeId = highlightedGameId ?? selectedGameId ?? fallbackGame?.id;
  if (activeId != null && activeId.isNotEmpty) {
    final active = orderedGames.where((game) => game.id == activeId).toList();
    if (active.isNotEmpty) return <TournamentGameSummary>[active.first];
  }

  return fallbackGame == null
      ? const <TournamentGameSummary>[]
      : <TournamentGameSummary>[fallbackGame];
}

Future<int> _copyEventGameSummariesAsPgn({
  required BuildContext context,
  required WidgetRef ref,
  required List<TournamentGameSummary> games,
}) async {
  if (games.isEmpty) {
    showDesktopToast(context, 'Nothing to copy.', error: true);
    return 0;
  }

  final pgns = <String>[];
  var skipped = 0;
  for (final game in games) {
    final pgn = await _resolveEventGameSummaryPgn(ref, game);
    if (pgn != null && pgnHasMoves(pgn)) {
      pgns.add(pgn.trim());
    } else {
      skipped += 1;
    }
  }

  if (!context.mounted) return 0;
  if (pgns.isEmpty) {
    showDesktopToast(context, 'No PGN with moves to copy.', error: true);
    return 0;
  }

  await Clipboard.setData(ClipboardData(text: pgns.join('\n\n')));
  if (!context.mounted) return pgns.length;
  final count = pgns.length;
  final suffix = skipped > 0 ? ' ($skipped skipped without moves)' : '';
  showDesktopToast(
    context,
    'Copied $count ${count == 1 ? 'game' : 'games'} as PGN$suffix.',
  );
  return count;
}

Future<String?> _resolveEventGameSummaryPgn(
  WidgetRef ref,
  TournamentGameSummary game,
) async {
  final direct = game.pgn?.trim();
  if (direct != null && direct.isNotEmpty && pgnHasMoves(direct)) return direct;

  final id = game.id.trim();
  if (id.isEmpty) return null;

  try {
    final supabasePgn = await ref.read(gameRepositoryProvider).getGamePgn(id);
    if (supabasePgn != null && pgnHasMoves(supabasePgn)) {
      return supabasePgn.trim();
    }
  } catch (_) {}

  try {
    final fullGame = await ref
        .read(gamebaseRepositoryProvider)
        .getGameWithPgn(id);
    final pgn = fullGame?.pgn;
    if (pgn != null && pgnHasMoves(pgn)) return pgn.trim();
    final built = buildPgnFromGamebaseData(fullGame?.data);
    if (built != null && pgnHasMoves(built)) return built.trim();
  } catch (_) {}

  return null;
}

/// Switches the active board tab to the game offset by [delta] (e.g. -1 for
/// the previous game, +1 for the next) within the side-pane list resolved
/// for the active tab. No-op when the list is empty, the delta would land
/// out of bounds, or the active tab has no resolvable list.
///
/// Used by the board pane's keyboard layer to drive Cmd/Ctrl+↑/↓ without
/// duplicating the round-grouping or open-game wiring lived in this file.
Future<void> navigateActiveEventGame(WidgetRef ref, {required int delta}) {
  if (delta == 0) return Future.value();

  final activeTabId = ref.read(desktopTabsProvider).activeId;
  if (activeTabId == null) return Future.value();

  final rawActiveArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
  final activeArgs = rawActiveArgs?.copyWith(
    routeGames: _readContinuationGames(
      ref,
      rawActiveArgs.routeGamesContinuation,
      fallbackGames: rawActiveArgs.routeGames,
    ),
    eventGames: _readContinuationGames(
      ref,
      rawActiveArgs.eventGamesContinuation,
      fallbackGames: rawActiveArgs.eventGames,
    ),
    databaseGames: _readContinuationGames(
      ref,
      rawActiveArgs.databaseGamesContinuation,
      fallbackGames: rawActiveArgs.databaseGames,
    ),
  );
  final legacy = ref.read(tournamentGamesProvider);
  final rail = _resolveGameRail(activeArgs, legacy);
  final resolved = rail.resolve(
    _normalizeRailTab(ref.read(_gameRailTabProvider(activeTabId)), rail),
  );
  if (resolved == null || resolved.games.isEmpty) return Future.value();

  final groupsForOrdering =
      resolved.kind == _GameListKind.favorites
          ? _buildDateGroups(resolved.games)
          : _buildRoundGroups(
            resolved.kind == _GameListKind.event &&
                    !ref.read(_eventUpcomingVisibleProvider(activeTabId))
                ? resolved.games
                    .where((game) => !_isUpcomingGameForRail(game))
                    .toList(growable: false)
                : resolved.games,
            groupByRound: resolved.kind == _GameListKind.event,
          );
  final orderedGames = groupsForOrdering
      .expand((round) => round.games)
      .toList(growable: false);
  if (orderedGames.isEmpty) return Future.value();

  final selectedId = resolved.selectedGameId;
  final currentIdx =
      selectedId == null
          ? -1
          : orderedGames.indexWhere((g) => g.id == selectedId);
  // Step from the selection if there is one; otherwise treat the head/tail
  // of the list as the implicit anchor so a fresh tab still navigates.
  final anchor =
      currentIdx >= 0 ? currentIdx : (delta > 0 ? -1 : orderedGames.length);
  final nextIdx = (anchor + delta).clamp(0, orderedGames.length - 1);
  if (nextIdx == currentIdx) return Future.value();

  final nextGame = orderedGames[nextIdx];

  // The round/day section containing the next game may have been
  // collapsed by the user; expand it so the row scrolls into view once
  // the active tab re-renders.
  if (resolved.kind == _GameListKind.event) {
    final roundKey = _roundKey(nextGame);
    if (!ref.read(_eventRoundExpandedProvider(roundKey))) {
      ref.read(_eventRoundExpandedProvider(roundKey).notifier).state = true;
    }
  } else if (resolved.kind == _GameListKind.favorites) {
    final bucket = nextGame.lastMoveTime ?? nextGame.startsAt;
    final dayKey =
        bucket == null
            ? 'fav-day-0000-00-00'
            : 'fav-day-${DateFormat('yyyy-MM-dd').format(bucket)}';
    if (!ref.read(_eventRoundExpandedProvider(dayKey))) {
      ref.read(_eventRoundExpandedProvider(dayKey).notifier).state = true;
    }
  }

  final allGroupsForContext =
      resolved.kind == _GameListKind.favorites
          ? groupsForOrdering
          : _buildRoundGroups(
            resolved.games,
            groupByRound: resolved.kind == _GameListKind.event,
          );
  final contextGames = allGroupsForContext
      .expand((round) => round.games)
      .toList(growable: false);

  return _openEventGame(
    ref: ref,
    kind: resolved.kind,
    game: nextGame,
    eventGames:
        resolved.kind == _GameListKind.event ? contextGames : orderedGames,
    tournamentTitle: resolved.title,
    activeArgs: activeArgs,
  );
}

_ResolvedGameRail _resolveGameRail(
  BoardTabGameArgs? activeArgs,
  TournamentGamesState? legacy,
) {
  _ResolvedEventGames? source;
  _ResolvedEventGames? event;

  final routeGames = activeArgs?.routeGames ?? const <TournamentGameSummary>[];
  if (routeGames.isNotEmpty) {
    final title = activeArgs?.routeTitle.trim() ?? '';
    source = _ResolvedEventGames(
      kind: _GameListKind.source,
      title: title.isNotEmpty ? title : 'Source',
      games: routeGames,
      selectedGameId: activeArgs?.gameListSelectedId ?? activeArgs?.gameId,
      isLoading: false,
    );
  }

  final databaseGames =
      activeArgs?.databaseGames ?? const <TournamentGameSummary>[];
  if (databaseGames.isNotEmpty) {
    final title = activeArgs?.databaseTitle.trim() ?? '';
    source = _ResolvedEventGames(
      kind: _GameListKind.database,
      title: title.isNotEmpty ? title : 'Database',
      games: databaseGames,
      selectedGameId: activeArgs?.gameListSelectedId ?? activeArgs?.gameId,
      isLoading: false,
    );
  }

  final argsGames = activeArgs?.eventGames ?? const <TournamentGameSummary>[];
  // A board tab opened from the Favorites pane carries `viewSource ==
  // ChessboardView.favScorecard`. In that case the rail should keep the
  // favorites context — group by date, not by tournament round, and never
  // fall back to the legacy single-tournament title.
  final isFavorites = activeArgs?.viewSource == ChessboardView.favScorecard;
  if (isFavorites && argsGames.isNotEmpty) {
    source = _ResolvedEventGames(
      kind: _GameListKind.favorites,
      title: 'Favorites',
      games: argsGames,
      selectedGameId: activeArgs?.gameListSelectedId ?? activeArgs?.gameId,
      isLoading: activeArgs?.eventGamesLoading ?? false,
    );
    return _ResolvedGameRail(source: source);
  }

  if (argsGames.isNotEmpty || activeArgs == null) {
    final games =
        argsGames.isNotEmpty
            ? argsGames
            : (legacy?.games ?? const <TournamentGameSummary>[]);
    if (games.isNotEmpty) {
      final argsTitle = activeArgs?.tournamentTitle.trim() ?? '';
      final legacyTitle = legacy?.tournamentTitle.trim() ?? '';
      event = _ResolvedEventGames(
        kind: _GameListKind.event,
        title: argsTitle.isNotEmpty ? argsTitle : legacyTitle,
        games: games,
        selectedGameId:
            activeArgs?.gameListSelectedId ??
            activeArgs?.gameId ??
            legacy?.activeGameId,
        isLoading: activeArgs?.eventGamesLoading ?? false,
      );
    }
  }

  return _ResolvedGameRail(source: source, event: event);
}

BoardTabGamesContinuation? _continuationForKind(
  BoardTabGameArgs args,
  _GameListKind kind,
) {
  return switch (kind) {
    _GameListKind.event => args.eventGamesContinuation,
    _GameListKind.favorites => args.eventGamesContinuation,
    _GameListKind.source => args.routeGamesContinuation,
    _GameListKind.database => args.databaseGamesContinuation,
  };
}

_ContinuationSnapshot? _continuationSnapshotForKind(
  _GameListKind kind, {
  required _ContinuationSnapshot? routeSnapshot,
  required _ContinuationSnapshot? eventSnapshot,
  required _ContinuationSnapshot? databaseSnapshot,
}) {
  return switch (kind) {
    _GameListKind.event => eventSnapshot,
    _GameListKind.favorites => eventSnapshot,
    _GameListKind.source => routeSnapshot,
    _GameListKind.database => databaseSnapshot,
  };
}

String _continuationKey(String tabId, BoardTabGamesContinuation continuation) {
  return '$tabId:${continuation.signature}';
}

List<TournamentGameSummary> _summariesFromGameModels(
  List<GamesTourModel> games,
) {
  return [
    for (final game in games) TournamentGameSummary.fromGamesTourModel(game),
  ];
}

List<TournamentGameSummary>? _readContinuationGames(
  WidgetRef ref,
  BoardTabGamesContinuation? continuation, {
  required List<TournamentGameSummary> fallbackGames,
}) {
  if (continuation == null) return null;

  final providerGames = switch (continuation.kind) {
    BoardTabGamesContinuationKind.favorites => _summariesFromGameModels(
      ref.read(favoritesCombinedGamesProvider).filteredGames,
    ),
    BoardTabGamesContinuationKind.countrymen => _summariesFromGameModels(
      ref.read(countrymenCombinedGamesProvider).filteredGames,
    ),
    BoardTabGamesContinuationKind.playerProfile => () {
      final argument = continuation.argument;
      if (argument is! PlayerProfileKey) {
        return const <TournamentGameSummary>[];
      }
      return _summariesFromGameModels(
        ref.read(playerProfileGamesKeyProvider(argument)).filteredGames,
      );
    }(),
    BoardTabGamesContinuationKind.twicDatabase => _summariesFromGameModels(
      ref.read(gamebaseDatabaseGamesPaginatedProvider).games,
    ),
  };

  return _mergeGameSummaries(fallbackGames, providerGames);
}

List<TournamentGameSummary> _mergeGameSummaries(
  List<TournamentGameSummary> fallbackGames,
  List<TournamentGameSummary> providerGames,
) {
  if (providerGames.isEmpty) return fallbackGames;
  if (fallbackGames.isEmpty) return providerGames;

  final merged = List<TournamentGameSummary>.of(fallbackGames);
  final seenIds = <String>{
    for (final game in merged)
      if (game.id.trim().isNotEmpty) game.id.trim(),
  };
  for (final game in providerGames) {
    final id = game.id.trim();
    if (id.isEmpty || seenIds.add(id)) {
      merged.add(game);
    }
  }
  return merged;
}

enum _GameRailTab { source, event }

enum _GameListKind { event, source, database, favorites }

class _ResolvedGameRail {
  const _ResolvedGameRail({this.source, this.event});

  final _ResolvedEventGames? source;
  final _ResolvedEventGames? event;

  bool get isEmpty =>
      (source == null || source!.games.isEmpty) &&
      (event == null || event!.games.isEmpty);

  bool get hasTabs =>
      source != null &&
      source!.games.isNotEmpty &&
      event != null &&
      event!.games.isNotEmpty;

  _ResolvedEventGames? resolve(_GameRailTab tab) {
    return switch (tab) {
      _GameRailTab.source => source ?? event,
      _GameRailTab.event => event ?? source,
    };
  }
}

_GameRailTab _normalizeRailTab(
  _GameRailTab? requested,
  _ResolvedGameRail rail,
) {
  if (requested == _GameRailTab.event &&
      rail.event != null &&
      rail.event!.games.isNotEmpty) {
    return _GameRailTab.event;
  }
  if (requested == _GameRailTab.source &&
      rail.source != null &&
      rail.source!.games.isNotEmpty) {
    return _GameRailTab.source;
  }
  return rail.source != null && rail.source!.games.isNotEmpty
      ? _GameRailTab.source
      : _GameRailTab.event;
}

String _railHeading(_GameListKind kind) {
  return switch (kind) {
    _GameListKind.event => 'EVENT GAMES',
    _GameListKind.source => 'SOURCE GAMES',
    _GameListKind.database => 'DATABASE GAMES',
    _GameListKind.favorites => 'FAVORITES',
  };
}

String _railCountText({
  required _ResolvedEventGames resolved,
  required int loadedCount,
  required BoardTabDatabaseGamesPagination? pagination,
  required _ContinuationSnapshot? continuation,
  required bool isLoadingMore,
}) {
  if (resolved.isLoading || isLoadingMore) return 'Loading…';
  if (continuation != null) {
    final total = continuation.totalCount;
    if (total != null && total > loadedCount) {
      return '$loadedCount/$total games';
    }
    if (continuation.hasMore) return '$loadedCount+ games';
    return loadedCount == 1 ? '1 game' : '$loadedCount games';
  }
  if (resolved.kind == _GameListKind.database && pagination != null) {
    final total = pagination.totalCount;
    if (total != null && total > loadedCount) {
      return '$loadedCount/$total games';
    }
    if (pagination.hasMore) return '$loadedCount+ games';
    return loadedCount == 1 ? '1 game' : '$loadedCount games';
  }
  return loadedCount == 1 ? '1 game' : '$loadedCount games';
}

class _ResolvedEventGames {
  const _ResolvedEventGames({
    required this.kind,
    required this.title,
    required this.games,
    required this.selectedGameId,
    required this.isLoading,
  });

  final _GameListKind kind;
  final String title;
  final List<TournamentGameSummary> games;
  final String? selectedGameId;
  final bool isLoading;
}

class _ContinuationSnapshot {
  const _ContinuationSnapshot({
    required this.games,
    required this.isLoading,
    required this.hasMore,
    this.totalCount,
    this.error,
  });

  final List<TournamentGameSummary> games;
  final bool isLoading;
  final bool hasMore;
  final int? totalCount;
  final String? error;
}

class _EventRoundGroup {
  const _EventRoundGroup({
    required this.id,
    required this.title,
    required this.status,
    required this.startsAt,
    required this.games,
  });

  final String id;
  final String title;
  final RoundStatus status;
  final DateTime? startsAt;
  final List<TournamentGameSummary> games;
}

List<_EventRoundGroup> _buildRoundGroups(
  List<TournamentGameSummary> games, {
  required bool groupByRound,
}) {
  if (!groupByRound) {
    return [
      _EventRoundGroup(
        id: 'database-games',
        title: 'Games',
        status: _roundStatus(games),
        startsAt: null,
        games: List<TournamentGameSummary>.of(games),
      ),
    ];
  }

  final byRound = <String, List<TournamentGameSummary>>{};
  for (final game in games) {
    byRound
        .putIfAbsent(_roundKey(game), () => <TournamentGameSummary>[])
        .add(game);
  }

  final groups =
      byRound.entries.map((entry) {
        final roundGames = List<TournamentGameSummary>.from(entry.value)
          ..sort(_compareEventGamesInRound);
        final first = roundGames.first;
        return _EventRoundGroup(
          id: entry.key,
          title: _roundTitle(first),
          status: _roundStatus(roundGames),
          startsAt: _roundHeaderStartsAt(roundGames),
          games: roundGames,
        );
      }).toList();

  // Deterministic reverse chronological order. The mobile `sortRoundsForDisplay`
  // rotates a "focus" round to the top based on `DateTime.now()` and
  // live-status flips, so every parent rebuild (toggling a round card's
  // expand/collapse triggers one) can produce a different order — the
  // round cards and the games inside reshuffle as the focus round moves.
  // The board-pane rail wants a stable linear list, so sort by start time
  // with round-number / title tiebreakers and ignore the focus rotation.
  groups.sort(_compareRoundGroupsForRail);
  return groups;
}

int _compareRoundGroupsForRail(_EventRoundGroup a, _EventRoundGroup b) {
  final aStart = a.startsAt;
  final bStart = b.startsAt;
  if (aStart != null && bStart != null) {
    final c = bStart.compareTo(aStart);
    if (c != 0) return c;
  } else if (aStart != null) {
    return -1;
  } else if (bStart != null) {
    return 1;
  }

  final aNumber = _genericRoundNumberFromTitle(a.title);
  final bNumber = _genericRoundNumberFromTitle(b.title);
  if (aNumber != null && bNumber != null && aNumber != bNumber) {
    return bNumber.compareTo(aNumber);
  }
  if (aNumber != null && bNumber == null) return -1;
  if (aNumber == null && bNumber != null) return 1;

  return a.title.compareTo(b.title);
}

int? _genericRoundNumberFromTitle(String title) {
  final match = RegExp(
    r'^round\s+(\d+)$',
    caseSensitive: false,
  ).firstMatch(title.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Groups favorites-rail games by their playing day rather than by round,
/// since a favorites feed spans many tournaments and a "Round 1" header
/// would collide across them. Falls back to the game's [startsAt] when no
/// last-move time exists. Sorted most-recent-day-first; unknown dates are
/// bucketed together at the bottom.
List<_EventRoundGroup> _buildDateGroups(List<TournamentGameSummary> games) {
  const unknownDateKey = '0000-00-00';
  final byDay = <String, List<TournamentGameSummary>>{};
  final dateByKey = <String, DateTime?>{};
  for (final game in games) {
    final bucket = game.lastMoveTime ?? game.startsAt;
    final key =
        bucket == null
            ? unknownDateKey
            : DateFormat('yyyy-MM-dd').format(bucket);
    byDay.putIfAbsent(key, () => <TournamentGameSummary>[]).add(game);
    dateByKey.putIfAbsent(key, () => bucket);
  }

  final sortedKeys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

  return [
    for (final key in sortedKeys)
      _EventRoundGroup(
        id: 'fav-day-$key',
        title: _formatDayHeader(key),
        status: _roundStatus(byDay[key]!),
        startsAt: dateByKey[key],
        games: byDay[key]!,
      ),
  ];
}

class _EventLiveSummary {
  const _EventLiveSummary({
    required this.status,
    required this.lastMove,
    required this.lastMoveTime,
    required this.hasPgnMoves,
  });

  final String? status;
  final String? lastMove;
  final DateTime? lastMoveTime;
  final bool hasPgnMoves;

  factory _EventLiveSummary.from(LiveGameUpdate update) {
    return _EventLiveSummary(
      status: update.status,
      lastMove: update.lastMove?.trim(),
      lastMoveTime: _parseDateTime(update.lastMoveTime),
      hasPgnMoves: pgnHasMoves(update.pgn),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _EventLiveSummary &&
            other.status == status &&
            other.lastMove == lastMove &&
            other.lastMoveTime == lastMoveTime &&
            other.hasPgnMoves == hasPgnMoves;
  }

  @override
  int get hashCode => Object.hash(status, lastMove, lastMoveTime, hasPgnMoves);
}

class _EventLiveSummaries {
  const _EventLiveSummaries(this.byId);

  static const empty = _EventLiveSummaries(<String, _EventLiveSummary>{});

  final Map<String, _EventLiveSummary> byId;

  static _EventLiveSummaries from(Map<String, LiveGameUpdate>? updates) {
    if (updates == null || updates.isEmpty) return empty;
    return _EventLiveSummaries(
      Map<String, _EventLiveSummary>.unmodifiable({
        for (final entry in updates.entries)
          entry.key: _EventLiveSummary.from(entry.value),
      }),
    );
  }

  _EventLiveSummary? operator [](String id) => byId[id];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _EventLiveSummaries || other.byId.length != byId.length) {
      return false;
    }
    for (final entry in byId.entries) {
      if (other.byId[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final keys = byId.keys.toList()..sort();
    return Object.hashAll([
      for (final key in keys) Object.hash(key, byId[key]),
    ]);
  }
}

String _formatDayHeader(String dateKey) {
  if (dateKey == '0000-00-00') return 'Unknown date';
  final date = DateTime.tryParse(dateKey);
  if (date == null) return dateKey;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final day = DateTime(date.year, date.month, date.day);
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return DateFormat('EEEE, MMM d').format(date);
}

String _roundKey(TournamentGameSummary game) {
  final roundId = game.roundId.trim();
  if (roundId.isNotEmpty) return roundId;

  final slug = game.roundSlug.trim();
  if (slug.isNotEmpty) return slug.toLowerCase();

  final label = game.roundLabel.trim();
  if (label.isNotEmpty) return label.toLowerCase();

  return 'round-unknown';
}

String _roundTitle(TournamentGameSummary game) {
  final roundName = game.roundName.trim();
  if (roundName.isNotEmpty) return roundName;

  final label = game.roundLabel.trim();
  final compactLabelRound = RegExp(
    r'^r(?:ound)?[\s\-_]*(\d+)$',
    caseSensitive: false,
  ).firstMatch(label);
  if (compactLabelRound != null) {
    return 'Round ${compactLabelRound.group(1)}';
  }

  final slugRound =
      RegExp(
        r'round[\s\-_]*(\d+)',
        caseSensitive: false,
      ).firstMatch(game.roundSlug) ??
      RegExp(
        r'round[\s\-_]*(\d+)',
        caseSensitive: false,
      ).firstMatch(game.roundId);
  if (slugRound != null) return 'Round ${slugRound.group(1)}';

  if (label.isNotEmpty) return _humanizeRoundLabel(label);
  if (game.roundSlug.trim().isNotEmpty) {
    return _humanizeRoundLabel(game.roundSlug);
  }
  if (game.roundId.trim().isNotEmpty) return _humanizeRoundLabel(game.roundId);
  return 'Round';
}

String _humanizeRoundLabel(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return 'Round';

  final lower = normalized.toLowerCase();
  if (lower == 'quarterfinal' || lower == 'quarterfinals') {
    return 'Quarterfinals';
  }
  if (lower == 'semifinal' || lower == 'semifinals') {
    return 'Semifinals';
  }
  if (lower == 'final' || lower == 'finals') {
    return 'Finals';
  }

  return normalized
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

RoundStatus _roundStatus(List<TournamentGameSummary> games) {
  if (games.any(
    (game) => _isActualLiveGame(
      status: game.status,
      hasStarted: game.hasStarted,
      lastMoveTime: game.lastMoveTime,
    ),
  )) {
    return RoundStatus.live;
  }

  if (games.any((game) => game.status.isOngoing && game.hasStarted)) {
    return RoundStatus.ongoing;
  }

  if (games.isNotEmpty && games.every((game) => game.status.isFinished)) {
    return RoundStatus.completed;
  }

  return RoundStatus.upcoming;
}

DateTime? _roundHeaderStartsAt(List<TournamentGameSummary> games) {
  // Prefer the canonical round schedule propagated from the Tournament Games
  // header. `TournamentGameSummary.startsAt` comes from the game row and, for
  // some broadcasts, is the pairing/upload timestamp rather than the actual
  // round time shown in the tournament screen.
  final scheduled =
      games.map((game) => game.roundStartsAt).whereType<DateTime>();
  final scheduledStart = _earliestDateTime(scheduled);
  if (scheduledStart != null) return scheduledStart;

  return _earliestDateTime(
    games.map((game) => game.startsAt).whereType<DateTime>(),
  );
}

DateTime? _earliestDateTime(Iterable<DateTime> dates) {
  DateTime? earliest;
  for (final date in dates) {
    if (earliest == null || date.isBefore(earliest)) {
      earliest = date;
    }
  }
  return earliest;
}

int _compareEventGamesInRound(
  TournamentGameSummary a,
  TournamentGameSummary b,
) {
  final aBoard = a.boardNumber;
  final bBoard = b.boardNumber;
  if (aBoard != null && bBoard != null && aBoard != bBoard) {
    return aBoard.compareTo(bBoard);
  }
  if (aBoard != null && bBoard == null) return -1;
  if (aBoard == null && bBoard != null) return 1;

  final aGame = _parseGameNumber(a.roundSlug) ?? _parseGameNumber(a.id);
  final bGame = _parseGameNumber(b.roundSlug) ?? _parseGameNumber(b.id);
  if (aGame != null && bGame != null && aGame != bGame) {
    return aGame.compareTo(bGame);
  }
  if (aGame != null && bGame == null) return -1;
  if (aGame == null && bGame != null) return 1;

  final aStart = _eventGameDateTime(a);
  final bStart = _eventGameDateTime(b);
  if (aStart != null && bStart != null) {
    final startCompare = bStart.compareTo(aStart);
    if (startCompare != 0) return startCompare;
  } else if (aStart != null) {
    return -1;
  } else if (bStart != null) {
    return 1;
  }

  final whiteCompare = a.whitePlayer.compareTo(b.whitePlayer);
  if (whiteCompare != 0) return whiteCompare;
  return a.blackPlayer.compareTo(b.blackPlayer);
}

DateTime? _eventGameDateTime(TournamentGameSummary game) {
  return game.startsAt ?? game.lastMoveTime;
}

bool _isUpcomingGameForRail(TournamentGameSummary game) {
  return _roundStatus([game]) == RoundStatus.upcoming;
}

int? _parseGameNumber(String value) {
  if (value.trim().isEmpty) return null;
  final match = RegExp(
    r'(?:game|board|match)[\s_\-:.]*?(\d+)',
    caseSensitive: false,
  ).firstMatch(value);
  return match == null ? null : int.tryParse(match.group(1)!);
}

DateTime? _parseDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

bool _isActualLiveGame({
  required GameStatus status,
  required bool hasStarted,
  required DateTime? lastMoveTime,
}) {
  if (!status.isOngoing || !hasStarted || lastMoveTime == null) {
    return false;
  }
  return DateTime.now().difference(lastMoveTime) <= _kSidebarLiveActivityWindow;
}

Future<void> _insertEventGame({
  required WidgetRef ref,
  required TournamentGameSummary game,
  required String tournamentTitle,
}) async {
  var pgn = game.pgn?.trim() ?? '';
  if (!pgnHasMoves(pgn) && game.id.trim().isNotEmpty) {
    pgn =
        (await ref.read(gameRepositoryProvider).getGamePgn(game.id))?.trim() ??
        '';
  }
  if (!pgnHasMoves(pgn)) return;
  ref
      .read(boardGameInsertRequestProvider.notifier)
      .state = BoardGameInsertRequest(
    id: DateTime.now().microsecondsSinceEpoch,
    pgn: pgn,
    sourceLabel: _sourceLabelFromSummary(game, tournamentTitle),
  );
}

String _sourceLabelFromSummary(
  TournamentGameSummary game,
  String tournamentTitle,
) {
  final result = _resultForSummary(game.status);
  final white = _compactSummaryPlayerCitation(
    game.whitePlayer,
    game.whiteRating,
  );
  final black = _compactSummaryPlayerCitation(
    game.blackPlayer,
    game.blackRating,
  );
  final place = tournamentTitle.trim();
  final year = _summaryYear(game);
  return [
    if (result.isNotEmpty) result,
    if (white.isNotEmpty || black.isNotEmpty) '$white-$black',
    if (place.isNotEmpty) place,
    if (year.isNotEmpty) year,
  ].join(' ');
}

String _compactSummaryPlayerCitation(String rawName, int rating) {
  final clean = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return '';
  final parts =
      clean.split(RegExp(r'[ ,]+')).where((p) => p.isNotEmpty).toList();
  final last = parts.isEmpty ? clean : parts.first;
  final initial = parts.length >= 2 ? ',${parts[1].substring(0, 1)}' : '';
  final ratingText = rating > 0 ? ' ($rating)' : '';
  return '$last$initial$ratingText';
}

String _summaryYear(TournamentGameSummary game) {
  final date = game.lastMoveTime ?? game.startsAt;
  return date == null ? '' : date.year.toString();
}

String _resultForSummary(GameStatus status) => switch (status) {
  GameStatus.whiteWins => '1-0',
  GameStatus.blackWins => '0-1',
  GameStatus.draw => '½-½',
  _ => '',
};

Future<void> _openEventGame({
  required WidgetRef ref,
  ProviderContainer? container,
  required _GameListKind kind,
  required TournamentGameSummary game,
  required List<TournamentGameSummary> eventGames,
  required String tournamentTitle,
  required BoardTabGameArgs? activeArgs,
  bool inNewTab = false,
}) async {
  if (kind == _GameListKind.database) {
    final pgn = game.pgn?.trim() ?? '';
    final hasPlayableLocalPgn = pgnHasMoves(pgn);
    final args = BoardTabGameArgs(
      gameId: hasPlayableLocalPgn ? null : game.id,
      pgn: pgn,
      label:
          game.name.isEmpty
              ? '${game.whitePlayer} vs ${game.blackPlayer}'
              : game.name,
      whiteName: game.whitePlayer,
      blackName: game.blackPlayer,
      whiteFederation: game.whiteFederation,
      blackFederation: game.blackFederation,
      whiteTitle: game.whiteTitle,
      blackTitle: game.blackTitle,
      whiteRating: game.whiteRating,
      blackRating: game.blackRating,
      whiteFideId: game.whiteFideId,
      blackFideId: game.blackFideId,
      fenSeed: game.fen,
      initialFen: activeArgs?.initialFen ?? game.fen,
      viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
      databaseTitle: tournamentTitle,
      databaseGames: eventGames,
      databaseGamesPagination: activeArgs?.databaseGamesPagination,
      databaseGamesContinuation: activeArgs?.databaseGamesContinuation,
      gameListSelectedId: game.id,
    );

    openBoardGameTab(
      ref,
      args,
      focus: true,
      reuseExisting: false,
      replaceActive: !inNewTab,
    );
    return;
  }

  if (kind == _GameListKind.source) {
    final pgn = game.pgn?.trim() ?? '';
    final eventSeed = _eventSeedForSourceGame(game, activeArgs);
    final shouldHydrateEventGames =
        game.tourId.trim().isNotEmpty && eventSeed.length <= 1;
    final args = BoardTabGameArgs(
      gameId: game.id,
      pgn: pgn,
      label:
          game.name.isEmpty
              ? '${game.whitePlayer} vs ${game.blackPlayer}'
              : game.name,
      whiteName: game.whitePlayer,
      blackName: game.blackPlayer,
      whiteFederation: game.whiteFederation,
      blackFederation: game.blackFederation,
      whiteTitle: game.whiteTitle,
      blackTitle: game.blackTitle,
      whiteRating: game.whiteRating,
      blackRating: game.blackRating,
      whiteFideId: game.whiteFideId,
      blackFideId: game.blackFideId,
      fenSeed: game.fen,
      initialFen: activeArgs?.initialFen ?? game.fen,
      viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
      tournamentTitle: _eventTitleForGame(game, activeArgs),
      eventGames: eventSeed,
      eventGamesLoading: shouldHydrateEventGames,
      eventGamesContinuation: activeArgs?.eventGamesContinuation,
      routeTitle: tournamentTitle,
      routeGames: eventGames,
      routeGamesContinuation: activeArgs?.routeGamesContinuation,
      gameListSelectedId: game.id,
    );

    final tabId = openBoardGameTab(
      ref,
      args,
      focus: true,
      reuseExisting: false,
      replaceActive: !inNewTab,
    );
    if (shouldHydrateEventGames && container != null) {
      unawaited(
        _hydrateSourceGameEventContext(
          container: container,
          gameRepo: container.read(gameRepositoryProvider),
          tabId: tabId,
          game: game,
        ),
      );
    }
    return;
  }

  final pgn = game.pgn?.trim() ?? '';
  if (!inNewTab) {
    ref.read(tournamentGamesProvider.notifier).markActive(game.id);
  }

  final args = BoardTabGameArgs(
    gameId: game.id,
    pgn: pgn,
    label:
        game.name.isEmpty
            ? '${game.whitePlayer} vs ${game.blackPlayer}'
            : game.name,
    whiteName: game.whitePlayer,
    blackName: game.blackPlayer,
    whiteFederation: game.whiteFederation,
    blackFederation: game.blackFederation,
    whiteTitle: game.whiteTitle,
    blackTitle: game.blackTitle,
    whiteRating: game.whiteRating,
    blackRating: game.blackRating,
    whiteFideId: game.whiteFideId,
    blackFideId: game.blackFideId,
    fenSeed: game.fen,
    viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
    tournamentTitle: tournamentTitle,
    eventGames: eventGames,
    eventGamesContinuation: activeArgs?.eventGamesContinuation,
    routeTitle: activeArgs?.routeTitle ?? '',
    routeGames: activeArgs?.routeGames ?? const <TournamentGameSummary>[],
    routeGamesContinuation: activeArgs?.routeGamesContinuation,
    gameListSelectedId: game.id,
  );

  openBoardGameTab(
    ref,
    args,
    focus: true,
    reuseExisting: false,
    replaceActive: !inNewTab,
  );
}

List<TournamentGameSummary> _eventSeedForSourceGame(
  TournamentGameSummary game,
  BoardTabGameArgs? activeArgs,
) {
  final currentEvent =
      activeArgs?.eventGames ?? const <TournamentGameSummary>[];
  if (currentEvent.any((summary) => summary.id == game.id)) {
    return currentEvent;
  }
  return <TournamentGameSummary>[game];
}

String _eventTitleForGame(
  TournamentGameSummary game,
  BoardTabGameArgs? activeArgs,
) {
  final currentEvent =
      activeArgs?.eventGames ?? const <TournamentGameSummary>[];
  if (currentEvent.any((summary) => summary.id == game.id)) {
    final title = activeArgs?.tournamentTitle.trim() ?? '';
    if (title.isNotEmpty) return title;
  }
  final slug = game.tourSlug.trim();
  if (slug.isNotEmpty) return _humanizeContextLabel(slug);
  final tourId = game.tourId.trim();
  return tourId.isEmpty ? '' : tourId;
}

Future<void> _hydrateSourceGameEventContext({
  required ProviderContainer container,
  required GameRepository gameRepo,
  required String tabId,
  required TournamentGameSummary game,
}) async {
  final tourId = game.tourId.trim();
  if (tourId.isEmpty) return;

  List<TournamentGameSummary> hydrated;
  try {
    final rows = await gameRepo.getGamesByTourId(tourId);
    hydrated = [for (final row in rows) TournamentGameSummary.fromGame(row)];
  } catch (_) {
    hydrated = const <TournamentGameSummary>[];
  }

  container.read(boardTabGameArgsByTabIdProvider.notifier).update((m) {
    final latest = m[tabId];
    if (latest == null || latest.gameId != game.id) return m;
    final nextEventGames = hydrated.isEmpty ? latest.eventGames : hydrated;
    return <String, BoardTabGameArgs>{
      ...m,
      tabId: latest.copyWith(
        tournamentTitle: _eventTitleForHydratedGames(
          hydrated,
          fallback: latest.tournamentTitle,
        ),
        eventGames: nextEventGames,
        eventGamesLoading: false,
      ),
    };
  });
}

String _eventTitleForHydratedGames(
  List<TournamentGameSummary> games, {
  required String fallback,
}) {
  for (final game in games) {
    final title = _eventTitleForGame(game, null).trim();
    if (title.isNotEmpty) return title;
  }
  return fallback;
}

String _humanizeContextLabel(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  return text
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) {
        final lower = part.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ');
}

class _UpcomingRoundsToggle extends StatefulWidget {
  const _UpcomingRoundsToggle({
    required this.expanded,
    required this.roundCount,
    required this.gameCount,
    required this.onToggle,
  });

  final bool expanded;
  final int roundCount;
  final int gameCount;
  final VoidCallback onToggle;

  @override
  State<_UpcomingRoundsToggle> createState() => _UpcomingRoundsToggleState();
}

class _UpcomingRoundsToggleState extends State<_UpcomingRoundsToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final roundLabel =
        widget.roundCount == 1
            ? '1 upcoming round'
            : '${widget.roundCount} upcoming rounds';
    final gameLabel =
        widget.gameCount == 1
            ? '1 game scheduled'
            : '${widget.gameCount} games scheduled';

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit:
              (_) => setState(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggle,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SingleMotionBuilder(
              value: _pressed ? 0.985 : (_hovered ? 1.003 : 1.0),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder:
                  (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.14)
                          : kPrimaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color:
                        _hovered
                            ? kPrimaryColor.withValues(alpha: 0.42)
                            : kPrimaryColor.withValues(alpha: 0.24),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.expanded
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                      size: 17,
                      color: kPrimaryColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.expanded
                                ? 'Hide upcoming rounds'
                                : 'See $roundLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            gameLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor70,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      widget.expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: kWhiteColor70,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-round table block. Wraps [AdaptiveGamesTable] in `useFixedRowAlignment`
/// mode so the round's games render inside one [Table] (no inner scroll —
/// the outer ListView in [EventGamesTable] owns vertical scrolling). Lets
/// the framework compute column widths from the actual flag chips, name
/// strings, and Elo digits per round.
class _EventRoundTable extends StatelessWidget {
  const _EventRoundTable({
    required this.games,
    required this.selectedGameId,
    required this.selectedGameIds,
    required this.highlightedGameId,
    required this.selectedRowKey,
    required this.liveSummaries,
    required this.showBoardColumn,
    required this.onHighlightGame,
    required this.onRangeHighlightGame,
    required this.onOpenGame,
    required this.onInsertGame,
    required this.onCopyGames,
  });

  final List<TournamentGameSummary> games;
  final String? selectedGameId;
  final Set<String> selectedGameIds;
  final String? highlightedGameId;
  final GlobalKey? selectedRowKey;
  final _EventLiveSummaries liveSummaries;
  final bool showBoardColumn;
  final void Function(TournamentGameSummary game) onHighlightGame;
  final void Function(TournamentGameSummary game) onRangeHighlightGame;
  final Future<void> Function(
    TournamentGameSummary game, {
    required bool inNewTab,
  })
  onOpenGame;
  final Future<void> Function(TournamentGameSummary game) onInsertGame;
  final Future<void> Function(List<TournamentGameSummary> games) onCopyGames;

  String? get _activeSelectionId => highlightedGameId ?? selectedGameId;

  bool _isSelected(TournamentGameSummary game) {
    if (selectedGameIds.isNotEmpty) return selectedGameIds.contains(game.id);
    return game.id == _activeSelectionId;
  }

  @override
  Widget build(BuildContext context) {
    final columns = <AdaptiveColumn<TournamentGameSummary>>[
      if (showBoardColumn)
        AdaptiveColumn<TournamentGameSummary>(
          id: 'board',
          label: 'BD',
          minWidth: 28,
          cellBuilder:
              (_, game) => _BoardBadge(game: game, selected: _isSelected(game)),
        ),
      AdaptiveColumn<TournamentGameSummary>(
        id: 'white',
        label: 'WHITE',
        flex: 1,
        cellBuilder:
            (_, game) => _PlayerCell(
              name: game.whitePlayer,
              federation: game.whiteFederation,
              fideId: game.whiteFideId,
              title: game.whiteTitle,
              rating: game.whiteRating,
              selected: _isSelected(game),
            ),
      ),
      AdaptiveColumn<TournamentGameSummary>(
        id: 'black',
        label: 'BLACK',
        flex: 1,
        cellBuilder:
            (_, game) => _PlayerCell(
              name: game.blackPlayer,
              federation: game.blackFederation,
              fideId: game.blackFideId,
              title: game.blackTitle,
              rating: game.blackRating,
              selected: _isSelected(game),
            ),
      ),
      AdaptiveColumn<TournamentGameSummary>(
        id: 'status',
        label: 'RES',
        minWidth: 38,
        headerAlignment: Alignment.center,
        cellAlignment: Alignment.center,
        cellBuilder: (_, game) {
          final live = liveSummaries[game.id];
          final liveStatus = GameStatus.fromString(live?.status);
          final status =
              liveStatus == GameStatus.unknown ? game.status : liveStatus;
          final liveLastMoveTime = live?.lastMoveTime;
          final liveLastMove = live?.lastMove;
          final liveHasStarted =
              (liveLastMove != null && liveLastMove.isNotEmpty) ||
              (live?.hasPgnMoves ?? false);
          final hasStarted = liveHasStarted || game.hasStarted;
          final lastMoveTime = liveLastMoveTime ?? game.lastMoveTime;
          final isLive = _isActualLiveGame(
            status: status,
            hasStarted: hasStarted,
            lastMoveTime: lastMoveTime,
          );
          return _StatusPill(
            status: status,
            isLive: isLive,
            hasStarted: hasStarted,
          );
        },
      ),
    ];

    return AdaptiveGamesTable<TournamentGameSummary>(
      columns: columns,
      rows: games,
      // Round-section tables sit inside the outer rail ListView, so they
      // can't own internal vertical scrolling. `useFixedRowAlignment` flips
      // the body to a single [Table] (no inner ListView) — column widths
      // align *across* rows too, which is what the user expects within a
      // round.
      useFixedRowAlignment: true,
      minTableWidth: EventGamesTable.width,
      scrollController: ScrollController(),
      showHeader: false,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      rowMinHeight: 34,
      rowKeyBuilder:
          (game) => game.id == _activeSelectionId ? selectedRowKey : null,
      onRowTap: (game, {required bool inNewTab, required bool shiftPressed}) {
        if (inNewTab) {
          onHighlightGame(game);
          unawaited(onOpenGame(game, inNewTab: true));
          return;
        }
        final effectiveShiftPressed =
            shiftPressed || HardwareKeyboard.instance.isShiftPressed;
        if (effectiveShiftPressed) {
          onRangeHighlightGame(game);
          return;
        }
        onHighlightGame(game);
      },
      onRowDoubleTap: (game, {required bool inNewTab}) {
        onHighlightGame(game);
        unawaited(onOpenGame(game, inNewTab: inNewTab));
      },
      onRowSecondaryTap: (game, position) async {
        final action = await showDesktopContextMenu<_GameRowAction>(
          context: context,
          position: position,
          entries: const [
            DesktopContextMenuItem<_GameRowAction>(
              value: _GameRowAction.openInNewTab,
              icon: Icons.open_in_new_rounded,
              label: 'Open game in new tab',
              shortcut: 'Ctrl/⌘·Click',
            ),
            DesktopContextMenuItem<_GameRowAction>(
              value: _GameRowAction.insertGame,
              icon: Icons.call_merge_rounded,
              label: 'Insert game',
            ),
            DesktopContextMenuDivider<_GameRowAction>(),
            DesktopContextMenuItem<_GameRowAction>(
              value: _GameRowAction.copyPgn,
              icon: Icons.copy_rounded,
              label: 'Copy PGN',
              shortcut: 'Ctrl/⌘C',
            ),
          ],
        );
        if (action == null) return;
        switch (action) {
          case _GameRowAction.openInNewTab:
            await onOpenGame(game, inNewTab: true);
          case _GameRowAction.insertGame:
            await onInsertGame(game);
          case _GameRowAction.copyPgn:
            final copyGames = eventRailGamesForCopy(
              orderedGames: games,
              selectedIds: selectedGameIds,
              highlightedGameId: highlightedGameId,
              selectedGameId: selectedGameId,
              fallbackGame: game,
            );
            await onCopyGames(copyGames);
        }
      },
      rowDecorationBuilder: (game, hovered) {
        final selected = _isSelected(game);
        return BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.18)
                  : (hovered ? kBlack3Color : Colors.transparent),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.72)
                    : Colors.transparent,
            width: selected ? 1.2 : 1,
          ),
          boxShadow:
              selected
                  ? [
                    BoxShadow(
                      color: kPrimaryColor.withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ]
                  : null,
        );
      },
    );
  }
}

class _EventRoundSection extends ConsumerWidget {
  const _EventRoundSection({
    required this.group,
    required this.selectedGameId,
    required this.selectedGameIds,
    required this.highlightedGameId,
    required this.selectedRowKey,
    required this.liveSummaries,
    required this.eventGames,
    required this.tournamentTitle,
    required this.kind,
    required this.activeArgs,
    required this.showBoardColumn,
    required this.onHighlightGame,
    required this.onRangeHighlightGame,
  });

  final _EventRoundGroup group;
  final String? selectedGameId;
  final Set<String> selectedGameIds;
  final String? highlightedGameId;
  final GlobalKey? selectedRowKey;
  final _EventLiveSummaries liveSummaries;
  final List<TournamentGameSummary> eventGames;
  final String tournamentTitle;
  final _GameListKind kind;
  final BoardTabGameArgs? activeArgs;
  final bool showBoardColumn;
  final void Function(TournamentGameSummary game) onHighlightGame;
  final void Function(TournamentGameSummary game) onRangeHighlightGame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(_eventRoundExpandedProvider(group.id));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EventRoundHeader(
            group: group,
            expanded: expanded,
            onToggle:
                () =>
                    ref
                        .read(_eventRoundExpandedProvider(group.id).notifier)
                        .state = !expanded,
          ),
          if (expanded) ...[
            const SizedBox(height: 5),
            _EventRoundTable(
              games: group.games,
              selectedGameId: selectedGameId,
              selectedGameIds: selectedGameIds,
              highlightedGameId: highlightedGameId,
              selectedRowKey: selectedRowKey,
              liveSummaries: liveSummaries,
              showBoardColumn: showBoardColumn,
              onHighlightGame: onHighlightGame,
              onRangeHighlightGame: onRangeHighlightGame,
              onOpenGame: (game, {required bool inNewTab}) async {
                await _openEventGame(
                  ref: ref,
                  container: ProviderScope.containerOf(context, listen: false),
                  kind: kind,
                  game: game,
                  eventGames: eventGames,
                  tournamentTitle: tournamentTitle,
                  activeArgs: activeArgs,
                  inNewTab: inNewTab,
                );
              },
              onInsertGame:
                  (game) => _insertEventGame(
                    ref: ref,
                    game: game,
                    tournamentTitle: tournamentTitle,
                  ),
              onCopyGames:
                  (games) => _copyEventGameSummariesAsPgn(
                    context: context,
                    ref: ref,
                    games: games,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventGamesLoadingSection extends StatelessWidget {
  const _EventGamesLoadingSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 2, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LoadingRoundHeader(),
          SizedBox(height: 6),
          _LoadingGameRow(),
          SizedBox(height: 4),
          _LoadingGameRow(),
          SizedBox(height: 4),
          _LoadingGameRow(),
        ],
      ),
    );
  }
}

class _GamesPaginationSection extends StatelessWidget {
  const _GamesPaginationSection({required this.isLoading, required this.error});

  final bool isLoading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          child:
              hasError
                  ? Text(
                    "Couldn't load more games",
                    key: const ValueKey('database-pagination-error'),
                    style: TextStyle(
                      color: kRedColor.withValues(alpha: 0.82),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                  : Row(
                    key: ValueKey(
                      isLoading
                          ? 'database-pagination-loading'
                          : 'database-pagination-ready',
                    ),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLoading) ...[
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        isLoading ? 'Loading more games' : 'More games below',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
        ),
      ),
    );
  }
}

class _LoadingRoundHeader extends StatelessWidget {
  const _LoadingRoundHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: const Row(
        children: [
          _ShimmerBlock(width: 46, height: 18, radius: 3),
          SizedBox(width: 8),
          Expanded(child: _ShimmerBlock(height: 13, radius: 3)),
          SizedBox(width: 8),
          _ShimmerBlock(width: 18, height: 12, radius: 3),
        ],
      ),
    );
  }
}

class _LoadingGameRow extends StatelessWidget {
  const _LoadingGameRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        children: [
          _ShimmerBlock(width: 30, height: 18, radius: 4),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBlock(height: 12, radius: 3),
                SizedBox(height: 7),
                _ShimmerBlock(width: 56, height: 9, radius: 3),
              ],
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBlock(height: 12, radius: 3),
                SizedBox(height: 7),
                _ShimmerBlock(width: 56, height: 9, radius: 3),
              ],
            ),
          ),
          SizedBox(width: 10),
          _ShimmerBlock(width: 38, height: 20, radius: 999),
        ],
      ),
    );
  }
}

class _ShimmerBlock extends StatelessWidget {
  const _ShimmerBlock({this.width, required this.height, required this.radius});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: kWhiteColor.withValues(alpha: 0.08),
      ),
    );
  }
}

class _EventRoundHeader extends StatefulWidget {
  const _EventRoundHeader({
    required this.group,
    required this.expanded,
    required this.onToggle,
  });

  final _EventRoundGroup group;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_EventRoundHeader> createState() => _EventRoundHeaderState();
}

class _EventRoundHeaderState extends State<_EventRoundHeader> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final subtitle =
        group.startsAt == null
            ? ''
            : TimeUtils.formatRoundDateTime(group.startsAt);

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.985 : (_hovered ? 1.003 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : kBackgroundColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.28)
                          : kDividerColor,
                ),
              ),
              child: Row(
                children: [
                  if (group.status != RoundStatus.completed) ...[
                    _EventRoundStatusChip(status: group.status),
                    const SizedBox(width: 7),
                  ],
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  SingleMotionBuilder(
                    value: widget.expanded ? 1.0 : 0.0,
                    motion: DesktopMotion.layout,
                    builder:
                        (context, t, child) =>
                            Transform.rotate(angle: t * 3.14159, child: child),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 17,
                      color: kWhiteColor70,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EventRoundStatusChip extends StatelessWidget {
  const _EventRoundStatusChip({required this.status});

  final RoundStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      RoundStatus.live => ('LIVE', kRedColor),
      RoundStatus.ongoing => ('ONGOING', kGreenColor),
      RoundStatus.completed => ('DONE', kLightGreyColor),
      RoundStatus.upcoming => ('SOON', kPrimaryColor),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == RoundStatus.live) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

enum _GameRowAction { openInNewTab, insertGame, copyPgn }

class _BoardBadge extends StatelessWidget {
  const _BoardBadge({required this.game, required this.selected});

  final TournamentGameSummary game;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final boardNumber = game.boardNumber;
    final label = boardNumber == null ? '-' : '$boardNumber';
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: selected ? kPrimaryColor : kWhiteColor70,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

String _compactPlayerName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '-';
  final commaParts = trimmed.split(',');
  if (commaParts.length >= 2) {
    final last = commaParts.first.trim();
    final first = commaParts.sublist(1).join(',').trim();
    final initial =
        first.isEmpty
            ? ''
            : String.fromCharCode(first.runes.first).toUpperCase();
    return initial.isEmpty ? last : '$last,$initial';
  }

  // Most event-feed names already arrive as "Last, First". When they do
  // not, keep the source spelling so legacy search/test finders and unusual
  // name orders remain stable instead of guessing the surname.
  return trimmed;
}

class _PlayerCell extends StatelessWidget {
  const _PlayerCell({
    required this.name,
    required this.federation,
    required this.fideId,
    required this.title,
    required this.rating,
    required this.selected,
  });

  final String name;
  final String federation;
  final int? fideId;
  final String title;
  final int rating;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final playerName = _compactPlayerName(name);
    final titleText = title.trim();
    final ratingText = rating > 0 ? rating.toString() : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BackfilledFederationFlag(
          federation: federation,
          fideId: fideId,
          width: 13,
          height: 9,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(width: 4),
        if (titleText.isNotEmpty) ...[
          Text(
            titleText,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: const TextStyle(
              color: kPrimaryColor,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            playerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? kWhiteColor : kWhiteColor70,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
        if (ratingText.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(
            ratingText,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    required this.isLive,
    required this.hasStarted,
  });

  final GameStatus status;
  final bool isLive;
  final bool hasStarted;

  @override
  Widget build(BuildContext context) {
    if (isLive) {
      return const _LiveBadge();
    }
    if (status.isFinished) {
      return _ResultText(status: status);
    }
    if (status.isOngoing && hasStarted) {
      // Started but not classified as live (e.g. stale stream) — surface the
      // raw status text in the muted treatment so it reads as "in progress"
      // without competing with finished results.
      final txt = status.displayText.trim();
      return Text(
        txt.isEmpty ? '·' : txt,
        maxLines: 1,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: kWhiteColor.withValues(alpha: 0.55),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }
    return Text(
      'vs',
      maxLines: 1,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: kWhiteColor.withValues(alpha: 0.32),
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: kGreenColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        const Text(
          'LIVE',
          style: TextStyle(
            color: kGreenColor,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

class _ResultText extends StatelessWidget {
  const _ResultText({required this.status});

  final GameStatus status;

  @override
  Widget build(BuildContext context) {
    final (whiteLabel, blackLabel, outcome) = switch (status) {
      GameStatus.whiteWins => ('1', '0', _ResultOutcome.white),
      GameStatus.blackWins => ('0', '1', _ResultOutcome.black),
      GameStatus.draw => ('½', '½', _ResultOutcome.draw),
      _ => ('', '', _ResultOutcome.none),
    };
    if (outcome == _ResultOutcome.none) {
      return const Text(
        '—',
        style: TextStyle(color: kLightGreyColor, fontSize: 11),
      );
    }
    const base = TextStyle(
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
      height: 1.0,
    );
    final strong = base.copyWith(
      color: kWhiteColor,
      fontWeight: FontWeight.w700,
    );
    final weak = base.copyWith(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontWeight: FontWeight.w500,
    );
    final neutral = base.copyWith(
      color: kWhiteColor.withValues(alpha: 0.62),
      fontWeight: FontWeight.w600,
    );
    final sep = base.copyWith(color: kWhiteColor.withValues(alpha: 0.28));
    final whiteStyle = switch (outcome) {
      _ResultOutcome.white => strong,
      _ResultOutcome.black => weak,
      _ResultOutcome.draw => neutral,
      _ResultOutcome.none => base,
    };
    final blackStyle = switch (outcome) {
      _ResultOutcome.white => weak,
      _ResultOutcome.black => strong,
      _ResultOutcome.draw => neutral,
      _ResultOutcome.none => base,
    };
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: whiteLabel, style: whiteStyle),
          TextSpan(text: '–', style: sep),
          TextSpan(text: blackLabel, style: blackStyle),
        ],
      ),
      maxLines: 1,
    );
  }
}

enum _ResultOutcome { white, black, draw, none }

class _GameRailCloseButton extends StatefulWidget {
  const _GameRailCloseButton({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_GameRailCloseButton> createState() => _GameRailCloseButtonState();
}

class _GameRailCloseButtonState extends State<_GameRailCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Hide games',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    _hover
                        ? kWhiteColor.withValues(alpha: 0.10)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      _hover
                          ? kWhiteColor.withValues(alpha: 0.22)
                          : kDividerColor.withValues(alpha: 0.55),
                ),
              ),
              child: Icon(
                Icons.close_rounded,
                size: 13,
                color: _hover ? kWhiteColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
