import 'dart:async';

import 'package:cue/cue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_event_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_hero_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_country_picker.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/providers/event_favorite_players_provider.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/screens/countrymen/tabs/countrymen_events_tab.dart';
import 'package:chessever/screens/countrymen/tabs/countrymen_players_tab.dart';
import 'package:chessever/screens/favorites/favorite_players_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';
import 'package:chessever/widgets/federation_flag.dart';

/// Desktop Countrymen pane.
///
/// Wraps `countrymenCombinedGamesProvider` (the same StateNotifier the
/// mobile combined-games tab uses). Reuses [LiveDesktopGameCard] so each
/// row is fully live-streamed (PGN / FEN / clocks / status) and shows the
/// federation flag beside *every* player name. The chrome — hero header,
/// search field, stat chips — animates in with cue + motor springs.
class CountrymenPane extends HookConsumerWidget {
  const CountrymenPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countrymenCombinedGamesProvider);
    final selectedMode = ref.watch(selectedCountrymenModeProvider);
    final effectiveCountry = ref.watch(effectiveCountryProvider).valueOrNull;
    final temporaryCountry = ref.watch(temporaryCountryProvider);

    final games = state.filteredGames;
    final liveCount =
        games.where((g) => !g.effectiveGameStatus.isFinished).length;

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CountrymenHero(
            countryName: effectiveCountry?.name ?? state.countryName,
            countryCode: effectiveCountry?.countryCode ?? state.countryCode,
            totalCount: state.games.length,
            liveCount: liveCount,
            liveOnly: state.liveOnly,
            onSelectLive:
                () => ref
                    .read(countrymenCombinedGamesProvider.notifier)
                    .setLiveOnly(true),
            onSelectTotal:
                () => ref
                    .read(countrymenCombinedGamesProvider.notifier)
                    .setLiveOnly(false),
            hasTemporaryCountry: temporaryCountry != null,
            onChangeCountry: () async {
              final picked = await showDesktopCountryPicker(
                context,
                initialCountry: effectiveCountry,
              );
              if (picked == null) return;
              ref.read(temporaryCountryProvider.notifier).state = picked;
            },
            onPinCountry:
                temporaryCountry == null
                    ? null
                    : () {
                      ref
                          .read(countryDropdownProvider.notifier)
                          .selectCountry(temporaryCountry.countryCode);
                      ref.read(temporaryCountryProvider.notifier).state = null;
                    },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Cue.onMount(
              motion: const CueMotion.smooth(),
              acts: [const Act.fadeIn(), const Act.slideY(from: 0.25)],
              child: DesktopSegmentedTabs<CountrymenScreenMode>(
                selected: selectedMode,
                onChanged: (mode) {
                  ref
                      .read(selectedCountrymenModeProvider.notifier)
                      .update((_) => mode);
                },
                tabs: const [
                  DesktopSegmentedTab(
                    value: CountrymenScreenMode.events,
                    label: 'Events',
                    icon: Icons.event_outlined,
                  ),
                  DesktopSegmentedTab(
                    value: CountrymenScreenMode.games,
                    label: 'Games',
                    icon: Icons.grid_4x4_outlined,
                  ),
                  DesktopSegmentedTab(
                    value: CountrymenScreenMode.players,
                    label: 'Players',
                    icon: Icons.groups_2_outlined,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: switch (selectedMode) {
                CountrymenScreenMode.events => const _CountrymenEventsView(
                  key: ValueKey('events'),
                ),
                CountrymenScreenMode.games => const _CountrymenGamesView(
                  key: ValueKey('games'),
                ),
                CountrymenScreenMode.players => const _CountrymenPlayersView(
                  key: ValueKey('players'),
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CountrymenGamesView extends HookConsumerWidget {
  const _CountrymenGamesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countrymenCombinedGamesProvider);
    final searchController = useTextEditingController(text: state.searchQuery);
    final debounceTimer = useRef<Timer?>(null);

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    final games = state.filteredGames;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(
                child: DesktopSearchField(
                  controller: searchController,
                  hintText: 'Search countrymen games by player',
                  onChanged: (v) {
                    debounceTimer.value?.cancel();
                    debounceTimer.value = Timer(
                      const Duration(milliseconds: 300),
                      () {
                        final notifier = ref.read(
                          countrymenCombinedGamesProvider.notifier,
                        );
                        if (v.trim().isEmpty) {
                          notifier.clearSearch();
                        } else {
                          notifier.searchGames(v);
                        }
                      },
                    );
                  },
                  onClear: () {
                    debounceTimer.value?.cancel();
                    ref
                        .read(countrymenCombinedGamesProvider.notifier)
                        .clearSearch();
                  },
                ),
              ),
              const SizedBox(width: 12),
              DesktopGameFilterButton(
                filter: state.filter,
                onPress: () async {
                  final result = await showDesktopGameFilterDialog(
                    context: context,
                    currentFilter: state.filter,
                    showFormatFilter: false,
                  );
                  if (result == null || !context.mounted) return;
                  ref
                      .read(countrymenCombinedGamesProvider.notifier)
                      .applyFilter(result);
                },
              ),
              const SizedBox(width: 12),
              const GameViewModeToggle(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              state.isLoading && state.games.isEmpty
                  ? const _Loading(key: ValueKey('loading'))
                  : state.error != null
                  ? _Error(key: const ValueKey('error'), message: state.error!)
                  : state.games.isEmpty
                  ? const _Empty(key: ValueKey('empty'))
                  : games.isEmpty &&
                      (state.filter.hasActiveFilters || state.liveOnly)
                  ? _PaneStateMessage(
                    key: const ValueKey('filters-empty'),
                    icon: Icons.filter_alt_off_outlined,
                    title:
                        state.liveOnly && !state.filter.hasActiveFilters
                            ? 'No live games right now'
                            : 'No games match your filters',
                    message:
                        state.liveOnly && !state.filter.hasActiveFilters
                            ? 'Switch to Total to see finished games.'
                            : 'Clear or relax the active filters.',
                    action: ClearDesktopGameFiltersButton(
                      onPress:
                          () =>
                              ref
                                  .read(
                                    countrymenCombinedGamesProvider.notifier,
                                  )
                                  .clearFilter(),
                    ),
                  )
                  : _CountrymenGames(
                    key: const ValueKey('list'),
                    games: games,
                    routeTitle:
                        (state.countryName?.trim().isNotEmpty ?? false)
                            ? '${state.countryName!.trim()} games'
                            : 'Countrymen games',
                    hasMore: state.hasMore,
                    isLoading: state.isLoading,
                    onLoadMore: () {
                      final notifier = ref.read(
                        countrymenCombinedGamesProvider.notifier,
                      );
                      if (state.isSearching) {
                        notifier.loadMoreSearchResults();
                      } else {
                        notifier.loadMoreGames();
                      }
                    },
                  ),
        ),
      ],
    );
  }
}

class _CountrymenEventsView extends HookConsumerWidget {
  const _CountrymenEventsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countrymenEventsProvider);
    final searchController = useTextEditingController(text: state.searchQuery);
    final debounceTimer = useRef<Timer?>(null);

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: DesktopSearchField(
            controller: searchController,
            hintText: 'Search events in this country',
            onChanged: (value) {
              debounceTimer.value?.cancel();
              debounceTimer.value = Timer(
                const Duration(milliseconds: 350),
                () {
                  ref.read(countrymenEventsProvider.notifier).search(value);
                },
              );
            },
            onClear: () {
              debounceTimer.value?.cancel();
              ref.read(countrymenEventsProvider.notifier).clearSearch();
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              state.isLoading && state.events.isEmpty
                  ? const _Loading()
                  : state.error != null && state.events.isEmpty
                  ? _PaneStateMessage(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load events',
                    message: state.error!,
                    error: true,
                  )
                  : state.events.isEmpty
                  ? _PaneStateMessage(
                    icon:
                        state.isSearching
                            ? Icons.search_off_rounded
                            : Icons.event_busy_outlined,
                    title:
                        state.isSearching
                            ? 'No events match your search'
                            : 'No country events found',
                    message:
                        state.isSearching
                            ? 'Try another event name.'
                            : 'Pick another country or check back later.',
                  )
                  : _CountrymenEventsList(state: state),
        ),
      ],
    );
  }
}

class _CountrymenEventsList extends ConsumerStatefulWidget {
  const _CountrymenEventsList({required this.state});

  final CountrymenEventsState state;

  @override
  ConsumerState<_CountrymenEventsList> createState() =>
      _CountrymenEventsListState();
}

class _CountrymenEventsListState extends ConsumerState<_CountrymenEventsList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (widget.state.isLoading ||
        !widget.state.hasMore ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 360) {
      ref.read(countrymenEventsProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveEventIds =
        ref.watch(liveGroupBroadcastIdsProvider).valueOrNull ??
        const <String>[];
    final events = widget.state.events;
    return ListKeyboardScrollFocus(
      controller: _scrollController,
      step: 80,
      child: ListView.builder(
        controller: _scrollController,
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: events.length + (widget.state.isLoading ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= events.length) return const _InlineLoader();
          final card = GroupEventCardModel.fromGroupBroadcast(
            events[i],
            liveEventIds,
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CountryEventTile(event: card),
          );
        },
      ),
    );
  }
}

class _CountryEventTile extends ConsumerStatefulWidget {
  const _CountryEventTile({required this.event});

  final GroupEventCardModel event;

  @override
  ConsumerState<_CountryEventTile> createState() => _CountryEventTileState();
}

class _CountryEventTileState extends ConsumerState<_CountryEventTile> {
  bool _hovered = false;

  void _open() {
    setActiveTournament(ref, widget.event);
  }

  Future<void> _toggleFavorite() async {
    final event = widget.event;
    await ref
        .read(favoriteEventsProvider.notifier)
        .toggleFavorite(
          eventId: event.id,
          eventName: event.title,
          timeControl: event.timeControl,
          maxAvgElo: event.maxAvgElo > 0 ? event.maxAvgElo : null,
          dates: event.dates.isNotEmpty ? event.dates : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final live = event.tourEventCategory == TourEventCategory.live;
    final isStarred = ref.watch(isEventFavoritedProvider(event.id));
    final favoritePlayers =
        isStarred
            ? const EventFavoritePlayers.empty()
            : ref.watch(eventFavoritePlayersProvider(event.id)).valueOrNull ??
                const EventFavoritePlayers.empty();

    return DesktopEventContextMenu(
      event: event,
      onOpen: _open,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: MotionCard(
              borderRadius: 9,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _hovered ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color:
                        _hovered
                            ? kPrimaryColor.withValues(alpha: 0.32)
                            : kDividerColor,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: kBlack3Color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kDividerColor),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        live
                            ? Icons.radio_button_checked_rounded
                            : Icons.emoji_events_outlined,
                        color: live ? kGreenColor : kPrimaryColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _MiniChip(
                                icon:
                                    live
                                        ? Icons.circle
                                        : Icons.calendar_today_rounded,
                                label: live ? 'Live' : event.dates,
                                color: live ? kGreenColor : kWhiteColor70,
                              ),
                              if (event.timeControl.isNotEmpty)
                                _MiniChip(
                                  icon: Icons.timer_outlined,
                                  label: event.timeControl,
                                ),
                              if (event.maxAvgElo > 0)
                                _MiniChip(
                                  icon: Icons.equalizer_rounded,
                                  label: 'Ø ${event.maxAvgElo}',
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (!isStarred && favoritePlayers.hasFavorites) ...[
                      _FavoritePlayersHeart(count: favoritePlayers.count),
                      const SizedBox(width: 8),
                    ],
                    _FavoriteStarButton(
                      active: isStarred,
                      onTap: () => unawaited(_toggleFavorite()),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: kLightGreyColor,
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

class _CountrymenPlayersView extends HookConsumerWidget {
  const _CountrymenPlayersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countrymenPlayersProvider);
    final favorites = ref.watch(favoritePlayersNotifierProvider);
    final favoriteIds =
        favorites.valueOrNull?.players
            .map((p) => p.fideId)
            .whereType<int>()
            .toSet() ??
        <int>{};
    final favoriteNames =
        favorites.valueOrNull?.players
            .map((p) => p.name.trim().toLowerCase())
            .toSet() ??
        <String>{};
    final searchController = useTextEditingController(text: state.searchQuery);
    final debounceTimer = useRef<Timer?>(null);

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: DesktopSearchField(
            controller: searchController,
            hintText: 'Search players in this country',
            onChanged: (value) {
              debounceTimer.value?.cancel();
              debounceTimer.value = Timer(
                const Duration(milliseconds: 350),
                () {
                  ref.read(countrymenPlayersProvider.notifier).search(value);
                },
              );
            },
            onClear: () {
              debounceTimer.value?.cancel();
              ref.read(countrymenPlayersProvider.notifier).clearSearch();
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              state.isLoading && state.players.isEmpty
                  ? const _Loading()
                  : state.error != null && state.players.isEmpty
                  ? _PaneStateMessage(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load players',
                    message: state.error!,
                    error: true,
                  )
                  : state.players.isEmpty
                  ? _PaneStateMessage(
                    icon:
                        state.isSearching
                            ? Icons.search_off_rounded
                            : Icons.group_off_outlined,
                    title:
                        state.isSearching
                            ? 'No players match your search'
                            : 'No country players found',
                    message:
                        state.isSearching
                            ? 'Try another player name.'
                            : 'Pick another country or check back later.',
                  )
                  : _CountrymenPlayersList(
                    state: state,
                    favoriteIds: favoriteIds,
                    favoriteNames: favoriteNames,
                  ),
        ),
      ],
    );
  }
}

class _CountrymenPlayersList extends ConsumerStatefulWidget {
  const _CountrymenPlayersList({
    required this.state,
    required this.favoriteIds,
    required this.favoriteNames,
  });

  final CountrymenPlayersState state;
  final Set<int> favoriteIds;
  final Set<String> favoriteNames;

  @override
  ConsumerState<_CountrymenPlayersList> createState() =>
      _CountrymenPlayersListState();
}

class _CountrymenPlayersListState
    extends ConsumerState<_CountrymenPlayersList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (widget.state.isLoading ||
        !widget.state.hasMore ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 360) {
      ref.read(countrymenPlayersProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final players = widget.state.players;
    return ListKeyboardScrollFocus(
      controller: _scrollController,
      step: 72,
      child: ListView.builder(
        controller: _scrollController,
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: players.length + (widget.state.isLoading ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= players.length) return const _InlineLoader();
          final player = players[i];
          final favorite =
              (player.fideId != null &&
                  widget.favoriteIds.contains(player.fideId)) ||
              widget.favoriteNames.contains(player.name.trim().toLowerCase());
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CountryPlayerTile(
              player: player,
              isFavorite: favorite,
              onFavoriteTap: () async {
                await ref
                    .read(favoritePlayersNotifierProvider.notifier)
                    .toggleFavorite(player);
                ref.invalidate(favoritePlayersProviderNew);
              },
            ),
          );
        },
      ),
    );
  }
}

enum _PlayerContextAction { profile, scoreCard, favorite }

class _CountryPlayerTile extends ConsumerStatefulWidget {
  const _CountryPlayerTile({
    required this.player,
    required this.isFavorite,
    required this.onFavoriteTap,
  });

  final PlayerStandingModel player;
  final bool isFavorite;
  final FutureOr<void> Function() onFavoriteTap;

  @override
  ConsumerState<_CountryPlayerTile> createState() => _CountryPlayerTileState();
}

class _CountryPlayerTileState extends ConsumerState<_CountryPlayerTile> {
  bool _hovered = false;

  void _open() {
    _openProfile();
  }

  void _openProfile() {
    final p = widget.player;
    openPlayerProfile(
      ref,
      PlayerProfileArgs(
        playerName: p.name,
        fideId: p.fideId,
        title: p.title,
        federation: p.countryCode.trim().isEmpty ? null : p.countryCode.trim(),
        rating: p.score > 0 ? p.score : null,
        gamebasePlayerId: p.gamebasePlayerId,
      ),
    );
  }

  void _openScoreCard() {
    openPlayerScoreCard(ref, widget.player, fromTournamentContext: false);
  }

  Future<void> _showContextMenu(Offset position) async {
    final picked = await showDesktopContextMenu<_PlayerContextAction>(
      context: context,
      position: position,
      width: 238,
      entries: [
        const DesktopContextMenuItem(
          value: _PlayerContextAction.profile,
          icon: Icons.person_outline_rounded,
          label: 'Open profile',
        ),
        const DesktopContextMenuItem(
          value: _PlayerContextAction.scoreCard,
          icon: Icons.badge_outlined,
          label: 'Open score card',
        ),
        const DesktopContextMenuDivider(),
        DesktopContextMenuItem(
          value: _PlayerContextAction.favorite,
          icon:
              widget.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
          label: widget.isFavorite ? 'Remove from favorites' : 'Add favorite',
          destructive: widget.isFavorite,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case _PlayerContextAction.profile:
        _openProfile();
      case _PlayerContextAction.scoreCard:
        _openScoreCard();
      case _PlayerContextAction.favorite:
        await widget.onFavoriteTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final fed = player.countryCode.trim();
    final hasFed = fed.isNotEmpty && fed.toUpperCase() != 'FID';
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          onSecondaryTapDown:
              (details) => unawaited(_showContextMenu(details.globalPosition)),
          child: MotionCard(
            borderRadius: 9,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : kBlack2Color,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.32)
                          : kDividerColor,
                ),
              ),
              child: Row(
                children: [
                  _CountryPlayerAvatar(player: player),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (player.title != null &&
                                player.title!.isNotEmpty) ...[
                              _TitleBadge(title: player.title!),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                player.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (hasFed)
                              _MiniChip(flag: fed, label: fed.toUpperCase()),
                            if (player.score > 0)
                              _MiniChip(
                                icon: Icons.equalizer_rounded,
                                label: player.score.toString(),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _FavoriteStarButton(
                    active: widget.isFavorite,
                    onTap: () => widget.onFavoriteTap(),
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

class _CountryPlayerAvatar extends StatelessWidget {
  const _CountryPlayerAvatar({required this.player});

  final PlayerStandingModel player;

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    final fed = player.countryCode.trim();
    final hasFed = fed.isNotEmpty && fed.toUpperCase() != 'FID';
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: FutureBuilder<String?>(
              future: FidePhotoService.getPhotoUrlOrNull(
                player.fideId?.toString(),
              ),
              builder: (context, snap) {
                return PlayerInitialsAvatar(
                  photoUrl: snap.data,
                  initials: _initials(player.name),
                  size: size,
                  borderRadius: 10,
                );
              },
            ),
          ),
          if (hasFed)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: FederationFlag(
                  federation: fed,
                  width: 18,
                  height: 12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FavoriteStarButton extends StatefulWidget {
  const _FavoriteStarButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_FavoriteStarButton> createState() => _FavoriteStarButtonState();
}

class _FavoriteStarButtonState extends State<_FavoriteStarButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
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
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.85 : (_hovered ? 1.1 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.arrival,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                widget.active
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 18,
                color: widget.active ? kPrimaryColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoritePlayersHeart extends StatelessWidget {
  const _FavoritePlayersHeart({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: kRedColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kRedColor.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite_rounded, color: kRedColor, size: 13),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: const TextStyle(
              color: kRedColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.label,
    this.icon,
    this.flag,
    this.color = kWhiteColor70,
  });

  final String label;
  final IconData? icon;
  final String? flag;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (flag != null) ...[
            FederationFlag(
              federation: flag!,
              width: 14,
              height: 10,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBadge extends StatelessWidget {
  const _TitleBadge({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: getTitleBadgeColor(title),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.split(',');
  if (parts.length > 1) {
    final last = parts[0].trim();
    final first = parts[1].trim();
    return '${last.isNotEmpty ? last[0] : ''}'
            '${first.isNotEmpty ? first[0] : ''}'
        .toUpperCase();
  }
  final words = name.trim().split(RegExp(r'\s+'));
  return words
      .take(2)
      .map((w) => w.isNotEmpty ? w[0] : '')
      .join()
      .toUpperCase();
}

class _InlineLoader extends StatelessWidget {
  const _InlineLoader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
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
    );
  }
}

class _PaneStateMessage extends StatelessWidget {
  const _PaneStateMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final accent = error ? kRedColor : kPrimaryColor;
    return Center(
      child: Cue.onMount(
        motion: const CueMotion.smooth(),
        acts: const [Act.fadeIn(), Act.slideY(from: 0.16)],
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: 0.28)),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 26, color: accent),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero header. Pairs a generously sized country flag with the country
/// name and a row of stat chips (live / total) so the pane finally has a
/// visual centre instead of a wall of text.
class _CountrymenHero extends StatelessWidget {
  const _CountrymenHero({
    required this.countryName,
    required this.countryCode,
    required this.totalCount,
    required this.liveCount,
    required this.liveOnly,
    required this.onSelectLive,
    required this.onSelectTotal,
    required this.hasTemporaryCountry,
    required this.onChangeCountry,
    required this.onPinCountry,
  });

  final String? countryName;
  final String? countryCode;
  final int totalCount;
  final int liveCount;
  final bool liveOnly;
  final VoidCallback onSelectLive;
  final VoidCallback onSelectTotal;
  final bool hasTemporaryCountry;
  final VoidCallback onChangeCountry;
  final VoidCallback? onPinCountry;

  @override
  Widget build(BuildContext context) {
    final hasCountry = countryName != null && countryName!.isNotEmpty;
    final code = countryCode == null ? '' : countryCode!.toUpperCase();
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Big flag — entrance pop with cue, hover-tilt with cue + motor
          // spring tucked into the FlagBadge widget.
          Cue.onMount(
            motion: const CueMotion.bouncy(),
            acts: [
              const Act.fadeIn(),
              const Act.scale(from: 0.82),
              const Act.slideY(from: 0.18),
            ],
            child: _FlagBadge(countryCode: code, hasCountry: hasCountry),
          ),
          const SizedBox(width: 16),
          Expanded(
            // Title + subtitle slide in from the leading edge a beat later
            // so the flag lands first and the text follows it in.
            child: Cue.onMount(
              motion: const CueMotion.spatial(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Actor(
                    delay: const Duration(milliseconds: 80),
                    acts: [const Act.fadeIn(), const Act.slideX(from: -0.12)],
                    child: Text(
                      hasCountry ? countryName! : 'Set country in Settings',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        height: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Actor(
                    delay: const Duration(milliseconds: 140),
                    acts: [const Act.fadeIn(), const Act.slideX(from: -0.12)],
                    child: Row(
                      children: [
                        const Icon(
                          Icons.public_outlined,
                          color: kLightGreyColor,
                          size: 13,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          hasCountry
                              ? code.isEmpty
                                  ? 'Live games from your countrymen'
                                  : 'Live games from your countrymen · $code'
                              : 'Pick a country in Settings → Account.',
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            letterSpacing: 0.1,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DesktopHeroActionButton(
                label: 'Change country',
                icon: Icons.public_rounded,
                onPress: onChangeCountry,
                tooltip: 'Choose a country for this pane',
                tone: DesktopHeroActionTone.primary,
              ),
              if (hasTemporaryCountry) ...[
                const SizedBox(width: 8),
                DesktopHeroActionButton(
                  label: 'Make default',
                  icon: Icons.push_pin_outlined,
                  onPress: onPinCountry,
                  tooltip: 'Pin this country as your default',
                ),
              ],
            ],
          ),
          const SizedBox(width: 16),
          // Stats: live + total, right-aligned. Both pills toggle the
          // games-list filter; the active one shows a selected ring.
          _StatChip(
            label: 'Live',
            value: liveCount,
            tone: liveCount > 0 ? _StatTone.live : _StatTone.muted,
            delay: const Duration(milliseconds: 160),
            selected: liveOnly,
            onTap: onSelectLive,
            tooltip: 'Hide finished games',
          ),
          const SizedBox(width: 8),
          _StatChip(
            label: 'Total',
            value: totalCount,
            tone: _StatTone.neutral,
            delay: const Duration(milliseconds: 220),
            selected: !liveOnly,
            onTap: onSelectTotal,
            tooltip: 'Show all games (live + finished)',
          ),
        ],
      ),
    );
  }
}

/// Country flag plate sitting at the lead of the hero. On hover the plate
/// lifts a few pixels via a motor spring (`DesktopMotion.hover`). When no
/// country is set, renders a quiet outline with the world icon.
class _FlagBadge extends StatefulWidget {
  const _FlagBadge({required this.countryCode, required this.hasCountry});
  final String countryCode;
  final bool hasCountry;

  @override
  State<_FlagBadge> createState() => _FlagBadgeState();
}

class _FlagBadgeState extends State<_FlagBadge> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const w = 96.0;
    const h = 64.0;
    final lift = _hovered ? -2.0 : 0.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SingleMotionBuilder(
        value: lift,
        motion: DesktopMotion.hover,
        builder:
            (context, y, child) =>
                Transform.translate(offset: Offset(0, y), child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  _hovered
                      ? kPrimaryColor.withValues(alpha: 0.5)
                      : kDividerColor,
            ),
            boxShadow:
                _hovered
                    ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                    : const [],
          ),
          alignment: Alignment.center,
          child:
              widget.hasCountry && widget.countryCode.isNotEmpty
                  ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: w - 14,
                      height: h - 14,
                      child: FederationFlag(
                        federation: widget.countryCode,
                        width: w - 14,
                        height: h - 14,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  )
                  : const Icon(
                    Icons.public_outlined,
                    color: kLightGreyColor,
                    size: 28,
                  ),
        ),
      ),
    );
  }
}

enum _StatTone { live, neutral, muted }

/// Small pill that displays a label + count. The "Live" tone wakes the
/// border up with a primary-colour wash and pulses the count when it
/// changes (cue's `Cue.onChange` rebuilds the value text with a soft
/// scale + colour tint). When [onTap] is provided, the pill becomes
/// clickable and renders a hover lift + a thicker, brighter border in
/// the [selected] state.
class _StatChip extends StatefulWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.tone,
    required this.delay,
    this.selected = false,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final int value;
  final _StatTone tone;
  final Duration delay;
  final bool selected;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<_StatChip> createState() => _StatChipState();
}

class _StatChipState extends State<_StatChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final (baseBorder, fg, dot) = switch (widget.tone) {
      _StatTone.live => (
        kGreenColor.withValues(alpha: 0.5),
        kGreenColor,
        kGreenColor,
      ),
      _StatTone.neutral => (kDividerColor, kWhiteColor, kPrimaryColor),
      _StatTone.muted => (kDividerColor, kLightGreyColor, kLightGreyColor),
    };
    final accent = switch (widget.tone) {
      _StatTone.live => kGreenColor,
      _StatTone.neutral => kPrimaryColor,
      _StatTone.muted => kLightGreyColor,
    };
    final clickable = widget.onTap != null;
    final selected = widget.selected;
    final borderColor =
        selected
            ? accent
            : _hovered && clickable
            ? accent.withValues(alpha: 0.7)
            : baseBorder;
    final borderWidth = selected ? 1.6 : 1.0;
    final bg =
        selected
            ? accent.withValues(alpha: 0.14)
            : _hovered && clickable
            ? kBlack2Color.withValues(alpha: 0.85)
            : kBlack2Color;

    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow:
            selected
                ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
                : const [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 8),
          Cue.onChange(
            value: widget.value,
            motion: const CueMotion.bouncy(),
            acts: [const Act.scale(from: 0.7), const Act.fadeIn(from: 0.4)],
            child: Text(
              '${widget.value}',
              key: ValueKey('chip-${widget.label}-${widget.value}'),
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );

    Widget content = pill;
    if (clickable) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            selected: selected,
            label: widget.tooltip ?? widget.label,
            child: pill,
          ),
        ),
      );
      if (widget.tooltip != null) {
        content = DesktopTooltip(message: widget.tooltip!, child: content);
      }
    }

    return Cue.onMount(
      motion: const CueMotion.spatial(),
      acts: [const Act.fadeIn(), const Act.slideY(from: 0.3)],
      child: Actor(
        delay: widget.delay,
        acts: const [Act.fadeIn(), Act.slideY(from: 0.3)],
        child: content,
      ),
    );
  }
}

/// Live games view. Each cell is a [LiveDesktopGameCard] (so PGN / FEN /
/// clocks / status all stream from Supabase Realtime, and white/black
/// names already render with their federation flags) wrapped in a
/// staggered cue mount animation so items cascade in instead of dumping
/// all at once. Reads the persisted layout out of the global game-card
/// view-mode provider so the toolbar toggle here drives the same record
/// the Library and Tournaments toggles do.
class _CountrymenGames extends ConsumerStatefulWidget {
  const _CountrymenGames({
    super.key,
    required this.games,
    required this.routeTitle,
    required this.hasMore,
    required this.isLoading,
    required this.onLoadMore,
  });

  final List<GamesTourModel> games;
  final String routeTitle;
  final bool hasMore;
  final bool isLoading;
  final VoidCallback onLoadMore;

  @override
  ConsumerState<_CountrymenGames> createState() => _CountrymenGamesState();
}

class _CountrymenGamesState extends ConsumerState<_CountrymenGames> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!widget.hasMore || widget.isLoading || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 420) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(gamesListViewModeProvider).desktopLayout;
    final groups = buildDesktopGameDateGroups(widget.games);
    if (layout == DesktopCardLayout.grid) {
      // Compute column count first so PageUp/PageDown can stride by a full
      // page (~3 rows of `columns` cards). The previous `pageStride: 9`
      // was hardcoded to an assumed 3×3 grid.
      return LayoutBuilder(
        builder: (context, constraints) {
          const targetWidth = 280.0;
          final columns = (constraints.maxWidth / targetWidth)
              .floor()
              .clamp(2, 6);
          return DesktopGameKeyboardFocus(
            scopeId: 'countrymen-games',
            games: widget.games,
            pageStride: columns * 3,
            onActivateGame:
                (game) => _openCountrymenGame(
                  ref,
                  game,
                  widget.routeTitle,
                  widget.games,
                ),
            builder: (context, selectedGameId, selectGame, keyForGame) {
              return CustomScrollView(
                  controller: _scrollController,
                  physics: const DesktopScrollPhysics(),
                  slivers: [
                    for (
                      var groupIndex = 0;
                      groupIndex < groups.length;
                      groupIndex++
                    ) ...[
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          groupIndex == 0 ? 4 : 16,
                          24,
                          8,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: DesktopDateGroupCard(
                            label: groups[groupIndex].label,
                            gameCount: groups[groupIndex].games.length,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 0.95,
                              ),
                          delegate: SliverChildBuilderDelegate((context, i) {
                            final flatIndex =
                                groups
                                    .take(groupIndex)
                                    .fold<int>(
                                      0,
                                      (sum, group) => sum + group.games.length,
                                    ) +
                                i;
                            final delay = Duration(
                              milliseconds: (flatIndex.clamp(0, 12)) * 32,
                            );
                            final game = groups[groupIndex].games[i];
                            return DesktopGameKeyboardItem(
                              itemKey: keyForGame(game.gameId),
                              gameId: game.gameId,
                              onSelect: selectGame,
                              child: Cue.onMount(
                                motion: const CueMotion.smooth(),
                                child: Actor(
                                  delay: delay,
                                  acts: const [
                                    Act.fadeIn(),
                                    Act.slideY(from: 0.18),
                                    Act.scale(from: 0.985),
                                  ],
                                  child: LiveDesktopGameCard(
                                    game: game,
                                    tournamentTitle:
                                        game.tourSlug ?? 'Countrymen',
                                    routeTitle: widget.routeTitle,
                                    routeGames: widget.games,
                                    routeGamesContinuation:
                                        const BoardTabGamesContinuation.countrymen(),
                                    layout: DesktopCardLayout.grid,
                                    selected: selectedGameId == game.gameId,
                                    viewSource: ChessboardView.countryman,
                                  ),
                                ),
                              ),
                            );
                          }, childCount: groups[groupIndex].games.length),
                        ),
                      ),
                    ],
                    if (widget.isLoading)
                      const SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        sliver: SliverToBoxAdapter(child: _InlineLoader()),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                );
              },
            );
          },
        );
    }
    return DesktopGameKeyboardFocus(
      scopeId: 'countrymen-games',
      games: widget.games,
      onActivateGame:
          (game) =>
              _openCountrymenGame(ref, game, widget.routeTitle, widget.games),
      builder: (context, selectedGameId, selectGame, keyForGame) {
        return CustomScrollView(
          controller: _scrollController,
          physics: const DesktopScrollPhysics(),
          slivers: [
            for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  groupIndex == 0 ? 4 : 16,
                  24,
                  8,
                ),
                sliver: SliverToBoxAdapter(
                  child: DesktopDateGroupCard(
                    label: groups[groupIndex].label,
                    gameCount: groups[groupIndex].games.length,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverToBoxAdapter(
                  child: DesktopGameCardsFlow(
                    layout: layout,
                    embedded: true,
                    itemCount: groups[groupIndex].games.length,
                    itemBuilder: (context, i) {
                      final flatIndex =
                          groups
                              .take(groupIndex)
                              .fold<int>(
                                0,
                                (sum, group) => sum + group.games.length,
                              ) +
                          i;
                      final delay = Duration(
                        milliseconds: (flatIndex.clamp(0, 12)) * 32,
                      );
                      final game = groups[groupIndex].games[i];
                      return DesktopGameKeyboardItem(
                        itemKey: keyForGame(game.gameId),
                        gameId: game.gameId,
                        onSelect: selectGame,
                        child: Cue.onMount(
                          motion: const CueMotion.smooth(),
                          child: Actor(
                            delay: delay,
                            acts: const [
                              Act.fadeIn(),
                              Act.slideY(from: 0.18),
                              Act.scale(from: 0.985),
                            ],
                            child: LiveDesktopGameCard(
                              game: game,
                              tournamentTitle: game.tourSlug ?? 'Countrymen',
                              routeTitle: widget.routeTitle,
                              routeGames: widget.games,
                              routeGamesContinuation:
                                  const BoardTabGamesContinuation.countrymen(),
                              layout: layout,
                              selected: selectedGameId == game.gameId,
                              viewSource: ChessboardView.countryman,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
            if (widget.isLoading)
              const SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverToBoxAdapter(child: _InlineLoader()),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

void _openCountrymenGame(
  WidgetRef ref,
  GamesTourModel game,
  String routeTitle,
  List<GamesTourModel> routeGames,
) {
  openTournamentGameTab(
    ref,
    game,
    game.tourSlug ?? 'Countrymen',
    routeTitle: routeTitle,
    routeGames: routeGames,
    routeGamesContinuation: const BoardTabGamesContinuation.countrymen(),
    viewSource: ChessboardView.countryman,
  );
}

class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Cue.onMount(
        motion: const CueMotion.smooth(),
        acts: const [Act.fadeIn(), Act.scale(from: 0.9)],
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Cue.onMount(
        motion: const CueMotion.smooth(),
        acts: const [Act.fadeIn(), Act.slideY(from: 0.2)],
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: kRedColor, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Cue.onMount(
        motion: const CueMotion.spatial(),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Actor(
                acts: const [Act.fadeIn(), Act.scale(from: 0.7)],
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kDividerColor),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.public_off_outlined,
                    size: 26,
                    color: kLightGreyColor,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Actor(
                delay: const Duration(milliseconds: 100),
                acts: const [Act.fadeIn(), Act.slideY(from: 0.18)],
                child: const Text(
                  'No games for your country right now',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Actor(
                delay: const Duration(milliseconds: 160),
                acts: const [Act.fadeIn(), Act.slideY(from: 0.18)],
                child: const Text(
                  'Set a country in Settings → Account.',
                  style: TextStyle(color: kLightGreyColor, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
