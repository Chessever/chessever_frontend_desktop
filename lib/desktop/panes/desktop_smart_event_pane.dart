import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/panes/desktop_smart_games_pane.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/smart_collection_access.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart'
    show DesktopCardLayout;
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/smart_event/smart_event_criteria_bar.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart'
    show ChessboardView;
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/smart_event/smart_aggregate_event_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// `TabKind.smartGames` router: a tab carrying a criteria-driven smart event
/// renders [DesktopSmartEventPane]; every other smart-games tab keeps the
/// fixed collection pane.
class DesktopSmartGamesTabContent extends ConsumerWidget {
  const DesktopSmartGamesTabContent({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSmartEvent = ref.watch(
      desktopSmartEventTabStateByTabIdProvider.select(
        (states) => states.containsKey(tabId),
      ),
    );
    return isSmartEvent
        ? DesktopSmartEventPane(tabId: tabId)
        : DesktopSmartGamesPane(tabId: tabId);
  }
}

enum DesktopSmartEventView { about, games, events }

/// A criteria-driven smart event as a desktop pane.
///
/// About, Games and Events are three readings of ONE query, watched once at
/// the pane: switching views never refetches, and the last loaded event is
/// retained while a re-keyed query loads, so editing criteria never flashes a
/// spinner or a false empty state. Search and the criteria editor live here at
/// the container level, not per view.
class DesktopSmartEventPane extends ConsumerStatefulWidget {
  const DesktopSmartEventPane({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<DesktopSmartEventPane> createState() =>
      _DesktopSmartEventPaneState();
}

class _DesktopSmartEventPaneState extends ConsumerState<DesktopSmartEventPane> {
  static const Duration _searchDebounceDuration = Duration(milliseconds: 350);

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _gamesScroll = ScrollController();
  final ScrollController _eventsScroll = ScrollController();
  final ScrollController _aboutScroll = ScrollController();
  final Set<String> _collapsedDays = <String>{};

  Timer? _searchDebounce;
  String _search = '';
  DesktopSmartEventView _view = DesktopSmartEventView.games;
  SmartAggregateEvent? _lastLoaded;
  bool _saving = false;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _gamesScroll.dispose();
    _eventsScroll.dispose();
    _aboutScroll.dispose();
    super.dispose();
  }

  DesktopSmartEventTabState? _readTabState() =>
      ref.read(desktopSmartEventTabStateByTabIdProvider)[widget.tabId];

  void _writeTabState(DesktopSmartEventTabState next) {
    ref
        .read(desktopSmartEventTabStateByTabIdProvider.notifier)
        .update((states) => {...states, widget.tabId: next});
  }

  void _applyRequest(SmartEventRequest next) {
    final current = _readTabState();
    if (current == null || current.request == next) return;
    _writeTabState(current.withRequest(next));
    ref
        .read(desktopTabsProvider.notifier)
        .rename(widget.tabId, title: next.displayName);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      setState(() => _search = value.trim());
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() => _search = '');
  }

  Future<void> _onSaveAction({
    required SmartEventRequest request,
    required FavoriteEvent? savedFavorite,
    required bool hasUnsavedCriteria,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    final notifier = ref.read(favoriteEventsProvider.notifier);
    String? failure;
    String? success;
    try {
      if (savedFavorite == null) {
        failure = "Couldn't save this smart event.";
        await notifier.addFavorite(
          eventId: request.favoriteEventId,
          eventName: request.displayName,
          maxAvgElo: request.minElo > 0 ? request.minElo : null,
          extraMetadata: request.toFavoriteMetadata(),
        );
        success = 'Saved to For You';
      } else if (hasUnsavedCriteria) {
        failure = "Couldn't save changes. Your saved smart event is unchanged.";
        await persistSmartEventCriteriaChange(
          notifier: notifier,
          savedFavorite: savedFavorite,
          updated: request,
        );
        success = 'Changes saved';
      } else {
        failure = "Couldn't remove this smart event.";
        await notifier.removeFavorite(savedFavorite.eventId);
        success = 'Removed from For You';
      }
      // The saved baseline advances only now, after the write is confirmed.
      final current = _readTabState();
      if (current != null) {
        _writeTabState(
          current.attachedTo(
            savedFavorite != null && !hasUnsavedCriteria
                ? null
                : request.criteriaKey,
          ),
        );
      }
      if (mounted) showDesktopToast(context, success);
    } catch (error) {
      debugPrint('[SmartEventPane] save action failed: $error');
      if (mounted) showDesktopToast(context, failure!, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetToSaved(FavoriteEvent savedFavorite) {
    _applyRequest(SmartEventRequest.fromFavoriteEvent(savedFavorite));
  }

  Future<void> _openGame(
    GamesTourModel game,
    SmartAggregateEvent event,
    SmartEventRequest request,
  ) async {
    final provenance = SmartCollectionProvenance(
      criteriaKey: request.criteriaKey,
      displayName: request.displayName,
    );
    final allowed = await ref.read(smartCollectionContentGateProvider)(
      context,
      provenance,
      SmartCollectionContentAction.openGame,
    );
    if (!allowed || !mounted) return;
    await openTournamentGameTab(
      ref,
      game,
      event.gameEventNames[game.gameId] ?? request.displayName,
      routeTitle: request.displayName,
      routeGames: event.games,
      viewSource: ChessboardView.tour,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabState = ref.watch(
      desktopSmartEventTabStateByTabIdProvider.select(
        (states) => states[widget.tabId],
      ),
    );
    if (tabState == null) return const SizedBox.shrink();

    final request = tabState.request;
    final query = SmartEventGamesQuery(request: request, searchQuery: _search);
    final async = ref.watch(smartAggregateEventRepositoryProvider(query));
    final loaded = async.valueOrNull;
    if (loaded != null) _lastLoaded = loaded;
    final shown = loaded ?? _lastLoaded;
    final isRefreshing = loaded == null && shown != null && async.isLoading;

    final savedFavorite = ref.watch(
      smartEventSavedFavoriteProvider(
        tabState.savedCriteriaKey ?? request.criteriaKey,
      ),
    );
    final isSaved = savedFavorite != null;
    final hasUnsavedCriteria = isSaved && tabState.hasUnsavedCriteria;

    return ColoredBox(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        request.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: kWhiteColor.withValues(alpha: 0.62),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                DesktopToolbarPillButton(
                  label:
                      !isSaved
                          ? 'Save'
                          : hasUnsavedCriteria
                          ? 'Save changes'
                          : 'Saved',
                  icon:
                      !isSaved
                          ? Icons.bookmark_add_outlined
                          : hasUnsavedCriteria
                          ? Icons.check_rounded
                          : Icons.bookmark_rounded,
                  tone:
                      isSaved
                          ? DesktopToolbarPillTone.primary
                          : DesktopToolbarPillTone.neutral,
                  busy: _saving,
                  tooltip:
                      !isSaved
                          ? 'Keep these criteria on For You'
                          : hasUnsavedCriteria
                          ? 'Save the edited criteria onto this smart event'
                          : 'Remove from For You',
                  onPress:
                      _saving
                          ? null
                          : () => _onSaveAction(
                            request: request,
                            savedFavorite: savedFavorite,
                            hasUnsavedCriteria: hasUnsavedCriteria,
                          ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: SmartEventCriteriaBar(
              request: request,
              onChanged: _applyRequest,
              onResetToSaved:
                  hasUnsavedCriteria
                      ? () => _resetToSaved(savedFavorite)
                      : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
            child: Row(
              children: [
                DesktopSegmentedTabs<DesktopSmartEventView>(
                  tabs: const [
                    DesktopSegmentedTab(
                      value: DesktopSmartEventView.about,
                      label: 'About',
                    ),
                    DesktopSegmentedTab(
                      value: DesktopSmartEventView.games,
                      label: 'Games',
                    ),
                    DesktopSegmentedTab(
                      value: DesktopSmartEventView.events,
                      label: 'Events',
                    ),
                  ],
                  selected: _view,
                  onChanged: (view) => setState(() => _view = view),
                ),
                const Spacer(),
                Flexible(
                  child: DesktopSearchField(
                    controller: _searchController,
                    maxWidth: 300,
                    hintText: 'Search players, events, openings',
                    onChanged: _onSearchChanged,
                    onClear: _clearSearch,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 2,
            child:
                isRefreshing
                    ? const LinearProgressIndicator(
                      minHeight: 2,
                      color: kPrimaryColor,
                      backgroundColor: Colors.transparent,
                    )
                    : null,
          ),
          Expanded(
            child:
                shown == null
                    ? _buildFirstLoad(async, query)
                    : IndexedStack(
                      index: _view.index,
                      children: [
                        _SmartEventAboutView(
                          request: request,
                          event: shown,
                          controller: _aboutScroll,
                        ),
                        _buildGames(shown, request, query),
                        _SmartEventEventsView(
                          event: shown,
                          controller: _eventsScroll,
                          onOpen:
                              (event) => setActiveTournament(
                                ref,
                                event,
                                openInNewTab: true,
                              ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirstLoad(
    AsyncValue<SmartAggregateEvent> async,
    SmartEventGamesQuery query,
  ) {
    if (async.hasError) {
      return _CenteredMessage(
        message: "Couldn't load this smart event.",
        action: DesktopToolbarPillButton(
          label: 'Retry',
          icon: Icons.refresh_rounded,
          onPress:
              () =>
                  ref.invalidate(smartAggregateEventRepositoryProvider(query)),
        ),
      );
    }
    return const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }

  Widget _buildGames(
    SmartAggregateEvent event,
    SmartEventRequest request,
    SmartEventGamesQuery query,
  ) {
    if (event.games.isEmpty) {
      return _CenteredMessage(
        message:
            _search.isEmpty
                ? 'No games match these criteria yet.'
                : 'No games match "$_search".',
      );
    }

    final days = groupSmartEventGamesByDay(event.games);
    final provenance = SmartCollectionProvenance(
      criteriaKey: request.criteriaKey,
      displayName: request.displayName,
    );
    final contextMenuAllowed = ref.watch(
      smartCollectionContextMenuAllowedProvider(provenance),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 900 &&
            event.hasMore &&
            !event.isLoadingMore) {
          ref
              .read(smartAggregateEventRepositoryProvider(query).notifier)
              .loadMore();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gutter = 24.0;
          const spacing = 8.0;
          const minTileWidth = 248.0;
          final columns = math.max(
            2,
            ((constraints.maxWidth - gutter * 2 + spacing) /
                    (minTileWidth + spacing))
                .floor(),
          );
          return CustomScrollView(
            key: PageStorageKey<String>('smart-event-games:${widget.tabId}'),
            controller: _gamesScroll,
            physics: const DesktopScrollPhysics(),
            slivers: [
              for (var i = 0; i < days.length; i++) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    i == 0 ? 8 : 20,
                    gutter,
                    10,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: DesktopDateGroupCard(
                      label: formatSmartEventDayLabel(days[i].day),
                      gameCount: days[i].games.length,
                      collapsed: _collapsedDays.contains(days[i].key),
                      onToggle:
                          () => setState(() {
                            if (!_collapsedDays.remove(days[i].key)) {
                              _collapsedDays.add(days[i].key);
                            }
                          }),
                    ),
                  ),
                ),
                if (!_collapsedDays.contains(days[i].key))
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: gutter),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio: 0.95,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final game = days[i].games[index];
                        return LiveDesktopGameCard(
                          key: ValueKey<String>('smart-event:${game.gameId}'),
                          game: game,
                          tournamentTitle:
                              event.gameEventNames[game.gameId] ??
                              request.displayName,
                          routeTitle: request.displayName,
                          routeGames: event.games,
                          layout: DesktopCardLayout.grid,
                          viewSource: ChessboardView.tour,
                          enableContextMenu: contextMenuAllowed,
                          onTap: () => _openGame(game, event, request),
                        );
                      }, childCount: days[i].games.length),
                    ),
                  ),
              ],
              if (event.isLoadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }
}

/// One whole `game_day` of a smart event, in the provider's order.
@immutable
class SmartEventDaySection {
  const SmartEventDaySection({required this.day, required this.games});

  final DateTime day;
  final List<GamesTourModel> games;

  String get key => DateFormat('yyyy-MM-dd').format(day);
}

/// Splits the already ordered games into day sections without re-sorting:
/// the provider's order (day, pinned, average Elo, top Elo, board, id) is the
/// only order, and it is not keyed on live status.
List<SmartEventDaySection> groupSmartEventGamesByDay(
  List<GamesTourModel> orderedGames,
) {
  final sections = <SmartEventDaySection>[];
  DateTime? currentDay;
  var current = <GamesTourModel>[];
  for (final game in orderedGames) {
    final raw =
        game.gameDay ?? game.bucketDate ?? game.lastMoveTime ?? DateTime(0);
    final day = DateTime(raw.year, raw.month, raw.day);
    if (currentDay != day) {
      if (currentDay != null) {
        sections.add(SmartEventDaySection(day: currentDay, games: current));
      }
      currentDay = day;
      current = <GamesTourModel>[];
    }
    current.add(game);
  }
  if (currentDay != null) {
    sections.add(SmartEventDaySection(day: currentDay, games: current));
  }
  return sections;
}

String formatSmartEventDayLabel(DateTime day, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return DateFormat('EEE d MMM yyyy').format(day);
}

class _SmartEventAboutView extends StatelessWidget {
  const _SmartEventAboutView({
    required this.request,
    required this.event,
    required this.controller,
  });

  final SmartEventRequest request;
  final SmartAggregateEvent event;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final explanation = request.openingExplanation;
    final days = groupSmartEventGamesByDay(event.games).length;
    final dateFormat = DateFormat('d MMM yyyy');
    final dateStart = event.dateStart;
    final dateEnd = event.dateEnd;
    return SingleChildScrollView(
      controller: controller,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                describeSmartEventCriteria(request),
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 44,
                runSpacing: 20,
                children: [
                  _Figure(value: '${event.games.length}', label: 'games'),
                  _Figure(
                    value: '${event.tournamentCount}',
                    label: event.tournamentCount == 1 ? 'event' : 'events',
                  ),
                  _Figure(value: '${event.liveGameCount}', label: 'live now'),
                  if (event.avgElo > 0)
                    _Figure(
                      value: '${event.avgElo}',
                      label: 'average event rating',
                    ),
                ],
              ),
              if (dateStart != null && dateEnd != null) ...[
                const SizedBox(height: 20),
                Text(
                  '${dateFormat.format(dateStart)} to ${dateFormat.format(dateEnd)}',
                  style: TextStyle(
                    color: kWhiteColor.withValues(alpha: 0.62),
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (explanation != null) ...[
                const SizedBox(height: 32),
                Text(
                  '${explanation.codeLabel}  ${explanation.title}',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  explanation.scope,
                  style: TextStyle(
                    color: kWhiteColor.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                if (explanation.moves != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    explanation.moves!,
                    style: TextStyle(
                      color: kWhiteColor.withValues(alpha: 0.7),
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
              if (days > 0) ...[
                const SizedBox(height: 32),
                Text(
                  days == 1
                      ? 'Figures cover the most recent day loaded.'
                      : 'Figures cover the $days most recent days loaded.',
                  style: TextStyle(
                    color: kWhiteColor.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Plain-language reading of a smart event's criteria for the About view.
String describeSmartEventCriteria(SmartEventRequest request) {
  final parts = <String>[];
  parts.add(
    request.hasEloRange && request.minElo > 0
        ? 'Games where the two players average ${request.minElo} or more'
        : 'Games at every rating level',
  );
  final hasLive = request.formatsAndStates.contains('live');
  final hasCompleted = request.formatsAndStates.contains('completed');
  if (hasLive && !hasCompleted) parts.add('being played right now');
  if (hasCompleted && !hasLive) parts.add('already finished');
  const controls = {
    'standard': 'classical',
    'rapid': 'rapid',
    'blitz': 'blitz',
  };
  final chosen = [
    for (final entry in controls.entries)
      if (request.formatsAndStates.contains(entry.key)) entry.value,
  ];
  if (chosen.isNotEmpty && chosen.length < controls.length) {
    parts.add('${chosen.join(' or ')} only');
  }
  final explanation = request.openingExplanation;
  if (explanation != null) parts.add('from the ${explanation.title}');
  return '${parts.join(', ')}.';
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: kWhiteColor.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _SmartEventEventsView extends StatelessWidget {
  const _SmartEventEventsView({
    required this.event,
    required this.controller,
    required this.onOpen,
  });

  final SmartAggregateEvent event;
  final ScrollController controller;
  final ValueChanged<GroupEventCardModel> onOpen;

  @override
  Widget build(BuildContext context) {
    if (event.events.isEmpty) {
      return const _CenteredMessage(message: 'No events in this smart event.');
    }
    final gamesByEvent = <String, int>{};
    for (final eventId in event.gameEventIds.values) {
      gamesByEvent[eventId] = (gamesByEvent[eventId] ?? 0) + 1;
    }
    return ListView.builder(
      controller: controller,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: event.events.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return const _EventsHeaderRow();
        final item = event.events[index - 1];
        return _EventRow(
          event: item,
          gameCount: gamesByEvent[item.id] ?? 0,
          onOpen: () => onOpen(item),
        );
      },
    );
  }
}

const TextStyle _eventHeaderStyle = TextStyle(
  color: Color(0x80FFFFFF),
  fontSize: 12,
  fontWeight: FontWeight.w600,
);

class _EventsHeaderRow extends StatelessWidget {
  const _EventsHeaderRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(flex: 6, child: Text('Event', style: _eventHeaderStyle)),
          Expanded(flex: 3, child: Text('Dates', style: _eventHeaderStyle)),
          Expanded(flex: 2, child: Text('Control', style: _eventHeaderStyle)),
          Expanded(
            flex: 2,
            child: Text(
              'Avg rating',
              textAlign: TextAlign.right,
              style: _eventHeaderStyle,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Games here',
              textAlign: TextAlign.right,
              style: _eventHeaderStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatefulWidget {
  const _EventRow({
    required this.event,
    required this.gameCount,
    required this.onOpen,
  });

  final GroupEventCardModel event;
  final int gameCount;
  final VoidCallback onOpen;

  @override
  State<_EventRow> createState() => _EventRowState();
}

class _EventRowState extends State<_EventRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final secondary = TextStyle(
      color: kWhiteColor.withValues(alpha: 0.68),
      fontSize: 13,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpen,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    event.dates,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondary,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    event.timeControl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondary,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    event.maxAvgElo > 0 ? '${event.maxAvgElo}' : '-',
                    textAlign: TextAlign.right,
                    style: secondary,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '${widget.gameCount}',
                    textAlign: TextAlign.right,
                    style: secondary.copyWith(color: kWhiteColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kWhiteColor.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}
