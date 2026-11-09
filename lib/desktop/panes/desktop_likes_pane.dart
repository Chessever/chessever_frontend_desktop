import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/services/desktop_local_day_clock.dart';
import 'package:chessever/desktop/services/likes/community_likes_access.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_keyboard_action.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/desktop_like_count_heart.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

typedef _LikesSection = CommunityLikesSection;

extension on CommunityLikesSection {
  String get label => switch (this) {
    _LikesSection.about => 'About',
    _LikesSection.games => 'Games',
    _LikesSection.players => 'Players',
  };

  IconData get icon => switch (this) {
    _LikesSection.about => Icons.info_outline_rounded,
    _LikesSection.games => Icons.grid_view_rounded,
    _LikesSection.players => Icons.people_alt_outlined,
  };
}

/// The community Likes ranking: the phone's Discovery › Likes on desktop and
/// in the browser build.
///
/// About explains the ranking and points at the user's own My Likes. Games
/// ranks the most liked games of the chosen day, week, month or year. Players
/// lists everyone in those games by the likes their games drew; picking one
/// narrows Games to their games. Browsing every ranking is free; opening a
/// game outside today's ranking is Premium (checked at the click).
class DesktopLikesPane extends ConsumerStatefulWidget {
  const DesktopLikesPane({
    super.key,
    required this.tabId,
    this.readOnlyPresentation = false,
  });

  final String tabId;
  final bool readOnlyPresentation;

  @override
  ConsumerState<DesktopLikesPane> createState() => _DesktopLikesPaneState();
}

class _DesktopLikesPaneState extends ConsumerState<DesktopLikesPane> {
  CommunityLikesPlayer? _player;

  void _showSection(CommunityLikesSection section) {
    ref.read(communityLikesSectionProvider.notifier).state = section;
  }

  void _pickPlayer(CommunityLikesPlayer player) {
    setState(() => _player = player);
    _showSection(CommunityLikesSection.games);
  }

  void _setPeriod(CommunityLikesPeriod period) {
    ref.read(communityLikesPeriodProvider.notifier).state = period;
    ref.read(communityLikesDayProvider.notifier).state = null;
    setState(() => _player = null);
  }

  void _step(CommunityLikesQuery? target) {
    if (target == null) return;
    final now = DateTime.now();
    // Landing on the current period follows the clock again.
    ref.read(communityLikesDayProvider.notifier).state =
        target.isCurrent(now) ? null : target.start;
    setState(() => _player = null);
  }

  void _refresh(CommunityLikesQuery query) {
    ref.invalidate(communityLikesProvider(query));
  }

  @override
  Widget build(BuildContext context) {
    // Re-derive "today" at local midnight so the free day and labels move.
    if (!widget.readOnlyPresentation) ref.watch(desktopLocalDayProvider);
    final now = DateTime.now();
    final query = communityLikesActiveQuery(ref, now: now);
    final current = ref.watch(communityLikesSectionProvider);
    final browsing = current != _LikesSection.about;

    return ColoredBox(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The home page's toolbar: what to show on the left, how to show
          // it on the right.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    DesktopSegmentedTabs<CommunityLikesSection>(
                      selected: current,
                      onChanged: (section) {
                        if (section != current) _showSection(section);
                      },
                      tabs: [
                        for (final section in _LikesSection.values)
                          DesktopSegmentedTab(
                            value: section,
                            label: section.label,
                            icon: section.icon,
                          ),
                      ],
                    ),
                    const Spacer(),
                    if (current == _LikesSection.games) ...[
                      const GameViewModeToggle(buttonSize: 38),
                      const SizedBox(width: 8),
                    ],
                    if (browsing)
                      DesktopTooltip(
                        message: 'Refresh',
                        child: FTheme(
                          data: FThemes.zinc.dark,
                          child: FButton.icon(
                            style: FButtonStyle.ghost(),
                            onPress: () => _refresh(query),
                            child: const Icon(Icons.refresh_rounded, size: 18),
                          ),
                        ),
                      ),
                  ],
                ),
                if (browsing) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _PeriodControl(
                      query: query,
                      now: now,
                      onPeriod: _setPeriod,
                      onStep: _step,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: switch (current) {
              _LikesSection.about => const _LikesAboutView(),
              _LikesSection.games => _RankedGamesView(
                tabId: widget.tabId,
                query: query,
                player: _player,
                readOnlyPresentation: widget.readOnlyPresentation,
                onClearPlayer: () => setState(() => _player = null),
              ),
              _LikesSection.players => _RankedPlayersView(
                query: query,
                selected: _player,
                onPick: _pickPlayer,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Today / Week / Month / Year, then "‹ Sep 21–27 ›" walking the picked
/// period. Earlier periods stop at the first day there were likes; the next
/// arrow is disabled on the current period.
class _PeriodControl extends StatelessWidget {
  const _PeriodControl({
    required this.query,
    required this.now,
    required this.onPeriod,
    required this.onStep,
  });

  final CommunityLikesQuery query;
  final DateTime now;
  final ValueChanged<CommunityLikesPeriod> onPeriod;
  final ValueChanged<CommunityLikesQuery?> onStep;

  @override
  Widget build(BuildContext context) {
    final previous = query.previous;
    final next = query.next(now);
    final unit = query.period.unit;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopSegmentedTabs<CommunityLikesPeriod>(
          selected: query.period,
          onChanged: (period) {
            if (period != query.period) onPeriod(period);
          },
          tabs: [
            for (final period in CommunityLikesPeriod.values)
              DesktopSegmentedTab(value: period, label: period.label),
          ],
        ),
        const SizedBox(width: 14),
        _StepButton(
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous $unit',
          onPress: previous == null ? null : () => onStep(previous),
        ),
        // A fixed measure so the arrows do not jump as the label changes.
        SizedBox(
          width: 150,
          child: Text(
            query.label(now),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: 'Most liked, ${query.label(now)}',
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _StepButton(
          icon: Icons.chevron_right_rounded,
          tooltip: 'Next $unit',
          onPress: next == null ? null : () => onStep(next),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: tooltip,
      child: FTheme(
        data: FThemes.zinc.dark,
        child: FButton.icon(
          style: FButtonStyle.ghost(),
          onPress: onPress,
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

/// The first page plus any loaded later pages, or the state to show instead.
typedef _Ranking =
    ({
      List<CommunityLikesEntry>? entries,
      CommunityLikesPagingState paging,
      Widget? placeholder,
    });

_Ranking _watchRanking(
  WidgetRef ref,
  CommunityLikesQuery query, {
  required String emptyTitle,
}) {
  final first = ref.watch(communityLikesProvider(query));
  final paging = ref.watch(communityLikesPagesProvider(query));
  void retry() => ref.invalidate(communityLikesProvider(query));

  Widget? placeholder;
  List<CommunityLikesEntry>? entries;
  first.when(
    loading: () => placeholder = const _Spinner(),
    error:
        (error, _) =>
            placeholder = _Message(
              title: 'Could not load the ranking',
              body: 'Check your connection and try again.',
              actionLabel: 'Retry',
              onAction: retry,
            ),
    data: (result) {
      switch (result.status) {
        case CommunityLikesStatus.notLive:
          placeholder = const _Message(
            title: 'Rankings are not live yet',
            body: 'Most liked games appear here once ranking starts.',
          );
        case CommunityLikesStatus.premiumRequired:
          placeholder = _Message(
            title: 'This ranking needs Premium',
            body:
                "Today's ranking is free. If you have Premium, it may "
                'still be syncing.',
            actionLabel: 'Retry',
            onAction: retry,
          );
        case CommunityLikesStatus.ranked:
          final all = [...result.entries, ...paging.entries];
          if (all.isEmpty) {
            placeholder = _EmptyRankingFallback(
              key: ValueKey(query),
              query: query,
              emptyTitle: emptyTitle,
            );
          } else {
            entries = all;
          }
      }
    },
  );
  return (entries: entries, paging: paging, placeholder: placeholder);
}

String _emptyTitle(CommunityLikesQuery query, DateTime now) {
  if (query.period == CommunityLikesPeriod.today) {
    return query.isCurrent(now)
        ? 'No games liked yet today'
        : 'No games liked that day';
  }
  return 'No games liked in this period';
}

/// The ranked games, in rank order and in the viewer's own games view (the
/// Card / List / Grid toggle every games list shares). Boards carry their
/// like count on the corner; a scorecard has no board, so its count and
/// event ride on a line above it, as on the phone.
class _RankedGamesView extends ConsumerStatefulWidget {
  const _RankedGamesView({
    required this.tabId,
    required this.query,
    required this.player,
    required this.onClearPlayer,
    this.readOnlyPresentation = false,
  });

  final String tabId;
  final CommunityLikesQuery query;
  final CommunityLikesPlayer? player;
  final VoidCallback onClearPlayer;
  final bool readOnlyPresentation;

  @override
  ConsumerState<_RankedGamesView> createState() => _RankedGamesViewState();
}

class _RankedGamesViewState extends ConsumerState<_RankedGamesView> {
  /// The compact scorecard's likes line, and the gap under it.
  static const double _metaHeight = 22;

  final ScrollController _scroll = DesktopScrollController();
  int _columns = 1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final query = widget.query;
    final layout = ref.watch(gamesListViewModeProvider).desktopLayout;
    final ranking = _watchRanking(
      ref,
      query,
      emptyTitle: _emptyTitle(query, now),
    );
    final placeholder = ranking.placeholder;
    if (placeholder != null) return placeholder;

    final player = widget.player;
    final entries = [
      for (final entry in ranking.entries!)
        if (player == null || communityLikesEntryHasPlayer(entry, player))
          entry,
    ];
    final games = [for (final entry in entries) entry.game];
    final accessContext = communityLikesAccessContext(
      query,
      DesktopAction.openContent,
    );
    void open(GamesTourModel game) => openCommunityLikesGame(
      context,
      ref,
      game,
      query: query,
      routeGames: games,
    );

    final active =
        !widget.readOnlyPresentation &&
        ref.watch(
          desktopTabsProvider.select((tabs) => tabs.activeId == widget.tabId),
        );
    final metrics = DesktopGameCardsFlow.metricsFor(layout);
    final compact = layout == DesktopCardLayout.compact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (player != null)
          _PlayerFilterBar(player: player, onClear: widget.onClearPlayer),
        Expanded(
          child:
              entries.isEmpty
                  ? _Message(
                    title: 'No ranked games for ${player?.player.name}',
                    body: 'Their games may be on a later page of the ranking.',
                  )
                  : DesktopGameKeyboardFocus(
                    scopeId: 'community-likes-${query.hashCode}',
                    enabled: !widget.readOnlyPresentation,
                    ensureInitialSelectionVisible: !widget.readOnlyPresentation,
                    games: games,
                    scrollController: _scroll,
                    resolveColumnCount: () => _columns,
                    onActivateGame: widget.readOnlyPresentation ? null : open,
                    builder: (context, selectedId, select, keyFor) {
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          _columns = DesktopGameCardsFlow.columnCountForWidth(
                            layout,
                            constraints.maxWidth - 40,
                          );
                          final SliverGridDelegate delegate =
                              layout == DesktopCardLayout.grid
                                  ? SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _columns,
                                    mainAxisSpacing: metrics.spacing,
                                    crossAxisSpacing: metrics.spacing,
                                    childAspectRatio: 0.95,
                                  )
                                  : SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _columns,
                                    mainAxisSpacing: metrics.spacing,
                                    crossAxisSpacing: metrics.spacing,
                                    mainAxisExtent:
                                        metrics.tileHeight +
                                        (compact ? _metaHeight : 0),
                                  );
                          return CustomScrollView(
                            controller: _scroll,
                            physics: const DesktopScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  4,
                                  20,
                                  16,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: delegate,
                                  delegate: SliverChildBuilderDelegate((
                                    context,
                                    i,
                                  ) {
                                    final entry = entries[i];
                                    final game = entry.game;
                                    final card = LiveDesktopGameCard(
                                      game: game,
                                      tournamentTitle:
                                          game.eventName ??
                                          game.tourName ??
                                          'Likes',
                                      layout: layout,
                                      selected: selectedId == game.gameId,
                                      // Drawn as Premium sees it, like
                                      // Countrymen; a denied open (click or
                                      // menu) shows the paywall instead.
                                      accessContext: accessContext,
                                      onTap: () => open(game),
                                      streamingEnabled: active,
                                      readOnlyPresentation:
                                          widget.readOnlyPresentation,
                                    );
                                    return DesktopGameKeyboardItem(
                                      itemKey: keyFor(game.gameId),
                                      gameId: game.gameId,
                                      onSelect: select,
                                      child:
                                          compact
                                              ? Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  _LikesMeta(entry: entry),
                                                  Expanded(child: card),
                                                ],
                                              )
                                              : DesktopBoardLikeBadge(
                                                likes: entry.likes,
                                                child: card,
                                              ),
                                    );
                                  }, childCount: entries.length),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: _LoadMore(
                                  paging: ranking.paging,
                                  onLoad:
                                      () =>
                                          ref
                                              .read(
                                                communityLikesPagesProvider(
                                                  query,
                                                ).notifier,
                                              )
                                              .loadMore(),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

/// "♥ 1.2K · Sinquefield Cup" over a scorecard: the card has no board for
/// the heart, so the count rides here with the game's event.
class _LikesMeta extends StatelessWidget {
  const _LikesMeta({required this.entry});

  final CommunityLikesEntry entry;

  @override
  Widget build(BuildContext context) {
    final game = entry.game;
    final event = (game.eventName ?? game.tourName)?.trim();
    const muted = Color(0xB3FFFFFF);
    return Semantics(
      label: [
        communityLikesLabel(entry.likes),
        if (event != null && event.isNotEmpty) event,
      ].join(', '),
      excludeSemantics: true,
      child: SizedBox(
        height: _RankedGamesViewState._metaHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Row(
            children: [
              const Icon(Icons.favorite_rounded, size: 12, color: muted),
              const SizedBox(width: 5),
              Text(
                compactLikeCount(entry.likes),
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (event != null && event.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: muted,
                      fontSize: 12,
                      height: 1,
                    ),
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

class _PlayerFilterBar extends StatelessWidget {
  const _PlayerFilterBar({required this.player, required this.onClear});

  final CommunityLikesPlayer player;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Games with ',
                    style: TextStyle(color: kWhiteColor70),
                  ),
                  TextSpan(
                    text: player.player.name,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          _LikesActionButton(
            label: 'All games',
            icon: Icons.close_rounded,
            height: 30,
            onPress: onClear,
          ),
        ],
      ),
    );
  }
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.paging, required this.onLoad});

  final CommunityLikesPagingState paging;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    if (!paging.hasMore) return const SizedBox(height: 16);
    if (paging.loading) return const _Spinner();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Center(
        child: _LikesActionButton(
          label: paging.failed ? 'Retry' : 'Show more',
          icon:
              paging.failed ? Icons.refresh_rounded : Icons.expand_more_rounded,
          onPress: onLoad,
        ),
      ),
    );
  }
}

/// Everyone with a game in the loaded ranking, most liked first. A click
/// narrows Games to their games; the profile opens from the trailing action.
class _RankedPlayersView extends ConsumerWidget {
  const _RankedPlayersView({
    required this.query,
    required this.selected,
    required this.onPick,
  });

  final CommunityLikesQuery query;
  final CommunityLikesPlayer? selected;
  final ValueChanged<CommunityLikesPlayer> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final ranking = _watchRanking(
      ref,
      query,
      emptyTitle: _emptyTitle(query, now),
    );
    final placeholder = ranking.placeholder;
    if (placeholder != null) return placeholder;
    final players = aggregateCommunityLikesPlayers(ranking.entries!);

    return DesktopScrollHost(
      child: ListView(
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(17, 0, 20, 24),
        children: [
          const _PlayerColumnsHeader(),
          const SizedBox(height: 6),
          for (final row in players)
            _PlayerRow(
              key: ValueKey('community_likes_player_${row.key}'),
              row: row,
              selected: selected?.key == row.key,
              onPick: () => onPick(row),
            ),
          _LoadMore(
            paging: ranking.paging,
            onLoad:
                () =>
                    ref
                        .read(communityLikesPagesProvider(query).notifier)
                        .loadMore(),
          ),
        ],
      ),
    );
  }
}

const double _kRankColumn = 36;
const double _kRatingColumn = 56;
const double _kGamesColumn = 64;
const double _kLikesColumn = 72;
const double _kProfileColumn = 40;

class _PlayerColumnsHeader extends StatelessWidget {
  const _PlayerColumnsHeader();

  static const TextStyle _style = TextStyle(
    color: kLightGreyColor,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
  );

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(3, 0, 0, 0),
      child: Row(
        children: [
          SizedBox(
            width: _kRankColumn,
            child: Text('#', textAlign: TextAlign.right, style: _style),
          ),
          SizedBox(width: 14),
          Expanded(child: Text('Player', style: _style)),
          SizedBox(
            width: _kRatingColumn,
            child: Text('Rating', textAlign: TextAlign.right, style: _style),
          ),
          SizedBox(
            width: _kGamesColumn,
            child: Text('Games', textAlign: TextAlign.right, style: _style),
          ),
          SizedBox(
            width: _kLikesColumn,
            child: Text('Likes', textAlign: TextAlign.right, style: _style),
          ),
          SizedBox(width: _kProfileColumn),
        ],
      ),
    );
  }
}

class _PlayerRow extends ConsumerStatefulWidget {
  const _PlayerRow({
    super.key,
    required this.row,
    required this.selected,
    required this.onPick,
  });

  final CommunityLikesPlayer row;
  final bool selected;
  final VoidCallback onPick;

  @override
  ConsumerState<_PlayerRow> createState() => _PlayerRowState();
}

class _PlayerRowState extends ConsumerState<_PlayerRow> {
  bool _hovered = false;

  void _openProfile() {
    final p = widget.row.player;
    final title = p.title.trim();
    final fed = p.countryCode.trim();
    openPlayerProfile(
      ref,
      PlayerProfileArgs(
        playerName: p.name,
        fideId: p.fideId,
        title: title.isEmpty ? null : title,
        federation: fed.isEmpty ? null : fed,
        rating: p.rating > 0 ? p.rating : null,
        gamebasePlayerId: p.gamebasePlayerId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final p = row.player;
    const tabular = [FontFeature.tabularFigures()];
    return Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${row.rank}, ${p.name}, ${row.games == 1 ? '1 game' : '${row.games} games'}, '
          '${communityLikesLabel(row.likes)}. Shows their games.',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: DesktopKeyboardAction(
          excludeChildFocus: false,
          onPress: widget.onPick,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            decoration: librarySelectedRowDecoration(
              selected: widget.selected,
              hovered: _hovered,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: _kRankColumn,
                  child: Text(
                    '${row.rank}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 12,
                      fontFeatures: tabular,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: LibraryTablePlayerCell(
                    name: p.name,
                    federation: p.countryCode,
                    fideId: p.fideId,
                    title: p.title,
                    abbreviate: false,
                  ),
                ),
                SizedBox(
                  width: _kRatingColumn,
                  child: Text(
                    p.rating > 0 ? '${p.rating}' : '',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: tabular,
                    ),
                  ),
                ),
                SizedBox(
                  width: _kGamesColumn,
                  child: Text(
                    '${row.games}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      fontFeatures: tabular,
                    ),
                  ),
                ),
                SizedBox(
                  width: _kLikesColumn,
                  child: Text(
                    compactLikeCount(row.likes),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: tabular,
                    ),
                  ),
                ),
                SizedBox(
                  width: _kProfileColumn,
                  child: Center(
                    child: DesktopTooltip(
                      message: 'Open profile',
                      child: FTheme(
                        data: FThemes.zinc.dark,
                        child: FButton.icon(
                          style: FButtonStyle.ghost(),
                          onPress: _openProfile,
                          child: Icon(
                            Icons.north_east_rounded,
                            size: 16,
                            color:
                                _hovered || widget.selected
                                    ? kWhiteColor
                                    : kWhiteColor70,
                          ),
                        ),
                      ),
                    ),
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

/// What the ranking is, what is free, and where the user's own likes live.
class _LikesAboutView extends ConsumerWidget {
  const _LikesAboutView();

  static const List<(String, String)> _rules = [
    (
      'Games',
      'The most liked games of the chosen day, week, month or year. A game '
          'needs two likes in that period to rank.',
    ),
    (
      'Players',
      'Everyone in those games, ranked by the likes their games drew. Pick '
          'a player to see their ranked games.',
    ),
    (
      'Liking',
      'Open a game and press its heart to like it. Sign in to keep your '
          'likes across devices. Press again to remove a like.',
    ),
    (
      'Free',
      "Every ranking to browse, and opening games from today's ranking. "
          'Premium opens games from every period.',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopScrollHost(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Games the community loves.',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Every like on ChessEver, on desktop, web and phone, counts '
                  'toward one shared ranking.',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                Table(
                  columnWidths: const {
                    0: IntrinsicColumnWidth(),
                    1: FlexColumnWidth(),
                  },
                  children: [
                    for (var i = 0; i < _rules.length; i++)
                      TableRow(
                        children: [
                          Padding(
                            padding: EdgeInsets.only(
                              right: 20,
                              bottom: i == _rules.length - 1 ? 0 : 14,
                            ),
                            child: Text(
                              _rules[i].$1,
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: i == _rules.length - 1 ? 0 : 14,
                            ),
                            child: Text(
                              _rules[i].$2,
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 30),
                const Text(
                  'The games you liked are saved in Library, under My Likes. '
                  'Most liked there brings you back here.',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _LikesActionButton(
                    label: 'Open Library',
                    icon: Icons.collections_bookmark_outlined,
                    onPress:
                        () => ref
                            .read(desktopTabsProvider.notifier)
                            .open(TabKind.library),
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

/// Stands in for an empty ranking: moves the tab to the nearest ranking with
/// a game (a wider period holding this one, then earlier ones), so a new week,
/// month or day never opens on "No games liked". The empty message shows only
/// when no ranking has a game yet.
class _EmptyRankingFallback extends ConsumerStatefulWidget {
  const _EmptyRankingFallback({
    super.key,
    required this.query,
    required this.emptyTitle,
  });

  final CommunityLikesQuery query;
  final String emptyTitle;

  @override
  ConsumerState<_EmptyRankingFallback> createState() =>
      _EmptyRankingFallbackState();
}

class _EmptyRankingFallbackState extends ConsumerState<_EmptyRankingFallback> {
  bool _searching = true;

  @override
  void initState() {
    super.initState();
    _fallBack();
  }

  Future<void> _fallBack() async {
    final pick = await firstRankedCommunityLikesQuery(
      communityLikesFallbackQueries(widget.query),
      (query) => ref.read(communityLikesProvider(query).future),
    );
    if (!mounted) return;
    // Only if the tab still shows the empty ranking this search began from.
    if (pick != null &&
        communityLikesActiveQuery(ref, now: DateTime.now()) == widget.query) {
      final now = DateTime.now();
      ref.read(communityLikesPeriodProvider.notifier).state = pick.period;
      ref.read(communityLikesDayProvider.notifier).state =
          pick.isCurrent(now) ? null : pick.start;
      return;
    }
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_searching) return const _Spinner();
    return _Message(
      title: widget.emptyTitle,
      body:
          'A game enters the ranking once two people like it. '
          'Open a game and press its heart to add yours.',
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kWhiteColor70, fontSize: 13),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              _LikesActionButton(
                label: actionLabel!,
                icon: Icons.refresh_rounded,
                onPress: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Preserve the shell's toolbar appearance while making every ranking action
/// reachable with one Tab stop, Enter and Space.
class _LikesActionButton extends StatelessWidget {
  const _LikesActionButton({
    required this.label,
    required this.icon,
    required this.onPress,
    this.height = 34,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPress;
  final double height;

  @override
  Widget build(BuildContext context) => DesktopKeyboardAction(
    label: label,
    onPress: onPress,
    child: DesktopToolbarPillButton(
      label: label,
      icon: icon,
      height: height,
      onPress: onPress,
    ),
  );
}
