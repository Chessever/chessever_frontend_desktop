import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailGamesSearchByTabIdProvider;
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_compact_player_identity.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_grouped_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_team_match_grouping.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/round_header_card.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/round_ordering.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/screens/tour_detail/bracket/utils/knockout_stage_parser.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

/// Per-round expansion for the desktop Games tab.
///
/// Keyed by `(roundId, initiallyExpanded)` so the default follows round status
/// — future rounds collapse while a round is live / the latest one is finished,
/// past + focus rounds stay open — and re-seeds when that live-state flips (the
/// key changes), while still honouring a manual toggle until then. Kept local
/// to the desktop tab so the shared `roundExpansionProvider` (mobile app-bar
/// scroll logic) is left untouched.
typedef _TournamentRoundExpansionKey = ({String id, bool initiallyExpanded});

typedef _TournamentMatchExpansionKey =
    ({String scopeId, String roundId, String matchId});

final _tournamentRoundExpandedProvider = StateProvider.autoDispose
    .family<bool, _TournamentRoundExpansionKey>(
      (ref, key) => key.initiallyExpanded,
    );

final _tournamentMatchExpandedProvider = StateProvider.autoDispose
    .family<bool, _TournamentMatchExpansionKey>((ref, key) => true);

enum DesktopKnockoutGamesPresentation { matchSeries, allBoards }

final tournamentKnockoutGamesPresentationByTabIdProvider =
    StateProvider.family<DesktopKnockoutGamesPresentation, String>(
      (ref, tabId) => DesktopKnockoutGamesPresentation.matchSeries,
    );

@visibleForTesting
bool shouldShowKnockoutMatchSections({
  required bool isKnockout,
  required bool canGroup,
  required DesktopKnockoutGamesPresentation presentation,
}) =>
    isKnockout &&
    canGroup &&
    presentation == DesktopKnockoutGamesPresentation.matchSeries;

/// Orders match sections by elimination stage, then by pairing start time with
/// the latest pairing first. Some feeds number matches in their slug
/// (`quarterfinals-match-3-4`); treating that match number as a round number
/// puts quarterfinal boards ahead of a later semifinal/final.
///
/// Stay conservative for legacy feeds: unless at least two distinct named
/// stages can be resolved, do not apply stage ranking. Missing or equal start
/// times preserve the detector's insertion order.
@visibleForTesting
List<MapEntry<String, List<GamesTourModel>>>
orderedKnockoutMatchEntriesForDisplay(List<GamesTourModel> games) {
  final entries = KnockoutMatchDetector.groupByMatches(
    games,
  ).entries.toList(growable: false);
  if (entries.length <= 1) return entries;

  final ranked = <
    ({
      MapEntry<String, List<GamesTourModel>> entry,
      int index,
      int? stageOrder,
      DateTime? startsAt,
    })
  >[
    for (var index = 0; index < entries.length; index += 1)
      (
        entry: entries[index],
        index: index,
        stageOrder: _latestKnockoutStageOrder(entries[index].value),
        startsAt:
            KnockoutMatchDetector.createMatchHeader(
              entries[index].key,
              entries[index].value,
            ).startsAt,
      ),
  ];
  final resolvedStageOrders =
      ranked.map((item) => item.stageOrder).whereType<int>().toSet();
  final shouldOrderByStage = resolvedStageOrders.length > 1;

  ranked.sort((left, right) {
    if (shouldOrderByStage) {
      final leftStage = left.stageOrder;
      final rightStage = right.stageOrder;
      if (leftStage != null && rightStage != null) {
        final stageOrder = rightStage.compareTo(leftStage);
        if (stageOrder != 0) return stageOrder;
      } else if (leftStage != null) {
        return -1;
      } else if (rightStage != null) {
        return 1;
      }
    }

    final leftStart = left.startsAt;
    final rightStart = right.startsAt;
    if (leftStart != null && rightStart != null) {
      final startOrder = rightStart.compareTo(leftStart);
      if (startOrder != 0) return startOrder;
    } else if (leftStart != null) {
      return -1;
    } else if (rightStart != null) {
      return 1;
    }
    return left.index.compareTo(right.index);
  });
  return ranked.map((item) => item.entry).toList(growable: false);
}

int? _latestKnockoutStageOrder(List<GamesTourModel> matchGames) {
  int? latest;
  for (final game in matchGames) {
    final stage = resolveLogicalKnockoutStage(
      '',
      game.roundSlug ?? '',
      tourName: game.tourName,
    );
    if (stage != null && (latest == null || stage.sortOrder > latest)) {
      latest = stage.sortOrder;
    }
  }
  return latest;
}

/// Games sub-view of the Tournament Detail.
///
/// Pipes through the same `gamesTourGroupedProvider` mobile uses, then
/// renders each round as a [RoundHeaderCard] followed by its games as
/// [DesktopGameCard]s. Layout toggles between list and grid; eval bars are
/// always rendered (settings to suppress them are a follow-up).
class TournamentGamesView extends ConsumerStatefulWidget {
  const TournamentGamesView({
    super.key,
    required this.tabId,
    required this.tournamentId,
    this.onHeaderCollapsedChanged,
  });

  final String tabId;
  final String tournamentId;
  final ValueChanged<bool>? onHeaderCollapsedChanged;

  @override
  ConsumerState<TournamentGamesView> createState() =>
      _TournamentGamesViewState();
}

class _TournamentGamesViewState extends ConsumerState<TournamentGamesView> {
  static const Duration _scrollIdleDelay = Duration(milliseconds: 180);

  late final TextEditingController _searchController;
  late final ScrollController _scrollController;
  Timer? _debounce;
  Timer? _scrollIdleTimer;
  bool _liveCardsPausedForScroll = false;
  bool _headerCollapsed = false;
  GroupedGamesData? _lastStableGrouped;
  String? _searchReplayInFlight;
  Set<String> _registeredPollingTourIds = const <String>{};
  final Map<String, GamesTourNotifier> _pollingNotifiersByTourId =
      <String, GamesTourNotifier>{};
  Set<String> _pendingPollingTourIds = const <String>{};
  bool? _registeredPollingActive;
  bool _pendingPollingActive = false;
  bool _pollingSyncScheduled = false;
  late final StateController<Set<String>> _liveCardsPauseReasonsController;

  // Captured once. liveGameCardsPaused is global, so a reason recomputed from a
  // changing widget.tabId could strand a stale reason in the pause set and
  // freeze every live card app-wide. tabId is fixed per pane today; freeze it
  // defensively so a future tabId-reusing State can't trip that.
  late final String _liveCardsPauseReason =
      'desktop_tournament_games_scroll_${widget.tabId}';

  @override
  void initState() {
    super.initState();
    _liveCardsPauseReasonsController = ref.read(
      liveGameCardsPauseReasonsProvider.notifier,
    );
    // Seed from the per-tab provider so search text restores after the tab
    // has been flipped to a Board route and back (which disposes this
    // state). The provider survives because it's owned by the
    // ProviderContainer, not the widget tree.
    final persisted = ref.read(
      tournamentDetailGamesSearchByTabIdProvider(widget.tabId),
    );
    _searchController = TextEditingController(text: persisted);
    _scrollController = ScrollController(
      debugLabel: 'desktop-tournament-games-${widget.tabId}',
    );
    // On re-mount, the games provider may have lost its search query (e.g.
    // because a sibling tournament tab cleared it). Replay the persisted
    // text once after first frame so the filter matches what the controller
    // shows. Skip if empty so we don't spam clearSearch.
    if (persisted.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(gamesTourScreenProvider.notifier)
            .searchGamesEnhanced(persisted.trim());
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollIdleTimer?.cancel();
    for (final notifier in _pollingNotifiersByTourId.values) {
      if (notifier.mounted) {
        notifier.removeDesktopPollingConsumer(widget.tabId);
      }
    }
    _pollingNotifiersByTourId.clear();
    _searchController.dispose();
    _scrollController.dispose();
    _setHeaderCollapsed(false);
    _setLiveCardsPausedForScroll(false);
    super.dispose();
  }

  void _schedulePollingActivitySync({
    required Set<String> tourIds,
    required bool active,
  }) {
    _pendingPollingTourIds = Set<String>.unmodifiable(tourIds);
    _pendingPollingActive = active;
    if (_pollingSyncScheduled) return;
    _pollingSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pollingSyncScheduled = false;
      if (!mounted) return;
      final nextIds = _pendingPollingTourIds;
      final nextActive = _pendingPollingActive;
      if (setEquals(_registeredPollingTourIds, nextIds) &&
          _registeredPollingActive == nextActive) {
        return;
      }
      for (final removedId in _registeredPollingTourIds.difference(nextIds)) {
        final notifier = _pollingNotifiersByTourId.remove(removedId);
        if (notifier?.mounted == true) {
          notifier!.removeDesktopPollingConsumer(widget.tabId);
        }
      }
      for (final tourId in nextIds) {
        final notifier = ref.read(gamesTourProvider(tourId).notifier);
        _pollingNotifiersByTourId[tourId] = notifier;
        notifier.setDesktopPollingConsumer(
          consumerId: widget.tabId,
          active: nextActive,
        );
      }
      final becameActive = nextActive && _registeredPollingActive != true;
      _registeredPollingTourIds = nextIds;
      _registeredPollingActive = nextActive;
      if (becameActive) {
        unawaited(ref.read(gamesAppBarProvider.notifier).refresh());
      }
    });
  }

  void _runSearch(String q) {
    ref
        .read(tournamentDetailGamesSearchByTabIdProvider(widget.tabId).notifier)
        .state = q;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final notifier = ref.read(gamesTourScreenProvider.notifier);
      if (q.trim().isEmpty) {
        notifier.clearSearch();
      } else {
        notifier.searchGamesEnhanced(q.trim());
      }
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    _setHeaderCollapsed(notification.metrics.pixels > 18);

    if (notification is ScrollEndNotification) {
      _scheduleLiveCardsIdle();
      return false;
    }

    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification ||
        notification is UserScrollNotification) {
      _markLiveCardsScrolling();
    }

    return false;
  }

  void _setHeaderCollapsed(bool collapsed) {
    if (_headerCollapsed == collapsed) return;
    _headerCollapsed = collapsed;
    widget.onHeaderCollapsedChanged?.call(collapsed);
  }

  void _markLiveCardsScrolling() {
    _setLiveCardsPausedForScroll(true);
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(_scrollIdleDelay, _markLiveCardsIdle);
  }

  void _scheduleLiveCardsIdle() {
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(_scrollIdleDelay, _markLiveCardsIdle);
  }

  void _markLiveCardsIdle() {
    if (!mounted) return;
    _setLiveCardsPausedForScroll(false);
  }

  void _setLiveCardsPausedForScroll(bool paused) {
    if (_liveCardsPausedForScroll == paused) return;
    _liveCardsPausedForScroll = paused;
    setLiveGameCardsPausedWithNotifier(
      _liveCardsPauseReasonsController,
      reason: _liveCardsPauseReason,
      paused: paused,
    );
  }

  Future<void> _retryTournamentGames() async {
    if (!mounted) return;
    final canonicalTourId =
        ref
            .read(tourDetailScreenProvider)
            .valueOrNull
            ?.aboutTourModel
            .id
            .trim();
    if (canonicalTourId == null || canonicalTourId.isEmpty) return;

    setState(() => _lastStableGrouped = null);
    try {
      await Future.wait<void>([
        ref.read(gamesTourProvider(canonicalTourId).notifier).retry(),
        ref.read(gamesAppBarRetryProvider)(),
      ]);
    } catch (error) {
      debugPrint('Tournament games retry failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final watchedGrouped = ref.watch(gamesTourGroupedProvider);
    final persistedQuery =
        ref
            .watch(tournamentDetailGamesSearchByTabIdProvider(widget.tabId))
            .trim();
    final screenModel = ref.watch(gamesTourScreenProvider).valueOrNull;
    final gamesTourMode = ref.watch(gamesTourScreenModeProvider).valueOrNull;
    if (persistedQuery.isEmpty) {
      _searchReplayInFlight = null;
    } else if (screenModel != null) {
      if (screenModel.isSearchMode &&
          screenModel.searchQuery == persistedQuery) {
        _searchReplayInFlight = null;
      } else if (_searchReplayInFlight != persistedQuery) {
        _searchReplayInFlight = persistedQuery;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref
              .read(gamesTourScreenProvider.notifier)
              .searchGamesEnhanced(persistedQuery);
        });
      }
    }
    final isRestoringSearch =
        persistedQuery.isNotEmpty &&
        !(screenModel?.isSearchMode == true &&
            screenModel?.searchQuery == persistedQuery);
    final liveOnly =
        screenModel?.gameDisplayMode == GameDisplayMode.hideFinishedGames;
    final grouped =
        (watchedGrouped.isLoading || isRestoringSearch) &&
                _lastStableGrouped != null
            ? _lastStableGrouped!
            : watchedGrouped;
    final knockoutPresentation = ref.watch(
      tournamentKnockoutGamesPresentationByTabIdProvider(widget.tabId),
    );
    if (!watchedGrouped.isLoading && !isRestoringSearch) {
      _lastStableGrouped = watchedGrouped;
    }
    final tournamentTitle = ref.watch(activeTournamentProvider)?.title ?? '';
    final isTeamEvent =
        gamesTourMode == GamesTourScreenMode.groupEvent &&
        !grouped.isKnockoutTournament;
    final streamingEnabled = ref.watch(
      desktopTabsProvider.select((state) => state.activeId == widget.tabId),
    );
    final canonicalTourId =
        ref
            .watch(tourDetailScreenProvider)
            .valueOrNull
            ?.aboutTourModel
            .id
            .trim();
    final pollingTourIds = <String>{
      if (canonicalTourId != null && canonicalTourId.isNotEmpty)
        canonicalTourId,
      for (final game in grouped.allGames)
        if (game.tourId.trim().isNotEmpty) game.tourId.trim(),
    };
    _schedulePollingActivitySync(
      tourIds: pollingTourIds,
      active: streamingEnabled,
    );
    final cardStreamingEnabled = streamingEnabled;
    // Build deterministic chunks once for the whole tournament render. Doing
    // this inside every card turns one parent refresh into O(gameCount^2)
    // filtering/key allocation on large broadcasts.
    final liveBatchKeyByGameId =
        cardStreamingEnabled
            ? liveBatchKeysForGames(
              games: grouped.allGames,
              scopePrefix: 'desktop_context:${widget.tabId}',
              includeFinishedGames: true,
            )
            : const <String, LiveGamesBatchKey>{};
    // Source of truth: the persisted board-settings store. Toggling here
    // (or anywhere else — Settings, Library, etc.) writes to the same
    // record, so every desktop pane stays in sync. See `desktop_game_card.dart`
    // for the GamesListViewMode → DesktopCardLayout mapping.
    final viewMode = ref.watch(gamesListViewModeProvider);
    final layout = viewMode.desktopLayout;
    final roundStartsAtById = <String, DateTime?>{
      for (final round in grouped.filteredRounds) round.id: round.startsAt,
    };
    final roundNameById = <String, String>{
      for (final round in grouped.rounds) round.id: round.name,
    };
    // Knockout stages are synthetic rounds (`knockout-stage-*`) whose ids
    // never match a game's real roundId. Map each game's roundId back to its
    // owning stage so board-rail summaries inherit the stage name and
    // schedule; direct id matches added above stay authoritative.
    for (final round in grouped.rounds) {
      final roundGames =
          grouped.gamesByRound[round.id] ?? const <GamesTourModel>[];
      for (final game in roundGames) {
        final gameRoundId = game.roundId.trim();
        if (gameRoundId.isEmpty) continue;
        roundNameById.putIfAbsent(gameRoundId, () => round.name);
        roundStartsAtById.putIfAbsent(gameRoundId, () => round.startsAt);
      }
    }
    // The list order is the source of truth: started rounds first in descending
    // order, then future rounds in descending order. A future round is promoted
    // only when every started board is finished and it begins within two hours.
    final displayRounds = sortRoundsForDisplay(
      grouped.filteredRounds,
      resolveDate: (model) => model.startsAt,
      hasGames:
          (model) =>
              (grouped.gamesByRound[model.id] ?? const <GamesTourModel>[])
                  .isNotEmpty,
      isRoundFullyPlayed: (model) {
        final games =
            grouped.gamesByRound[model.id] ?? const <GamesTourModel>[];
        return games.isNotEmpty &&
            games.every((game) => game.gameStatus.isFinished);
      },
    );
    final topRoundId = displayRounds.isEmpty ? null : displayRounds.first.id;
    final tournamentScopeId = 'tournament:${widget.tournamentId}';
    // Open the actual top round plus every already-started round. There is no
    // separate focus scroll; opening a tournament naturally starts at the top.
    bool initialExpanded(GamesAppBarModel round) =>
        round.id == topRoundId || round.roundStatus != RoundStatus.upcoming;
    bool isRoundExpanded(GamesAppBarModel round) => ref.watch(
      _tournamentRoundExpandedProvider((
        id: round.id,
        initiallyExpanded: initialExpanded(round),
      )),
    );

    // Keyboard nav must only step through games that are currently visible.
    // When a round is collapsed its games stay in `grouped.allGames` but the
    // rows aren't rendered — stepping into those would land the highlight on an
    // invisible item with no `currentContext` for `Scrollable.ensureVisible`.
    // Filter to expanded rounds only, in on-screen (descending) order.
    final keyboardGroups = <DesktopGameKeyboardGroup>[];
    for (final round in displayRounds) {
      final expanded = isRoundExpanded(round);
      final roundGames =
          grouped.gamesByRound[round.id] ?? const <GamesTourModel>[];
      final visibleRoundGames = <GamesTourModel>[];
      final showMatches = shouldShowKnockoutMatchSections(
        isKnockout: grouped.isKnockoutTournament,
        canGroup: KnockoutMatchDetector.canGroupConfirmedKnockout(roundGames),
        presentation: knockoutPresentation,
      );
      if (expanded) {
        if (!showMatches) {
          visibleRoundGames.addAll(roundGames);
        } else {
          for (final entry in orderedKnockoutMatchEntriesForDisplay(
            roundGames,
          )) {
            final expansionKey = (
              scopeId: tournamentScopeId,
              roundId: round.id,
              matchId: entry.key,
            );
            if (ref.watch(_tournamentMatchExpandedProvider(expansionKey))) {
              visibleRoundGames.addAll(entry.value);
            }
          }
        }
      }
      keyboardGroups.add(
        DesktopGameKeyboardGroup(
          id: round.id,
          games: visibleRoundGames,
          expanded: expanded,
        ),
      );
    }

    void toggleRound(String roundId) {
      final round = displayRounds.firstWhere((item) => item.id == roundId);
      final expansionKey = (
        id: round.id,
        initiallyExpanded: initialExpanded(round),
      );
      final notifier = ref.read(
        _tournamentRoundExpandedProvider(expansionKey).notifier,
      );
      notifier.state =
          !ref.read(_tournamentRoundExpandedProvider(expansionKey));
    }

    Widget searchField({required EdgeInsetsGeometry padding}) {
      return Padding(
        padding: padding,
        child: DesktopSearchField(
          controller: _searchController,
          hintText: 'Search games in this tournament (player, opening, ECO)…',
          onChanged: _runSearch,
          onClear: () {
            _debounce?.cancel();
            ref
                .read(
                  tournamentDetailGamesSearchByTabIdProvider(
                    widget.tabId,
                  ).notifier,
                )
                .state = '';
            ref.read(gamesTourScreenProvider.notifier).clearSearch();
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (grouped.loadError != null)
          Expanded(
            child: TournamentGamesLoadError(
              onRetry: () => unawaited(_retryTournamentGames()),
            ),
          )
        else if ((watchedGrouped.isLoading || isRestoringSearch) &&
            _lastStableGrouped == null)
          const Expanded(child: _LoadingState())
        else ...[
          searchField(padding: const EdgeInsets.fromLTRB(24, 12, 24, 4)),
          const SizedBox(height: 4),
          if (grouped.isKnockoutTournament)
            _KnockoutPresentationSwitcher(
              selected: knockoutPresentation,
              onChanged:
                  (next) =>
                      ref
                          .read(
                            tournamentKnockoutGamesPresentationByTabIdProvider(
                              widget.tabId,
                            ).notifier,
                          )
                          .state = next,
            ),
          if (grouped.filteredRounds.isEmpty &&
              grouped.matchFormatHeader == null)
            Expanded(
              child:
                  _searchController.text.trim().isNotEmpty
                      ? _NoSearchResults(query: _searchController.text.trim())
                      : TournamentGamesEmptyState(liveOnly: liveOnly),
            )
          else
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Row stride for ArrowUp/ArrowDown must match the on-screen
                  // grid. Grid/list/compact rounds all render at the same column
                  // count (the ListView eats 24px of padding on each side).
                  // Match/knockout/team rounds aren't a uniform grid, so keep the
                  // flat single-step walk there.
                  final isMatchStyle =
                      (grouped.isKnockoutTournament &&
                          knockoutPresentation ==
                              DesktopKnockoutGamesPresentation.matchSeries) ||
                      isTeamEvent;
                  final contentWidth =
                      (constraints.maxWidth - 48)
                          .clamp(0, double.infinity)
                          .toDouble();
                  final cardColumns = DesktopGameCardsFlow.columnCountForWidth(
                    layout,
                    contentWidth,
                  );
                  final keyboardColumns = isMatchStyle ? 1 : cardColumns;
                  return DesktopGroupedGameKeyboardFocus(
                    scopeId: tournamentScopeId,
                    groups: keyboardGroups,
                    scrollController: _scrollController,
                    resolveColumnCount: (_) => keyboardColumns,
                    onActivateGroup: toggleRound,
                    onActivateGame:
                        (game) => openTournamentGameTab(
                          ref,
                          game,
                          tournamentTitle,
                          eventGames: grouped.allGames,
                          roundNameById: roundNameById,
                        ),
                    builder:
                        (
                          context,
                          selection,
                          selectGroup,
                          selectGame,
                          keyForGroup,
                          keyForGame,
                        ) => _TournamentLiveBatchScope(
                          keysByGameId: liveBatchKeyByGameId,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _handleScrollNotification,
                            child: CustomScrollView(
                              key: PageStorageKey<String>(
                                'tournament-detail-games:${widget.tabId}',
                              ),
                              controller: _scrollController,
                              physics: const DesktopScrollPhysics(),
                              // A small overscan keeps wheel/trackpad scrolling
                              // smooth without mounting an entire 1,000-board
                              // broadcast and its realtime subscriptions.
                              scrollCacheExtent: const ScrollCacheExtent.pixels(
                                400,
                              ),
                              slivers: [
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    0,
                                    24,
                                    24,
                                  ),
                                  sliver: SliverMainAxisGroup(
                                    slivers: [
                                      // Match-format tournaments (e.g. "12-game Match" —
                                      // Carlsen vs Nepo) get one summary above the rounds.
                                      if (grouped.matchFormatHeader != null &&
                                          knockoutPresentation ==
                                              DesktopKnockoutGamesPresentation
                                                  .matchSeries)
                                        SliverToBoxAdapter(
                                          child: _MatchHeaderBanner(
                                            match: grouped.matchFormatHeader!,
                                          ),
                                        ),
                                      for (final round in displayRounds)
                                        _RoundSliverSection(
                                          key: ValueKey<String>(round.id),
                                          scopeId: tournamentScopeId,
                                          selectedGameId:
                                              selection?.groupId == round.id
                                                  ? selection?.gameId
                                                  : null,
                                          onSelectGame:
                                              (gameId) =>
                                                  selectGame(round.id, gameId),
                                          keyForGame:
                                              (gameId) =>
                                                  keyForGame(round.id, gameId),
                                          selectedHeader:
                                              selection?.isGroup == true &&
                                              selection?.groupId == round.id,
                                          onSelectHeader: selectGroup,
                                          headerKey: keyForGroup(round.id),
                                          round: round,
                                          initiallyExpanded: initialExpanded(
                                            round,
                                          ),
                                          games:
                                              grouped.gamesByRound[round.id] ??
                                              const [],
                                          eventGames: grouped.allGames,
                                          tournamentTitle: tournamentTitle,
                                          layout: layout,
                                          columns: cardColumns,
                                          isKnockout:
                                              grouped.isKnockoutTournament &&
                                              knockoutPresentation ==
                                                  DesktopKnockoutGamesPresentation
                                                      .matchSeries,
                                          isTeamEvent: isTeamEvent,
                                          roundStartsAtById: roundStartsAtById,
                                          roundNameById: roundNameById,
                                          streamingEnabled:
                                              cardStreamingEnabled,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}

final _desktopCardPgnProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, gameId) async {
      final id = gameId.trim();
      if (id.isEmpty) return null;

      final pgn = await ref.read(gameRepositoryProvider).getGamePgn(id);
      final trimmed = pgn?.trim();
      return pgnHasMoves(trimmed) ? trimmed : null;
    });

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 28,
              color: kLightGreyColor,
            ),
            const SizedBox(height: 12),
            Text(
              'No games match "$query"',
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TournamentGamesQuickFilter { all, live }

class _KnockoutPresentationSwitcher extends StatelessWidget {
  const _KnockoutPresentationSwitcher({
    required this.selected,
    required this.onChanged,
  });

  final DesktopKnockoutGamesPresentation selected;
  final ValueChanged<DesktopKnockoutGamesPresentation> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Row(
        children: [
          const Text(
            'VIEW',
            style: TextStyle(
              color: kWhiteColor70,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.55,
            ),
          ),
          const SizedBox(width: 10),
          DesktopSegmentedTabs<DesktopKnockoutGamesPresentation>(
            tabs: const [
              DesktopSegmentedTab(
                value: DesktopKnockoutGamesPresentation.matchSeries,
                label: 'Match series',
                icon: Icons.account_tree_outlined,
              ),
              DesktopSegmentedTab(
                value: DesktopKnockoutGamesPresentation.allBoards,
                label: 'All boards',
                icon: Icons.grid_view_outlined,
              ),
            ],
            selected: selected,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Game-count label rendered next to the segment tabs so the controllers
/// can hug the right edge of the bar without a leading text block pushing
/// them inward. Hidden until the grouped provider resolves a non-zero
/// count so a fresh tab doesn't briefly read "0 games".
class TournamentGamesCountLabel extends ConsumerWidget {
  const TournamentGamesCountLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grouped = ref.watch(gamesTourGroupedProvider);
    final totalGames = grouped.allGames.length;
    if (grouped.loadError != null) {
      return const Text(
        'Games unavailable',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (grouped.isLoading) {
      return const Text(
        'Loading games…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (totalGames == 0) {
      return const SizedBox.shrink();
    }
    return Text(
      totalGames == 1 ? '1 game' : '$totalGames games',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Right-aligned controllers for the Games segment: All/Live quick filter
/// + grid/list/compact view toggle. Count moved to
/// [TournamentGamesCountLabel] so this strip hugs the right edge of the
/// segment bar with no leading text padding it off-axis.
class TournamentGamesHeaderControls extends ConsumerWidget {
  const TournamentGamesHeaderControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayMode =
        ref.watch(gamesTourScreenProvider).valueOrNull?.gameDisplayMode ??
        GameDisplayMode.all;
    final selected =
        displayMode == GameDisplayMode.hideFinishedGames
            ? _TournamentGamesQuickFilter.live
            : _TournamentGamesQuickFilter.all;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopSegmentedTabs<_TournamentGamesQuickFilter>(
          tabs: const [
            DesktopSegmentedTab(
              value: _TournamentGamesQuickFilter.all,
              label: 'All',
              icon: Icons.format_list_bulleted_rounded,
            ),
            DesktopSegmentedTab(
              value: _TournamentGamesQuickFilter.live,
              label: 'Live',
              icon: Icons.radio_button_checked_rounded,
            ),
          ],
          selected: selected,
          onChanged: (next) {
            if (next == selected) return;
            switch (next) {
              case _TournamentGamesQuickFilter.all:
                unawaited(
                  ref.read(gamesTourScreenProvider.notifier).showAllGames(),
                );
              case _TournamentGamesQuickFilter.live:
                unawaited(
                  ref
                      .read(gamesTourScreenProvider.notifier)
                      .hideFinishedGames(),
                );
            }
          },
        ),
        const SizedBox(width: 10),
        const GameViewModeToggle(),
      ],
    );
  }
}

class _RoundSliverSection extends ConsumerWidget {
  const _RoundSliverSection({
    super.key,
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.selectedHeader,
    required this.onSelectHeader,
    required this.headerKey,
    required this.round,
    required this.initiallyExpanded,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.columns,
    required this.isKnockout,
    required this.isTeamEvent,
    required this.roundStartsAtById,
    required this.roundNameById,
    required this.streamingEnabled,
  });

  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final bool selectedHeader;
  final ValueChanged<String> onSelectHeader;
  final Key headerKey;
  final GamesAppBarModel round;

  /// Status-derived default open/closed state. Also the second half of the
  /// `_tournamentRoundExpandedProvider` key, so a manual toggle survives until
  /// this default flips (i.e. the round's live-state changes).
  final bool initiallyExpanded;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final int columns;
  final bool isKnockout;
  final bool isTeamEvent;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expansionKey = (id: round.id, initiallyExpanded: initiallyExpanded);
    final expanded = ref.watch(_tournamentRoundExpandedProvider(expansionKey));

    // For knockout-style stages, group games by player pairing. Tournament
    // state is already the trusted format signal; modern feeds may publish a
    // whole playoff stage without legacy `game-N` round slugs.
    final showMatches =
        isKnockout && KnockoutMatchDetector.canGroupConfirmedKnockout(games);
    final showTeamMatches = isTeamEvent && games.isNotEmpty;

    final contentSlivers = <Widget>[];
    if (expanded) {
      if (showTeamMatches) {
        for (final group in buildDesktopTeamMatchGroups(games)) {
          contentSlivers
            ..add(SliverToBoxAdapter(child: _TeamMatchHeader(group: group)))
            ..add(const SliverToBoxAdapter(child: SizedBox(height: 8)))
            ..add(
              _TournamentGamesSliverGrid(
                scopeId: scopeId,
                selectedGameId: selectedGameId,
                onSelectGame: onSelectGame,
                keyForGame: keyForGame,
                games: group.gameModels,
                eventGames: eventGames,
                tournamentTitle: tournamentTitle,
                layout: layout,
                columns: columns,
                roundStartsAtById: roundStartsAtById,
                roundNameById: roundNameById,
                streamingEnabled: streamingEnabled,
              ),
            )
            ..add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
        }
      } else if (showMatches) {
        for (final entry in orderedKnockoutMatchEntriesForDisplay(games)) {
          contentSlivers.add(
            _MatchSliverSection(
              key: ValueKey<String>('${round.id}:${entry.key}'),
              expansionKey: (
                scopeId: scopeId,
                roundId: round.id,
                matchId: entry.key,
              ),
              scopeId: scopeId,
              selectedGameId: selectedGameId,
              onSelectGame: onSelectGame,
              keyForGame: keyForGame,
              header: KnockoutMatchDetector.createMatchHeader(
                entry.key,
                entry.value,
              ),
              eventGames: eventGames,
              tournamentTitle: tournamentTitle,
              layout: layout,
              columns: columns,
              roundStartsAtById: roundStartsAtById,
              roundNameById: roundNameById,
              streamingEnabled: streamingEnabled,
            ),
          );
        }
      } else {
        contentSlivers.add(
          _TournamentGamesSliverGrid(
            scopeId: scopeId,
            selectedGameId: selectedGameId,
            onSelectGame: onSelectGame,
            keyForGame: keyForGame,
            games: games,
            eventGames: eventGames,
            tournamentTitle: tournamentTitle,
            layout: layout,
            columns: columns,
            roundStartsAtById: roundStartsAtById,
            roundNameById: roundNameById,
            streamingEnabled: streamingEnabled,
          ),
        );
      }
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: DesktopGroupedGameKeyboardHeader(
            itemKey: headerKey,
            groupId: round.id,
            onSelect: onSelectHeader,
            child: RoundHeaderCard(
              round: round,
              gameCount: games.length,
              expanded: expanded,
              selected: selectedHeader,
              onToggle:
                  () =>
                      ref
                          .read(
                            _tournamentRoundExpandedProvider(
                              expansionKey,
                            ).notifier,
                          )
                          .state = !expanded,
            ),
          ),
        ),
        if (expanded) const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ...contentSlivers,
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }
}

class _TournamentGamesSliverGrid extends StatelessWidget {
  const _TournamentGamesSliverGrid({
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.columns,
    required this.roundStartsAtById,
    required this.roundNameById,
    required this.streamingEnabled,
  });

  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final int columns;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context) {
    final metrics = DesktopGameCardsFlow.metricsFor(layout);
    final gridDelegate =
        layout == DesktopCardLayout.grid
            ? SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: metrics.spacing,
              crossAxisSpacing: metrics.spacing,
              childAspectRatio: 0.95,
            )
            : SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: metrics.spacing,
              crossAxisSpacing: metrics.spacing,
              mainAxisExtent: metrics.tileHeight,
            );
    return SliverGrid(
      gridDelegate: gridDelegate,
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final game = games[index];
          return DesktopGameKeyboardItem(
            key: ValueKey<String>(
              'tournament-lazy-card:$scopeId:${game.gameId}',
            ),
            itemKey: keyForGame(game.gameId),
            gameId: game.gameId,
            onSelect: onSelectGame,
            child: LiveDesktopGameCard(
              game: game,
              eventGames: eventGames,
              tournamentTitle: tournamentTitle,
              // DesktopGameKeyboardItem selects immediately on pointer-down;
              // the child reserves activation for double-click.
              selectionHandledByAncestor: true,
              layout: layout,
              selected: selectedGameId == game.gameId,
              roundStartsAtById: roundStartsAtById,
              roundNameById: roundNameById,
              streamingEnabled: streamingEnabled,
            ),
          );
        },
        childCount: games.length,
        // Cards outside the viewport must dispose their Riverpod listeners.
        // Selection lives in DesktopGameKeyboardFocus, not in card State, so
        // keeping every historical child alive only wastes realtime/CPU work.
        addAutomaticKeepAlives: false,
      ),
    );
  }
}

class _TeamMatchHeader extends StatelessWidget {
  const _TeamMatchHeader({required this.group});

  final DesktopTeamMatchGroup group;

  @override
  Widget build(BuildContext context) {
    final score = group.score;
    final leftScore = formatDesktopTeamMatchScore(score.left);
    final rightScore = formatDesktopTeamMatchScore(score.right);
    final leftColor =
        score.isDraw
            ? kWhiteColor
            : score.left > score.right
            ? kPrimaryColor
            : kRedColor;
    final rightColor =
        score.isDraw
            ? kWhiteColor
            : score.right > score.left
            ? kPrimaryColor
            : kRedColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
            ),
            child: const Text(
              'TEAM',
              style: TextStyle(
                color: kPrimaryColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              group.leftTeam,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _TeamScoreText(label: leftScore, color: leftColor),
          const SizedBox(width: 10),
          const Text(
            'VS',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(width: 10),
          _TeamScoreText(label: rightScore, color: rightColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              group.rightTeam,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${group.games.length} board${group.games.length == 1 ? '' : 's'}',
            style: const TextStyle(color: kLightGreyColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _TeamScoreText extends StatelessWidget {
  const _TeamScoreText({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Builds the production lazy tournament-card sliver in isolation.
///
/// This intentionally exposes only a test seam, not a second rendering path:
/// stress regressions exercise the same [_TournamentGamesSliverGrid], live
/// batch scoping, and [LiveDesktopGameCard] lifecycle used by
/// [TournamentGamesView].
@visibleForTesting
Widget buildLazyTournamentGamesViewportForTesting({
  required List<GamesTourModel> games,
  required ScrollController scrollController,
  ValueChanged<String>? onSelectGame,
  DesktopCardLayout layout = DesktopCardLayout.compact,
  bool streamingEnabled = true,
  double cacheExtent = 400,
  String scopeId = 'tournament-lazy-stress',
}) {
  final batchKeys =
      streamingEnabled
          ? liveBatchKeysForGames(
            games: games,
            scopePrefix: 'desktop_context:$scopeId',
            includeFinishedGames: true,
          )
          : const <String, LiveGamesBatchKey>{};
  return LayoutBuilder(
    builder: (context, constraints) {
      final columns = DesktopGameCardsFlow.columnCountForWidth(
        layout,
        constraints.maxWidth,
      );
      return _TournamentLiveBatchScope(
        keysByGameId: batchKeys,
        child: CustomScrollView(
          controller: scrollController,
          scrollCacheExtent: ScrollCacheExtent.pixels(cacheExtent),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: _TournamentGamesSliverGrid(
                scopeId: scopeId,
                selectedGameId: null,
                onSelectGame: onSelectGame ?? (_) {},
                keyForGame:
                    (gameId) => ValueKey<String>(
                      'tournament-lazy-stress-item:$scopeId:$gameId',
                    ),
                games: games,
                eventGames: games,
                tournamentTitle: 'Stress fixture',
                layout: layout,
                columns: columns,
                roundStartsAtById: const <String, DateTime?>{},
                roundNameById: const <String, String>{},
                streamingEnabled: streamingEnabled,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _MatchSliverSection extends ConsumerWidget {
  const _MatchSliverSection({
    super.key,
    required this.expansionKey,
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.header,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.columns,
    required this.roundStartsAtById,
    required this.roundNameById,
    required this.streamingEnabled,
  });

  final _TournamentMatchExpansionKey expansionKey;
  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final MatchHeaderModel header;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final int columns;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(_tournamentMatchExpandedProvider(expansionKey));
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _MatchSectionHeader(
            header: header,
            expanded: expanded,
            onToggle:
                () =>
                    ref
                        .read(
                          _tournamentMatchExpandedProvider(
                            expansionKey,
                          ).notifier,
                        )
                        .state = !expanded,
          ),
        ),
        if (expanded) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          _TournamentGamesSliverGrid(
            scopeId: scopeId,
            selectedGameId: selectedGameId,
            onSelectGame: onSelectGame,
            keyForGame: keyForGame,
            games: header.games,
            eventGames: eventGames,
            tournamentTitle: tournamentTitle,
            layout: layout,
            columns: columns,
            roundStartsAtById: roundStartsAtById,
            roundNameById: roundNameById,
            streamingEnabled: streamingEnabled,
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }
}

@visibleForTesting
Widget buildKnockoutMatchSectionHeaderForTesting(MatchHeaderModel header) =>
    _MatchSectionHeader(header: header, expanded: true, onToggle: () {});

class _MatchSectionHeader extends StatefulWidget {
  const _MatchSectionHeader({
    required this.header,
    required this.expanded,
    required this.onToggle,
  });

  final MatchHeaderModel header;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_MatchSectionHeader> createState() => _MatchSectionHeaderState();
}

class _MatchSectionHeaderState extends State<_MatchSectionHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.header;
    final startsAt = h.startsAt;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : kBlack2Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    _hovered
                        ? kPrimaryColor.withValues(alpha: 0.3)
                        : kDividerColor,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: _MatchPlayerIdentity(player: h.player1Card),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder:
                              (child, animation) => FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.35),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child:
                              h.hasReportedScore
                                  ? Row(
                                    key: const ValueKey<String>('scores'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _MatchScoreText(
                                        label: h.player1ScoreLabel,
                                        tone: h.player1ResultTone,
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                        ),
                                        child: Text(
                                          '–',
                                          style: TextStyle(
                                            color: kWhiteColor.withValues(
                                              alpha: 0.42,
                                            ),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      _MatchScoreText(
                                        label: h.player2ScoreLabel,
                                        tone: h.player2ResultTone,
                                      ),
                                    ],
                                  )
                                  : Text(
                                    'vs',
                                    key: ValueKey<bool>(h.hasReportedScore),
                                    style: TextStyle(
                                      color: kWhiteColor.withValues(
                                        alpha: 0.42,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                        ),
                      ),
                      Flexible(
                        child: _MatchPlayerIdentity(player: h.player2Card),
                      ),
                    ],
                  ),
                ),
                if (startsAt != null) ...[
                  const SizedBox(width: 16),
                  Icon(
                    Icons.schedule_rounded,
                    size: 13,
                    color: kWhiteColor.withValues(alpha: 0.36),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    DateFormat('MMM d · HH:mm').format(startsAt.toLocal()),
                    style: TextStyle(
                      color: kWhiteColor.withValues(alpha: 0.46),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                Text(
                  '${h.games.length} game${h.games.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Icon(
                  widget.expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: kWhiteColor70,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MatchPlayerIdentity extends StatelessWidget {
  const _MatchPlayerIdentity({required this.player});

  final PlayerCard player;

  @override
  Widget build(BuildContext context) {
    final hasFlag =
        player.federation.trim().isNotEmpty || (player.fideId ?? 0) > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasFlag) ...[
          BackfilledFederationFlag(
            federation: player.federation,
            fideId: player.fideId,
            playerName: player.name,
            width: 18,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 6),
        ],
        if (player.title.trim().isNotEmpty) ...[
          DesktopPlainPlayerTitle(title: player.title, compact: true),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ),
        if (player.rating > 0) ...[
          const SizedBox(width: 5),
          Text(
            '(${player.rating})',
            style: TextStyle(
              color: kWhiteColor.withValues(alpha: 0.48),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _MatchScoreText extends StatelessWidget {
  const _MatchScoreText({required this.label, required this.tone});

  final String label;
  final MatchPlayerResultTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      MatchPlayerResultTone.leading => kPrimaryColor,
      MatchPlayerResultTone.trailing => kRedColor,
      MatchPlayerResultTone.neutral => kWhiteColor,
    };
    return Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 13.5,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _MatchHeaderBanner extends StatelessWidget {
  const _MatchHeaderBanner({required this.match});
  final MatchHeaderModel match;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.sports_kabaddi_outlined,
              size: 18,
              color: kPrimaryColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.matchTitle,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${match.games.length} games · ${match.isComplete ? 'Match complete' : 'In progress'}',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: kBackgroundColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child: Text(
                match.scoreDisplay,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens a tournament game in a Board tab.
///
/// Opens a Board tab keyed to this game after resolving the freshest available
/// PGN/FEN snapshot. Server-backed event rails retain a bounded immediate
/// window and page the rest; broader route/source lists remain capped around
/// the selection.
///
/// Plain clicks use [replaceActive] so a game opens in the tab the user is
/// currently reading, even if another copy of that game is already open.
/// Explicit new-tab gestures (Cmd/Ctrl-click, middle-click, tab-strip drop)
/// pass `replaceActive: false` and `reuseExisting: false`.
const int _kRouteRailContextRadius = 30;

BoardTabGameArgs buildTournamentBoardTabArgs(
  GamesTourModel game,
  String tournamentTitle, {
  List<GamesTourModel> eventGames = const <GamesTourModel>[],
  String routeTitle = '',
  List<GamesTourModel> routeGames = const <GamesTourModel>[],
  BoardTabGamesContinuation? eventGamesContinuation,
  BoardTabGamesContinuation? routeGamesContinuation,
  Map<String, DateTime?> roundStartsAtById = const <String, DateTime?>{},
  Map<String, String> roundNameById = const <String, String>{},
  ChessboardView viewSource = ChessboardView.tour,
  String? eventBroadcastId,
  bool includeServerEventRail = true,
}) {
  final pgn = pgnHasMoves(game.pgn) ? game.pgn!.trim() : '';
  final normalizedGame = _withFreshestFen(game, pgnOverride: pgn);
  final eventTourId = normalizedGame.tourId.trim();
  final sourceOwnsSmartCollection =
      routeGamesContinuation?.kind == BoardTabGamesContinuationKind.smartGames;
  final eventGamesKey =
      !includeServerEventRail ||
              sourceOwnsSmartCollection ||
              viewSource == ChessboardView.favScorecard ||
              eventTourId.isEmpty
          ? null
          : BoardTabEventGamesKey(
            tourId: eventTourId,
            selectedGameId: normalizedGame.gameId,
            selectedRoundId: normalizedGame.roundId,
            selectedBoardNumber: normalizedGame.boardNr,
          );
  final eventContextGames = _boardRailContextGames(
    normalizedGame,
    eventGames,
    fallbackToSelected: true,
    // Multi-tournament Favorites rails stay keyless, but their continuation
    // can still restore every game on demand. Keep only the selected window
    // in immutable Board args so opening a large Favorites feed does not
    // mount or retain the full collection at once.
    retainAll: eventGamesKey == null && eventGamesContinuation == null,
  );
  final routeContextGames = _boardRailContextGames(
    normalizedGame,
    routeGames,
    fallbackToSelected: false,
  );
  final eventSummaries = _summariesFromModels(
    eventContextGames,
    fallbackGame: normalizedGame,
    roundStartsAtById: roundStartsAtById,
    roundNameById: roundNameById,
  );
  final routeSummaries =
      routeGames.isEmpty
          ? const <TournamentGameSummary>[]
          : _summariesFromModels(
            routeContextGames,
            fallbackGame: normalizedGame,
            roundStartsAtById: roundStartsAtById,
            roundNameById: roundNameById,
          );
  return BoardTabGameArgs(
    gameId: normalizedGame.gameId,
    pgn: pgn,
    label:
        '${normalizedGame.whitePlayer.name} vs ${normalizedGame.blackPlayer.name}',
    whiteName: normalizedGame.whitePlayer.name,
    blackName: normalizedGame.blackPlayer.name,
    whiteFederation: normalizedGame.whitePlayer.federation,
    blackFederation: normalizedGame.blackPlayer.federation,
    whiteTitle: normalizedGame.whitePlayer.title,
    blackTitle: normalizedGame.blackPlayer.title,
    whiteRating: normalizedGame.whitePlayer.rating,
    blackRating: normalizedGame.blackPlayer.rating,
    whiteFideId: normalizedGame.whitePlayer.fideId,
    blackFideId: normalizedGame.blackPlayer.fideId,
    fenSeed: normalizedGame.fen,
    sourceGame: normalizedGame.copyWith(pgn: pgn.isEmpty ? game.pgn : pgn),
    viewSource: viewSource,
    eventBroadcastId: _normalizedOptionalId(eventBroadcastId),
    tournamentTitle: tournamentTitle,
    eventGames: eventSummaries,
    eventGamesLoading: false,
    eventGamesKey: eventGamesKey,
    eventGamesContinuation: eventGamesContinuation,
    routeTitle: routeTitle,
    routeGames: routeSummaries,
    routeGamesContinuation: routeGamesContinuation,
    gameListSelectedId: normalizedGame.gameId,
  );
}

Future<void> openTournamentGameTab(
  WidgetRef ref,
  GamesTourModel game,
  String tournamentTitle, {
  List<GamesTourModel> eventGames = const <GamesTourModel>[],
  String routeTitle = '',
  List<GamesTourModel> routeGames = const <GamesTourModel>[],
  BoardTabGamesContinuation? eventGamesContinuation,
  BoardTabGamesContinuation? routeGamesContinuation,
  Map<String, DateTime?> roundStartsAtById = const <String, DateTime?>{},
  Map<String, String> roundNameById = const <String, String>{},
  bool focus = true,
  bool reuseExisting = true,
  bool replaceActive = true,
  ChessboardView viewSource = ChessboardView.tour,
  String? eventBroadcastId,
  bool Function(ProviderContainer container)? canCommitOpen,
}) async {
  // Capture the ProviderContainer up front. `ref` belongs to the widget
  // that owns the tap (often a LiveDesktopGameCard whose live-stream
  // rebuild can dispose the card while we await the PGN fetch below),
  // and Riverpod asserts on `ref.read` once the underlying element is
  // unmounted — which used to swallow the click silently. The container
  // is held by the surrounding ProviderScope and survives card disposal.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final gameRepo = container.read(gameRepositoryProvider);

  final hydratedGame = await _hydrateTournamentGameForBoardOpen(
    gameRepo: gameRepo,
    game: game,
  );
  if (canCommitOpen != null && !canCommitOpen(container)) return;
  _seedBaseGameIfFresher(container, hydratedGame);

  final args = buildTournamentBoardTabArgs(
    hydratedGame,
    tournamentTitle,
    eventGames: _replaceGameInModels(eventGames, hydratedGame),
    routeTitle: routeTitle,
    routeGames: _replaceGameInModels(routeGames, hydratedGame),
    eventGamesContinuation: eventGamesContinuation,
    routeGamesContinuation: routeGamesContinuation,
    roundStartsAtById: roundStartsAtById,
    roundNameById: roundNameById,
    viewSource: viewSource,
    eventBroadcastId: eventBroadcastId,
  );
  container.read(chessboardViewFromProviderNew.notifier).state = viewSource;
  final tabId = openBoardGameTabFromContainer(
    container,
    args,
    focus: focus,
    reuseExisting: reuseExisting,
    replaceActive: replaceActive,
  );

  unawaited(
    _refreshOpenedBoardTabWithLatestLiveGame(
      container: container,
      gameRepo: gameRepo,
      tabId: tabId,
      openedGame: args.sourceGame ?? hydratedGame,
    ),
  );
}

Future<void> openTournamentGameWindow({
  required ProviderContainer container,
  required GamesTourModel game,
  required String tournamentTitle,
  List<GamesTourModel> eventGames = const <GamesTourModel>[],
  String routeTitle = '',
  List<GamesTourModel> routeGames = const <GamesTourModel>[],
  BoardTabGamesContinuation? eventGamesContinuation,
  BoardTabGamesContinuation? routeGamesContinuation,
  Map<String, DateTime?> roundStartsAtById = const <String, DateTime?>{},
  Map<String, String> roundNameById = const <String, String>{},
  ChessboardView viewSource = ChessboardView.tour,
  String? eventBroadcastId,
}) async {
  // Both services belong to the surrounding ProviderScope, not to the live
  // card that initiated the action. Capture them before hydration so removing
  // or filtering that card cannot invalidate the detached-window open.
  final gameRepo = container.read(gameRepositoryProvider);
  final windowService = container.read(desktopBoardWindowServiceProvider);
  final hydratedGame = await _hydrateTournamentGameForBoardOpen(
    gameRepo: gameRepo,
    game: game,
  );
  _seedBaseGameIfFresher(container, hydratedGame);
  final args = buildTournamentBoardTabArgs(
    hydratedGame,
    tournamentTitle,
    eventGames: _replaceGameInModels(eventGames, hydratedGame),
    routeTitle: routeTitle,
    routeGames: _replaceGameInModels(routeGames, hydratedGame),
    eventGamesContinuation: eventGamesContinuation,
    routeGamesContinuation: routeGamesContinuation,
    roundStartsAtById: roundStartsAtById,
    roundNameById: roundNameById,
    viewSource: viewSource,
    eventBroadcastId: eventBroadcastId,
  );
  await windowService.openBoardGameWindow(args);
}

@visibleForTesting
String? forYouEventBroadcastIdFromScopeId(String? scopeId) {
  final normalized = scopeId?.trim() ?? '';
  final match = RegExp(r'^for_you:([^:]+):').firstMatch(normalized);
  final eventId = match?.group(1)?.trim() ?? '';
  return eventId.isEmpty ? null : eventId;
}

String? _normalizedOptionalId(String? value) {
  final normalized = value?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

Future<GamesTourModel> _hydrateTournamentGameForBoardOpen({
  required GameRepository gameRepo,
  required GamesTourModel game,
}) async {
  return hydrateTournamentGameForBoardOpen(
    game: game,
    fetchCanonicalGame: (gameId) async {
      final latestRow = await gameRepo.getGameWithPGN(gameId);
      return GamesTourModel.fromGame(latestRow);
    },
  );
}

/// Resolves a canonical event game before it reaches a desktop board tab.
///
/// Smart Event rows may be sourced from Gamebase even though their UUID maps
/// to a real ChessEver broadcast game. Fetching that UUID supplies the full
/// canonical PGN. Local Gamebase/TWIC rows remain offline-only and are left
/// untouched.
Future<GamesTourModel> hydrateTournamentGameForBoardOpen({
  required GamesTourModel game,
  required Future<GamesTourModel> Function(String gameId) fetchCanonicalGame,
}) async {
  final normalizedCurrent = _withFreshestFen(game);
  final shouldFetchCanonicalGame =
      game.source == GameSource.supabase ||
      isDesktopCanonicalGamebaseGame(game);
  if (!shouldFetchCanonicalGame || game.gameId.trim().isEmpty) {
    return normalizedCurrent;
  }

  try {
    final latest = _withFreshestFen(await fetchCanonicalGame(game.gameId));
    return _withFreshestFen(
      selectFreshestNavigationGame(
        current: normalizedCurrent,
        incoming: latest,
      ),
    );
  } catch (error) {
    debugPrint(
      '[DesktopBoard] Failed to hydrate game ${game.gameId} before open: $error',
    );
    return normalizedCurrent;
  }
}

void _seedBaseGameIfFresher(ProviderContainer container, GamesTourModel game) {
  final gameId = game.gameId.trim();
  if (gameId.isEmpty) return;

  final currentBase = container.read(baseGameProvider(gameId));
  if (!shouldReplaceBaseGame(currentBase, game)) return;
  container.read(baseGameProvider(gameId).notifier).state = game;
}

List<GamesTourModel> _replaceGameInModels(
  List<GamesTourModel> games,
  GamesTourModel selected,
) {
  if (games.isEmpty) return games;
  final index = games.indexWhere((game) => game.gameId == selected.gameId);
  if (index < 0) return games;

  final next = List<GamesTourModel>.from(games);
  next[index] = selected;
  return next;
}

List<GamesTourModel> _boardRailContextGames(
  GamesTourModel selected,
  List<GamesTourModel> games, {
  required bool fallbackToSelected,
  bool retainAll = false,
}) {
  if (games.isEmpty) {
    return fallbackToSelected ? <GamesTourModel>[selected] : const [];
  }
  final selectedIndex = games.indexWhere(
    (game) => game.gameId == selected.gameId,
  );
  if (selectedIndex < 0) return <GamesTourModel>[selected];

  if (retainAll) {
    final context = List<GamesTourModel>.from(games);
    context[selectedIndex] = selected;
    return context;
  }

  final start =
      selectedIndex - _kRouteRailContextRadius < 0
          ? 0
          : selectedIndex - _kRouteRailContextRadius;
  final end =
      selectedIndex + _kRouteRailContextRadius + 1 > games.length
          ? games.length
          : selectedIndex + _kRouteRailContextRadius + 1;
  final context = games.sublist(start, end);
  final contextSelectedIndex = selectedIndex - start;
  if (contextSelectedIndex >= 0 && contextSelectedIndex < context.length) {
    context[contextSelectedIndex] = selected;
  }
  return context;
}

Future<void> _refreshOpenedBoardTabWithLatestLiveGame({
  required ProviderContainer container,
  required GameRepository gameRepo,
  required String tabId,
  required GamesTourModel openedGame,
}) async {
  final gameId = openedGame.gameId.trim();
  if (gameId.isEmpty || openedGame.gameStatus.isFinished) return;

  try {
    final latestRow = await gameRepo.getGameWithPGN(gameId);
    final fetched = _withFreshestFen(GamesTourModel.fromGame(latestRow));

    // A live card may already hold a newer realtime snapshot than this one-shot
    // REST read (the stream can be ahead of the games table). Seed the board
    // from whichever is fresher so we neither show a stale position/clock nor
    // clobber fresher realtime data already in flight on another channel.
    final currentBase = container.read(baseGameProvider(gameId));
    final latestGame =
        shouldReplaceBaseGame(currentBase, fetched)
            ? fetched
            : (currentBase ?? fetched);

    if (currentBase != latestGame) {
      container.read(baseGameProvider(gameId).notifier).state = latestGame;
    }

    final latestPgn =
        pgnHasMoves(latestGame.pgn) ? latestGame.pgn!.trim() : null;
    final latestFen = latestGame.fen?.trim();
    final usableLatestFen =
        latestFen == null || latestFen.isEmpty ? null : latestFen;

    container.read(boardTabGameArgsByTabIdProvider.notifier).update((tabs) {
      final current = tabs[tabId];
      if (current == null || current.gameId != gameId) return tabs;

      final shouldUpdatePgn = latestPgn != null && latestPgn != current.pgn;
      final shouldUpdateFen =
          usableLatestFen != null && usableLatestFen != current.fenSeed;
      final shouldUpdateSourceGame = current.sourceGame != latestGame;

      if (!shouldUpdatePgn && !shouldUpdateFen && !shouldUpdateSourceGame) {
        return tabs;
      }

      return <String, BoardTabGameArgs>{
        ...tabs,
        tabId: current.copyWith(
          pgn: shouldUpdatePgn ? latestPgn : null,
          fenSeed: shouldUpdateFen ? usableLatestFen : null,
          sourceGame: shouldUpdateSourceGame ? latestGame : null,
        ),
      };
    });
  } catch (error) {
    debugPrint(
      '[DesktopBoard] Failed to refresh latest live game seed for $gameId: $error',
    );
  }
}

List<TournamentGameSummary> _summariesFromModels(
  List<GamesTourModel> games, {
  required GamesTourModel fallbackGame,
  Map<String, DateTime?> roundStartsAtById = const <String, DateTime?>{},
  Map<String, String> roundNameById = const <String, String>{},
}) {
  final byId = <String, TournamentGameSummary>{};
  for (final game in games) {
    byId[game.gameId] = TournamentGameSummary.fromGamesTourModel(
      game,
      roundStartsAt: _roundStartsAtForGame(game, roundStartsAtById),
      roundName: _roundNameForGame(game, roundNameById),
    );
  }
  byId.putIfAbsent(
    fallbackGame.gameId,
    () => TournamentGameSummary.fromGamesTourModel(
      fallbackGame,
      roundStartsAt: _roundStartsAtForGame(fallbackGame, roundStartsAtById),
      roundName: _roundNameForGame(fallbackGame, roundNameById),
    ),
  );
  return byId.values.toList(growable: false);
}

GamesTourModel _withFreshestFen(GamesTourModel game, {String? pgnOverride}) {
  final resolvedFen = resolveFreshestGameFen(
    fen: game.fen,
    pgn: pgnOverride?.trim().isNotEmpty == true ? pgnOverride : game.pgn,
    lastMove: game.lastMove,
  );
  if (resolvedFen == null || resolvedFen == game.fen) return game;
  return game.copyWith(fen: resolvedFen);
}

GamesTourModel _withHydratedCardPgn(GamesTourModel game, String? pgn) {
  final trimmed = pgn?.trim();
  if (!pgnHasMoves(trimmed)) return game;

  final snapshot = resolveFinalPositionFromPgn(trimmed);
  if (snapshot == null) return game.copyWith(pgn: trimmed);

  return game.copyWith(
    pgn: trimmed,
    fen: snapshot.fen,
    lastMove: snapshot.lastMoveUci ?? game.lastMove,
  );
}

bool _needsDesktopCardPgnHydration(GamesTourModel game) {
  if (game.source != GameSource.supabase || game.gameId.trim().isEmpty) {
    return false;
  }
  return game.gameStatus.isFinished &&
      !pgnHasMoves(game.pgn) &&
      !isValidGameFen(game.fen);
}

DateTime? _roundStartsAtForGame(
  GamesTourModel game,
  Map<String, DateTime?> roundStartsAtById,
) {
  final byId = roundStartsAtById[game.roundId];
  if (byId != null) return byId;
  final slug = game.roundSlug?.trim();
  if (slug != null && slug.isNotEmpty) {
    return roundStartsAtById[slug];
  }
  return null;
}

String? _roundNameForGame(
  GamesTourModel game,
  Map<String, String> roundNameById,
) {
  final byId = roundNameById[game.roundId]?.trim();
  if (byId != null && byId.isNotEmpty) return byId;
  final slug = game.roundSlug?.trim();
  if (slug != null && slug.isNotEmpty) {
    final bySlug = roundNameById[slug]?.trim();
    if (bySlug != null && bySlug.isNotEmpty) return bySlug;
  }
  return null;
}

/// Wraps a tournament-feed game into a [GameTabDragPayload] so it can be
/// dragged onto the tab strip. The spawn callback delegates to
/// [openTournamentGameTab] (which fetches PGN if needed and registers
/// the live-stream args), passing through the drop target's `focus`.
GameTabDragPayload tournamentGameDragPayload(
  GamesTourModel game,
  String tournamentTitle, {
  List<GamesTourModel> eventGames = const <GamesTourModel>[],
  String routeTitle = '',
  List<GamesTourModel> routeGames = const <GamesTourModel>[],
  BoardTabGamesContinuation? eventGamesContinuation,
  BoardTabGamesContinuation? routeGamesContinuation,
  Map<String, DateTime?> roundStartsAtById = const <String, DateTime?>{},
  Map<String, String> roundNameById = const <String, String>{},
  ChessboardView viewSource = ChessboardView.tour,
  String? eventBroadcastId,
}) {
  return GameTabDragPayload(
    id: game.gameId,
    label: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
    eventBroadcastId: _normalizedOptionalId(eventBroadcastId),
    spawn:
        (ref, {required focus}) => openTournamentGameTab(
          ref,
          game,
          tournamentTitle,
          eventGames: eventGames,
          routeTitle: routeTitle,
          routeGames: routeGames,
          eventGamesContinuation: eventGamesContinuation,
          routeGamesContinuation: routeGamesContinuation,
          roundStartsAtById: roundStartsAtById,
          roundNameById: roundNameById,
          focus: focus,
          viewSource: viewSource,
          eventBroadcastId: eventBroadcastId,
          // Drag/drop and modifier clicks are explicit new-tab gestures.
          // They must not jump to an already-open copy of the same game.
          replaceActive: false,
          reuseExisting: false,
        ),
  );
}

/// `DesktopGameCard` wrapper that subscribes to Supabase Realtime updates
/// for [game] via [watchLiveGame] (the same provider mobile uses) and
/// rebuilds the card whenever the broadcast pushes a new PGN, FEN,
/// last_move, clock, or status. Broadcast lists must pass [liveBatchKey] so
/// visible cards share a scoped Realtime channel instead of opening one
/// channel per board.
///
/// Use this anywhere a tournament-feed game appears on the desktop — the
/// static [DesktopGameCard] is reserved for non-live sources (Library
/// saved analyses, drag-and-drop import previews) where there's no row in
/// the `games` table to subscribe to.
class LiveDesktopGameCard extends ConsumerWidget {
  const LiveDesktopGameCard({
    super.key,
    required this.game,
    required this.tournamentTitle,
    this.eventGames = const <GamesTourModel>[],
    this.routeTitle = '',
    this.routeGames = const <GamesTourModel>[],
    this.eventGamesContinuation,
    this.routeGamesContinuation,
    this.layout = DesktopCardLayout.list,
    this.roundStartsAtById = const <String, DateTime?>{},
    this.roundNameById = const <String, String>{},
    this.selected = false,
    this.onTap,
    this.onSelect,
    this.selectionHandledByAncestor = false,
    this.enableContextMenu = true,
    this.viewSource = ChessboardView.tour,
    this.liveBatchKey,
    this.streamingEnabled = true,
    this.allowStockfishFallback = true,
    this.federationFallbackForName,
    this.federationFallback,
  });

  final GamesTourModel game;
  final String tournamentTitle;
  final List<GamesTourModel> eventGames;
  final String routeTitle;
  final List<GamesTourModel> routeGames;
  final BoardTabGamesContinuation? eventGamesContinuation;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final DesktopCardLayout layout;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;
  final bool selected;
  final bool enableContextMenu;
  final ChessboardView viewSource;
  final LiveGamesBatchKey? liveBatchKey;
  final bool streamingEnabled;

  /// When false, the eval bar inside this card suppresses Stockfish fallback.
  /// Pass `false` while the host list is actively scrolling so we don't burn
  /// CPU evaluating boards that are about to leave the viewport.
  final bool allowStockfishFallback;

  /// Tap handler override. Defaults to the standard
  /// [openTournamentGameTab] flow so callers don't have to repeat the
  /// boilerplate; pass a custom callback (e.g. to land on a dedicated
  /// player score-card pane) when needed.
  final VoidCallback? onTap;

  /// When supplied, a normal click only selects the card and a double-click
  /// performs the usual game-open action. Other game-card surfaces keep their
  /// existing single-click behavior by leaving this null.
  final VoidCallback? onSelect;

  /// The surrounding keyboard item owns immediate pointer-down selection.
  /// In this mode a plain child tap has no action, while double-click keeps
  /// the usual game-open behavior and modifier-click still opens a new tab.
  final bool selectionHandledByAncestor;

  /// When set together with [federationFallback], any side whose name
  /// matches and whose federation is empty inherits the fallback ISO2 code.
  /// Used by the player profile to honour the user's Countrymen selection
  /// when the profile player has no federation on file.
  final String? federationFallbackForName;
  final String? federationFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effectiveLiveBatchKey =
        liveBatchKey ??
        _TournamentLiveBatchScope.keyFor(context, game.gameId) ??
        liveContextBatchKeyForGame(
          game: game,
          contextGames: eventGames.isNotEmpty ? eventGames : routeGames,
          scopePrefix: 'desktop_context',
          includeFinishedGames: true,
        );
    final liveGame = watchLiveGame(
      ref,
      game,
      batchKey: effectiveLiveBatchKey,
      streamEnabled: streamingEnabled,
    );
    final hydratedPgn =
        _needsDesktopCardPgnHydration(liveGame)
            ? ref.watch(_desktopCardPgnProvider(liveGame.gameId)).valueOrNull
            : null;
    final displayGame = _withHydratedCardPgn(liveGame, hydratedPgn);
    final eventBroadcastId =
        viewSource == ChessboardView.forYou
            ? forYouEventBroadcastIdFromScopeId(effectiveLiveBatchKey?.scopeId)
            : null;
    final liveCardsPaused = ref.watch(liveGameCardsPausedProvider);
    final shouldStream = ref.watch(shouldStreamProvider);
    var data = GameCardData.fromGamesTourModel(displayGame);
    final fallback = federationFallback?.trim();
    final fallbackName = federationFallbackForName?.trim();
    if (fallback != null &&
        fallback.isNotEmpty &&
        fallbackName != null &&
        fallbackName.isNotEmpty) {
      final lcName = fallbackName.toLowerCase();
      if (data.whiteName.trim().toLowerCase() == lcName &&
          data.whiteFederation.trim().isEmpty) {
        data = data.copyWith(whiteFederation: fallback);
      }
      if (data.blackName.trim().toLowerCase() == lcName &&
          data.blackFederation.trim().isEmpty) {
        data = data.copyWith(blackFederation: fallback);
      }
    }
    void openGame() {
      final callback = onTap;
      if (callback != null) {
        callback();
        return;
      }
      openTournamentGameTab(
        ref,
        displayGame,
        tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        roundNameById: roundNameById,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      );
    }

    return DesktopGameCard(
      // Re-derive every rebuild so the eval bar's FEN, the status pill,
      // and the "In play"/result label pick up Realtime deltas.
      data: data,
      onTap: selectionHandledByAncestor ? null : onSelect ?? openGame,
      onDoubleTap:
          selectionHandledByAncestor
              ? openGame
              : onSelect == null
              ? null
              : () {
                onSelect!();
                openGame();
              },
      onContextMenu:
          enableContextMenu
              ? (position) {
                unawaited(
                  _showLiveGameContextMenu(
                    context: context,
                    ref: ref,
                    position: position,
                    game: liveGame,
                    tournamentTitle: tournamentTitle,
                    eventGames: eventGames,
                    routeTitle: routeTitle,
                    routeGames: routeGames,
                    eventGamesContinuation: eventGamesContinuation,
                    routeGamesContinuation: routeGamesContinuation,
                    roundStartsAtById: roundStartsAtById,
                    roundNameById: roundNameById,
                    viewSource: viewSource,
                    eventBroadcastId: eventBroadcastId,
                  ),
                );
              }
              : null,
      dragPayload: tournamentGameDragPayload(
        liveGame,
        tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        roundNameById: roundNameById,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      ),
      layout: layout,
      selected: selected,
      allowStockfishFallback:
          streamingEnabled &&
          allowStockfishFallback &&
          shouldStream &&
          !liveCardsPaused,
    );
  }
}

class _TournamentLiveBatchScope extends InheritedWidget {
  const _TournamentLiveBatchScope({
    required this.keysByGameId,
    required super.child,
  });

  final Map<String, LiveGamesBatchKey> keysByGameId;

  static LiveGamesBatchKey? keyFor(BuildContext context, String gameId) {
    return context
        .dependOnInheritedWidgetOfExactType<_TournamentLiveBatchScope>()
        ?.keysByGameId[gameId];
  }

  @override
  bool updateShouldNotify(_TournamentLiveBatchScope oldWidget) {
    return !identical(keysByGameId, oldWidget.keysByGameId);
  }
}

enum _LiveGameContextAction {
  open,
  openNewTab,
  openNewWindow,
  openBackground,
  saveToLibrary,
  share,
  copyShareLink,
  whiteProfile,
  blackProfile,
  copyGameId,
}

Future<void> _showLiveGameContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset position,
  required GamesTourModel game,
  required String tournamentTitle,
  required List<GamesTourModel> eventGames,
  required String routeTitle,
  required List<GamesTourModel> routeGames,
  required BoardTabGamesContinuation? eventGamesContinuation,
  required BoardTabGamesContinuation? routeGamesContinuation,
  required Map<String, DateTime?> roundStartsAtById,
  required Map<String, String> roundNameById,
  required ChessboardView viewSource,
  required String? eventBroadcastId,
}) async {
  final shareUrl = buildDesktopGameShareUrl(game: game);
  final canSaveToLibrary = canSaveDesktopGameToLibrary(game);
  final picked = await showDesktopContextMenu<_LiveGameContextAction>(
    context: context,
    position: position,
    width: 248,
    entries: [
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.open,
        icon: Icons.open_in_new_rounded,
        label: 'Open game',
      ),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.openNewTab,
        icon: Icons.add_to_photos_outlined,
        label: 'Open in new tab',
      ),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.openNewWindow,
        icon: Icons.open_in_new_rounded,
        label: 'Open in new window',
      ),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.openBackground,
        icon: Icons.tab_unselected_rounded,
        label: 'Open in background',
      ),
      if (canSaveToLibrary) ...[
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: _LiveGameContextAction.saveToLibrary,
          icon: Icons.library_add_outlined,
          label: 'Save to library',
        ),
      ],
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.share,
        icon: Icons.share_rounded,
        label: 'Share Game',
      ),
      DesktopContextMenuItem(
        value: _LiveGameContextAction.copyShareLink,
        icon: Icons.copy_rounded,
        label: 'Copy share link',
        enabled: shareUrl != null,
      ),
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.whiteProfile,
        icon: Icons.person_outline_rounded,
        label: 'Open White profile',
      ),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.blackProfile,
        icon: Icons.person_2_outlined,
        label: 'Open Black profile',
      ),
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _LiveGameContextAction.copyGameId,
        icon: Icons.tag_rounded,
        label: 'Copy game ID',
      ),
    ],
  );
  if (picked == null || !context.mounted) return;

  switch (picked) {
    case _LiveGameContextAction.open:
      await openTournamentGameTab(
        ref,
        game,
        tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        roundNameById: roundNameById,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      );
    case _LiveGameContextAction.openNewTab:
      await openTournamentGameTab(
        ref,
        game,
        tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        focus: true,
        reuseExisting: false,
        replaceActive: false,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      );
    case _LiveGameContextAction.openNewWindow:
      final container = ProviderScope.containerOf(context, listen: false);
      await openTournamentGameWindow(
        container: container,
        game: game,
        tournamentTitle: tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        roundNameById: roundNameById,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      );
    case _LiveGameContextAction.openBackground:
      await openTournamentGameTab(
        ref,
        game,
        tournamentTitle,
        eventGames: eventGames,
        routeTitle: routeTitle,
        routeGames: routeGames,
        eventGamesContinuation: eventGamesContinuation,
        routeGamesContinuation: routeGamesContinuation,
        roundStartsAtById: roundStartsAtById,
        focus: false,
        reuseExisting: false,
        replaceActive: false,
        viewSource: viewSource,
        eventBroadcastId: eventBroadcastId,
      );
    case _LiveGameContextAction.saveToLibrary:
      await saveDesktopGameToLibrary(
        context: context,
        ref: ref,
        game: game,
        sourceLabel: tournamentTitle,
      );
    case _LiveGameContextAction.share:
      await showDesktopGameShareDialog(context: context, ref: ref, game: game);
    case _LiveGameContextAction.copyShareLink:
      await copyDesktopShareUrl(
        context,
        shareUrl,
        copiedLabel: 'Game link copied to clipboard',
        missingLabel: 'This game has no shareable link yet.',
      );
    case _LiveGameContextAction.whiteProfile:
      _openGamePlayerProfile(ref, game.whitePlayer);
    case _LiveGameContextAction.blackProfile:
      _openGamePlayerProfile(ref, game.blackPlayer);
    case _LiveGameContextAction.copyGameId:
      await Clipboard.setData(ClipboardData(text: game.gameId));
  }
}

void _openGamePlayerProfile(WidgetRef ref, PlayerCard player) {
  final name = player.name.trim();
  if (name.isEmpty) return;
  openPlayerProfile(
    ref,
    PlayerProfileArgs(
      playerName: name,
      fideId: player.fideId,
      title: player.title.trim().isEmpty ? null : player.title.trim(),
      federation:
          player.federation.trim().isNotEmpty
              ? player.federation.trim()
              : (player.countryCode.trim().isEmpty
                  ? null
                  : player.countryCode.trim()),
      rating: player.rating > 0 ? player.rating : null,
      gamebasePlayerId: player.gamebasePlayerId,
    ),
  );
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

class TournamentGamesLoadError extends StatelessWidget {
  const TournamentGamesLoadError({required this.onRetry, super.key});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 32,
              color: kLightGreyColor,
            ),
            const SizedBox(height: 12),
            const Text(
              'Could not load games',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'The tournament feed did not respond. Check your connection and try again.',
              style: TextStyle(color: kLightGreyColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            DesktopHeaderActionButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPress: onRetry,
              accented: true,
            ),
          ],
        ),
      ),
    );
  }
}

class TournamentGamesEmptyState extends StatelessWidget {
  const TournamentGamesEmptyState({required this.liveOnly, super.key});

  final bool liveOnly;

  @override
  Widget build(BuildContext context) {
    final icon =
        liveOnly
            ? Icons.radio_button_unchecked_rounded
            : Icons.event_note_outlined;
    final title = liveOnly ? 'No live games right now' : 'No rounds yet';
    final message =
        liveOnly
            ? 'Switch to All to browse completed and upcoming games.'
            : 'Tournament rounds will appear here once they\'re scheduled.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: kLightGreyColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(color: kLightGreyColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
