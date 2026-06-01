import 'dart:async';

import 'package:country_flags/country_flags.dart';
import 'package:cue/cue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/favorites/favorite_players_provider.dart';
import 'package:chessever/screens/favorites/player_games/provider/favorites_combined_games_provider.dart';
import 'package:chessever/screens/favorites/provider/favorites_mode_provider.dart';
import 'package:chessever/screens/favorites/tabs/favorites_players_tab.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

/// Favorites pane built on the same Supabase-backed providers the mobile
/// Favorites entry uses.
///
/// The desktop presentation keeps the mobile tab contract — Favorites,
/// Games, Players — but adapts each surface for desktop scanning. The
/// Favorites tab keeps the two-column event/player overview, Games uses
/// live desktop cards, and Players exposes the global player search.
///
/// Motion is sourced exclusively from [DesktopMotion] / [DesktopSprings]:
/// `PressableScale` springs handle hover/press feedback, count chips spring
/// when the underlying list changes, and tile entry uses a stagger so the
/// content lands in waves rather than as a single block.
class FavoritesPane extends HookConsumerWidget {
  const FavoritesPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedMode = ref.watch(selectedFavoritesModeProvider);

    return Container(
      color: kBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.favorite_rounded, size: 18, color: kRedColor),
              const SizedBox(width: 10),
              const Text(
                'Favorites',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const Spacer(),
              DesktopSegmentedTabs<FavoritesScreenMode>(
                selected: selectedMode,
                onChanged: (mode) {
                  ref
                      .read(selectedFavoritesModeProvider.notifier)
                      .update((_) => mode);
                },
                tabs: const [
                  DesktopSegmentedTab(
                    value: FavoritesScreenMode.favorites,
                    label: 'Favorites',
                    icon: Icons.favorite_rounded,
                  ),
                  DesktopSegmentedTab(
                    value: FavoritesScreenMode.games,
                    label: 'Games',
                    icon: Icons.grid_4x4_outlined,
                  ),
                  DesktopSegmentedTab(
                    value: FavoritesScreenMode.players,
                    label: 'Players',
                    icon: Icons.person_search_rounded,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: switch (selectedMode) {
                FavoritesScreenMode.favorites => const _FavoritePlayersListTab(
                  key: ValueKey('favorite-players'),
                ),
                FavoritesScreenMode.games => const _FavoritesGamesTab(
                  key: ValueKey('games'),
                ),
                FavoritesScreenMode.players => const _WorldPlayersTab(
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

/// First tab inside the Favorites pane — a flat list of favourited players.
///
/// Earlier this tab carried favourited events; that view never matched the
/// way the user actually scans favourites (they reach for *who* they're
/// following, not *what* tournament). Events stay reachable from the
/// Tournaments pane's star; this surface is reserved for the player list
/// + one-tap heart unfavourite so the user can curate without leaving the
/// pane.
class _FavoritePlayersListTab extends HookConsumerWidget {
  const _FavoritePlayersListTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritePlayersNotifierProvider);
    final searchController = useTextEditingController();
    final query = useState<String>('');
    final q = query.value.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSearchField(
          controller: searchController,
          hintText: 'Filter favorited players',
          onChanged: (v) => query.value = v,
          onClear: () => query.value = '',
        ),
        const SizedBox(height: 12),
        Expanded(
          child: favoritesAsync.when(
            loading: () => const _PaneLoading(),
            error:
                (e, _) => _PaneMessage(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load favorite players',
                  message: '$e',
                  tone: _PaneMessageTone.error,
                ),
            data: (state) {
              final players =
                  q.isEmpty
                      ? state.players
                      : state.players
                          .where((p) => p.name.toLowerCase().contains(q))
                          .toList(growable: false);
              if (players.isEmpty) {
                return _PaneMessage(
                  icon:
                      q.isEmpty
                          ? Icons.person_add_alt_rounded
                          : Icons.search_off_rounded,
                  title:
                      q.isEmpty
                          ? 'No favorite players yet'
                          : 'No players match your filter',
                  message:
                      q.isEmpty
                          ? 'Tap the heart on any player to follow them.'
                          : 'Try another name.',
                );
              }
              return _FavoritePlayersList(players: players);
            },
          ),
        ),
      ],
    );
  }
}

class _FavoritePlayersList extends StatelessWidget {
  const _FavoritePlayersList({required this.players});

  final List<PlayerStandingModel> players;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: players.length,
      itemBuilder: (context, i) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _PlayerTile(player: players[i], isFavorite: true),
        );
      },
    );
  }
}

class _FavoritesGamesTab extends HookConsumerWidget {
  const _FavoritesGamesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(favoritesCombinedGamesProvider);
    final favoritePlayersAsync = ref.watch(favoritePlayersNotifierProvider);
    final favoritePlayers = favoritePlayersAsync.valueOrNull?.players ?? [];
    final searchController = useTextEditingController(text: state.searchQuery);
    final debounceTimer = useRef<Timer?>(null);

    ref.listen(favoritePlayersNotifierProvider, (prev, next) {
      final prevCount = prev?.valueOrNull?.players.length ?? 0;
      final nextCount = next.valueOrNull?.players.length ?? 0;
      if (prevCount != nextCount) {
        Future.microtask(
          () =>
              ref.read(favoritesCombinedGamesProvider.notifier).refreshGames(),
        );
      }
    });

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    final games = state.filteredGames;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DesktopSearchField(
                controller: searchController,
                hintText: 'Search favorite games by player',
                onChanged: (value) {
                  debounceTimer.value?.cancel();
                  debounceTimer.value = Timer(
                    const Duration(milliseconds: 300),
                    () {
                      final notifier = ref.read(
                        favoritesCombinedGamesProvider.notifier,
                      );
                      if (value.trim().isEmpty) {
                        notifier.clearSearch();
                      } else {
                        notifier.searchGames(value);
                      }
                    },
                  );
                },
                onClear: () {
                  debounceTimer.value?.cancel();
                  ref
                      .read(favoritesCombinedGamesProvider.notifier)
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
                    .read(favoritesCombinedGamesProvider.notifier)
                    .applyFilter(result);
              },
            ),
            const SizedBox(width: 12),
            const GameViewModeToggle(),
          ],
        ),
        if (favoritePlayers.length > 1 && !state.isSearching) ...[
          const SizedBox(height: 10),
          _FavoritePlayerFilterStrip(
            players: favoritePlayers,
            selectedFideIds: state.selectedFideIds,
            onToggle:
                (fideId) => ref
                    .read(favoritesCombinedGamesProvider.notifier)
                    .togglePlayerFilter(fideId),
            onClear:
                () =>
                    ref
                        .read(favoritesCombinedGamesProvider.notifier)
                        .clearPlayerFilters(),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child:
                state.isLoading && state.games.isEmpty
                    ? const _PaneLoading(key: ValueKey('loading'))
                    : state.error != null && state.games.isEmpty
                    ? _PaneMessage(
                      key: const ValueKey('error'),
                      icon: Icons.error_outline_rounded,
                      title: 'Could not load favorite games',
                      message: state.error!,
                      tone: _PaneMessageTone.error,
                    )
                    : games.isEmpty
                    ? _PaneMessage(
                      key: const ValueKey('empty'),
                      icon:
                          state.filter.hasActiveFilters
                              ? Icons.filter_alt_off_outlined
                              : state.isSearching
                              ? Icons.search_off_rounded
                              : Icons.grid_4x4_outlined,
                      title:
                          state.filter.hasActiveFilters
                              ? 'No games match your filters'
                              : state.isSearching
                              ? 'No games match your search'
                              : 'No favorite games yet',
                      message:
                          state.filter.hasActiveFilters
                              ? 'Clear or relax the active filters.'
                              : state.isSearching
                              ? 'Try another player name.'
                              : 'Add favorite players to build this feed.',
                      action:
                          state.filter.hasActiveFilters
                              ? ClearDesktopGameFiltersButton(
                                onPress:
                                    () =>
                                        ref
                                            .read(
                                              favoritesCombinedGamesProvider
                                                  .notifier,
                                            )
                                            .clearFilter(),
                              )
                              : null,
                    )
                    : _FavoritesGamesList(
                      key: const ValueKey('list'),
                      games: games,
                      hasMore: state.hasMore,
                      isLoading: state.isLoading,
                      onLoadMore: () {
                        final notifier = ref.read(
                          favoritesCombinedGamesProvider.notifier,
                        );
                        if (state.isSearching) {
                          notifier.loadMoreSearchResults();
                        } else {
                          notifier.loadMoreGames();
                        }
                      },
                    ),
          ),
        ),
      ],
    );
  }
}

class _FavoritesGamesList extends ConsumerStatefulWidget {
  const _FavoritesGamesList({
    super.key,
    required this.games,
    required this.hasMore,
    required this.isLoading,
    required this.onLoadMore,
  });

  final List<GamesTourModel> games;
  final bool hasMore;
  final bool isLoading;
  final VoidCallback onLoadMore;

  @override
  ConsumerState<_FavoritesGamesList> createState() =>
      _FavoritesGamesListState();
}

class _FavoritesGamesListState extends ConsumerState<_FavoritesGamesList> {
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
      // page (~3 rows of `columns` cards) — `pageStride: 9` was hardcoded to
      // an assumed 3×3 grid and broke on every other window width.
      return LayoutBuilder(
        builder: (context, constraints) {
          const targetWidth = 280.0;
          final columns = (constraints.maxWidth / targetWidth)
              .floor()
              .clamp(2, 6);
          return DesktopGameKeyboardFocus(
            scopeId: 'favorites-games',
            games: widget.games,
            pageStride: columns * 3,
            onActivateGame:
                (game) => _openFavoriteGame(ref, game, widget.games),
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
                      padding: EdgeInsets.only(
                        top: groupIndex == 0 ? 0 : 16,
                        bottom: 8,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: DesktopDateGroupCard(
                          label: groups[groupIndex].label,
                          gameCount: groups[groupIndex].games.length,
                        ),
                      ),
                    ),
                    SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 0.95,
                      ),
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final game = groups[groupIndex].games[i];
                        return DesktopGameKeyboardItem(
                          itemKey: keyForGame(game.gameId),
                          gameId: game.gameId,
                          onSelect: selectGame,
                          child: _FavoriteLiveGameCard(
                            game: game,
                            layout: DesktopCardLayout.grid,
                            allGames: widget.games,
                            selected: selectedGameId == game.gameId,
                          ),
                        );
                      }, childCount: groups[groupIndex].games.length),
                    ),
                  ],
                  if (widget.isLoading)
                    const SliverToBoxAdapter(child: _InlineLoader()),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              );
            },
          );
        },
      );
    }

    return DesktopGameKeyboardFocus(
      scopeId: 'favorites-games',
      games: widget.games,
      onActivateGame: (game) => _openFavoriteGame(ref, game, widget.games),
      builder: (context, selectedGameId, selectGame, keyForGame) {
        return CustomScrollView(
          controller: _scrollController,
          physics: const DesktopScrollPhysics(),
          slivers: [
            for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) ...[
              SliverPadding(
                padding: EdgeInsets.only(
                  top: groupIndex == 0 ? 0 : 16,
                  bottom: 8,
                ),
                sliver: SliverToBoxAdapter(
                  child: DesktopDateGroupCard(
                    label: groups[groupIndex].label,
                    gameCount: groups[groupIndex].games.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: DesktopGameCardsFlow(
                  layout: layout,
                  embedded: true,
                  itemCount: groups[groupIndex].games.length,
                  itemBuilder: (context, i) {
                    final game = groups[groupIndex].games[i];
                    return DesktopGameKeyboardItem(
                      itemKey: keyForGame(game.gameId),
                      gameId: game.gameId,
                      onSelect: selectGame,
                      child: _FavoriteLiveGameCard(
                        game: game,
                        layout: layout,
                        allGames: widget.games,
                        selected: selectedGameId == game.gameId,
                      ),
                    );
                  },
                ),
              ),
            ],
            if (widget.isLoading)
              const SliverToBoxAdapter(child: _InlineLoader()),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

void _openFavoriteGame(
  WidgetRef ref,
  GamesTourModel game,
  List<GamesTourModel> allGames,
) {
  openTournamentGameTab(
    ref,
    game,
    'Favorites',
    eventGames: allGames,
    eventGamesContinuation: const BoardTabGamesContinuation.favorites(),
    viewSource: ChessboardView.favScorecard,
  );
}

class _FavoriteLiveGameCard extends StatelessWidget {
  const _FavoriteLiveGameCard({
    required this.game,
    required this.layout,
    required this.allGames,
    this.selected = false,
  });

  final GamesTourModel game;
  final DesktopCardLayout layout;
  final bool selected;

  /// Full favorites feed at tap time — handed to [LiveDesktopGameCard] so
  /// the resulting board tab's left rail keeps the favorites context (day-
  /// grouped multi-tournament list) instead of resolving to the tapped
  /// game's single tournament.
  final List<GamesTourModel> allGames;

  @override
  Widget build(BuildContext context) {
    return Cue.onMount(
      motion: const CueMotion.smooth(),
      acts: const [Act.fadeIn(), Act.slideY(from: 0.12), Act.scale(from: 0.99)],
      child: LiveDesktopGameCard(
        game: game,
        tournamentTitle: 'Favorites',
        eventGames: allGames,
        eventGamesContinuation: const BoardTabGamesContinuation.favorites(),
        layout: layout,
        selected: selected,
        viewSource: ChessboardView.favScorecard,
      ),
    );
  }
}

class _FavoritePlayerFilterStrip extends StatelessWidget {
  const _FavoritePlayerFilterStrip({
    required this.players,
    required this.selectedFideIds,
    required this.onToggle,
    required this.onClear,
  });

  final List<PlayerStandingModel> players;
  final Set<String> selectedFideIds;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final filterable = players
        .where((p) => p.fideId != null)
        .toList(growable: false);
    if (filterable.length <= 1) return const SizedBox.shrink();

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const DesktopScrollPhysics(),
        itemCount: filterable.length + (selectedFideIds.isNotEmpty ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index >= filterable.length) {
            return _PlayerFilterChip(
              label: 'Clear',
              icon: Icons.close_rounded,
              selected: false,
              onTap: onClear,
            );
          }
          final player = filterable[index];
          final fideId = player.fideId!.toString();
          final selected = selectedFideIds.contains(fideId);
          return _PlayerFilterChip(
            label: _shortName(player.name),
            federation: player.countryCode,
            selected: selected,
            onTap: () => onToggle(fideId),
          );
        },
      ),
    );
  }
}

class _PlayerFilterChip extends StatefulWidget {
  const _PlayerFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.federation,
    this.icon,
  });

  final String label;
  final String? federation;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PlayerFilterChip> createState() => _PlayerFilterChipState();
}

class _PlayerFilterChipState extends State<_PlayerFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kRedColor.withValues(alpha: 0.88)
                      : _hovered
                      ? kBlack3Color
                      : kBlack2Color,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color:
                    selected
                        ? kRedColor
                        : _hovered
                        ? kPrimaryColor.withValues(alpha: 0.42)
                        : kDividerColor,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: kWhiteColor70, size: 13),
                  const SizedBox(width: 5),
                ] else if ((widget.federation ?? '').isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      width: 16,
                      height: 11,
                      child: CountryFlag.fromCountryCode(widget.federation!),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: selected ? kWhiteColor : kWhiteColor70,
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
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

class _WorldPlayersTab extends HookConsumerWidget {
  const _WorldPlayersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(worldPlayersSearchProvider);
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
        DesktopSearchField(
          controller: searchController,
          hintText: 'Search all players',
          onChanged: (value) {
            debounceTimer.value?.cancel();
            debounceTimer.value = Timer(const Duration(milliseconds: 350), () {
              ref.read(worldPlayersSearchProvider.notifier).search(value);
            });
          },
          onClear: () {
            debounceTimer.value?.cancel();
            ref.read(worldPlayersSearchProvider.notifier).clearSearch();
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              state.isLoading && state.players.isEmpty
                  ? const _PaneLoading()
                  : state.error != null && state.players.isEmpty
                  ? _PaneMessage(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load players',
                    message: state.error!,
                    tone: _PaneMessageTone.error,
                  )
                  : state.players.isEmpty
                  ? _PaneMessage(
                    icon:
                        state.isSearching
                            ? Icons.search_off_rounded
                            : Icons.person_search_rounded,
                    title:
                        state.isSearching
                            ? 'No players match your search'
                            : 'No players found',
                    message: 'Try another name or federation.',
                  )
                  : _WorldPlayersList(
                    state: state,
                    favoriteIds: favoriteIds,
                    favoriteNames: favoriteNames,
                  ),
        ),
      ],
    );
  }
}

class _WorldPlayersList extends ConsumerStatefulWidget {
  const _WorldPlayersList({
    required this.state,
    required this.favoriteIds,
    required this.favoriteNames,
  });

  final WorldPlayersSearchState state;
  final Set<int> favoriteIds;
  final Set<String> favoriteNames;

  @override
  ConsumerState<_WorldPlayersList> createState() => _WorldPlayersListState();
}

class _WorldPlayersListState extends ConsumerState<_WorldPlayersList> {
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
      ref.read(worldPlayersSearchProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final players = widget.state.players;
    return ListView.builder(
      controller: _scrollController,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
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
          child: _PlayerTile(
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
    );
  }
}

// =====================================================================
// Player tile — FIDE photo, country flag, title badge, name, rating
// =====================================================================

enum _PlayerContextAction { profile, scoreCard, favorite }

class _PlayerTile extends ConsumerStatefulWidget {
  const _PlayerTile({
    required this.player,
    this.isFavorite = true,
    this.onFavoriteTap,
  });

  final PlayerStandingModel player;
  final bool isFavorite;
  final FutureOr<void> Function()? onFavoriteTap;

  @override
  ConsumerState<_PlayerTile> createState() => _PlayerTileState();
}

class _PlayerTileState extends ConsumerState<_PlayerTile> {
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
        await _unfavorite();
    }
  }

  Future<void> _unfavorite() async {
    final custom = widget.onFavoriteTap;
    if (custom != null) {
      await custom();
      return;
    }
    await ref
        .read(favoritePlayersNotifierProvider.notifier)
        .removeFavorite(widget.player);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final fed = p.countryCode.trim();
    final hasFed = fed.isNotEmpty && fed.toUpperCase() != 'FID';
    final ratingText = p.score > 0 ? p.score.toString() : null;

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
            borderRadius: 10,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.35)
                          : kDividerColor,
                ),
                // hover/press shadow now owned by MotionCard
              ),
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _PlayerAvatar(player: p, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (p.title != null && p.title!.isNotEmpty) ...[
                              _TitlePill(title: p.title!),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (hasFed) ...[
                              _MetaChip(
                                leadingFlag: fed,
                                label: fed.toUpperCase(),
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (ratingText != null)
                              _MetaChip(
                                icon: Icons.equalizer_rounded,
                                label: ratingText,
                              ),
                            if (p.matchScore != null &&
                                p.matchScore!.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _MetaChip(
                                icon: Icons.scoreboard_outlined,
                                label: p.matchScore!,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StarToggle(
                    active: widget.isFavorite,
                    onTap: _unfavorite,
                    activeIcon: Icons.favorite_rounded,
                    inactiveIcon: Icons.favorite_border_rounded,
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

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({required this.player, required this.size});

  final PlayerStandingModel player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = _initials(player.name);
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
                  initials: initials,
                  size: size,
                  borderRadius: 10,
                  // Title badge is shown next to the name; suppress on the
                  // avatar itself so a 48px tile doesn't double-stamp the
                  // GM/IM glyph.
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    width: 18,
                    height: 12,
                    child: CountryFlag.fromCountryCode(fed),
                  ),
                ),
              ),
            ),
        ],
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

String _shortName(String fullName) {
  final parts = fullName.split(',');
  if (parts.length > 1 && parts.first.trim().isNotEmpty) {
    return parts.first.trim();
  }
  final words = fullName.trim().split(RegExp(r'\s+'));
  if (words.length > 1) return words.last;
  return fullName.length > 14 ? '${fullName.substring(0, 12)}...' : fullName;
}

// =====================================================================
// Shared bits: meta chip, title pill, star toggle, card chrome, empty
// =====================================================================

class _MetaChip extends StatelessWidget {
  const _MetaChip({this.icon, this.leadingFlag, required this.label});

  final IconData? icon;
  final String? leadingFlag;
  final String label;

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
          if (leadingFlag != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                width: 14,
                height: 10,
                child: CountryFlag.fromCountryCode(leadingFlag!),
              ),
            ),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: 11, color: kWhiteColor70),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.title});
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
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _StarToggle extends StatefulWidget {
  const _StarToggle({
    required this.active,
    required this.onTap,
    this.activeIcon = Icons.star_rounded,
    this.inactiveIcon = Icons.star_border_rounded,
  });
  final bool active;
  final VoidCallback onTap;
  final IconData activeIcon;
  final IconData inactiveIcon;

  @override
  State<_StarToggle> createState() => _StarToggleState();
}

class _StarToggleState extends State<_StarToggle> {
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
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SingleMotionBuilder(
              value: _pressed ? 0.85 : (_hovered ? 1.1 : 1.0),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.arrival,
              builder:
                  (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  widget.active ? widget.activeIcon : widget.inactiveIcon,
                  size: 18,
                  color: widget.active ? kPrimaryColor : kWhiteColor70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

class _PaneLoading extends StatelessWidget {
  const _PaneLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

enum _PaneMessageTone { normal, error }

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.tone = _PaneMessageTone.normal,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final _PaneMessageTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final accent = tone == _PaneMessageTone.error ? kRedColor : kPrimaryColor;
    return Center(
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
    ).animate().fadeIn(duration: 240.ms);
  }
}
