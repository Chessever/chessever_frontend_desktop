import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/event_rail_games.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/adaptive_games_table.dart';
import 'package:chessever/desktop/widgets/board_unsaved_analysis_dialog.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
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
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/round_ordering.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/atomic_countdown_text.dart';

const Duration _kSidebarLiveActivityWindow = Duration(minutes: 120);

typedef _EventRoundExpansionKey = ({String id, bool initiallyExpanded});

final _eventRoundExpandedProvider = StateProvider.autoDispose
    .family<bool, _EventRoundExpansionKey>((ref, key) => key.initiallyExpanded);

/// Independently expanded Event-rail rounds, scoped per Board tab and event.
/// `null` means first use, when only the top-most round opens by default; an
/// empty set means the user explicitly collapsed every round.
final _eventRailExpandedRoundsProvider = StateProvider.autoDispose
    .family<Set<String>?, String>((ref, scope) => null);

Set<String> _resolveExpandedEventRoundIds({
  required Set<String>? stored,
  required List<String> orderedRoundIds,
}) {
  if (stored == null) {
    return orderedRoundIds.isEmpty
        ? const <String>{}
        : <String>{orderedRoundIds.first};
  }
  return stored.where(orderedRoundIds.contains).toSet();
}

@visibleForTesting
Set<String> eventRailExpandedRoundIdsAfterNavigation({
  required Set<String>? stored,
  required List<String> orderedRoundIds,
  required String destinationRoundId,
}) {
  final next = _resolveExpandedEventRoundIds(
    stored: stored,
    orderedRoundIds: orderedRoundIds,
  );
  if (orderedRoundIds.contains(destinationRoundId)) {
    next.add(destinationRoundId);
  }
  return Set<String>.unmodifiable(next);
}

final _gameRailTabProvider = StateProvider.autoDispose
    .family<_GameRailTab?, String>((ref, tabId) => null);

bool _eventGameReplacementConfirmationOpen = false;

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

@visibleForTesting
List<String> eventRailOrderedIdsForTesting(
  List<TournamentGameSummary> games, {
  bool preserveInputOrder = false,
}) {
  return _buildRoundGroups(
        games,
        groupByRound: true,
        preserveInputOrder: preserveInputOrder,
      )
      .expand((group) => group.games)
      .map((game) => game.id)
      .toList(growable: false);
}

@visibleForTesting
List<
  ({
    String id,
    String title,
    String status,
    bool pairingOnly,
    List<String> gameIds,
  })
>
eventRailRoundGroupsForTesting(List<TournamentGameSummary> games) {
  return [
    for (final group in _buildRoundGroups(games, groupByRound: true))
      (
        id: group.id,
        title: group.title,
        status: group.status.name,
        pairingOnly: group.pairingOnly,
        gameIds: [for (final game in group.games) game.id],
      ),
  ];
}

@visibleForTesting
List<({String? title, String? score, List<String> gameIds})>
eventRailRoundSegmentsForTesting(List<TournamentGameSummary> games) {
  return [
    for (final group in _buildRoundGroups(games, groupByRound: true))
      for (final segment in group.displaySegments)
        (
          title: segment.title,
          score: segment.score,
          gameIds: [for (final game in segment.games) game.id],
        ),
  ];
}

@visibleForTesting
List<TournamentGameSummary> eventRailMergeFreshEventGamesForTesting(
  List<TournamentGameSummary> fallbackGames,
  List<TournamentGameSummary> freshGames,
) {
  return _mergeFreshEventGameSummaries(fallbackGames, freshGames);
}

@visibleForTesting
List<TournamentGameSummary> eventRailMergeTournamentProviderGamesForTesting(
  List<TournamentGameSummary> fallbackGames,
  List<Games> freshGames,
) {
  return _mergeFreshTournamentProviderGames(fallbackGames, freshGames);
}

@visibleForTesting
List<LiveGamesBatchKey> eventRailLiveBatchKeysForTesting({
  required String activeTabId,
  required List<TournamentGameSummary> games,
  required bool isEventRail,
  required bool isDatabaseRail,
}) {
  return _eventRailLiveBatchKeys(
    activeTabId: activeTabId,
    games: games,
    kind:
        isDatabaseRail
            ? _GameListKind.database
            : isEventRail
            ? _GameListKind.event
            : _GameListKind.source,
  );
}

@visibleForTesting
List<TournamentGameSummary> eventRailWindowContinuationGamesForTesting({
  required List<TournamentGameSummary> fallbackGames,
  required List<TournamentGameSummary> providerGames,
  required String? selectedGameId,
  required int visibleLimit,
}) {
  return _windowContinuationGames(
    fallbackGames: fallbackGames,
    providerGames: providerGames,
    selectedGameId: selectedGameId,
    visibleLimit: visibleLimit,
  );
}

/// Board-pane companion table for the event that produced the active game.
///
/// The source of truth is the active Board tab's [BoardTabGameArgs]. The
/// legacy [tournamentGamesProvider] is kept as a fallback for older flows
/// that still load a tournament into the scratch board through PGN intake.
class EventGamesTable extends ConsumerStatefulWidget {
  const EventGamesTable({super.key, required this.tabId, this.onClose});

  static const double width = 320;

  final String tabId;

  /// Optional dismissal hook. When supplied, the rail renders a close
  /// affordance in its header that invokes this. Hosts wire it to the
  /// outer split-view controller's `collapse(...)` so the rail's
  /// collapsed-state restore button takes over.
  final VoidCallback? onClose;

  @override
  ConsumerState<EventGamesTable> createState() => _EventGamesTableState();
}

class _EventGamesTableState extends ConsumerState<EventGamesTable>
    with WidgetsBindingObserver {
  static const double _databaseScrollPrefetchExtent = 360;
  static const double _databaseGameRowExtent = 38;
  static const int _continuationInitialContextRadius = 30;
  static const int _continuationVisiblePageSize =
      _continuationInitialContextRadius * 2 + 1;
  static const int _eventRailRenderPageSize = kEventRailGamesPageSize;

  final ScrollController _scrollController = ScrollController();
  final FocusNode _railFocusNode = FocusNode(debugLabel: 'event-games-rail');
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Map<String, int> _continuationVisibleLimits = <String, int>{};
  String? _lastScrollSignature;
  String? _loadingDatabaseTabId;
  String? _databaseLoadErrorTabId;
  String? _highlightedGameId;
  String? _rangeAnchorGameId;
  Set<String> _highlightedGameIds = const <String>{};
  Future<void> _highlightNavigationTail = Future<void>.value();
  String? _lastCanonicalSelectionId;
  ({String staleId, String canonicalId})? _pendingHighlightSync;
  String? _databaseLoadError;
  String? _loadingContinuationKey;
  String? _continuationLoadErrorKey;
  String? _continuationLoadError;
  EventRailGamesProviderKey? _scheduledEventRailProviderKey;
  BoardTabEventGamesKey? _scheduledEventRailSelection;
  bool? _scheduledEventRailForeground;
  int _eventRailScheduleGeneration = 0;
  String? _activatedEventRailTourId;
  bool _eventRailWasActivated = false;
  bool _appLifecycleAllowsStreaming = true;
  String? _eventRailPageScope;
  String? _eventRailPageSelectionId;
  int _eventRailVisibleLimit = _eventRailRenderPageSize;

  /// Ordered-row count behind the current window, so growth stops at the end
  /// of what is loaded instead of climbing forever.
  int _eventRailWindowTotal = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycleAllowsStreaming = _lifecycleAllowsStreaming(
      WidgetsBinding.instance.lifecycleState,
    );
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final allowsStreaming = _lifecycleAllowsStreaming(state);
    if (_appLifecycleAllowsStreaming == allowsStreaming || !mounted) return;
    setState(() => _appLifecycleAllowsStreaming = allowsStreaming);
  }

  bool _lifecycleAllowsStreaming(AppLifecycleState? state) {
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  @override
  void dispose() {
    _eventRailScheduleGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _railFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    unawaited(_maybeLoadMoreDatabaseGames());
    unawaited(_maybeLoadMoreContinuedGames());
    // Revealing rows we already hold is a pure render concern, so it must not
    // sit behind the streaming/foreground gates that guard network fetches.
    _maybeGrowEventRailWindow();
    unawaited(_maybeLoadMoreEventRailGames());
  }

  void _maybeGrowEventRailWindow() {
    if (!mounted || !_scrollController.hasClients) return;
    if (_eventRailVisibleLimit >= _eventRailWindowTotal) return;
    final position = _scrollController.position;
    final nearBottom =
        position.maxScrollExtent <= 0 ||
        position.pixels >=
            position.maxScrollExtent - _databaseScrollPrefetchExtent;
    if (!nearBottom) return;
    _growEventRailWindow();
  }

  Future<void> _maybeLoadMoreEventRailGames({bool force = false}) async {
    if (!mounted) return;
    final activeTabId = widget.tabId;
    if (ref.read(desktopTabsProvider).activeId != activeTabId ||
        !ref.read(shouldStreamProvider) ||
        !_appLifecycleAllowsStreaming) {
      return;
    }
    final activeArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
    final eventKey = activeArgs?.eventGamesKey;
    if (activeArgs == null || eventKey == null) return;

    final rail = _resolveGameRail(
      activeArgs,
      ref.read(tournamentGamesProvider),
    );
    final selectedTab = _normalizeRailTab(
      ref.read(_gameRailTabProvider(activeTabId)),
      rail,
    );
    if (rail.resolve(selectedTab)?.kind != _GameListKind.event) return;

    if (!force) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final nearBottom =
          position.maxScrollExtent <= 0 ||
          position.pixels >=
              position.maxScrollExtent - _databaseScrollPrefetchExtent;
      if (!nearBottom) return;
    }

    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(ownerId: activeTabId, eventKey: eventKey),
    );
    await ref.read(provider.notifier).loadMore();
  }

  void _scheduleEventRailForeground(
    EventRailGamesProviderKey providerKey,
    BoardTabEventGamesKey selection,
    bool isForeground,
  ) {
    if (_scheduledEventRailProviderKey == providerKey &&
        _scheduledEventRailSelection == selection &&
        _scheduledEventRailForeground == isForeground) {
      return;
    }
    _scheduledEventRailProviderKey = providerKey;
    _scheduledEventRailSelection = selection;
    _scheduledEventRailForeground = isForeground;
    final generation = ++_eventRailScheduleGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _eventRailScheduleGeneration ||
          _scheduledEventRailProviderKey != providerKey ||
          _scheduledEventRailSelection != selection ||
          _scheduledEventRailForeground != isForeground) {
        return;
      }
      final currentSelection =
          ref
              .read(boardTabGameArgsByTabIdProvider)[widget.tabId]
              ?.eventGamesKey;
      if (currentSelection == null || currentSelection != selection) return;
      final notifier = ref.read(eventRailGamesProvider(providerKey).notifier);
      notifier.setForeground(isForeground);
      notifier.updateSelection(selection);
    });
  }

  void _clearScheduledEventRail() {
    if (_scheduledEventRailProviderKey == null &&
        _scheduledEventRailSelection == null &&
        _scheduledEventRailForeground == null) {
      return;
    }
    _eventRailScheduleGeneration++;
    _scheduledEventRailProviderKey = null;
    _scheduledEventRailSelection = null;
    _scheduledEventRailForeground = null;
  }

  /// Rows the rail is willing to build right now — a prefix of the ordered
  /// games that grows as the user scrolls, never a page the user has to click
  /// through. Every round above the limit is still reachable by scrolling, and
  /// the window always stretches far enough to contain the selected game.
  _EventRailWindow _eventRailWindowFor({
    required String scope,
    required List<TournamentGameSummary> games,
    required String? selectedGameId,
  }) {
    final normalizedSelectedId = selectedGameId?.trim();
    if (_eventRailPageScope != scope) {
      // New event (or new rail scope): start small again.
      _eventRailPageScope = scope;
      _eventRailPageSelectionId = normalizedSelectedId;
      _eventRailVisibleLimit = _eventRailRenderPageSize;
    } else if (_eventRailPageSelectionId != normalizedSelectedId) {
      _eventRailPageSelectionId = normalizedSelectedId;
    }

    // Never hide the selected row behind the limit, however deep it sits.
    if (normalizedSelectedId != null && normalizedSelectedId.isNotEmpty) {
      final selectedIndex = games.indexWhere(
        (game) => game.id == normalizedSelectedId,
      );
      if (selectedIndex >= _eventRailVisibleLimit) {
        _eventRailVisibleLimit =
            ((selectedIndex + 1) / _eventRailRenderPageSize).ceil() *
            _eventRailRenderPageSize;
      }
    }

    final limit =
        _eventRailVisibleLimit
            .clamp(
              _eventRailRenderPageSize,
              math.max(_eventRailRenderPageSize, games.length),
            )
            .toInt();
    _eventRailWindowTotal = games.length;
    final end = math.min(games.length, limit);
    return _EventRailWindow(
      games: games.sublist(0, end),
      hasMoreRows: end < games.length,
    );
  }

  /// Reveals the next slice of already-loaded rows. Paired with
  /// [_maybeLoadMoreEventRailGames], which fetches further rows from the
  /// backend, so one scroll gesture both reveals and fetches.
  void _growEventRailWindow() {
    if (!mounted) return;
    setState(() {
      _eventRailVisibleLimit = math.min(
        _eventRailVisibleLimit + _eventRailRenderPageSize,
        math.max(_eventRailRenderPageSize, _eventRailWindowTotal),
      );
    });
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

  void _queueEventHighlightMove(
    List<TournamentGameSummary> visibleOrderedGames, {
    required int delta,
    required String? fallbackSelectedGameId,
    required BoardTabGameArgs? activeArgs,
  }) {
    final previous = _highlightNavigationTail;
    _highlightNavigationTail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed hydration must not poison later keyboard navigation.
      }
      if (!mounted) return;
      final activeTabId = ref.read(desktopTabsProvider).activeId;
      final eventKey = activeArgs?.eventGamesKey;
      if (activeTabId == null || eventKey == null) {
        _moveHighlightedGame(
          visibleOrderedGames,
          delta: delta,
          fallbackSelectedGameId: fallbackSelectedGameId,
        );
        return;
      }

      final provider = eventRailGamesProvider(
        EventRailGamesProviderKey(ownerId: activeTabId, eventKey: eventKey),
      );
      final snapshot = ref.read(provider).valueOrNull;
      final available = snapshot?.games ?? visibleOrderedGames;
      final activeId = _highlightedGameId ?? fallbackSelectedGameId;
      final selectedIndex =
          activeId == null
              ? -1
              : available.indexWhere((game) => game.id == activeId);
      final selected = selectedIndex < 0 ? null : available[selectedIndex];
      if (selected == null) {
        _moveHighlightedGame(
          visibleOrderedGames,
          delta: delta,
          fallbackSelectedGameId: fallbackSelectedGameId,
        );
        return;
      }

      final notifier = ref.read(provider.notifier);
      notifier.updateSelection(
        eventKey.copyWith(
          selectedGameId: selected.id,
          selectedRoundId: selected.roundId,
          selectedBoardNumber: selected.boardNumber,
        ),
      );
      if (!await notifier.ensureNavigationAdjacency(delta) || !mounted) return;

      final refreshed = ref.read(provider).valueOrNull?.games ?? available;
      final visibleRoundKeys = visibleOrderedGames.map(_roundKey).toSet();
      final refreshedVisible = _buildRoundGroups(refreshed, groupByRound: true)
          .where((group) => visibleRoundKeys.contains(group.id))
          .expand((group) => group.games)
          .toList(growable: false);
      _moveHighlightedGame(
        refreshedVisible.isEmpty ? visibleOrderedGames : refreshedVisible,
        delta: delta,
        fallbackSelectedGameId: fallbackSelectedGameId,
      );
    }();
  }

  KeyEventResult _handleRailKeyEvent(
    KeyEvent event,
    List<TournamentGameSummary> orderedGames, {
    required _GameListKind kind,
    required Map<String, LiveGamesBatchKey> liveBatchKeyByGameId,
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
      if (kind == _GameListKind.event && activeArgs?.eventGamesKey != null) {
        _queueEventHighlightMove(
          orderedGames,
          delta: 1,
          fallbackSelectedGameId: selectedGameId,
          activeArgs: activeArgs,
        );
        return KeyEventResult.handled;
      }
      return _moveHighlightedGame(
            orderedGames,
            delta: 1,
            fallbackSelectedGameId: selectedGameId,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (kind == _GameListKind.event && activeArgs?.eventGamesKey != null) {
        _queueEventHighlightMove(
          orderedGames,
          delta: -1,
          fallbackSelectedGameId: selectedGameId,
          activeArgs: activeArgs,
        );
        return KeyEventResult.handled;
      }
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
      final openGame = _eventSummaryWithCurrentLiveUpdate(
        ref,
        game,
        liveBatchKeyByGameId[game.id],
      );
      if (_highlightedGameId != game.id) {
        setState(() => _highlightedGameId = game.id);
      }
      unawaited(
        _openEventGame(
          ref: ref,
          context: context,
          container: ProviderScope.containerOf(context, listen: false),
          kind: kind,
          game: openGame,
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

  /// Source and event rails have a deliberately local keyboard/multiselect
  /// cursor. Keep that cursor while the user moves through rows in the rail,
  /// but drop it when the board's own Cmd/Ctrl navigation changes the canonical
  /// selection. Otherwise the stale local cursor keeps overriding the game now
  /// shown on the board.
  void _synchronizeHighlight({
    required String? canonicalSelectionId,
    required List<TournamentGameSummary> games,
  }) {
    final canonicalId = canonicalSelectionId?.trim();
    final normalizedCanonicalId =
        canonicalId == null || canonicalId.isEmpty ? null : canonicalId;
    final previousCanonicalId = _lastCanonicalSelectionId;
    _lastCanonicalSelectionId = normalizedCanonicalId;

    final highlightedId = _highlightedGameId;
    if (highlightedId == null ||
        normalizedCanonicalId == null ||
        previousCanonicalId == normalizedCanonicalId ||
        highlightedId == normalizedCanonicalId ||
        !games.any((game) => game.id == normalizedCanonicalId)) {
      return;
    }

    final sync = (staleId: highlightedId, canonicalId: normalizedCanonicalId);
    _pendingHighlightSync = sync;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingHighlightSync != sync) return;
      _pendingHighlightSync = null;
      // Do not overwrite a new row selection the user made while this frame
      // was settling.
      if (_highlightedGameId != sync.staleId) return;
      setState(() {
        _highlightedGameId = null;
        _rangeAnchorGameId = null;
        _highlightedGameIds = const <String>{};
      });
    });
  }

  void _clearHighlightTracking() {
    _lastCanonicalSelectionId = null;
    _pendingHighlightSync = null;
  }

  void _scheduleSelectedScroll({
    required String? selectedGameId,
    required String signature,
    required List<_EventRoundGroup> visibleGroups,
  }) {
    if (selectedGameId == null || selectedGameId.isEmpty) return;
    if (_lastScrollSignature == signature) return;
    _lastScrollSignature = signature;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[selectedGameId]?.currentContext;
      if (rowContext != null) {
        _ensureEventRowVisible(rowContext);
        return;
      }
      if (!_scrollController.hasClients) return;
      final estimatedOffset = _estimatedEventRowOffset(
        visibleGroups,
        selectedGameId,
      );
      if (estimatedOffset == null) return;
      final position = _scrollController.position;
      final target =
          (estimatedOffset - position.viewportDimension * 0.34)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final mountedRow = _rowKeys[selectedGameId]?.currentContext;
              if (mountedRow != null) _ensureEventRowVisible(mountedRow);
            });
          });
    });
  }

  void _ensureEventRowVisible(BuildContext rowContext) {
    Scrollable.ensureVisible(
      rowContext,
      alignment: 0.34,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
  }

  double? _estimatedEventRowOffset(
    List<_EventRoundGroup> visibleGroups,
    String selectedGameId,
  ) {
    var offset = 0.0;
    for (final group in visibleGroups) {
      offset += 34; // round header
      for (final segment in group.displaySegments) {
        if (segment.title != null) offset += 24; // label + spacing
        for (final game in segment.games) {
          if (game.id == selectedGameId) return offset;
          offset += 34;
        }
      }
      offset += 8;
    }
    return null;
  }

  void _scheduleDatabaseSelectedScroll({
    required List<TournamentGameSummary> orderedGames,
    required String? selectedGameId,
    required String signature,
  }) {
    if (selectedGameId == null || selectedGameId.isEmpty) return;
    if (_lastScrollSignature == signature) return;
    _lastScrollSignature = signature;
    final selectedIndex = orderedGames.indexWhere(
      (game) => game.id == selectedGameId,
    );
    if (selectedIndex < 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target =
          (selectedIndex * _databaseGameRowExtent -
                  position.viewportDimension * 0.34)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
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
      final selectedGameId = _selectedGameIdForArgs(activeArgs);
      final fallbackGames = _fallbackGamesForKind(activeArgs, resolved.kind);
      final providerGames = _readContinuationProviderGames(ref, continuation);
      final visibleLimit = _continuationVisibleLimit(
        loadKey,
        fallbackCount: fallbackGames.length,
      );
      final hasHiddenLoadedGames = _hasHiddenContinuationProviderGames(
        providerGames: providerGames,
        selectedGameId: selectedGameId,
        visibleLimit: visibleLimit,
      );

      if (hasHiddenLoadedGames) {
        setState(() {
          _continuationVisibleLimits[loadKey] =
              visibleLimit + _continuationVisiblePageSize;
          if (_loadingContinuationKey == loadKey) {
            _loadingContinuationKey = null;
          }
        });
        return;
      }

      if (!_canLoadMoreContinuation(continuation)) {
        setState(() {
          if (_loadingContinuationKey == loadKey) {
            _loadingContinuationKey = null;
          }
        });
        return;
      }

      await _loadMoreContinuation(continuation);
      if (!mounted) return;
      setState(() {
        _continuationVisibleLimits[loadKey] =
            visibleLimit + _continuationVisiblePageSize;
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
    required String? selectedGameId,
  }) {
    if (continuation == null) return null;
    final continuationKey = _continuationKey(widget.tabId, continuation);
    final visibleLimit = _continuationVisibleLimit(
      continuationKey,
      fallbackCount: fallbackGames.length,
    );
    _ContinuationSnapshot snapshot({
      required List<TournamentGameSummary> providerGames,
      required bool isLoading,
      required bool providerHasMore,
      int? totalCount,
      String? error,
    }) {
      final games = _windowContinuationGames(
        fallbackGames: fallbackGames,
        providerGames: providerGames,
        selectedGameId: selectedGameId,
        visibleLimit: visibleLimit,
      );
      final hasHiddenLoadedGames = _hasHiddenContinuationProviderGames(
        providerGames: providerGames,
        selectedGameId: selectedGameId,
        visibleLimit: visibleLimit,
      );
      return _ContinuationSnapshot(
        games: games,
        isLoading: isLoading,
        hasMore: providerHasMore || hasHiddenLoadedGames,
        totalCount: totalCount,
        error: error,
      );
    }

    switch (continuation.kind) {
      case BoardTabGamesContinuationKind.favorites:
        final state = ref.watch(favoritesCombinedGamesProvider);
        return snapshot(
          providerGames: _summariesFromGameModels(state.filteredGames),
          isLoading: state.isLoading,
          providerHasMore: state.hasMore,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.countrymen:
        final state = ref.watch(countrymenCombinedGamesProvider);
        return snapshot(
          providerGames: _summariesFromGameModels(state.filteredGames),
          isLoading: state.isLoading,
          providerHasMore: state.hasMore,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.playerProfile:
        final argument = continuation.argument;
        if (argument is! PlayerProfileKey) return null;
        final state = ref.watch(playerProfileGamesKeyProvider(argument));
        return snapshot(
          providerGames: _summariesFromGameModels(state.filteredGames),
          isLoading: state.isLoading || state.isLoadingMore,
          providerHasMore: state.hasMorePages,
          totalCount: state.totalCount,
          error: state.error,
        );
      case BoardTabGamesContinuationKind.twicDatabase:
        final state = ref.watch(gamebaseDatabaseGamesPaginatedProvider);
        return snapshot(
          providerGames: _summariesFromGameModels(state.games),
          isLoading: state.isLoading,
          providerHasMore: state.hasMore,
          totalCount: state.totalCount > 0 ? state.totalCount : null,
          error: state.error,
        );
    }
  }

  ({List<TournamentGameSummary>? games, bool isLoading})
  _watchFreshTournamentEventGames(BoardTabGameArgs? activeArgs) {
    final tourId = _eventTourIdForArgs(activeArgs);
    if (tourId.isEmpty) return (games: null, isLoading: false);

    final fresh = ref.watch(gamesTourProvider(tourId));
    final freshGames = fresh.valueOrNull;
    if (freshGames == null) {
      return (games: null, isLoading: fresh.isLoading);
    }

    return (
      games: _mergeFreshTournamentProviderGames(
        activeArgs?.eventGames ?? const <TournamentGameSummary>[],
        freshGames,
      ),
      isLoading: false,
    );
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

  int _continuationVisibleLimit(
    String continuationKey, {
    required int fallbackCount,
  }) {
    final initial = math.max(fallbackCount, _continuationVisiblePageSize);
    final current = _continuationVisibleLimits[continuationKey];
    return current == null || current < initial ? initial : current;
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
    final isForegroundTab = ref.watch(
      desktopTabsProvider.select((state) => state.activeId == activeTabId),
    );
    final streamingEnabled = ref.watch(shouldStreamProvider);
    final shouldStreamVisibleRail =
        isForegroundTab && streamingEnabled && _appLifecycleAllowsStreaming;
    final activeSelectedGameId = _selectedGameIdForArgs(activeArgs);
    final requestedRailTab = ref.watch(_gameRailTabProvider(activeTabId));
    final eventRailProviderKey =
        activeArgs?.eventGamesKey == null
            ? null
            : EventRailGamesProviderKey(
              ownerId: activeTabId,
              eventKey: activeArgs!.eventGamesKey!,
            );
    final eventTourId = activeArgs?.eventGamesKey?.tourId.trim();
    if (_activatedEventRailTourId != eventTourId) {
      _activatedEventRailTourId = eventTourId;
      _eventRailWasActivated = false;
    }
    if (eventRailProviderKey != null && !_eventRailWasActivated) {
      final fallbackRail = _resolveGameRail(activeArgs, null);
      final fallbackResolved =
          fallbackRail.isEmpty
              ? null
              : fallbackRail.resolve(
                _normalizeRailTab(requestedRailTab, fallbackRail),
              );
      _eventRailWasActivated =
          shouldStreamVisibleRail &&
          (fallbackResolved == null ||
              fallbackResolved.kind == _GameListKind.event);
    }
    final eventRailAsync =
        eventRailProviderKey == null || !_eventRailWasActivated
            ? null
            : ref.watch(eventRailGamesProvider(eventRailProviderKey));
    final eventRailValue = eventRailAsync?.valueOrNull;
    final eventRailSnapshot =
        eventRailProviderKey == null || !_eventRailWasActivated
            ? null
            : _ContinuationSnapshot(
              games:
                  eventRailValue == null
                      ? activeArgs?.eventGames ??
                          const <TournamentGameSummary>[]
                      : _mergeFreshEventGameSummaries(
                        activeArgs?.eventGames ??
                            const <TournamentGameSummary>[],
                        eventRailValue.games,
                      ),
              isLoading: eventRailAsync?.isLoading ?? false,
              hasMore: eventRailValue?.hasMore ?? false,
              totalCount: eventRailValue?.totalCount,
              error: eventRailValue?.loadMoreError,
            );
    final routeContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.routeGamesContinuation,
      fallbackGames: activeArgs?.routeGames ?? const <TournamentGameSummary>[],
      selectedGameId: activeSelectedGameId,
    );
    final eventContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.eventGamesContinuation,
      fallbackGames: activeArgs?.eventGames ?? const <TournamentGameSummary>[],
      selectedGameId: activeSelectedGameId,
    );
    final freshTournamentEventGames =
        eventRailProviderKey == null
            ? _watchFreshTournamentEventGames(activeArgs)
            : (games: null, isLoading: false);
    final databaseContinuationSnapshot = _watchContinuationSnapshot(
      activeArgs?.databaseGamesContinuation,
      fallbackGames:
          activeArgs?.databaseGames ?? const <TournamentGameSummary>[],
      selectedGameId: activeSelectedGameId,
    );
    final baseEventGamesLoading = activeArgs?.eventGamesLoading ?? false;
    final effectiveArgs = activeArgs?.copyWith(
      routeGames: routeContinuationSnapshot?.games,
      eventGames:
          eventRailSnapshot?.games ??
          freshTournamentEventGames.games ??
          eventContinuationSnapshot?.games,
      databaseGames: databaseContinuationSnapshot?.games,
      eventGamesLoading:
          baseEventGamesLoading ||
          freshTournamentEventGames.isLoading ||
          (eventRailSnapshot?.isLoading ?? false),
    );
    final legacy =
        effectiveArgs == null ? ref.watch(tournamentGamesProvider) : null;
    final rail = _resolveGameRail(effectiveArgs, legacy);
    if (rail.isEmpty) {
      if (eventRailProviderKey == null || !_eventRailWasActivated) {
        _clearScheduledEventRail();
      } else {
        _scheduleEventRailForeground(
          eventRailProviderKey,
          activeArgs!.eventGamesKey!,
          false,
        );
      }
      return const SizedBox.shrink();
    }
    final railKey = activeTabId;
    final selectedTab = _normalizeRailTab(requestedRailTab, rail);
    final resolved = rail.resolve(selectedTab);
    if (resolved == null || resolved.games.isEmpty) {
      if (eventRailProviderKey != null && _eventRailWasActivated) {
        _scheduleEventRailForeground(
          eventRailProviderKey,
          activeArgs!.eventGamesKey!,
          false,
        );
      } else {
        _clearScheduledEventRail();
      }
      return const SizedBox.shrink();
    }
    if (eventRailProviderKey == null || !_eventRailWasActivated) {
      _clearScheduledEventRail();
    } else {
      _scheduleEventRailForeground(
        eventRailProviderKey,
        activeArgs!.eventGamesKey!,
        shouldStreamVisibleRail && resolved.kind == _GameListKind.event,
      );
    }
    if (resolved.kind == _GameListKind.source ||
        resolved.kind == _GameListKind.event) {
      _synchronizeHighlight(
        canonicalSelectionId: resolved.selectedGameId,
        games: resolved.games,
      );
    } else {
      _clearHighlightTracking();
    }
    final preserveEventInputOrder =
        resolved.kind == _GameListKind.event &&
        effectiveArgs?.viewSource == ChessboardView.playerProfile;

    // The rail seeds from the games handed over when the board opened, then the
    // provider resolves with the authoritative round catalog. Painting headings
    // from the seed first made the round list visibly re-sort a second later, so
    // the event rail waits for the catalog and paints its final order once.
    final isEventRail = resolved.kind == _GameListKind.event;
    final eventRoundCatalog =
        eventRailValue?.roundCatalog ?? const <EventRailRoundMetadata>[];
    // Only while the event-rail provider is genuinely in flight. Without the
    // activation check a rail that never runs the provider (profile/route rails)
    // would wait forever and render empty.
    final awaitingEventRoundCatalog =
        isEventRail &&
        !preserveEventInputOrder &&
        eventRailProviderKey != null &&
        _eventRailWasActivated &&
        eventRailValue == null;
    final allRoundGroups =
        resolved.kind == _GameListKind.database
            ? const <_EventRoundGroup>[]
            : resolved.kind == _GameListKind.favorites
            ? _buildDateGroups(resolved.games)
            : awaitingEventRoundCatalog
            ? const <_EventRoundGroup>[]
            : _buildRoundGroups(
              resolved.games,
              groupByRound: isEventRail,
              preserveInputOrder: preserveEventInputOrder,
              roundCatalog:
                  isEventRail
                      ? eventRoundCatalog
                      : const <EventRailRoundMetadata>[],
            );
    final allOrderedGames =
        resolved.kind == _GameListKind.database
            ? resolved.games
            : allRoundGroups
                .expand((round) => round.games)
                .toList(growable: false);
    final eventPage =
        resolved.kind == _GameListKind.event
            ? _eventRailWindowFor(
              scope:
                  '$activeTabId:${eventRailProviderKey?.eventKey.tourId.trim() ?? eventTourId ?? resolved.title}',
              games: allOrderedGames,
              selectedGameId: activeSelectedGameId,
            )
            : null;
    // A Board rail is intentionally page-bounded. Grouping every row and
    // watching every round made a thousand-board event expensive even though
    // Flutter lazily painted the outer list. The current page alone owns row
    // widgets, expansion providers, and realtime batch membership.
    final roundGroups =
        eventPage == null
            ? allRoundGroups
            : _buildRoundGroups(
              eventPage.games,
              groupByRound: true,
              preserveInputOrder: preserveEventInputOrder,
              // The catalog has to reach the groups that actually render.
              // Without it only rounds holding a game inside the current window
              // got a heading, so a 9-round event listed 9, 7, 5, 4 and simply
              // dropped 8, 6, 3, 2 and 1.
              roundCatalog: eventRoundCatalog,
            );
    final showBoardColumn = resolved.kind == _GameListKind.event;
    final expansionKeys = <String, _EventRoundExpansionKey>{
      for (final group in roundGroups)
        group.id: _eventRoundExpansionKey(
          group,
          groups: roundGroups,
          collapseUpcomingDuringActiveRound:
              resolved.kind == _GameListKind.event,
        ),
    };
    // Start with the top-most round only, then preserve each user-controlled
    // expansion independently. The event window still bounds how many rows can
    // be built and streamed at once for large broadcasts.
    final expandedRoundScope =
        '$activeTabId:${eventRailProviderKey?.eventKey.tourId.trim() ?? eventTourId ?? resolved.title}';
    final storedExpandedRoundIds =
        isEventRail
            ? ref.watch(_eventRailExpandedRoundsProvider(expandedRoundScope))
            : null;
    final expandedRoundIds =
        isEventRail
            ? _resolveExpandedEventRoundIds(
              stored: storedExpandedRoundIds,
              orderedRoundIds: <String>[
                for (final group in roundGroups) group.id,
              ],
            )
            : const <String>{};
    final expandedByGroup = <String, bool>{
      for (final group in roundGroups)
        group.id:
            isEventRail
                ? expandedRoundIds.contains(group.id)
                : ref.watch(
                  _eventRoundExpandedProvider(expansionKeys[group.id]!),
                ),
    };
    final visibleRoundGroups = [
      for (final group in roundGroups)
        if (expandedByGroup[group.id] == true) group,
    ];
    final orderedGames =
        resolved.kind == _GameListKind.database
            ? resolved.games
            : visibleRoundGroups
                .expand((round) => round.games)
                .toList(growable: false);
    final selectedGameId = resolved.selectedGameId;
    final activeSelectionId = _highlightedGameId ?? selectedGameId;
    _pruneRowKeys(orderedGames);
    final liveBatchKeys =
        shouldStreamVisibleRail
            ? _eventRailLiveBatchKeys(
              activeTabId: activeTabId,
              games: orderedGames,
              kind: resolved.kind,
            )
            : const <LiveGamesBatchKey>[];
    final liveBatchKeyByGameId = <String, LiveGamesBatchKey>{};
    for (final batchKey in liveBatchKeys) {
      for (final gameId in batchKey.gameIds) {
        liveBatchKeyByGameId[gameId] = batchKey;
      }
    }

    final scrollSignature =
        resolved.kind == _GameListKind.database
            ? [
              activeSelectionId ?? '',
              resolved.kind.index,
              orderedGames.length,
              orderedGames.isEmpty ? '' : orderedGames.first.id,
              orderedGames.isEmpty ? '' : orderedGames.last.id,
            ].join('|')
            // Only the selection's own context. Two reasons:
            //   * a signature over every game id rebuilt an O(total games)
            //     string on every build, and the rail rebuilds each live tick;
            //   * including row counts made the signature change whenever
            //     scroll-to-fetch appended rows, which re-fired the
            //     scroll-to-selection animation and yanked the rail back under
            //     the user. Rows arriving below the selection must never move
            //     the viewport.
            // Selection identity only. Anything that also varies with loaded
            // rows (row counts, whether the selection's group has resolved yet,
            // its expansion state) flipped this signature while the user was
            // scrolling, which re-fired the scroll-to-selection animation and
            // threw the viewport back to the selected game.
            : [resolved.kind.index, activeSelectionId ?? ''].join('|');
    if (resolved.kind == _GameListKind.database) {
      _scheduleDatabaseSelectedScroll(
        orderedGames: orderedGames,
        selectedGameId: activeSelectionId,
        signature: scrollSignature,
      );
    } else {
      _scheduleSelectedScroll(
        selectedGameId: activeSelectionId,
        signature: scrollSignature,
        visibleGroups: visibleRoundGroups,
      );
    }

    final databasePagination =
        resolved.kind == _GameListKind.database
            ? effectiveArgs?.databaseGamesPagination
            : null;
    final activeContinuation =
        effectiveArgs == null
            ? null
            : _continuationForKind(effectiveArgs, resolved.kind);
    final baseContinuationSnapshot = _continuationSnapshotForKind(
      resolved.kind,
      routeSnapshot: routeContinuationSnapshot,
      eventSnapshot: eventContinuationSnapshot,
      databaseSnapshot: databaseContinuationSnapshot,
    );
    final continuationSnapshot =
        resolved.kind == _GameListKind.event && eventRailSnapshot != null
            ? eventRailSnapshot
            : baseContinuationSnapshot;
    final continuationKey =
        activeContinuation != null
            ? _continuationKey(activeTabId, activeContinuation)
            : null;
    final isLoadingMoreDatabase = _loadingDatabaseTabId == activeTabId;
    final isLoadingMoreContinuation =
        (continuationSnapshot?.isLoading ?? false) ||
        (continuationKey != null && _loadingContinuationKey == continuationKey);
    final databaseLoadError =
        _databaseLoadErrorTabId == activeTabId ? _databaseLoadError : null;
    final continuationLoadError =
        continuationSnapshot?.error ??
        (continuationKey != null && _continuationLoadErrorKey == continuationKey
            ? _continuationLoadError
            : null);
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
            liveBatchKeyByGameId: liveBatchKeyByGameId,
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
                child:
                    resolved.kind == _GameListKind.database
                        ? _DatabaseGamesList(
                          controller: _scrollController,
                          games: orderedGames,
                          copyScopeGames: railActivationGames,
                          selectedGameId: selectedGameId,
                          selectedGameIds: _highlightedGameIds,
                          highlightedGameId: _highlightedGameId,
                          selectedRowKey:
                              (_highlightedGameId ?? selectedGameId) == null
                                  ? null
                                  : _rowKeyFor(
                                    _highlightedGameId ?? selectedGameId!,
                                  ),
                          tournamentTitle: resolved.title,
                          activeArgs: effectiveArgs,
                          isLoadingMoreDatabase: isLoadingMoreDatabase,
                          databaseHasMore: databasePagination?.hasMore == true,
                          databaseLoadError: databaseLoadError,
                          activeContinuation: activeContinuation,
                          isLoadingMoreContinuation: isLoadingMoreContinuation,
                          continuationHasMore:
                              continuationSnapshot?.hasMore == true,
                          continuationLoadError: continuationLoadError,
                          isLoading: resolved.isLoading,
                          onHighlightGame: _highlightGame,
                          onRangeHighlightGame:
                              (game) => _highlightGameRange(
                                orderedGames,
                                game,
                                fallbackAnchorGameId: selectedGameId,
                              ),
                        )
                        : _buildRoundGroupsList(
                          roundGroups: roundGroups,
                          expansionKeys: expansionKeys,
                          expandedByGroup: expandedByGroup,
                          selectedGameId: selectedGameId,
                          liveBatchKeyByGameId: liveBatchKeyByGameId,
                          eventGames:
                              resolved.kind == _GameListKind.event
                                  ? allOrderedGames
                                  : orderedGames,
                          orderedGames: orderedGames,
                          resolved: resolved,
                          effectiveArgs: effectiveArgs,
                          showBoardColumn: showBoardColumn,
                          activeContinuation: activeContinuation,
                          isEventRail: isEventRail,
                          expandedRoundScope: expandedRoundScope,
                          expandedRoundIds: expandedRoundIds,
                          eventWindow: eventPage,
                          hasEventRailPagination:
                              resolved.kind == _GameListKind.event &&
                              eventRailSnapshot != null,
                          isLoadingMoreContinuation: isLoadingMoreContinuation,
                          continuationHasMore:
                              continuationSnapshot?.hasMore == true,
                          continuationLoadError: continuationLoadError,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Lazily renders the round-grouped rail (event/favorites kinds).
  ///
  /// Uses [ListView.builder] so a tournament round with an arbitrary number
  /// of boards (a big open can publish hundreds) only instantiates the
  /// round sections near the viewport instead of building every section up
  /// front. Trailing pagination/loading affordances are appended after the
  /// round sections.
  Widget _buildRoundGroupsList({
    required List<_EventRoundGroup> roundGroups,
    required Map<String, _EventRoundExpansionKey> expansionKeys,
    required Map<String, bool> expandedByGroup,
    required String? selectedGameId,
    required Map<String, LiveGamesBatchKey> liveBatchKeyByGameId,
    required List<TournamentGameSummary> eventGames,
    required List<TournamentGameSummary> orderedGames,
    required _ResolvedEventGames resolved,
    required BoardTabGameArgs? effectiveArgs,
    required bool showBoardColumn,
    required BoardTabGamesContinuation? activeContinuation,
    required bool isEventRail,
    required String expandedRoundScope,
    required Set<String> expandedRoundIds,
    required _EventRailWindow? eventWindow,
    required bool hasEventRailPagination,
    required bool isLoadingMoreContinuation,
    required bool continuationHasMore,
    required String? continuationLoadError,
  }) {
    final selectedRowKey =
        (_highlightedGameId ?? selectedGameId) == null
            ? null
            : _rowKeyFor(_highlightedGameId ?? selectedGameId!);
    final items = <Widget>[];
    const rowChunkSize = 24;
    for (final group in roundGroups) {
      final expansionKey = expansionKeys[group.id]!;
      final expanded = expandedByGroup[group.id] == true;
      items.add(
        _EventRoundHeaderItem(
          group: group,
          expanded: expanded,
          onToggle: () {
            if (isEventRail) {
              final nextExpandedRoundIds = <String>{...expandedRoundIds};
              if (expanded) {
                nextExpandedRoundIds.remove(group.id);
              } else {
                nextExpandedRoundIds.add(group.id);
              }
              ref
                  .read(
                    _eventRailExpandedRoundsProvider(
                      expandedRoundScope,
                    ).notifier,
                  )
                  .state = Set<String>.unmodifiable(nextExpandedRoundIds);
              return;
            }
            ref.read(_eventRoundExpandedProvider(expansionKey).notifier).state =
                !expanded;
          },
        ),
      );
      if (expanded) {
        for (final segment in group.displaySegments) {
          if (segment.title != null) {
            items.add(
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _EventMatchupHeader(
                  title: segment.title!,
                  score: segment.score,
                ),
              ),
            );
          }
          for (
            var start = 0;
            start < segment.games.length;
            start += rowChunkSize
          ) {
            final end = math.min(start + rowChunkSize, segment.games.length);
            final chunk = segment.games.sublist(start, end);
            items.add(
              Padding(
                padding: EdgeInsets.only(top: start == 0 ? 5 : 0),
                child: _EventRoundTable(
                  games: chunk,
                  copyScopeGames: eventGames,
                  selectedGameId: selectedGameId,
                  selectedGameIds: _highlightedGameIds,
                  highlightedGameId: _highlightedGameId,
                  selectedRowKey:
                      chunk.any(
                            (game) =>
                                game.id ==
                                (_highlightedGameId ?? selectedGameId),
                          )
                          ? selectedRowKey
                          : null,
                  liveBatchKeyByGameId: liveBatchKeyByGameId,
                  showBoardColumn: showBoardColumn,
                  onHighlightGame: _highlightGame,
                  onRangeHighlightGame:
                      (game) => _highlightGameRange(
                        orderedGames,
                        game,
                        fallbackAnchorGameId: selectedGameId,
                      ),
                  onOpenGame: (
                    game, {
                    required bool inNewTab,
                    bool inNewWindow = false,
                  }) async {
                    await _openEventGame(
                      ref: ref,
                      context: context,
                      container: ProviderScope.containerOf(
                        context,
                        listen: false,
                      ),
                      kind: resolved.kind,
                      game: _eventSummaryWithCurrentLiveUpdate(
                        ref,
                        game,
                        liveBatchKeyByGameId[game.id],
                      ),
                      eventGames: eventGames,
                      tournamentTitle: resolved.title,
                      activeArgs: effectiveArgs,
                      inNewTab: inNewTab,
                      inNewWindow: inNewWindow,
                    );
                  },
                  onInsertGame:
                      (game) => _insertEventGame(
                        ref: ref,
                        game: game,
                        tournamentTitle: resolved.title,
                      ),
                  onCopyGames:
                      (games) => _copyEventGameSummariesAsPgn(
                        context: context,
                        ref: ref,
                        games: games,
                      ),
                ),
              ),
            );
          }
        }
      }
      items.add(const SizedBox(height: 8));
    }

    items.addAll(<Widget>[
      if ((activeContinuation != null || hasEventRailPagination) &&
          (isLoadingMoreContinuation ||
              continuationHasMore ||
              continuationLoadError != null))
        _GamesPaginationSection(
          isLoading: isLoadingMoreContinuation,
          error: continuationLoadError,
        ),
      if (resolved.isLoading) const _EventGamesLoadingSection(),
    ]);

    return ListView.builder(
      // A lazy list can retain offscreen children across parent rebuilds. Give
      // the streamed and non-streamed trees distinct identities so hiding the
      // Board tab disposes every cached status-cell subscription, including
      // rows outside the current viewport. The shared controller preserves
      // the user's scroll position when the foreground tree is restored.
      key: ValueKey<bool>(liveBatchKeyByGameId.isNotEmpty),
      controller: _scrollController,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      itemCount: items.length,
      itemBuilder: (context, index) {
        return items[index];
      },
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
final Map<String, Future<void>> _eventNavigationTailByTabId =
    <String, Future<void>>{};

Future<void> navigateActiveEventGame(
  WidgetRef ref, {
  required BuildContext context,
  required int delta,
}) async {
  if (delta == 0) return;

  final activeTabId = ref.read(desktopTabsProvider).activeId;
  if (activeTabId == null) return;

  final previous = _eventNavigationTailByTabId[activeTabId];
  final turn = Completer<void>();
  final tail = turn.future;
  _eventNavigationTailByTabId[activeTabId] = tail;
  try {
    if (previous != null) await previous;
    // A queued repeat belongs to the tab that was active when the user pressed
    // the key. Do not mutate a retained background tab after focus moved.
    if (ref.read(desktopTabsProvider).activeId != activeTabId ||
        !context.mounted) {
      return;
    }
    await _navigateActiveEventGameNow(
      ref,
      context: context,
      delta: delta,
      activeTabId: activeTabId,
    );
  } finally {
    if (!turn.isCompleted) turn.complete();
    if (identical(_eventNavigationTailByTabId[activeTabId], tail)) {
      _eventNavigationTailByTabId.remove(activeTabId);
    }
  }
}

Future<void> _navigateActiveEventGameNow(
  WidgetRef ref, {
  required BuildContext context,
  required int delta,
  required String activeTabId,
}) async {
  var activeArgs = _readNavigationBoardArgs(ref, activeTabId);
  var legacy = activeArgs == null ? ref.read(tournamentGamesProvider) : null;
  var rail = _resolveGameRail(activeArgs, legacy);
  var resolved = rail.resolve(
    _normalizeRailTab(ref.read(_gameRailTabProvider(activeTabId)), rail),
  );
  var navigationRoundCatalog = const <EventRailRoundMetadata>[];
  if (resolved == null || resolved.games.isEmpty) return;

  // A keyed event rail may still be publishing its initial bounded page.
  // Await that provider only when the Event list is actually selected; Source
  // navigation must never wake an unrelated tournament session.
  final initialEventKey = activeArgs?.eventGamesKey;
  if (resolved.kind == _GameListKind.event && initialEventKey != null) {
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: activeTabId,
        eventKey: initialEventKey,
      ),
    );
    if (ref.read(provider).valueOrNull == null) {
      await ref.read(provider.future);
      activeArgs = _readNavigationBoardArgs(ref, activeTabId);
      legacy = activeArgs == null ? ref.read(tournamentGamesProvider) : null;
      rail = _resolveGameRail(activeArgs, legacy);
      resolved = rail.resolve(
        _normalizeRailTab(ref.read(_gameRailTabProvider(activeTabId)), rail),
      );
      if (resolved == null || resolved.games.isEmpty) return;
    }

    // The provider seed is a union of canonical page zero and a bounded window
    // around the selected board. Best-effort: re-center within a round or
    // demand-hydrate lightweight metadata at a cross-round edge so a sparse
    // union does not skip boards. Do not hard-abort when hydration cannot run
    // (inactive / disposed rail, network failure, true event edge): the
    // already-resolved ordered list still supports prev/next when a neighbor
    // is already in memory. Index navigation below is a no-op at list edges.
    final notifier = ref.read(provider.notifier);
    notifier.updateSelection(initialEventKey);
    await notifier.ensureNavigationAdjacency(delta);
    navigationRoundCatalog =
        ref.read(provider).valueOrNull?.roundCatalog ??
        const <EventRailRoundMetadata>[];
    activeArgs = _readNavigationBoardArgs(ref, activeTabId);
    legacy = activeArgs == null ? ref.read(tournamentGamesProvider) : null;
    rail = _resolveGameRail(activeArgs, legacy);
    resolved = rail.resolve(
      _normalizeRailTab(ref.read(_gameRailTabProvider(activeTabId)), rail),
    );
    if (resolved == null || resolved.games.isEmpty) return;
  }

  var navigation = _navigationOrdering(
    resolved,
    activeArgs,
    roundCatalog: navigationRoundCatalog,
  );
  var orderedGames = navigation.orderedGames;
  var groupsForOrdering = navigation.groups;
  if (orderedGames.isEmpty) return;

  var currentIdx = _navigationSelectedIndex(resolved, orderedGames);
  var nextIdx = _navigationNextIndex(
    currentIndex: currentIdx,
    gameCount: orderedGames.length,
    delta: delta,
  );

  // Demand-load one adjacent metadata page when the current selection sits
  // at the loaded boundary. This crosses normal page boundaries without
  // starting the legacy all-games provider or fetching the entire event in a
  // single key press.
  final boundaryEventKey = activeArgs?.eventGamesKey;
  if (nextIdx == currentIdx &&
      resolved.kind == _GameListKind.event &&
      boundaryEventKey != null) {
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: activeTabId,
        eventKey: boundaryEventKey,
      ),
    );
    final providerState = ref.read(provider).valueOrNull;
    if (providerState?.hasMore == true &&
        await ref.read(provider.notifier).loadMore()) {
      activeArgs = _readNavigationBoardArgs(ref, activeTabId);
      rail = _resolveGameRail(activeArgs, null);
      resolved = rail.resolve(
        _normalizeRailTab(ref.read(_gameRailTabProvider(activeTabId)), rail),
      );
      if (resolved == null || resolved.games.isEmpty) return;
      navigationRoundCatalog =
          ref.read(provider).valueOrNull?.roundCatalog ??
          navigationRoundCatalog;
      navigation = _navigationOrdering(
        resolved,
        activeArgs,
        roundCatalog: navigationRoundCatalog,
      );
      orderedGames = navigation.orderedGames;
      groupsForOrdering = navigation.groups;
      currentIdx = _navigationSelectedIndex(resolved, orderedGames);
      nextIdx = _navigationNextIndex(
        currentIndex: currentIdx,
        gameCount: orderedGames.length,
        delta: delta,
      );
    }
  }
  if (orderedGames.isEmpty || nextIdx == currentIdx) return;

  final preserveEventInputOrder =
      resolved.kind == _GameListKind.event &&
      activeArgs?.viewSource == ChessboardView.playerProfile;

  final nextGame = orderedGames[nextIdx];

  // The round/day section containing the next game may have been collapsed by
  // the user. Add it to the Event rail's independent expansion set so keyboard
  // navigation reveals the row without collapsing any other open round.
  if (resolved.kind == _GameListKind.event) {
    final roundKey = _roundKeyResolverFor(resolved.games)(nextGame);
    final displayGroups = _buildRoundGroups(
      resolved.games,
      groupByRound: true,
      preserveInputOrder: preserveEventInputOrder,
    );
    final orderedRoundIds = <String>[
      for (final group in displayGroups) group.id,
    ];
    final expansionScope =
        '$activeTabId:${activeArgs?.eventGamesKey?.tourId.trim() ?? resolved.title}';
    final expansionProvider = _eventRailExpandedRoundsProvider(expansionScope);
    final expandedRoundIds = eventRailExpandedRoundIdsAfterNavigation(
      stored: ref.read(expansionProvider),
      orderedRoundIds: orderedRoundIds,
      destinationRoundId: roundKey,
    );
    ref.read(expansionProvider.notifier).state = expandedRoundIds;
  } else if (resolved.kind == _GameListKind.favorites) {
    final bucket = nextGame.lastMoveTime ?? nextGame.startsAt;
    final dayKey =
        bucket == null
            ? 'fav-day-0000-00-00'
            : 'fav-day-${DateFormat('yyyy-MM-dd').format(bucket)}';
    final expansionKey = (id: dayKey, initiallyExpanded: true);
    if (!ref.read(_eventRoundExpandedProvider(expansionKey))) {
      ref.read(_eventRoundExpandedProvider(expansionKey).notifier).state = true;
    }
  }

  final allGroupsForContext =
      resolved.kind == _GameListKind.favorites
          ? groupsForOrdering
          : _buildRoundGroups(
            resolved.games,
            groupByRound: resolved.kind == _GameListKind.event,
            preserveInputOrder: preserveEventInputOrder,
          );
  final contextGames = allGroupsForContext
      .expand((round) => round.games)
      .toList(growable: false);

  if (!context.mounted) return;
  await _openEventGame(
    ref: ref,
    context: context,
    kind: resolved.kind,
    game: nextGame,
    eventGames:
        resolved.kind == _GameListKind.event ? contextGames : orderedGames,
    tournamentTitle: resolved.title,
    activeArgs: activeArgs,
  );
}

BoardTabGameArgs? _readNavigationBoardArgs(WidgetRef ref, String activeTabId) {
  final raw = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
  if (raw == null) return null;
  final selectedGameId = _selectedGameIdForArgs(raw);

  List<TournamentGameSummary>? eventGames;
  final eventKey = raw.eventGamesKey;
  if (eventKey != null) {
    final fallbackRail = _resolveGameRail(raw, null);
    final selected =
        fallbackRail.isEmpty
            ? null
            : fallbackRail.resolve(
              _normalizeRailTab(
                ref.read(_gameRailTabProvider(activeTabId)),
                fallbackRail,
              ),
            );
    if (selected?.kind == _GameListKind.event) {
      final providerState =
          ref
              .read(
                eventRailGamesProvider(
                  EventRailGamesProviderKey(
                    ownerId: activeTabId,
                    eventKey: eventKey,
                  ),
                ),
              )
              .valueOrNull;
      if (providerState != null) {
        eventGames = _mergeFreshEventGameSummaries(
          raw.eventGames,
          providerState.games,
        );
      }
    }
  } else {
    eventGames = _readFreshTournamentEventGames(ref, raw);
  }

  return raw.copyWith(
    routeGames: _readContinuationGames(
      ref,
      raw.routeGamesContinuation,
      fallbackGames: raw.routeGames,
      selectedGameId: selectedGameId,
    ),
    eventGames:
        eventGames ??
        _readContinuationGames(
          ref,
          raw.eventGamesContinuation,
          fallbackGames: raw.eventGames,
          selectedGameId: selectedGameId,
        ),
    databaseGames: _readContinuationGames(
      ref,
      raw.databaseGamesContinuation,
      fallbackGames: raw.databaseGames,
      selectedGameId: selectedGameId,
    ),
  );
}

({List<_EventRoundGroup> groups, List<TournamentGameSummary> orderedGames})
_navigationOrdering(
  _ResolvedEventGames resolved,
  BoardTabGameArgs? activeArgs, {
  List<EventRailRoundMetadata> roundCatalog = const <EventRailRoundMetadata>[],
}) {
  final preserveEventInputOrder =
      resolved.kind == _GameListKind.event &&
      activeArgs?.viewSource == ChessboardView.playerProfile;
  final groups = switch (resolved.kind) {
    _GameListKind.favorites => _buildDateGroups(resolved.games),
    // Player-profile event rails mirror the source list's own ordering.
    _GameListKind.event when preserveEventInputOrder => _buildRoundGroups(
      resolved.games,
      groupByRound: true,
      preserveInputOrder: true,
    ),
    // Prev/next follows the same flattened order the user sees in the Event
    // rail, including the catalog's started-then-upcoming partition.
    _GameListKind.event => _buildRoundGroups(
      resolved.games,
      groupByRound: true,
      roundCatalog: roundCatalog,
    ),
    _GameListKind.source || _GameListKind.database => _buildRoundGroups(
      resolved.games,
      groupByRound: false,
    ),
  };
  return (
    groups: groups,
    orderedGames: groups.expand((round) => round.games).toList(growable: false),
  );
}

int _navigationSelectedIndex(
  _ResolvedEventGames resolved,
  List<TournamentGameSummary> orderedGames,
) {
  final selectedId = resolved.selectedGameId;
  return selectedId == null
      ? -1
      : orderedGames.indexWhere((game) => game.id == selectedId);
}

int _navigationNextIndex({
  required int currentIndex,
  required int gameCount,
  required int delta,
}) {
  if (gameCount <= 0) return -1;
  final anchor =
      currentIndex >= 0 ? currentIndex : (delta > 0 ? -1 : gameCount);
  return (anchor + delta).clamp(0, gameCount - 1);
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

List<TournamentGameSummary> _fallbackGamesForKind(
  BoardTabGameArgs args,
  _GameListKind kind,
) {
  return switch (kind) {
    _GameListKind.event => args.eventGames,
    _GameListKind.favorites => args.eventGames,
    _GameListKind.source => args.routeGames,
    _GameListKind.database => args.databaseGames,
  };
}

String? _selectedGameIdForArgs(BoardTabGameArgs? args) {
  final selected = args?.gameListSelectedId?.trim();
  if (selected != null && selected.isNotEmpty) return selected;

  final gameId = args?.gameId?.trim();
  return gameId == null || gameId.isEmpty ? null : gameId;
}

/// Returns one canonical tour id only when the tab carries an event context
/// for a single tournament. A Favorites tab deliberately uses `eventGames`
/// as a cross-event source list, so it must never be refreshed as though it
/// were one tournament rail.
String _eventTourIdForArgs(BoardTabGameArgs? args) {
  if (args == null ||
      args.viewSource == ChessboardView.favScorecard ||
      args.eventGames.isEmpty) {
    return '';
  }

  final sourceTourId = args.sourceGame?.tourId.trim() ?? '';
  if (sourceTourId.isNotEmpty) return sourceTourId;

  final tourIds = <String>{
    for (final game in args.eventGames)
      if (game.tourId.trim().isNotEmpty) game.tourId.trim(),
  };
  return tourIds.length == 1 ? tourIds.single : '';
}

List<TournamentGameSummary>? _readFreshTournamentEventGames(
  WidgetRef ref,
  BoardTabGameArgs? activeArgs,
) {
  final tourId = _eventTourIdForArgs(activeArgs);
  if (tourId.isEmpty) return null;

  final freshGames = ref.read(gamesTourProvider(tourId)).valueOrNull;
  if (freshGames == null) return null;
  return _mergeFreshTournamentProviderGames(
    activeArgs?.eventGames ?? const <TournamentGameSummary>[],
    freshGames,
  );
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
  required String? selectedGameId,
}) {
  if (continuation == null) return null;

  return _windowContinuationGames(
    fallbackGames: fallbackGames,
    providerGames: _readContinuationProviderGames(ref, continuation),
    selectedGameId: selectedGameId,
    visibleLimit: math.max(
      fallbackGames.length,
      _EventGamesTableState._continuationVisiblePageSize,
    ),
  );
}

List<TournamentGameSummary> _readContinuationProviderGames(
  WidgetRef ref,
  BoardTabGamesContinuation continuation,
) {
  return switch (continuation.kind) {
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
}

bool _hasHiddenContinuationProviderGames({
  required List<TournamentGameSummary> providerGames,
  required String? selectedGameId,
  required int visibleLimit,
}) {
  if (providerGames.length <= visibleLimit) return false;
  final selected = selectedGameId?.trim();
  if (selected == null || selected.isEmpty) return true;
  return providerGames.any((game) => game.id == selected);
}

List<TournamentGameSummary> _windowContinuationGames({
  required List<TournamentGameSummary> fallbackGames,
  required List<TournamentGameSummary> providerGames,
  required String? selectedGameId,
  required int visibleLimit,
}) {
  if (providerGames.isEmpty) return fallbackGames;

  final limit = math.max(1, visibleLimit);
  final selected = selectedGameId?.trim();
  if (selected == null || selected.isEmpty) {
    return providerGames.take(limit).toList(growable: false);
  }

  final selectedIndex = providerGames.indexWhere((game) => game.id == selected);
  if (selectedIndex < 0) {
    return fallbackGames.isNotEmpty
        ? fallbackGames
        : providerGames.take(limit).toList(growable: false);
  }

  final before = (limit - 1) ~/ 2;
  var start = math.max(0, selectedIndex - before);
  var end = math.min(providerGames.length, start + limit);
  start = math.max(0, end - limit);
  final window = providerGames.sublist(start, end);
  if (fallbackGames.isEmpty) return window;

  final fallbackById = <String, TournamentGameSummary>{
    for (final game in fallbackGames)
      if (game.id.trim().isNotEmpty) game.id: game,
  };
  return [for (final game in window) fallbackById[game.id] ?? game];
}

List<LiveGamesBatchKey> _eventRailLiveBatchKeys({
  required String activeTabId,
  required List<TournamentGameSummary> games,
  required _GameListKind kind,
}) {
  if (kind == _GameListKind.database || games.isEmpty) {
    return const <LiveGamesBatchKey>[];
  }

  // Keep membership stable when a game changes from ongoing to finished.
  // Filtering terminal rows here shifted every later chunk and recreated all
  // downstream realtime channels after one result. Visible row leaves still
  // auto-dispose their batch when scrolled away or hidden.
  final liveGames = games
      .where((game) => game.id.trim().isNotEmpty)
      .toList(growable: false);
  if (liveGames.isEmpty) return const <LiveGamesBatchKey>[];

  final scopeId = 'desktop-event-rail:$activeTabId:${kind.index}';
  final keys = <LiveGamesBatchKey>[];
  for (
    var start = 0;
    start < liveGames.length;
    start += kLiveContextBatchSize
  ) {
    final end =
        start + kLiveContextBatchSize > liveGames.length
            ? liveGames.length
            : start + kLiveContextBatchSize;
    final chunk = liveGames.sublist(start, end);
    keys.add(
      LiveGamesBatchKey(
        scopeId:
            '$scopeId:${start ~/ kLiveContextBatchSize}:${chunk.first.id}:${chunk.last.id}',
        gameIds: chunk.map((game) => game.id),
      ),
    );
  }
  return keys;
}

List<TournamentGameSummary> _mergeFreshTournamentProviderGames(
  List<TournamentGameSummary> fallbackGames,
  List<Games> freshGames,
) {
  return _mergeFreshEventGameSummaries(fallbackGames, [
    for (final game in freshGames) TournamentGameSummary.fromGame(game),
  ]);
}

List<TournamentGameSummary> _mergeFreshEventGameSummaries(
  List<TournamentGameSummary> fallbackGames,
  List<TournamentGameSummary> freshGames,
) {
  if (freshGames.isEmpty) return fallbackGames;
  final normalizedFreshGames = [
    for (final game in freshGames) _normalizeFreshEventGameSummary(game),
  ];
  if (fallbackGames.isEmpty) return normalizedFreshGames;

  final freshById = <String, TournamentGameSummary>{};
  for (final game in normalizedFreshGames) {
    final id = game.id.trim();
    if (id.isNotEmpty) freshById[id] = game;
  }
  if (freshById.isEmpty) return fallbackGames;

  final merged = <TournamentGameSummary>[];
  final seen = <String>{};
  for (final fallback in fallbackGames) {
    final id = fallback.id.trim();
    final fresh = freshById[id];
    if (id.isNotEmpty) seen.add(id);
    merged.add(
      fresh == null ? fallback : _mergeFreshEventGameSummary(fallback, fresh),
    );
  }

  for (final fresh in normalizedFreshGames) {
    final id = fresh.id.trim();
    if (id.isEmpty || seen.add(id)) {
      merged.add(fresh);
    }
  }
  return merged;
}

TournamentGameSummary _normalizeFreshEventGameSummary(
  TournamentGameSummary fresh,
) {
  if (fresh.hasStarted || !fresh.status.isOngoing) return fresh;
  return fresh.copyWith(hasStarted: true);
}

TournamentGameSummary _mergeFreshEventGameSummary(
  TournamentGameSummary current,
  TournamentGameSummary fresh,
) {
  return TournamentGameSummary(
    id: fresh.id,
    name: fresh.name,
    whitePlayer: fresh.whitePlayer,
    blackPlayer: fresh.blackPlayer,
    hasPgn: fresh.hasPgn || current.hasPgn,
    tourId: fresh.tourId.isNotEmpty ? fresh.tourId : current.tourId,
    tourSlug: fresh.tourSlug.isNotEmpty ? fresh.tourSlug : current.tourSlug,
    whiteFederation:
        fresh.whiteFederation.isNotEmpty
            ? fresh.whiteFederation
            : current.whiteFederation,
    blackFederation:
        fresh.blackFederation.isNotEmpty
            ? fresh.blackFederation
            : current.blackFederation,
    whiteTitle:
        fresh.whiteTitle.isNotEmpty ? fresh.whiteTitle : current.whiteTitle,
    blackTitle:
        fresh.blackTitle.isNotEmpty ? fresh.blackTitle : current.blackTitle,
    whiteRating:
        fresh.whiteRating > 0 ? fresh.whiteRating : current.whiteRating,
    blackRating:
        fresh.blackRating > 0 ? fresh.blackRating : current.blackRating,
    whiteClockSeconds: fresh.whiteClockSeconds ?? current.whiteClockSeconds,
    blackClockSeconds: fresh.blackClockSeconds ?? current.blackClockSeconds,
    whiteFideId: fresh.whiteFideId ?? current.whiteFideId,
    blackFideId: fresh.blackFideId ?? current.blackFideId,
    fen: fresh.fen ?? current.fen,
    roundId: fresh.roundId.isNotEmpty ? fresh.roundId : current.roundId,
    roundSlug: fresh.roundSlug.isNotEmpty ? fresh.roundSlug : current.roundSlug,
    roundLabel:
        fresh.roundLabel.isNotEmpty ? fresh.roundLabel : current.roundLabel,
    roundName: fresh.roundName.isNotEmpty ? fresh.roundName : current.roundName,
    boardNumber: fresh.boardNumber ?? current.boardNumber,
    status: mergeEventGameStatus(
      current: current.status,
      incoming: fresh.status,
    ),
    openingName: fresh.openingName ?? current.openingName,
    lastMoveTime: fresh.lastMoveTime ?? current.lastMoveTime,
    startsAt: fresh.startsAt ?? current.startsAt,
    roundStartsAt: fresh.roundStartsAt ?? current.roundStartsAt,
    hasStarted: fresh.hasStarted || current.hasStarted,
    pgn: fresh.pgn ?? current.pgn,
    whiteTeam: fresh.whiteTeam.isNotEmpty ? fresh.whiteTeam : current.whiteTeam,
    blackTeam: fresh.blackTeam.isNotEmpty ? fresh.blackTeam : current.blackTeam,
    localPgnSource: fresh.localPgnSource ?? current.localPgnSource,
  );
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
    this.pairingOnly = false,
    this.catalogOnly = false,
    this.segments,
  });

  final String id;
  final String title;
  final RoundStatus status;
  final DateTime? startsAt;

  /// Rows in render order. Always the flattened concatenation of
  /// [displaySegments], so keyboard navigation and range selection walk the
  /// exact order shown on screen.
  final List<TournamentGameSummary> games;

  /// True for upcoming rounds whose rows are published pairings with no
  /// moves yet (mobile's pairing-only round cards).
  final bool pairingOnly;

  /// True for a round the tournament's round metadata knows about but which has
  /// no loaded rows yet. It renders as a collapsed heading, so the full round
  /// list is stable from first paint and nothing appears later.
  final bool catalogOnly;

  /// Matchup slices for team / knockout rounds; null for plain rounds.
  final List<_EventRoundSegment>? segments;

  List<_EventRoundSegment> get displaySegments =>
      segments ?? [_EventRoundSegment(games: games)];
}

/// A slice of a round's rows rendered under an optional matchup header.
/// Regular events yield one header-less segment; team events group boards
/// by team matchup; knockout match rounds group by player pairing —
/// mirroring the mobile Games tab's team / knockout match cards.
class _EventRoundSegment {
  const _EventRoundSegment({this.title, this.score, required this.games});

  final String? title;
  final String? score;
  final List<TournamentGameSummary> games;
}

List<_EventRoundGroup> _buildRoundGroups(
  List<TournamentGameSummary> games, {
  required bool groupByRound,
  bool preserveInputOrder = false,
  List<EventRailRoundMetadata> roundCatalog = const <EventRailRoundMetadata>[],
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

  final keyFor = _roundKeyResolverFor(games);
  final byRound = <String, List<TournamentGameSummary>>{};
  for (final game in games) {
    byRound
        .putIfAbsent(keyFor(game), () => <TournamentGameSummary>[])
        .add(game);
  }

  // When the tournament's round metadata is available it owns the round list and
  // its order, permanently. Deriving order from loaded rows meant a round flipped
  // status the moment its games arrived, `sortRoundsForDisplay` re-partitioned,
  // and the list reshuffled mid-scroll — which moved the top-most (expanded)
  // round and made the user's scroll offset meaningless, so the rail appeared to
  // jump back to the top. Rows now fill fixed slots instead of deciding them.
  if (roundCatalog.isNotEmpty && !preserveInputOrder) {
    return _catalogOrderedRoundGroups(
      roundCatalog: roundCatalog,
      gamesByRoundKey: byRound,
    );
  }

  if (preserveInputOrder) {
    // Player-profile event rails mirror the source list's own ordering.
    return [
      for (final entry in byRound.entries)
        _EventRoundGroup(
          id: entry.key,
          title: _roundGroupTitle(entry.value),
          status: _roundStatus(entry.value),
          startsAt: _roundHeaderStartsAt(entry.value),
          games: List<TournamentGameSummary>.from(entry.value),
        ),
    ];
  }

  // Mobile Games-tab parity (mobile `gamesTourGroupedProvider` +
  // `sortRoundsForDisplay`):
  //  - a round shows its board-visible games (resolved players + a played
  //    position);
  //  - upcoming rounds with published pairings surface those pairings;
  //  - rounds whose rows are all "?" placeholders stay hidden until real
  //    pairings or moves arrive.
  final playedGroups = <_EventRoundGroup>[];
  final pairingGroups = <_EventRoundGroup>[];
  for (final entry in byRound.entries) {
    final visible =
        entry.value.where(_isBoardVisibleEventGame).toList()
          ..sort(_compareEventGamesInRound);
    if (visible.isNotEmpty) {
      playedGroups.add(_eventRoundGroupFor(entry.key, visible));
      continue;
    }

    final pairings =
        entry.value.where(_hasResolvedPlayers).toList()
          ..sort(_comparePairingGames);
    if (pairings.isEmpty) continue;
    final group = _eventRoundGroupFor(entry.key, pairings, pairingOnly: true);
    if (group.status != RoundStatus.upcoming) continue;
    pairingGroups.add(group);
  }

  // Use the same ordering as the mobile Games tab for every visible round,
  // including rounds whose pairings were published before play begins. This
  // keeps the active/latest round first and prevents advance pairings from
  // displacing it. The shared sorter promotes only the next round when it is
  // inside the configured promotion window and all started rounds are done.
  // Rounds the catalog knows about but that have no rows yet still get a
  // heading. Without this the rail only showed rounds whose games happened to
  // be loaded, so rounds appeared (and the list re-ordered) as rows streamed in.
  final groups = [...playedGroups, ...pairingGroups];
  final groupsById = <String, _EventRoundGroup>{
    for (final group in groups) group.id: group,
  };
  final models = [
    for (final group in groups)
      GamesAppBarModel(
        id: group.id,
        name: group.title,
        startsAt: group.startsAt,
        roundStatus: group.status,
      ),
  ];
  final sortedModels = sortRoundsForDisplay(
    models,
    resolveDate: (model) => model.startsAt,
    isRoundFullyPlayed: (model) {
      final group = groupsById[model.id];
      return group != null &&
          group.games.isNotEmpty &&
          group.games.every((game) => game.status.isFinished);
    },
  );
  return [
    for (final model in sortedModels)
      if (groupsById[model.id] case final group?) group,
  ];
}

_EventRoundExpansionKey _eventRoundExpansionKey(
  _EventRoundGroup group, {
  required List<_EventRoundGroup> groups,
  required bool collapseUpcomingDuringActiveRound,
}) {
  final hasActiveRound =
      collapseUpcomingDuringActiveRound &&
      groups.any((candidate) {
        final gameStatus = _roundStatus(candidate.games);
        return gameStatus == RoundStatus.live ||
            gameStatus == RoundStatus.ongoing;
      });
  return (
    id: group.id,
    initiallyExpanded:
        !group.catalogOnly &&
        !(hasActiveRound && group.status == RoundStatus.upcoming),
  );
}

_EventRoundGroup _eventRoundGroupFor(
  String id,
  List<TournamentGameSummary> games, {
  bool pairingOnly = false,
}) {
  final startsAt = _roundHeaderStartsAt(games);
  final segments = _buildEventRoundSegments(games);
  final orderedGames =
      segments == null
          ? games
          : [for (final segment in segments) ...segment.games];
  return _EventRoundGroup(
    id: id,
    title: _roundGroupTitle(games),
    status: _eventRoundStatus(games, startsAt: startsAt),
    startsAt: startsAt,
    games: orderedGames,
    pairingOnly: pairingOnly,
    segments: segments,
  );
}

/// Round-group key resolver. Knockout stages surface as several DB rounds
/// (`game-1`, `game-2`, `tiebreak-…`) that all carry the same propagated
/// stage `roundName`, so grouping prefers that name — a stage then renders
/// as one section, mirroring the mobile Games tab's synthetic stage rounds.
/// Games missing the name (fresh realtime rows) inherit it from siblings
/// that share their `roundId`.
/// Round key used for both catalog rounds and game-derived rounds, so the two
/// sides always line up (see [_roundKeyResolverFor], which groups by name).
String _catalogRoundKey(EventRailRoundMetadata round) =>
    round.name.trim().isEmpty
        ? 'round-id:${round.id.trim()}'
        : 'round-name:${round.name.trim().toLowerCase()}';

/// Builds one group per catalog round, in a fixed order taken from the schedule.
///
/// Started rounds first, newest first, then the remaining schedule ascending —
/// the same shape `sortRoundsForDisplay` produces, but computed only from
/// `startsAt`, which never changes as rows load. A round with no rows yet is
/// marked [_EventRoundGroup.catalogOnly] and renders as a collapsed heading.
List<_EventRoundGroup> _catalogOrderedRoundGroups({
  required List<EventRailRoundMetadata> roundCatalog,
  required Map<String, List<TournamentGameSummary>> gamesByRoundKey,
}) {
  final now = DateTime.now();
  final seen = <String>{};
  final started = <EventRailRoundMetadata>[];
  final upcoming = <EventRailRoundMetadata>[];
  for (final round in roundCatalog) {
    if (round.id.trim().isEmpty) continue;
    if (!seen.add(_catalogRoundKey(round))) continue;
    final startsAt = round.startsAt;
    if (startsAt != null && startsAt.isAfter(now)) {
      upcoming.add(round);
    } else {
      started.add(round);
    }
  }

  int byStart(EventRailRoundMetadata a, EventRailRoundMetadata b, bool asc) {
    final aAt = a.startsAt ?? a.createdAt;
    final bAt = b.startsAt ?? b.createdAt;
    int result;
    if (aAt == null && bAt == null) {
      result = a.name.compareTo(b.name);
    } else if (aAt == null) {
      result = 1;
    } else if (bAt == null) {
      result = -1;
    } else {
      result = aAt.compareTo(bAt);
      if (result == 0) result = a.name.compareTo(b.name);
    }
    return asc ? result : -result;
  }

  started.sort((a, b) => byStart(a, b, false));
  upcoming.sort((a, b) => byStart(a, b, true));

  final ordered = <_EventRoundGroup>[];
  for (final round in <EventRailRoundMetadata>[...started, ...upcoming]) {
    final key = _catalogRoundKey(round);
    final rows = gamesByRoundKey[key] ?? const <TournamentGameSummary>[];
    if (rows.isEmpty) {
      ordered.add(
        _EventRoundGroup(
          id: key,
          title: round.name.trim().isEmpty ? 'Round' : round.name.trim(),
          status:
              round.startsAt != null && round.startsAt!.isAfter(now)
                  ? RoundStatus.upcoming
                  : RoundStatus.completed,
          startsAt: round.startsAt,
          games: const <TournamentGameSummary>[],
          catalogOnly: true,
        ),
      );
      continue;
    }
    final visible =
        rows.where(_isBoardVisibleEventGame).toList()
          ..sort(_compareEventGamesInRound);
    final pairings =
        visible.isNotEmpty
            ? visible
            : (rows.where(_hasResolvedPlayers).toList()
              ..sort(_comparePairingGames));
    ordered.add(
      _eventRoundGroupFor(
        key,
        pairings.isEmpty ? rows : pairings,
        pairingOnly: visible.isEmpty && pairings.isNotEmpty,
      ),
    );
  }

  // Any round that produced rows but is absent from the catalog still belongs on
  // screen; keep it after the catalog's own order so nothing disappears.
  for (final entry in gamesByRoundKey.entries) {
    if (seen.contains(entry.key)) continue;
    ordered.add(_eventRoundGroupFor(entry.key, entry.value));
  }
  return ordered;
}

String Function(TournamentGameSummary game) _roundKeyResolverFor(
  List<TournamentGameSummary> games,
) {
  final nameByRoundId = <String, String>{};
  for (final game in games) {
    final roundId = game.roundId.trim();
    final name = game.roundName.trim();
    if (roundId.isEmpty || name.isEmpty) continue;
    nameByRoundId.putIfAbsent(roundId, () => name);
  }
  return (game) {
    var name = game.roundName.trim();
    if (name.isEmpty) {
      final roundId = game.roundId.trim();
      name = roundId.isEmpty ? '' : (nameByRoundId[roundId] ?? '');
    }
    if (name.isNotEmpty) return 'round-name:${name.toLowerCase()}';
    return _roundKey(game);
  };
}

String _roundGroupTitle(List<TournamentGameSummary> games) {
  for (final game in games) {
    final name = game.roundName.trim();
    if (name.isNotEmpty) return name;
  }
  return _roundTitle(games.first);
}

/// Team / knockout matchup slices for a round, mirroring the mobile Games
/// tab: team events group boards into `Team A vs Team B` matchups, knockout
/// match rounds group repeated head-to-head games (`game-1`, `game-2`,
/// `tiebreak-*`) into player matchups. Returns null for plain rounds.
List<_EventRoundSegment>? _buildEventRoundSegments(
  List<TournamentGameSummary> games,
) {
  if (games.isEmpty) return null;
  if (_isTeamEventRound(games)) {
    return _matchupSegments(
      games,
      leftLabelOf: (game) => game.whiteTeam,
      rightLabelOf: (game) => game.blackTeam,
    );
  }
  if (_isKnockoutMatchRound(games)) {
    final segments = _matchupSegments(
      games,
      leftLabelOf: (game) => game.whitePlayer,
      rightLabelOf: (game) => game.blackPlayer,
      compactLabels: true,
    );
    for (final segment in segments) {
      segment.games.sort(
        (a, b) => _compareMatchGameSlugs(a.roundSlug, b.roundSlug),
      );
    }
    return segments;
  }
  return null;
}

bool _isTeamEventRound(List<TournamentGameSummary> games) {
  return games.every(
    (game) =>
        game.whiteTeam.trim().isNotEmpty && game.blackTeam.trim().isNotEmpty,
  );
}

/// Summary-model port of `KnockoutMatchDetector.isKnockoutMatchFormat`:
/// ≥4 games, ≥30% of round slugs look like `game-N` / `tiebreak`, more than
/// one distinct matchup, and most matchups have 2+ games.
bool _isKnockoutMatchRound(List<TournamentGameSummary> games) {
  if (games.length < 4) return false;

  final patternCount =
      games.where((game) {
        final slug = game.roundSlug.toLowerCase();
        return RegExp(r'game-\d+').hasMatch(slug) || slug.contains('tiebreak');
      }).length;
  if (patternCount / games.length < 0.3) return false;

  final matchups = <String, int>{};
  for (final game in games) {
    final key = _normalizedPairKey(game.whitePlayer, game.blackPlayer);
    matchups[key] = (matchups[key] ?? 0) + 1;
  }
  if (matchups.length <= 1) return false;
  final multiGameMatchups = matchups.values.where((count) => count >= 2).length;
  return multiGameMatchups / matchups.length > 0.5;
}

List<_EventRoundSegment> _matchupSegments(
  List<TournamentGameSummary> games, {
  required String Function(TournamentGameSummary game) leftLabelOf,
  required String Function(TournamentGameSummary game) rightLabelOf,
  bool compactLabels = false,
}) {
  final buckets = <String, List<TournamentGameSummary>>{};
  final labels = <String, (String, String)>{};
  for (final game in games) {
    final left = leftLabelOf(game).trim();
    final right = rightLabelOf(game).trim();
    final key = _normalizedPairKey(left, right);
    buckets.putIfAbsent(key, () => <TournamentGameSummary>[]).add(game);
    labels.putIfAbsent(key, () => (left, right));
  }
  return [
    for (final entry in buckets.entries)
      _EventRoundSegment(
        title:
            compactLabels
                ? '${_compactPlayerName(labels[entry.key]!.$1)} vs ${_compactPlayerName(labels[entry.key]!.$2)}'
                : '${labels[entry.key]!.$1} vs ${labels[entry.key]!.$2}',
        score: _matchupScoreDisplay(
          entry.value,
          isLeftSideWhite:
              (game) =>
                  leftLabelOf(game).trim().toLowerCase() ==
                  labels[entry.key]!.$1.toLowerCase(),
        ),
        games: entry.value,
      ),
  ];
}

String _normalizedPairKey(String a, String b) {
  final pair = [a.trim().toLowerCase(), b.trim().toLowerCase()]..sort();
  return '${pair[0]}|${pair[1]}';
}

/// `game-N` before tiebreaks (rapid < blitz < armageddon), matching
/// `KnockoutMatchDetector._compareRoundSlugs`.
int _compareMatchGameSlugs(String a, String b) {
  final aInfo = _parseMatchSlugInfo(a);
  final bInfo = _parseMatchSlugInfo(b);
  if (aInfo.$1 != bInfo.$1) return aInfo.$1.compareTo(bInfo.$1);
  if (aInfo.$2 != bInfo.$2) return aInfo.$2.compareTo(bInfo.$2);
  return aInfo.$3.compareTo(bInfo.$3);
}

(int, int, int) _parseMatchSlugInfo(String slug) {
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

String _matchupScoreDisplay(
  List<TournamentGameSummary> games, {
  required bool Function(TournamentGameSummary game) isLeftSideWhite,
}) {
  var left = 0.0;
  var right = 0.0;
  var finished = 0;
  for (final game in games) {
    final leftIsWhite = isLeftSideWhite(game);
    switch (game.status) {
      case GameStatus.whiteWins:
        if (leftIsWhite) {
          left += 1;
        } else {
          right += 1;
        }
        finished++;
      case GameStatus.blackWins:
        if (leftIsWhite) {
          right += 1;
        } else {
          left += 1;
        }
        finished++;
      case GameStatus.draw:
        left += 0.5;
        right += 0.5;
        finished++;
      default:
        break;
    }
  }
  if (finished == 0) return '';
  return '${_formatMatchPoints(left)}–${_formatMatchPoints(right)}';
}

String _formatMatchPoints(double value) {
  final whole = value.truncate();
  final hasHalf = (value - whole) >= 0.5;
  if (whole == 0 && hasHalf) return '½';
  return hasHalf ? '$whole½' : '$whole';
}

/// Round status with mobile semantics: any actually-live board marks the
/// round LIVE (the rail's realtime stand-in for mobile's `live_round_ids`
/// signal); otherwise classify from the round's scheduled start time via
/// `GamesAppBarModel.status` — a future start is UPCOMING even when the
/// pre-created game rows claim `hasStarted`.
RoundStatus _eventRoundStatus(
  List<TournamentGameSummary> games, {
  required DateTime? startsAt,
}) {
  final hasLiveGame = games.any(
    (game) => _isActualLiveGame(
      status: game.status,
      hasStarted: game.hasStarted,
      lastMoveTime: game.lastMoveTime,
    ),
  );
  if (hasLiveGame) return RoundStatus.live;
  // Rounds with no propagated schedule (data-poor sources) fall back to the
  // game-derived classification instead of reading as perpetually upcoming.
  if (startsAt == null) return _roundStatus(games);
  return GamesAppBarModel.status(
    currentId: '',
    startsAt: startsAt,
    liveRound: const <String>[],
  );
}

bool _isBoardVisibleEventGame(TournamentGameSummary game) {
  return _hasResolvedPlayers(game) && _hasPlayedPosition(game);
}

bool _hasResolvedPlayers(TournamentGameSummary game) {
  return _isResolvedPlayerName(game.whitePlayer) &&
      _isResolvedPlayerName(game.blackPlayer);
}

bool _isResolvedPlayerName(String name) {
  final normalized = name.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  return normalized != '?' &&
      normalized != '??' &&
      normalized != 'tbd' &&
      normalized != 'tba' &&
      normalized != 'unknown';
}

bool _hasPlayedPosition(TournamentGameSummary game) {
  final lastMoveTime = game.lastMoveTime;
  if (lastMoveTime != null && !lastMoveTime.isAfter(DateTime.now())) {
    return true;
  }
  if (pgnHasMoves(game.pgn)) return true;
  final fen = game.fen?.trim();
  if (fen == null || fen.isEmpty) return false;
  return !_isInitialFen(fen);
}

bool _isInitialFen(String fen) {
  final board = fen.split(RegExp(r'\s+')).first;
  return board == 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
}

int _comparePairingGames(TournamentGameSummary a, TournamentGameSummary b) {
  final aBoard = a.boardNumber;
  final bBoard = b.boardNumber;
  if (aBoard != null && bBoard != null && aBoard != bBoard) {
    return aBoard.compareTo(bBoard);
  }
  if (aBoard != null) return -1;
  if (bBoard != null) return 1;
  return a.id.compareTo(b.id);
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

TournamentGameSummary _eventSummaryWithCurrentLiveUpdate(
  WidgetRef ref,
  TournamentGameSummary game,
  LiveGamesBatchKey? batchKey,
) {
  if (batchKey == null) return game;
  final arbitrated = ref.read(baseGameProvider(game.id));
  if (arbitrated == null) return game;
  return tournamentSummaryWithArbitratedLiveGame(
    structuralSummary: game,
    liveGame: arbitrated,
  );
}

TournamentGameSummary _watchArbitratedEventSummary(
  WidgetRef ref,
  TournamentGameSummary game,
  LiveGamesBatchKey? batchKey,
) {
  if (batchKey == null) return game;
  final live = watchLiveGamePosition(
    ref,
    gamesTourModelFromTournamentSummary(game),
    batchKey: batchKey,
  );
  return tournamentSummaryWithArbitratedLiveGame(
    structuralSummary: game,
    liveGame: live,
  );
}

/// Realtime is deliberately consumed once per visible matchup, not at the rail
/// or round level. One clock/status push therefore dirties one compact row leaf
/// instead of rebuilding every board in a large event.
class _EventGameMatchupCell extends ConsumerWidget {
  const _EventGameMatchupCell({
    required this.game,
    required this.selected,
    this.liveBatchKey,
  });

  final TournamentGameSummary game;
  final bool selected;
  final LiveGamesBatchKey? liveBatchKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayed = _watchArbitratedEventSummary(ref, game, liveBatchKey);
    final isLive = _isActualLiveGame(
      status: displayed.status,
      hasStarted: displayed.hasStarted,
      lastMoveTime: displayed.lastMoveTime,
    );
    final fenParts = displayed.fen?.trim().split(RegExp(r'\s+'));
    final bool? whiteToMove =
        fenParts != null && fenParts.length > 1
            ? switch (fenParts[1]) {
              'w' => true,
              'b' => false,
              _ => null,
            }
            : null;

    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _EventGamePlayerLine(
                game: displayed,
                isWhite: true,
                selected: selected,
                clockActive: isLive && whiteToMove == true,
              ),
              const SizedBox(height: 2),
              _EventGamePlayerLine(
                game: displayed,
                isWhite: false,
                selected: selected,
                clockActive: isLive && whiteToMove == false,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventGamePlayerLine extends StatelessWidget {
  const _EventGamePlayerLine({
    required this.game,
    required this.isWhite,
    required this.selected,
    required this.clockActive,
  });

  final TournamentGameSummary game;
  final bool isWhite;
  final bool selected;
  final bool clockActive;

  @override
  Widget build(BuildContext context) {
    final clockSeconds =
        isWhite ? game.whiteClockSeconds : game.blackClockSeconds;
    final result = _eventGamePlayerResult(game.status, isWhite: isWhite);
    final trailingStyle = TextStyle(
      color:
          result != null
              ? _eventGameResultColor(result)
              : clockSeconds != null && clockActive
              ? kPrimaryColor
              : kWhiteColor70,
      fontSize: 11.5,
      fontWeight:
          result == null && clockSeconds != null && clockActive
              ? FontWeight.w700
              : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      key: Key('event-game-${game.id}-${isWhite ? 'white' : 'black'}-line'),
      children: [
        Expanded(
          child: _PlayerCell(
            name: isWhite ? game.whitePlayer : game.blackPlayer,
            federation: isWhite ? game.whiteFederation : game.blackFederation,
            fideId: isWhite ? game.whiteFideId : game.blackFideId,
            title: isWhite ? game.whiteTitle : game.blackTitle,
            rating: isWhite ? game.whiteRating : game.blackRating,
            selected: selected,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child:
              result != null
                  ? Text(
                    result,
                    textAlign: TextAlign.right,
                    style: trailingStyle,
                  )
                  : Align(
                    alignment: Alignment.centerRight,
                    child: AtomicCountdownText(
                      clockSeconds: clockSeconds,
                      clockCentiseconds: 0,
                      lastMoveTime: game.lastMoveTime,
                      isActive: clockSeconds != null && clockActive,
                      style: trailingStyle,
                    ),
                  ),
        ),
      ],
    );
  }
}

Color _eventGameResultColor(String result) {
  return switch (result) {
    '1' => kPrimaryColor,
    '0' => kRedColor,
    '½' => kLightGreyColor,
    _ => kLightGreyColor,
  };
}

String? _eventGamePlayerResult(GameStatus status, {required bool isWhite}) {
  return switch (status) {
    GameStatus.whiteWins => isWhite ? '1' : '0',
    GameStatus.blackWins => isWhite ? '0' : '1',
    GameStatus.draw => '½',
    _ => null,
  };
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

int? _parseGameNumber(String value) {
  if (value.trim().isEmpty) return null;
  final match = RegExp(
    r'(?:game|board|match)[\s_\-:.]*?(\d+)',
    caseSensitive: false,
  ).firstMatch(value);
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool _isActualLiveGame({
  required GameStatus status,
  required bool hasStarted,
  required DateTime? lastMoveTime,
}) {
  if (!status.isOngoing || !hasStarted || lastMoveTime == null) {
    return false;
  }
  final timeSinceLastMove = DateTime.now().difference(lastMoveTime);
  return !timeSinceLastMove.isNegative &&
      timeSinceLastMove <= _kSidebarLiveActivityWindow;
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

Future<bool> _confirmReplaceActiveBoardGameIfNeeded({
  required WidgetRef ref,
  required BuildContext? context,
  required TournamentGameSummary nextGame,
  required bool inNewTab,
}) async {
  if (inNewTab) return true;

  final activeTabId = ref.read(desktopTabsProvider).activeId;
  if (activeTabId == null) return true;

  final activeArgs = ref.read(boardTabGameArgsByTabIdProvider)[activeTabId];
  final selectedId = activeArgs?.gameListSelectedId ?? activeArgs?.gameId;
  // Re-opening the already selected game would rebuild the active Board tab
  // and can discard local analysis for no user-visible benefit. Treat it as
  // a no-op unless the caller explicitly asked for a new tab.
  if (selectedId == nextGame.id) return false;

  final session = ref.read(boardPaneSessionByTabIdProvider)[activeTabId];
  if (!boardSessionHasUnsavedAnalysis(session)) return true;

  if (context == null || !context.mounted) return false;
  if (_eventGameReplacementConfirmationOpen) return false;
  _eventGameReplacementConfirmationOpen = true;
  return confirmDiscardBoardAnalysis(
    context,
  ).whenComplete(() => _eventGameReplacementConfirmationOpen = false);
}

class _EventGameOpenSeed {
  const _EventGameOpenSeed({required this.game, this.sourceGame});

  final TournamentGameSummary game;
  final GamesTourModel? sourceGame;
}

Future<_EventGameOpenSeed> _resolveEventGameOpenSeed({
  required GameRepository gameRepository,
  required TournamentGameSummary game,
}) async {
  final gameId = game.id.trim();
  if (gameId.isEmpty) return _EventGameOpenSeed(game: game);

  try {
    final latestRow = await gameRepository.getGameWithPGN(gameId);
    final latestModel = GamesTourModel.fromGame(latestRow);
    final hydratedSummary = tournamentSummaryWithArbitratedLiveGame(
      structuralSummary: game,
      liveGame: latestModel,
    );
    return _EventGameOpenSeed(game: hydratedSummary, sourceGame: latestModel);
  } catch (_) {
    return _EventGameOpenSeed(game: game);
  }
}

@visibleForTesting
TournamentGameSummary selectFreshestEventSummaryForOpen({
  required TournamentGameSummary current,
  required TournamentGameSummary incoming,
}) {
  if (current.id != incoming.id) return current;
  if (_shouldUseIncomingEventSummary(current, incoming) ||
      _incomingSummaryHasRicherPgn(current, incoming)) {
    return _mergeFreshEventGameSummary(current, incoming);
  }
  return current;
}

bool _shouldUseIncomingEventSummary(
  TournamentGameSummary current,
  TournamentGameSummary incoming,
) {
  final currentTime = current.lastMoveTime;
  final incomingTime = incoming.lastMoveTime;
  if (currentTime != null && incomingTime != null) {
    if (incomingTime.isBefore(currentTime)) return false;
    if (incomingTime.isAfter(currentTime)) return true;
  } else if (currentTime != null && incomingTime == null) {
    return false;
  } else if (currentTime == null && incomingTime != null) {
    return true;
  }

  if (current.status.isOngoing && incoming.status.isFinished) return true;
  if (current.status.isFinished && incoming.status.isOngoing) return false;

  final currentPly = _knownSummaryPly(current);
  final incomingPly = _knownSummaryPly(incoming);
  if (currentPly != null && incomingPly != null) {
    if (incomingPly < currentPly) return false;
    if (incomingPly > currentPly) return true;
  } else if (currentPly != null && incomingPly == null) {
    return false;
  } else if (currentPly == null && incomingPly != null) {
    return true;
  }

  final currentFen = current.fen?.trim();
  final incomingFen = incoming.fen?.trim();
  if ((currentFen == null || currentFen.isEmpty) &&
      incomingFen != null &&
      incomingFen.isNotEmpty) {
    return true;
  }

  return current.status != incoming.status &&
      incoming.status != GameStatus.unknown;
}

bool _incomingSummaryHasRicherPgn(
  TournamentGameSummary current,
  TournamentGameSummary incoming,
) {
  if (current.status.isFinished && !incoming.status.isFinished) return false;
  final incomingPgnLength = incoming.pgn?.trim().length ?? 0;
  final currentPgnLength = current.pgn?.trim().length ?? 0;
  if (incomingPgnLength <= currentPgnLength) return false;

  final currentTime = current.lastMoveTime;
  final incomingTime = incoming.lastMoveTime;
  if (currentTime != null &&
      incomingTime != null &&
      incomingTime.isBefore(currentTime)) {
    return false;
  }

  final currentPly = _knownSummaryPly(current);
  final incomingPly = _knownSummaryPly(incoming);
  if (currentPly != null && incomingPly != null && incomingPly < currentPly) {
    return false;
  }
  if (currentPly != null && incomingPly == null) return false;

  return true;
}

int? _knownSummaryPly(TournamentGameSummary game) {
  final pgnPly = resolveFinalPositionFromPgn(game.pgn)?.moveCount;
  final fenPly = plyFromFen(game.fen);
  if (pgnPly == null) return fenPly;
  if (fenPly == null) return pgnPly;
  return pgnPly > fenPly ? pgnPly : fenPly;
}

List<TournamentGameSummary> _replaceEventSummary(
  List<TournamentGameSummary> games,
  TournamentGameSummary selected,
) {
  if (games.isEmpty) return games;
  final index = games.indexWhere((game) => game.id == selected.id);
  if (index < 0) return games;

  final next = List<TournamentGameSummary>.from(games);
  next[index] = selected;
  return next;
}

GameRepository? _tryReadGameRepositoryForEventOpen({
  required WidgetRef ref,
  required BuildContext? context,
  required ProviderContainer? container,
}) {
  try {
    if (container != null) return container.read(gameRepositoryProvider);
    if (context != null && context.mounted) {
      return ProviderScope.containerOf(
        context,
        listen: false,
      ).read(gameRepositoryProvider);
    }
    return ref.read(gameRepositoryProvider);
  } catch (_) {
    return null;
  }
}

Future<void> _openEventGame({
  required WidgetRef ref,
  BuildContext? context,
  ProviderContainer? container,
  required _GameListKind kind,
  required TournamentGameSummary game,
  required List<TournamentGameSummary> eventGames,
  required String tournamentTitle,
  required BoardTabGameArgs? activeArgs,
  bool inNewTab = false,
  bool inNewWindow = false,
}) async {
  final GameRepository? gameRepository =
      kind == _GameListKind.database
          ? null
          : _tryReadGameRepositoryForEventOpen(
            ref: ref,
            context: context,
            container: container,
          );

  if (!await _confirmReplaceActiveBoardGameIfNeeded(
    ref: ref,
    context: context,
    nextGame: game,
    inNewTab: inNewTab,
  )) {
    return;
  }

  final openSeed =
      gameRepository == null
          ? _EventGameOpenSeed(game: game)
          : await _resolveEventGameOpenSeed(
            gameRepository: gameRepository,
            game: game,
          );
  final openGame = openSeed.game;
  final openEventGames = _replaceEventSummary(eventGames, openGame);

  if (kind == _GameListKind.database) {
    final pgn = openGame.pgn?.trim() ?? '';
    final hasPlayableLocalPgn = pgnHasMoves(pgn);
    final localPgnSaveOrigin = _localPgnSaveOriginForSummary(openGame);
    final args = BoardTabGameArgs(
      // A local database id is not a Supabase id. Keep it detached even if
      // the file can no longer be read, so a failed local lookup never binds
      // the board to an unrelated remote stream.
      gameId:
          hasPlayableLocalPgn || localPgnSaveOrigin != null
              ? null
              : openGame.id,
      pgn: pgn,
      label:
          openGame.name.isEmpty
              ? '${openGame.whitePlayer} vs ${openGame.blackPlayer}'
              : openGame.name,
      whiteName: openGame.whitePlayer,
      blackName: openGame.blackPlayer,
      whiteFederation: openGame.whiteFederation,
      blackFederation: openGame.blackFederation,
      whiteTitle: openGame.whiteTitle,
      blackTitle: openGame.blackTitle,
      whiteRating: openGame.whiteRating,
      blackRating: openGame.blackRating,
      whiteFideId: openGame.whiteFideId,
      blackFideId: openGame.blackFideId,
      fenSeed: openGame.fen,
      initialFen: activeArgs?.initialFen ?? openGame.fen,
      viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
      databaseTitle: tournamentTitle,
      databaseGames: openEventGames,
      databaseGamesPagination: activeArgs?.databaseGamesPagination,
      databaseGamesContinuation: activeArgs?.databaseGamesContinuation,
      gameListSelectedId: openGame.id,
      librarySaveOrigin: localPgnSaveOrigin,
    );

    if (inNewWindow) {
      await openBoardGameWindow(ref, args);
      return;
    }

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
    final pgn = openGame.pgn?.trim() ?? '';
    final eventSeed = _replaceEventSummary(
      _eventSeedForSourceGame(openGame, activeArgs),
      openGame,
    );
    final args = BoardTabGameArgs(
      gameId: openGame.id,
      pgn: pgn,
      label:
          openGame.name.isEmpty
              ? '${openGame.whitePlayer} vs ${openGame.blackPlayer}'
              : openGame.name,
      whiteName: openGame.whitePlayer,
      blackName: openGame.blackPlayer,
      whiteFederation: openGame.whiteFederation,
      blackFederation: openGame.blackFederation,
      whiteTitle: openGame.whiteTitle,
      blackTitle: openGame.blackTitle,
      whiteRating: openGame.whiteRating,
      blackRating: openGame.blackRating,
      whiteFideId: openGame.whiteFideId,
      blackFideId: openGame.blackFideId,
      fenSeed: openGame.fen,
      initialFen: activeArgs?.initialFen ?? openGame.fen,
      sourceGame: openSeed.sourceGame,
      viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
      tournamentTitle: _eventTitleForGame(openGame, activeArgs),
      eventGames: eventSeed,
      eventGamesLoading: false,
      eventGamesKey: _eventGamesKeyForSummary(openGame, activeArgs),
      eventGamesContinuation: activeArgs?.eventGamesContinuation,
      routeTitle: tournamentTitle,
      routeGames: openEventGames,
      routeGamesContinuation: activeArgs?.routeGamesContinuation,
      gameListSelectedId: openGame.id,
    );

    if (inNewWindow) {
      await openBoardGameWindow(ref, args);
      return;
    }

    openBoardGameTab(
      ref,
      args,
      focus: true,
      reuseExisting: false,
      replaceActive: !inNewTab,
    );
    return;
  }

  final pgn = openGame.pgn?.trim() ?? '';
  if (!inNewTab && !inNewWindow) {
    ref.read(tournamentGamesProvider.notifier).markActive(openGame.id);
  }

  final args = BoardTabGameArgs(
    gameId: openGame.id,
    pgn: pgn,
    label:
        openGame.name.isEmpty
            ? '${openGame.whitePlayer} vs ${openGame.blackPlayer}'
            : openGame.name,
    whiteName: openGame.whitePlayer,
    blackName: openGame.blackPlayer,
    whiteFederation: openGame.whiteFederation,
    blackFederation: openGame.blackFederation,
    whiteTitle: openGame.whiteTitle,
    blackTitle: openGame.blackTitle,
    whiteRating: openGame.whiteRating,
    blackRating: openGame.blackRating,
    whiteFideId: openGame.whiteFideId,
    blackFideId: openGame.blackFideId,
    fenSeed: openGame.fen,
    sourceGame: openSeed.sourceGame,
    viewSource: activeArgs?.viewSource ?? ChessboardView.tour,
    tournamentTitle: tournamentTitle,
    eventGames: openEventGames,
    eventGamesKey: _eventGamesKeyForSummary(openGame, activeArgs),
    eventGamesContinuation: activeArgs?.eventGamesContinuation,
    routeTitle: activeArgs?.routeTitle ?? '',
    routeGames: activeArgs?.routeGames ?? const <TournamentGameSummary>[],
    routeGamesContinuation: activeArgs?.routeGamesContinuation,
    gameListSelectedId: openGame.id,
  );

  if (inNewWindow) {
    await openBoardGameWindow(ref, args);
    return;
  }

  openBoardGameTab(
    ref,
    args,
    focus: true,
    reuseExisting: false,
    replaceActive: !inNewTab,
  );
}

BoardTabEventGamesKey? _eventGamesKeyForSummary(
  TournamentGameSummary game,
  BoardTabGameArgs? activeArgs,
) {
  if (activeArgs?.viewSource == ChessboardView.favScorecard) return null;
  final tourId = game.tourId.trim();
  // A local/database/source row without a canonical tournament id must not
  // inherit the previously selected event. That would keep polling and
  // merging an unrelated tournament after the source switch.
  if (tourId.isEmpty) return null;
  return BoardTabEventGamesKey(
    tourId: tourId,
    selectedGameId: game.id,
    selectedRoundId: game.roundId,
    selectedBoardNumber: game.boardNumber,
  );
}

BoardTabLibrarySaveOrigin? _localPgnSaveOriginForSummary(
  TournamentGameSummary game,
) {
  final source = game.localPgnSource;
  if (source == null || source.sourcePath.trim().isEmpty) return null;
  return BoardTabLibrarySaveOrigin.localPgnFile(
    sourcePath: source.sourcePath,
    sourceIndex: source.sourceIndex,
    sourceFileGameCount: source.sourceFileGameCount,
    sourcePgnFingerprint: source.pgnFingerprint,
    title: source.title,
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

class _DatabaseGamesList extends ConsumerWidget {
  const _DatabaseGamesList({
    required this.controller,
    required this.games,
    required this.copyScopeGames,
    required this.selectedGameId,
    required this.selectedGameIds,
    required this.highlightedGameId,
    required this.selectedRowKey,
    required this.tournamentTitle,
    required this.activeArgs,
    required this.isLoadingMoreDatabase,
    required this.databaseHasMore,
    required this.databaseLoadError,
    required this.activeContinuation,
    required this.isLoadingMoreContinuation,
    required this.continuationHasMore,
    required this.continuationLoadError,
    required this.isLoading,
    required this.onHighlightGame,
    required this.onRangeHighlightGame,
  });

  final ScrollController controller;
  final List<TournamentGameSummary> games;
  final List<TournamentGameSummary> copyScopeGames;
  final String? selectedGameId;
  final Set<String> selectedGameIds;
  final String? highlightedGameId;
  final GlobalKey? selectedRowKey;
  final String tournamentTitle;
  final BoardTabGameArgs? activeArgs;
  final bool isLoadingMoreDatabase;
  final bool databaseHasMore;
  final String? databaseLoadError;
  final BoardTabGamesContinuation? activeContinuation;
  final bool isLoadingMoreContinuation;
  final bool continuationHasMore;
  final String? continuationLoadError;
  final bool isLoading;
  final void Function(TournamentGameSummary game) onHighlightGame;
  final void Function(TournamentGameSummary game) onRangeHighlightGame;

  String? get _activeSelectionId => highlightedGameId ?? selectedGameId;

  bool _isSelected(TournamentGameSummary game) {
    if (selectedGameIds.isNotEmpty) return selectedGameIds.contains(game.id);
    return game.id == _activeSelectionId;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showDatabasePagination =
        isLoadingMoreDatabase || databaseHasMore || databaseLoadError != null;
    final showContinuationPagination =
        activeContinuation != null &&
        (isLoadingMoreContinuation ||
            continuationHasMore ||
            continuationLoadError != null);
    final itemCount =
        games.length +
        (showDatabasePagination ? 1 : 0) +
        (showContinuationPagination ? 1 : 0) +
        (isLoading ? 1 : 0);

    return ListView.builder(
      controller: controller,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < games.length) {
          final game = games[index];
          return _DatabaseGameRow(
            key: game.id == _activeSelectionId ? selectedRowKey : null,
            game: game,
            selected: _isSelected(game),
            onTap: ({required bool inNewTab, required bool shiftPressed}) {
              if (inNewTab) {
                onHighlightGame(game);
                unawaited(
                  _openEventGame(
                    ref: ref,
                    context: context,
                    container: ProviderScope.containerOf(
                      context,
                      listen: false,
                    ),
                    kind: _GameListKind.database,
                    game: game,
                    eventGames: copyScopeGames,
                    tournamentTitle: tournamentTitle,
                    activeArgs: activeArgs,
                    inNewTab: true,
                  ),
                );
                return;
              }
              if (shiftPressed) {
                onRangeHighlightGame(game);
                return;
              }
              onHighlightGame(game);
            },
            onDoubleTap: ({required bool inNewTab}) {
              onHighlightGame(game);
              unawaited(
                _openEventGame(
                  ref: ref,
                  context: context,
                  container: ProviderScope.containerOf(context, listen: false),
                  kind: _GameListKind.database,
                  game: game,
                  eventGames: copyScopeGames,
                  tournamentTitle: tournamentTitle,
                  activeArgs: activeArgs,
                  inNewTab: inNewTab,
                ),
              );
            },
            onSecondaryTap: (position) async {
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
                    value: _GameRowAction.openInNewWindow,
                    icon: Icons.open_in_browser_rounded,
                    label: 'Open game in new window',
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
              if (!context.mounted) return;
              final container = ProviderScope.containerOf(
                context,
                listen: false,
              );
              switch (action) {
                case _GameRowAction.openInNewTab:
                  await _openEventGame(
                    ref: ref,
                    context: context,
                    container: container,
                    kind: _GameListKind.database,
                    game: game,
                    eventGames: copyScopeGames,
                    tournamentTitle: tournamentTitle,
                    activeArgs: activeArgs,
                    inNewTab: true,
                  );
                case _GameRowAction.openInNewWindow:
                  await _openEventGame(
                    ref: ref,
                    context: context,
                    container: container,
                    kind: _GameListKind.database,
                    game: game,
                    eventGames: copyScopeGames,
                    tournamentTitle: tournamentTitle,
                    activeArgs: activeArgs,
                    inNewWindow: true,
                  );
                case _GameRowAction.insertGame:
                  await _insertEventGame(
                    ref: ref,
                    game: game,
                    tournamentTitle: tournamentTitle,
                  );
                case _GameRowAction.copyPgn:
                  final copyGames = eventRailGamesForCopy(
                    orderedGames: copyScopeGames,
                    selectedIds: selectedGameIds,
                    highlightedGameId: highlightedGameId,
                    selectedGameId: selectedGameId,
                    fallbackGame: game,
                  );
                  await _copyEventGameSummariesAsPgn(
                    context: context,
                    ref: ref,
                    games: copyGames,
                  );
              }
            },
          );
        }

        var footerIndex = index - games.length;
        if (showDatabasePagination) {
          if (footerIndex == 0) {
            return _GamesPaginationSection(
              isLoading: isLoadingMoreDatabase,
              error: databaseLoadError,
            );
          }
          footerIndex--;
        }
        if (showContinuationPagination) {
          if (footerIndex == 0) {
            return _GamesPaginationSection(
              isLoading: isLoadingMoreContinuation,
              error: continuationLoadError,
            );
          }
          footerIndex--;
        }
        return const _EventGamesLoadingSection();
      },
    );
  }
}

class _DatabaseGameRow extends StatefulWidget {
  const _DatabaseGameRow({
    super.key,
    required this.game,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTap,
  });

  final TournamentGameSummary game;
  final bool selected;
  final void Function({required bool inNewTab, required bool shiftPressed})
  onTap;
  final void Function({required bool inNewTab}) onDoubleTap;
  final ValueChanged<Offset> onSecondaryTap;

  @override
  State<_DatabaseGameRow> createState() => _DatabaseGameRowState();
}

class _DatabaseGameRowState extends State<_DatabaseGameRow> {
  bool _hovered = false;
  bool _tapDownInNewTab = false;
  bool _tapDownShiftPressed = false;

  void _captureGestureModifiers(TapDownDetails _) {
    _tapDownInNewTab = isNewTabModifierPressed();
    _tapDownShiftPressed = HardwareKeyboard.instance.isShiftPressed;
  }

  bool _newTabForGesture() {
    final inNewTab = _tapDownInNewTab || isNewTabModifierPressed();
    _tapDownInNewTab = false;
    return inNewTab;
  }

  bool _shiftForGesture() {
    final shiftPressed =
        _tapDownShiftPressed || HardwareKeyboard.instance.isShiftPressed;
    _tapDownShiftPressed = false;
    return shiftPressed;
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final selected = widget.selected;
    final bg =
        selected
            ? kPrimaryColor.withValues(alpha: 0.18)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final border =
        selected ? kPrimaryColor.withValues(alpha: 0.72) : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _captureGestureModifiers,
            onTap:
                () => widget.onTap(
                  inNewTab: _newTabForGesture(),
                  shiftPressed: _shiftForGesture(),
                ),
            onDoubleTap:
                () => widget.onDoubleTap(inNewTab: _newTabForGesture()),
            onSecondaryTapUp:
                (details) => widget.onSecondaryTap(details.globalPosition),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              height: _EventGamesTableState._databaseGameRowExtent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: border, width: selected ? 1.2 : 1),
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
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _PlayerCell(
                      name: game.whitePlayer,
                      federation: game.whiteFederation,
                      fideId: game.whiteFideId,
                      title: game.whiteTitle,
                      rating: game.whiteRating,
                      selected: selected,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PlayerCell(
                      name: game.blackPlayer,
                      federation: game.blackFederation,
                      fideId: game.blackFideId,
                      title: game.blackTitle,
                      rating: game.blackRating,
                      selected: selected,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 38,
                    child: Center(
                      child: _StatusPill(
                        status: game.status,
                        isLive: false,
                        hasStarted: game.hasStarted,
                      ),
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

/// Per-round compact matchup block. Each game is one stacked White/Black row;
/// the outer ListView in [EventGamesTable] owns vertical scrolling.
class _EventRoundTable extends StatelessWidget {
  const _EventRoundTable({
    required this.games,
    required this.copyScopeGames,
    required this.selectedGameId,
    required this.selectedGameIds,
    required this.highlightedGameId,
    required this.selectedRowKey,
    required this.liveBatchKeyByGameId,
    required this.showBoardColumn,
    required this.onHighlightGame,
    required this.onRangeHighlightGame,
    required this.onOpenGame,
    required this.onInsertGame,
    required this.onCopyGames,
  });

  final List<TournamentGameSummary> games;
  final List<TournamentGameSummary> copyScopeGames;
  final String? selectedGameId;
  final Set<String> selectedGameIds;
  final String? highlightedGameId;
  final GlobalKey? selectedRowKey;
  final Map<String, LiveGamesBatchKey> liveBatchKeyByGameId;
  final bool showBoardColumn;
  final void Function(TournamentGameSummary game) onHighlightGame;
  final void Function(TournamentGameSummary game) onRangeHighlightGame;
  final Future<void> Function(
    TournamentGameSummary game, {
    required bool inNewTab,
    bool inNewWindow,
  })
  onOpenGame;
  final Future<void> Function(TournamentGameSummary game) onInsertGame;
  final Future<void> Function(List<TournamentGameSummary> games) onCopyGames;

  String? get _activeSelectionId => highlightedGameId ?? selectedGameId;

  bool _isSelected(TournamentGameSummary game) {
    if (selectedGameIds.isNotEmpty) return selectedGameIds.contains(game.id);
    return game.id == _activeSelectionId;
  }

  bool _isShiftPressedForRowTap(bool shiftPressed) {
    if (shiftPressed || HardwareKeyboard.instance.isShiftPressed) return true;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shift) ||
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
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
        id: 'matchup',
        label: 'GAME',
        flex: 1,
        minWidth: 210,
        cellBuilder:
            (_, game) => _EventGameMatchupCell(
              game: game,
              selected: _isSelected(game),
              liveBatchKey: liveBatchKeyByGameId[game.id],
            ),
      ),
    ];

    return _OwnedScrollControllers(
      builder:
          (
            verticalController,
            horizontalController,
          ) => AdaptiveGamesTable<TournamentGameSummary>(
            columns: columns,
            rows: games,
            // Round-section tables sit inside the outer rail ListView, so they
            // can't own internal vertical scrolling. `useFixedRowAlignment` flips
            // the body to a single [Table] (no inner ListView) — column widths
            // align *across* rows too, which is what the user expects within a
            // round.
            useFixedRowAlignment: true,
            minTableWidth: 280,
            scrollController: verticalController,
            horizontalScrollController: horizontalController,
            showHeader: false,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            rowMinHeight: 48,
            rowKeyBuilder:
                (game) => game.id == _activeSelectionId ? selectedRowKey : null,
            onRowTap: (
              game, {
              required bool inNewTab,
              required bool shiftPressed,
            }) {
              final effectiveShiftPressed = _isShiftPressedForRowTap(
                shiftPressed,
              );
              if (effectiveShiftPressed) {
                onRangeHighlightGame(game);
                return;
              }
              if (inNewTab) {
                onHighlightGame(game);
                unawaited(onOpenGame(game, inNewTab: true));
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
                    value: _GameRowAction.openInNewWindow,
                    icon: Icons.open_in_browser_rounded,
                    label: 'Open game in new window',
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
                case _GameRowAction.openInNewWindow:
                  await onOpenGame(game, inNewTab: false, inNewWindow: true);
                case _GameRowAction.insertGame:
                  await onInsertGame(game);
                case _GameRowAction.copyPgn:
                  final copyGames = eventRailGamesForCopy(
                    orderedGames: copyScopeGames,
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
              final hasFollowingGame = game.id != games.last.id;
              return BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.11)
                        : (hovered ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: Border(
                  left:
                      selected
                          ? const BorderSide(color: kPrimaryColor, width: 2)
                          : BorderSide.none,
                  bottom:
                      hasFollowingGame
                          ? const BorderSide(color: kDividerColor, width: 0.5)
                          : BorderSide.none,
                ),
              );
            },
          ),
    );
  }
}

class _OwnedScrollControllers extends StatefulWidget {
  const _OwnedScrollControllers({required this.builder});

  final Widget Function(
    ScrollController verticalController,
    ScrollController horizontalController,
  )
  builder;

  @override
  State<_OwnedScrollControllers> createState() =>
      _OwnedScrollControllersState();
}

class _OwnedScrollControllersState extends State<_OwnedScrollControllers> {
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(_verticalController, _horizontalController);
  }
}

class _EventRoundHeaderItem extends StatelessWidget {
  const _EventRoundHeaderItem({
    required this.group,
    required this.expanded,
    required this.onToggle,
  });

  final _EventRoundGroup group;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _EventRoundHeader(
      group: group,
      expanded: expanded,
      onToggle: onToggle,
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

@immutable
class _EventRailWindow {
  const _EventRailWindow({required this.games, required this.hasMoreRows});

  final List<TournamentGameSummary> games;

  /// True when more already-loaded rows sit past the current window, so the
  /// rail shows a scroll affordance instead of page arrows.
  final bool hasMoreRows;
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
        group.status != RoundStatus.upcoming || group.startsAt == null
            ? ''
            : DateFormat('MMM d · HH:mm').format(group.startsAt!.toLocal());

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
                (context, scale, child) => Transform.scale(
                  scale: scale,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
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

/// Slim matchup label above a segment of rows: `Team A vs Team B  2½–1½`
/// for team rounds, `Player 1 vs Player 2  1½–½` for knockout matches.
class _EventMatchupHeader extends StatelessWidget {
  const _EventMatchupHeader({required this.title, this.score});

  final String title;
  final String? score;

  @override
  Widget build(BuildContext context) {
    final scoreText = score?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (scoreText.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              scoreText,
              maxLines: 1,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _GameRowAction { openInNewTab, openInNewWindow, insertGame, copyPgn }

class _BoardBadge extends StatelessWidget {
  const _BoardBadge({required this.game, required this.selected});

  final TournamentGameSummary game;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final boardNumber = game.boardNumber;
    final label = boardNumber == null ? '' : '$boardNumber';
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
  final trimmed = desktopTablePlayerValue(name);
  if (trimmed.isEmpty) return '';
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
    if (playerName.isEmpty) return const SizedBox.shrink();
    final titleText = title.trim();
    final ratingText = rating > 0 ? rating.toString() : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BackfilledFederationFlag(
          federation: federation,
          fideId: fideId,
          width: 16,
          height: 11,
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
              fontSize: 10.5,
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
              fontSize: 12.5,
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
              fontSize: 11,
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
      final displayText = desktopTableDisplayValue(txt);
      if (displayText.isEmpty) return const SizedBox.shrink();
      return Text(
        displayText,
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
    return const SizedBox.shrink();
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'LIVE',
      style: TextStyle(
        color: kPrimaryColor,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.35,
        height: 1,
      ),
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
      return const SizedBox.shrink();
    }
    const base = TextStyle(
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
      height: 1.0,
    );
    final strong = base.copyWith(
      color: kPrimaryColor,
      fontWeight: FontWeight.w700,
    );
    final weak = base.copyWith(color: kRedColor, fontWeight: FontWeight.w700);
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
