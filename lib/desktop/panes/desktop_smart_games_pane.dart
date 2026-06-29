import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/utils/desktop_smart_game_sections.dart';
import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_miniatures_filter_controls.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopSmartGamesPane extends ConsumerStatefulWidget {
  const DesktopSmartGamesPane({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<DesktopSmartGamesPane> createState() =>
      _DesktopSmartGamesPaneState();
}

class _DesktopSmartGamesPaneState extends ConsumerState<DesktopSmartGamesPane> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type =
        ref.watch(
          desktopSmartGamesTypeByTabIdProvider.select(
            (types) => types[widget.tabId],
          ),
        ) ??
        PremiumGamesType.live;
    final gamesAsync = ref.watch(premiumGamesProvider(type));
    final copy = _copyForType(type);

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        copy.title,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        copy.subtitle,
                        style: TextStyle(
                          color: kWhiteColor.withValues(alpha: 0.68),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                DesktopTooltip(
                  message: 'Refresh',
                  child: FButton.icon(
                    style: FButtonStyle.ghost(),
                    onPress: () {
                      ref.read(premiumGamesProvider(type).notifier).refresh();
                    },
                    child: const Icon(Icons.refresh_rounded),
                  ),
                ),
                const SizedBox(width: 8),
                const GameViewModeToggle(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child:
                type == PremiumGamesType.miniatures
                    ? Row(
                      children: [
                        Expanded(
                          child: DesktopSearchField(
                            controller: _searchController,
                            hintText:
                                'Search miniatures — player, event, opening, ECO…',
                            onChanged:
                                (value) => setState(() => _query = value),
                            onClear: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        const DesktopMiniaturesFilterButton(),
                      ],
                    )
                    : Row(
                      children: [
                        Expanded(
                          child: DesktopSearchField(
                            controller: _searchController,
                            hintText:
                                'Search games — player, event, opening, ECO…',
                            onChanged:
                                (value) => setState(() => _query = value),
                            onClear: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        DesktopPremiumGamesFilterButton(type: type),
                      ],
                    ),
          ),
          Expanded(
            child: gamesAsync.when(
              loading: () => const _SmartGamesLoadingSkeleton(),
              error:
                  (error, stack) => _PaneMessage(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load games',
                    message: '$error',
                    error: true,
                  ),
              data: (state) {
                final visibleGames = filterDesktopSmartGames(
                  state.games,
                  _query,
                );
                if (state.games.isEmpty) {
                  final miniatureFilter =
                      type == PremiumGamesType.miniatures
                          ? ref.watch(miniatureGamesFilterProvider)
                          : MiniatureGamesFilter.defaultFilter;
                  final premiumFilter =
                      type == PremiumGamesType.miniatures
                          ? PremiumGamesFilter.defaultFilter
                          : ref.watch(premiumGamesFilterProvider(type));
                  final hasActiveFilters =
                      type == PremiumGamesType.miniatures
                          ? miniatureFilter.hasActiveFilters
                          : premiumFilter.hasActiveFilters;
                  return _PaneMessage(
                    icon: Icons.grid_off_rounded,
                    title:
                        hasActiveFilters
                            ? type == PremiumGamesType.miniatures
                                ? 'No matching miniatures'
                                : 'No matching games'
                            : 'No games found',
                    message:
                        hasActiveFilters
                            ? 'No games match your filters.'
                            : copy.emptyMessage,
                    actionLabel: hasActiveFilters ? 'Reset filters' : null,
                    onAction:
                        hasActiveFilters
                            ? () {
                              if (type == PremiumGamesType.miniatures) {
                                unawaited(
                                  ref
                                      .read(
                                        premiumGamesProvider(
                                          PremiumGamesType.miniatures,
                                        ).notifier,
                                      )
                                      .applyMiniatureFilter(
                                        MiniatureGamesFilter.defaultFilter
                                            .copyWith(
                                              sort: miniatureFilter.sort,
                                              order: miniatureFilter.order,
                                            ),
                                      ),
                                );
                              } else {
                                ref
                                    .read(premiumGamesProvider(type).notifier)
                                    .resetFilter();
                              }
                            }
                            : null,
                  );
                }
                if (visibleGames.isEmpty) {
                  return _PaneMessage(
                    icon: Icons.search_off_rounded,
                    title: 'No matching games',
                    message: 'No games match "${_query.trim()}".',
                  );
                }
                return _SmartGamesList(
                  tabId: widget.tabId,
                  type: type,
                  games: visibleGames,
                  routeTitle: copy.title,
                  hasMore: state.hasMore,
                  isLoading: state.isLoadingMore,
                  showCounts:
                      type == PremiumGamesType.miniatures || !state.hasMore,
                  onLoadMore: () {
                    ref.read(premiumGamesProvider(type).notifier).loadMore();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartGamesList extends ConsumerStatefulWidget {
  const _SmartGamesList({
    required this.tabId,
    required this.type,
    required this.games,
    required this.routeTitle,
    required this.hasMore,
    required this.isLoading,
    required this.onLoadMore,
    required this.showCounts,
  });

  final String tabId;
  final PremiumGamesType type;
  final List<GamesTourModel> games;
  final String routeTitle;
  final bool hasMore;
  final bool isLoading;
  final VoidCallback onLoadMore;
  final bool showCounts;

  @override
  ConsumerState<_SmartGamesList> createState() => _SmartGamesListState();
}

class _SmartGamesListState extends ConsumerState<_SmartGamesList> {
  static const Duration _scrollIdleDelay = Duration(milliseconds: 180);

  final ScrollController _scrollController = ScrollController();
  final Set<String> _collapsedGroups = <String>{};
  Timer? _scrollIdleTimer;
  bool _liveCardsPausedForScroll = false;

  String get _liveCardsPauseReason =>
      'desktop_smart_games_scroll_${widget.routeTitle}';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _setLiveCardsPausedForScroll(false);
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) {
      return;
    }
    _markLiveCardsScrolling();
    if (!widget.hasMore || widget.isLoading) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 420) {
      widget.onLoadMore();
    }
  }

  void _markLiveCardsScrolling() {
    _setLiveCardsPausedForScroll(true);
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
    setLiveGameCardsPaused(ref, reason: _liveCardsPauseReason, paused: paused);
  }

  List<DesktopSmartGameSection> _buildMiniatureSections(
    List<GamesTourModel> games,
    MiniatureGamesFilter filter,
  ) {
    final groups = buildDesktopGameDateGroups(games, preserveGameOrder: true);

    return [
      for (final group in groups)
        DesktopSmartGameSection(
          key: 'miniatures-${group.key}',
          title: group.label,
          dateLabel: filter.window.label,
          games: group.games,
          liveCount: 0,
          eventAverageRating: _peakMiniatureRating(group.games),
          latestActivity: _latestMiniatureActivity(group.games),
          sortDay: _miniatureSortDay(group.key),
        ),
    ];
  }

  int _peakMiniatureRating(List<GamesTourModel> games) {
    var peakRating = 0;
    for (final game in games) {
      final rating = game.avgElo ?? desktopGameAverageRating(game);
      if (rating > peakRating) peakRating = rating;
    }
    return peakRating;
  }

  DateTime _latestMiniatureActivity(List<GamesTourModel> games) {
    var latestActivity = DateTime(0);
    for (final game in games) {
      final activity = game.lastMoveTime ?? game.gameDay ?? DateTime(0);
      if (activity.isAfter(latestActivity)) latestActivity = activity;
    }
    return latestActivity;
  }

  DateTime _miniatureSortDay(String dateKey) {
    if (dateKey == '0000-00-00') return DateTime(0);
    return DateTime.tryParse(dateKey) ?? DateTime(0);
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(gamesListViewModeProvider).desktopLayout;
    final streamingEnabled = ref.watch(
      desktopTabsProvider.select((state) => state.activeId == widget.tabId),
    );
    final cardStreamingEnabled = streamingEnabled;
    final sections =
        widget.type == PremiumGamesType.miniatures
            ? _buildMiniatureSections(
              widget.games,
              ref.watch(miniatureGamesFilterProvider),
            )
            : buildDesktopSmartGameSections(widget.games, type: widget.type);
    final groupedGames = <GamesTourModel>[
      for (final section in sections) ...section.games,
    ];
    final keyboardGames = <GamesTourModel>[
      for (final section in sections)
        if (!_collapsedGroups.contains(section.key)) ...section.games,
    ];
    final scopeId = 'smart-games-${widget.type.name}';

    if (sections.isEmpty) {
      return const _PaneMessage(
        icon: Icons.grid_off_rounded,
        title: 'No games found',
        message: 'No current games match this smart collection.',
      );
    }

    if (layout == DesktopCardLayout.grid) {
      return LayoutBuilder(
        builder: (context, constraints) {
          const targetWidth = 280.0;
          final columns = (constraints.maxWidth / targetWidth).floor().clamp(
            2,
            6,
          );
          return DesktopGameKeyboardFocus(
            scopeId: scopeId,
            games: keyboardGames,
            pageStride: columns * 3,
            ensureInitialSelectionVisible: false,
            onActivateGame:
                (game) =>
                    _openSmartGame(ref, game, widget.routeTitle, groupedGames),
            builder: (context, selectedGameId, selectGame, keyForGame) {
              return CustomScrollView(
                controller: _scrollController,
                physics: const DesktopScrollPhysics(),
                slivers: [
                  for (
                    var sectionIndex = 0;
                    sectionIndex < sections.length;
                    sectionIndex++
                  ) ...[
                    _sectionHeader(sections[sectionIndex], sectionIndex),
                    if (!_collapsedGroups.contains(sections[sectionIndex].key))
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
                            final game = sections[sectionIndex].games[i];
                            return DesktopGameKeyboardItem(
                              itemKey: keyForGame(game.gameId),
                              gameId: game.gameId,
                              onSelect: selectGame,
                              child: LiveDesktopGameCard(
                                game: game,
                                tournamentTitle: _smartGameTournamentTitle(
                                  game,
                                  widget.routeTitle,
                                ),
                                routeTitle: widget.routeTitle,
                                routeGames: groupedGames,
                                layout: DesktopCardLayout.grid,
                                selected: selectedGameId == game.gameId,
                                viewSource: ChessboardView.tour,
                                streamingEnabled: cardStreamingEnabled,
                                allowStockfishFallback: true,
                              ),
                            );
                          }, childCount: sections[sectionIndex].games.length),
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
        },
      );
    }
    if (layout == DesktopCardLayout.list) {
      return DesktopGameKeyboardFocus(
        scopeId: scopeId,
        games: keyboardGames,
        onActivateGame:
            (game) =>
                _openSmartGame(ref, game, widget.routeTitle, groupedGames),
        builder: (context, selectedGameId, selectGame, keyForGame) {
          return CustomScrollView(
            controller: _scrollController,
            physics: const DesktopScrollPhysics(),
            slivers: [
              for (
                var sectionIndex = 0;
                sectionIndex < sections.length;
                sectionIndex++
              ) ...[
                _sectionHeader(sections[sectionIndex], sectionIndex),
                if (!_collapsedGroups.contains(sections[sectionIndex].key))
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    sliver: SliverToBoxAdapter(
                      child: _SmartGamesTable(
                        games: sections[sectionIndex].games,
                        routeTitle: widget.routeTitle,
                        routeGames: groupedGames,
                        selectedGameId: selectedGameId,
                        onSelectGame: selectGame,
                        keyForGame: keyForGame,
                      ),
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

    return DesktopGameKeyboardFocus(
      scopeId: scopeId,
      games: keyboardGames,
      ensureInitialSelectionVisible: false,
      onActivateGame:
          (game) => _openSmartGame(ref, game, widget.routeTitle, groupedGames),
      builder: (context, selectedGameId, selectGame, keyForGame) {
        return CustomScrollView(
          controller: _scrollController,
          physics: const DesktopScrollPhysics(),
          slivers: [
            for (
              var sectionIndex = 0;
              sectionIndex < sections.length;
              sectionIndex++
            ) ...[
              _sectionHeader(sections[sectionIndex], sectionIndex),
              if (!_collapsedGroups.contains(sections[sectionIndex].key))
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverToBoxAdapter(
                    child: DesktopGameCardsFlow(
                      layout: layout,
                      embedded: true,
                      itemCount: sections[sectionIndex].games.length,
                      itemBuilder: (context, i) {
                        final game = sections[sectionIndex].games[i];
                        return DesktopGameKeyboardItem(
                          itemKey: keyForGame(game.gameId),
                          gameId: game.gameId,
                          onSelect: selectGame,
                          child: LiveDesktopGameCard(
                            game: game,
                            tournamentTitle: _smartGameTournamentTitle(
                              game,
                              widget.routeTitle,
                            ),
                            routeTitle: widget.routeTitle,
                            routeGames: groupedGames,
                            layout: layout,
                            selected: selectedGameId == game.gameId,
                            viewSource: ChessboardView.tour,
                            streamingEnabled: cardStreamingEnabled,
                            allowStockfishFallback: true,
                          ),
                        );
                      },
                    ),
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

  SliverPadding _sectionHeader(
    DesktopSmartGameSection section,
    int sectionIndex,
  ) {
    final collapsed = _collapsedGroups.contains(section.key);
    void toggleCollapsed() {
      setState(() {
        if (collapsed) {
          _collapsedGroups.remove(section.key);
        } else {
          _collapsedGroups.add(section.key);
        }
      });
    }

    final usesDateHeader =
        widget.type == PremiumGamesType.miniatures ||
        widget.type == PremiumGamesType.gm;
    final header =
        usesDateHeader
            ? DesktopDateGroupCard(
              label: section.title,
              gameCount: section.gameCount,
              showCount: widget.showCounts,
              collapsed: collapsed,
              onToggle: toggleCollapsed,
            )
            : _SmartEventSectionCard(
              section: section,
              showCount: widget.showCounts,
              collapsed: collapsed,
              onToggle: toggleCollapsed,
            );

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(24, sectionIndex == 0 ? 4 : 16, 24, 8),
      sliver: SliverToBoxAdapter(child: header),
    );
  }
}

class _SmartEventSectionCard extends StatelessWidget {
  const _SmartEventSectionCard({
    required this.section,
    required this.collapsed,
    required this.onToggle,
    this.showCount = true,
  });

  final DesktopSmartGameSection section;
  final bool collapsed;
  final VoidCallback onToggle;

  /// Whether to render the game-count badge. Hidden while the feed is still
  /// paginating and the total would be misleading.
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      section.dateLabel,
      if (section.timeControlLabel != null) section.timeControlLabel!,
      if (section.eventAverageRating > 0) 'Avg ${section.eventAverageRating}',
    ];

    return FTheme(
      data: FThemes.zinc.dark,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Semantics(
          button: true,
          toggled: !collapsed,
          label: section.title,
          child: FCard.raw(
            style:
                (style) => style.copyWith(
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          section.hasLiveGames
                              ? kPrimaryColor.withValues(alpha: 0.32)
                              : kDividerColor,
                    ),
                  ),
                ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 30,
                    decoration: BoxDecoration(
                      color:
                          section.hasLiveGames ? kPrimaryColor : kWhiteColor70,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    section.hasLiveGames
                        ? Icons.radio_button_checked_rounded
                        : Icons.event_note_rounded,
                    size: 16,
                    color: section.hasLiveGames ? kPrimaryColor : kWhiteColor70,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          section.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          meta.join('  •  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: kWhiteColor.withValues(alpha: 0.58),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (section.liveCount > 0) ...[
                    _SmartHeaderBadge(
                      label:
                          section.liveCount == 1
                              ? '1 live'
                              : '${section.liveCount} live',
                      accent: kPrimaryColor,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (showCount) ...[
                    _SmartHeaderBadge(
                      label:
                          section.gameCount == 1
                              ? '1 game'
                              : '${section.gameCount} games',
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right_rounded
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
    );
  }
}

class _SmartHeaderBadge extends StatelessWidget {
  const _SmartHeaderBadge({required this.label, this.accent});

  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? kWhiteColor70;
    return FBadge(
      style: FBadgeStyle.outline(
        (style) => style.copyWith(
          decoration: BoxDecoration(
            color: (accent ?? kBlack3Color).withValues(
              alpha: accent == null ? 1 : 0.12,
            ),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accent?.withValues(alpha: 0.42) ?? kDividerColor,
            ),
          ),
          contentStyle:
              (content) => content.copyWith(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                labelTextStyle: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
        ),
      ),
      child: Text(label),
    );
  }
}

void _openSmartGame(
  WidgetRef ref,
  GamesTourModel game,
  String routeTitle,
  List<GamesTourModel> routeGames,
) {
  openTournamentGameTab(
    ref,
    game,
    game.tourSlug ?? routeTitle,
    routeTitle: routeTitle,
    routeGames: routeGames,
    viewSource: ChessboardView.tour,
  );
}

String _smartGameTournamentTitle(GamesTourModel game, String fallback) {
  for (final value in [
    game.eventName,
    game.tourName,
    game.tourSlug,
    game.roundSlug,
    fallback,
  ]) {
    final title = value?.trim();
    if (title != null && title.isNotEmpty) return title;
  }
  return fallback;
}

List<GamesTourModel> filterDesktopSmartGames(
  List<GamesTourModel> games,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return games;

  return games.where((game) {
    final haystack =
        <String?>[
          game.whitePlayer.name,
          game.whitePlayer.title,
          game.whitePlayer.federation,
          game.blackPlayer.name,
          game.blackPlayer.title,
          game.blackPlayer.federation,
          game.eventName,
          game.tourName,
          game.tourSlug,
          game.roundSlug,
          game.eco,
          game.openingName,
          game.timeControl,
        ].whereType<String>().join(' ').toLowerCase();
    return haystack.contains(normalized);
  }).toList();
}

class _SmartGamesTable extends ConsumerWidget {
  const _SmartGamesTable({
    required this.games,
    required this.routeTitle,
    required this.routeGames,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
  });

  final List<GamesTourModel> games;
  final String routeTitle;
  final List<GamesTourModel> routeGames;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        children: [
          const _SmartGamesTableHeader(),
          for (var i = 0; i < games.length; i++)
            DesktopGameKeyboardItem(
              itemKey: keyForGame(games[i].gameId),
              gameId: games[i].gameId,
              onSelect: onSelectGame,
              child: _SmartGamesTableRow(
                game: games[i],
                selected: selectedGameId == games[i].gameId,
                showDivider: i < games.length - 1,
                onSelect: () => onSelectGame(games[i].gameId),
                onOpen:
                    () => _openSmartGame(ref, games[i], routeTitle, routeGames),
              ),
            ),
        ],
      ),
    );
  }
}

class _SmartGamesTableHeader extends StatelessWidget {
  const _SmartGamesTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 68, child: _HeaderText('STATUS')),
          Expanded(flex: 4, child: _HeaderText('WHITE')),
          SizedBox(width: 56, child: Center(child: _HeaderText('RESULT'))),
          Expanded(flex: 4, child: _HeaderText('BLACK')),
          SizedBox(
            width: 64,
            child: Align(
              alignment: Alignment.centerRight,
              child: _HeaderText('AVG'),
            ),
          ),
          SizedBox(width: 14),
          Expanded(flex: 3, child: _HeaderText('EVENT')),
        ],
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  const _HeaderText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _SmartGamesTableRow extends StatefulWidget {
  const _SmartGamesTableRow({
    required this.game,
    required this.selected,
    required this.showDivider,
    required this.onSelect,
    required this.onOpen,
  });

  final GamesTourModel game;
  final bool selected;
  final bool showDivider;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<_SmartGamesTableRow> createState() => _SmartGamesTableRowState();
}

class _SmartGamesTableRowState extends State<_SmartGamesTableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final statusText =
        game.effectiveGameStatus == GameStatus.ongoing ? 'LIVE' : 'DONE';
    final statusColor =
        game.effectiveGameStatus == GameStatus.ongoing
            ? kPrimaryColor
            : kWhiteColor70;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onDoubleTap: widget.onOpen,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color:
                widget.selected
                    ? kPrimaryColor.withValues(alpha: 0.12)
                    : (_hovered ? kBlack3Color.withValues(alpha: 0.55) : null),
            border:
                widget.showDivider
                    ? Border(
                      bottom: BorderSide(
                        color: kDividerColor.withValues(alpha: 0.75),
                      ),
                    )
                    : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 68,
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(flex: 4, child: _PlayerCell(player: game.whitePlayer)),
              SizedBox(
                width: 56,
                child: Center(child: _ResultCell(game: game)),
              ),
              Expanded(flex: 4, child: _PlayerCell(player: game.blackPlayer)),
              SizedBox(
                width: 64,
                child: Text(
                  desktopGameAverageRating(game).toString(),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: Text(
                  _smartGameEventLabel(game),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerCell extends StatelessWidget {
  const _PlayerCell({required this.player});
  final PlayerCard player;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (player.title.isNotEmpty) ...[
          Text(
            player.title,
            style: const TextStyle(
              color: kPrimaryColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (player.rating > 0) ...[
          const SizedBox(width: 8),
          Text(
            player.rating.toString(),
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

String _smartGameEventLabel(GamesTourModel game) {
  for (final value in [
    game.eventName,
    game.tourName,
    game.tourSlug,
    game.openingName,
  ]) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return '—';
}

class _ResultCell extends StatelessWidget {
  const _ResultCell({required this.game});
  final GamesTourModel game;

  @override
  Widget build(BuildContext context) {
    final status = game.effectiveGameStatus;
    final label = switch (status) {
      GameStatus.whiteWins => '1-0',
      GameStatus.blackWins => '0-1',
      GameStatus.draw => '½-½',
      _ => '*',
    };
    return Text(
      label,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool error;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = error ? Colors.redAccent : kPrimaryColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: color.withValues(alpha: 0.85)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kWhiteColor.withValues(alpha: 0.64),
                fontSize: 13,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FTheme(
                data: FThemes.zinc.dark,
                child: FButton(
                  style: FButtonStyle.outline(),
                  onPress: onAction,
                  child: Text(actionLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmartGamesLoadingSkeleton extends StatelessWidget {
  const _SmartGamesLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetWidth = 280.0;
        final columns =
            (constraints.maxWidth / targetWidth).floor().clamp(2, 6).toInt();

        return Skeletonizer(
          ignorePointers: true,
          effect: const ShimmerEffect(
            baseColor: kBlackColor,
            highlightColor: kDarkGreyColor,
          ),
          child: CustomScrollView(
            physics: const DesktopScrollPhysics(),
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
                sliver: SliverToBoxAdapter(
                  child: _SmartSkeletonSectionHeader(),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.95,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => const _SmartSkeletonGameCard(),
                    childCount: columns * 2,
                  ),
                ),
              ),
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
                sliver: SliverToBoxAdapter(
                  child: _SmartSkeletonSectionHeader(),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.95,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => const _SmartSkeletonGameCard(),
                    childCount: columns,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );
  }
}

class _SmartSkeletonSectionHeader extends StatelessWidget {
  const _SmartSkeletonSectionHeader();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Bone(width: 3, height: 30, uniRadius: 2),
            SizedBox(width: 10),
            Bone.circle(size: 16),
            SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Bone(width: 220, height: 14, uniRadius: 4),
                  SizedBox(height: 7),
                  Bone(width: 150, height: 10, uniRadius: 4),
                ],
              ),
            ),
            SizedBox(width: 12),
            Bone(width: 62, height: 22, uniRadius: 999),
            SizedBox(width: 8),
            Bone.circle(size: 18),
          ],
        ),
      ),
    );
  }
}

class _SmartSkeletonGameCard extends StatelessWidget {
  const _SmartSkeletonGameCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 12),
        child: Column(
          children: [
            const Row(
              children: [
                Bone.circle(size: 8),
                SizedBox(width: 8),
                Expanded(child: Bone(height: 13, uniRadius: 4)),
                SizedBox(width: 8),
                Bone(width: 38, height: 14, uniRadius: 4),
              ],
            ),
            SizedBox(height: compact ? 10 : 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: const Bone(
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
            SizedBox(height: compact ? 10 : 12),
            const Row(
              children: [
                Bone.circle(size: 8),
                SizedBox(width: 8),
                Expanded(child: Bone(height: 13, uniRadius: 4)),
                SizedBox(width: 8),
                Bone(width: 48, height: 18, uniRadius: 4),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineLoader extends StatelessWidget {
  const _InlineLoader();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      ignorePointers: true,
      effect: const ShimmerEffect(
        baseColor: kBlackColor,
        highlightColor: kDarkGreyColor,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
        child: SizedBox(
          height: 88,
          child: Row(
            children: const [
              Expanded(child: _SmartSkeletonGameCard(compact: true)),
              SizedBox(width: 8),
              Expanded(child: _SmartSkeletonGameCard(compact: true)),
              SizedBox(width: 8),
              Expanded(child: _SmartSkeletonGameCard(compact: true)),
            ],
          ),
        ),
      ),
    );
  }
}

({String title, String subtitle, String emptyMessage}) _copyForType(
  PremiumGamesType type,
) {
  return switch (type) {
    PremiumGamesType.live => (
      title: 'Live',
      subtitle: 'All games that are currently in progress.',
      emptyMessage: 'No live games are available right now.',
    ),
    PremiumGamesType.gm => (
      title: 'GM',
      subtitle: 'Games with an average player rating of 2500 or higher.',
      emptyMessage: 'No 2500+ average-rating games were found.',
    ),
    PremiumGamesType.classical => (
      title: 'Classical',
      subtitle: 'Classical and standard time-control games.',
      emptyMessage: 'No classical games were found.',
    ),
    PremiumGamesType.miniatures => (
      title: 'Miniatures',
      subtitle: 'Decisive Gamebase wins that ended by move 25.',
      emptyMessage: 'No miniature games were found.',
    ),
    PremiumGamesType.favorites => (
      title: 'Favorites',
      subtitle: 'Games featuring your favorite players.',
      emptyMessage: 'No favorite-player games were found.',
    ),
    PremiumGamesType.countrymen => (
      title: 'Countrymen',
      subtitle: 'Games featuring players from your federation.',
      emptyMessage: 'No countrymen games were found.',
    ),
  };
}
