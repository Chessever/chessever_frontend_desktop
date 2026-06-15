import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
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
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: DesktopSearchField(
              controller: _searchController,
              hintText: 'Search games — player, event, opening, ECO…',
              onChanged: (value) => setState(() => _query = value),
              onClear: () {
                _searchController.clear();
                setState(() => _query = '');
              },
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
                final visibleGames = filterDesktopSmartGames(
                  state.games,
                  _query,
                );
                if (state.games.isEmpty) {
                  return _PaneMessage(
                    icon: Icons.grid_off_rounded,
                    title: 'No games found',
                    message: copy.emptyMessage,
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
                  games: visibleGames,
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
  final Set<String> _collapsedGroups = <String>{};

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
    final groups = buildDesktopGameDateGroups(
      widget.games,
      includeToday: true,
      excludeFuture: true,
    );
    final groupedGames = <GamesTourModel>[
      for (final group in groups) ...group.games,
    ];
    final keyboardGames = <GamesTourModel>[
      for (final group in groups)
        if (!_collapsedGroups.contains(group.key)) ...group.games,
    ];
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
                    var groupIndex = 0;
                    groupIndex < groups.length;
                    groupIndex++
                  ) ...[
                    _dateHeader(
                      groups[groupIndex].key,
                      groups[groupIndex].label,
                      groups[groupIndex].games.length,
                      groupIndex,
                    ),
                    if (!_collapsedGroups.contains(groups[groupIndex].key))
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
                                routeGames: groupedGames,
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
                var groupIndex = 0;
                groupIndex < groups.length;
                groupIndex++
              ) ...[
                _dateHeader(
                  groups[groupIndex].key,
                  groups[groupIndex].label,
                  groups[groupIndex].games.length,
                  groupIndex,
                ),
                if (!_collapsedGroups.contains(groups[groupIndex].key))
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    sliver: SliverToBoxAdapter(
                      child: _SmartGamesTable(
                        games: groups[groupIndex].games,
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
              var groupIndex = 0;
              groupIndex < groups.length;
              groupIndex++
            ) ...[
              _dateHeader(
                groups[groupIndex].key,
                groups[groupIndex].label,
                groups[groupIndex].games.length,
                groupIndex,
              ),
              if (!_collapsedGroups.contains(groups[groupIndex].key))
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
                            routeGames: groupedGames,
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

  SliverPadding _dateHeader(
    String groupKey,
    String label,
    int gameCount,
    int groupIndex,
  ) {
    final collapsed = _collapsedGroups.contains(groupKey);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(24, groupIndex == 0 ? 4 : 16, 24, 8),
      sliver: SliverToBoxAdapter(
        child: DesktopDateGroupCard(
          label: label,
          gameCount: gameCount,
          collapsed: collapsed,
          onToggle: () {
            setState(() {
              if (collapsed) {
                _collapsedGroups.remove(groupKey);
              } else {
                _collapsedGroups.add(groupKey);
              }
            });
          },
        ),
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
                  game.tourSlug ?? game.openingName ?? '—',
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
        const SizedBox(width: 8),
        Text(
          player.rating > 0 ? player.rating.toString() : '—',
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
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
