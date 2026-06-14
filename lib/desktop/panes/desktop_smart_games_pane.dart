import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopSmartGamesPane extends ConsumerWidget {
  const DesktopSmartGamesPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type =
        ref.watch(
          desktopSmartGamesTypeByTabIdProvider.select((types) => types[tabId]),
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
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () {
                    ref.read(premiumGamesProvider(type).notifier).refresh();
                  },
                  icon: const Icon(Icons.refresh_rounded, color: kWhiteColor),
                ),
                const SizedBox(width: 8),
                const GameViewModeToggle(),
              ],
            ),
          ),
          Expanded(
            child: gamesAsync.when(
              loading:
                  () => const _PaneMessage(
                    icon: Icons.hourglass_empty_rounded,
                    title: 'Loading games',
                    message: 'Building the collection…',
                  ),
              error:
                  (error, stack) => _PaneMessage(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load games',
                    message: '$error',
                    error: true,
                  ),
              data: (state) {
                if (state.games.isEmpty) {
                  return _PaneMessage(
                    icon: Icons.grid_off_rounded,
                    title: 'No games found',
                    message: copy.emptyMessage,
                  );
                }
                return _SmartGamesList(
                  games: state.games,
                  routeTitle: copy.title,
                  hasMore: state.hasMore,
                  isLoading: state.isLoadingMore,
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
  ConsumerState<_SmartGamesList> createState() => _SmartGamesListState();
}

class _SmartGamesListState extends ConsumerState<_SmartGamesList> {
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
    final scopeId = 'smart-games-${widget.routeTitle.toLowerCase()}';

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
            games: widget.games,
            pageStride: columns * 3,
            onActivateGame:
                (game) =>
                    _openSmartGame(ref, game, widget.routeTitle, widget.games),
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
                    _dateHeader(
                      groups[groupIndex].label,
                      groups[groupIndex].games.length,
                      groupIndex,
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
                        delegate: SliverChildBuilderDelegate((context, i) {
                          final game = groups[groupIndex].games[i];
                          return DesktopGameKeyboardItem(
                            itemKey: keyForGame(game.gameId),
                            gameId: game.gameId,
                            onSelect: selectGame,
                            child: LiveDesktopGameCard(
                              game: game,
                              tournamentTitle:
                                  game.tourSlug ?? widget.routeTitle,
                              routeTitle: widget.routeTitle,
                              routeGames: widget.games,
                              layout: DesktopCardLayout.grid,
                              selected: selectedGameId == game.gameId,
                              viewSource: ChessboardView.tour,
                            ),
                          );
                        }, childCount: groups[groupIndex].games.length),
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

    return DesktopGameKeyboardFocus(
      scopeId: scopeId,
      games: widget.games,
      onActivateGame:
          (game) => _openSmartGame(ref, game, widget.routeTitle, widget.games),
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
              _dateHeader(
                groups[groupIndex].label,
                groups[groupIndex].games.length,
                groupIndex,
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverToBoxAdapter(
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
                        child: LiveDesktopGameCard(
                          game: game,
                          tournamentTitle: game.tourSlug ?? widget.routeTitle,
                          routeTitle: widget.routeTitle,
                          routeGames: widget.games,
                          layout: layout,
                          selected: selectedGameId == game.gameId,
                          viewSource: ChessboardView.tour,
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

  SliverPadding _dateHeader(String label, int gameCount, int groupIndex) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(24, groupIndex == 0 ? 4 : 16, 24, 8),
      sliver: SliverToBoxAdapter(
        child: DesktopDateGroupCard(label: label, gameCount: gameCount),
      ),
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

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool error;

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
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kPrimaryColor,
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
