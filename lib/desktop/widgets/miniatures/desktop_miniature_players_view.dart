import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/services/desktop_local_day_clock.dart';
import 'package:chessever/desktop/services/miniature_game_open.dart';
import 'package:chessever/desktop/services/miniatures_access.dart';
import 'package:chessever/desktop/state/desktop_miniature_players.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_lock_reasons.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/miniatures/miniature_players.dart';
import 'package:chessever/repository/gamebase/miniatures/miniatures_order.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// One player's miniatures, newest UTC day first, then average rating.
final desktopMiniaturePlayerGamesProvider = FutureProvider.autoDispose
    .family<List<GamesTourModel>, String>((ref, playerId) async {
      final page = await ref
          .read(gamebaseRepositoryProvider)
          .getMiniatures(
            filter: MiniatureGamesFilter.defaultFilter.copyWith(
              playerId: playerId,
            ),
            limit: 50,
          );
      return orderMiniaturesByDayAndAverageRating(
        page.items,
      ).map(miniatureGameFromGamebase).toList(growable: false);
    });

/// Miniatures Players: the rating leaderboard on the left, the selected
/// player's miniature scorecard on the right.
class DesktopMiniaturePlayersView extends HookConsumerWidget {
  const DesktopMiniaturePlayersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(desktopMiniaturePlayersQueryProvider);
    final state = ref.watch(desktopMiniaturePlayersProvider);
    final selected = useState<ChessPlayer?>(null);
    final searchController = useTextEditingController(text: query.search);
    final debounce = useRef<Timer?>(null);
    final scrollController = useScrollController();
    useEffect(() => () => debounce.value?.cancel(), const []);
    useEffect(() {
      void onScroll() {
        final position = scrollController.position;
        if (position.pixels >= position.maxScrollExtent - 320) {
          unawaited(
            ref.read(desktopMiniaturePlayersProvider.notifier).loadMore(),
          );
        }
      }

      scrollController.addListener(onScroll);
      return () => scrollController.removeListener(onScroll);
    }, [scrollController]);

    void updateQuery(DesktopMiniaturePlayersQuery next) {
      ref.read(desktopMiniaturePlayersQueryProvider.notifier).state = next;
    }

    Widget list;
    if (state.items.isEmpty && state.isLoading) {
      list = const _Spinner();
    } else if (state.items.isEmpty && state.error != null) {
      list = _Message(
        title: "Couldn't load players",
        body: 'Check your connection and try again.',
        actionLabel: 'Retry',
        onAction:
            () => ref.read(desktopMiniaturePlayersProvider.notifier).refresh(),
      );
    } else if (state.items.isEmpty) {
      list = const _Message(
        title: 'No players found',
        body: 'Try another name or title.',
      );
    } else {
      list = ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 0, 16, 24),
        itemCount: state.items.length + (state.isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.items.length) return const _Spinner();
          final player = state.items[index];
          return _PlayerRow(
            rank: index + 1,
            player: player,
            selected: selected.value?.fideid == player.fideid,
            onTap: () => selected.value = player,
          );
        },
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: DesktopSearchField(
                        controller: searchController,
                        hintText: 'Search players',
                        onChanged: (value) {
                          debounce.value?.cancel();
                          debounce.value = Timer(
                            const Duration(milliseconds: 300),
                            () => updateQuery(query.copyWith(search: value)),
                          );
                        },
                        onClear: () {
                          debounce.value?.cancel();
                          searchController.clear();
                          updateQuery(query.copyWith(search: ''));
                        },
                      ),
                    ),
                    for (final title in MiniaturePlayerTitle.values) ...[
                      const SizedBox(width: 6),
                      _TitleToggle(
                        label: title.label,
                        selected: query.titles.contains(title),
                        onPressed: () {
                          final next = <MiniaturePlayerTitle>{...query.titles};
                          if (!next.remove(title)) next.add(title);
                          updateQuery(query.copyWith(titles: next));
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 16, 6),
                child: _PlayerColumnsHeader(),
              ),
              Expanded(child: list),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: kDividerColor)),
            ),
            child:
                selected.value == null
                    ? const _Message(
                      title: 'Pick a player',
                      body: 'Their miniatures and W-L record show here.',
                    )
                    : DesktopMiniatureScorecard(
                      key: ValueKey(selected.value!.fideid),
                      player: selected.value!,
                    ),
          ),
        ),
      ],
    );
  }
}

const double _kRankColumn = 36;
const double _kRatingColumn = 56;
const double _kRecordColumn = 76;

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
      padding: EdgeInsets.fromLTRB(3, 0, 12, 0),
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
            width: _kRecordColumn,
            child: Text(
              'Miniatures',
              textAlign: TextAlign.right,
              style: _style,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerRow extends ConsumerStatefulWidget {
  const _PlayerRow({
    required this.rank,
    required this.player,
    required this.selected,
    required this.onTap,
  });

  final int rank;
  final ChessPlayer player;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_PlayerRow> createState() => _PlayerRowState();
}

class _PlayerRowState extends ConsumerState<_PlayerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final record =
        ref
            .watch(
              desktopMiniaturePlayerRecordProvider((
                fideId: player.fideid,
                name: player.name,
              )),
            )
            .valueOrNull;
    const tabular = [FontFeature.tabularFigures()];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.only(right: 12),
          decoration: librarySelectedRowDecoration(
            selected: widget.selected,
            hovered: _hovered,
          ),
          child: Row(
            children: [
              SizedBox(
                width: _kRankColumn,
                child: Text(
                  '${widget.rank}',
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
                  name: player.name,
                  federation: player.country ?? '',
                  fideId: player.fideid,
                  title: player.title ?? '',
                ),
              ),
              SizedBox(
                width: _kRatingColumn,
                child: Text(
                  player.rating?.toString() ?? '',
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
                width: _kRecordColumn,
                child: Text(
                  record?.winLossLabel ?? '',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    fontFeatures: tabular,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One player's miniatures: record header, then games by UTC day. Games are
/// drawn locked at rest when they are not free today and are re-checked when
/// opened.
class DesktopMiniatureScorecard extends ConsumerWidget {
  const DesktopMiniatureScorecard({super.key, required this.player});

  final ChessPlayer player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordAsync = ref.watch(
      desktopMiniaturePlayerRecordProvider((
        fideId: player.fideid,
        name: player.name,
      )),
    );
    final record = recordAsync.valueOrNull;
    final facts = <String>[
      if (player.rating != null) 'Rating ${player.rating}',
      if (record != null) record.winLossLabel,
      if (record?.fastestWin != null)
        'fastest win in ${record!.fastestWin} moves',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    if ((player.title ?? '').isNotEmpty)
                      TextSpan(
                        text: '${player.title} ',
                        style: const TextStyle(color: kLightYellowColor),
                      ),
                    TextSpan(text: player.name),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  facts.join('  ·  '),
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12.5,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: recordAsync.when(
            loading: () => const _Spinner(),
            error:
                (_, _) => _Message(
                  title: "Couldn't load this player's miniatures",
                  body: 'Check your connection and try again.',
                  actionLabel: 'Retry',
                  onAction:
                      () => ref.invalidate(
                        desktopMiniaturePlayerRecordProvider((
                          fideId: player.fideid,
                          name: player.name,
                        )),
                      ),
                ),
            data:
                (record) =>
                    record == null
                        ? const _Message(
                          title: 'No miniatures yet',
                          body: 'This player has no games in the index.',
                        )
                        : _ScorecardGames(
                          playerId: record.playerId,
                          routeTitle: player.name,
                        ),
          ),
        ),
      ],
    );
  }
}

class _ScorecardGames extends ConsumerWidget {
  const _ScorecardGames({required this.playerId, required this.routeTitle});

  final String playerId;
  final String routeTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gamesAsync = ref.watch(desktopMiniaturePlayerGamesProvider(playerId));
    final subscription = ref.watch(subscriptionProvider);
    final entitlement = ref.watch(desktopEntitlementProvider);
    ref.watch(desktopLocalDayProvider);

    return gamesAsync.when(
      loading: () => const _Spinner(),
      error:
          (_, _) => _Message(
            title: "Couldn't load miniatures",
            body: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction:
                () => ref.invalidate(
                  desktopMiniaturePlayerGamesProvider(playerId),
                ),
          ),
      data: (games) {
        if (games.isEmpty) {
          return const _Message(
            title: 'No miniatures yet',
            body: 'This player has no games in the index.',
          );
        }
        final groups = buildMiniatureDayGroups(games);
        return CustomScrollView(
          slivers: [
            for (var i = 0; i < groups.length; i++) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(24, i == 0 ? 0 : 14, 24, 6),
                sliver: SliverToBoxAdapter(
                  child: DesktopDateGroupCard(
                    label: groups[i].label,
                    gameCount: groups[i].games.length,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList.builder(
                  itemCount: groups[i].games.length,
                  itemBuilder: (context, index) {
                    final game = groups[i].games[index];
                    return _ScorecardGameRow(
                      game: game,
                      locked: miniatureGameIsLockedAtRest(
                        game,
                        subscription: subscription,
                        entitlement: entitlement,
                      ),
                      onOpen:
                          () => openMiniatureGame(
                            context,
                            ref,
                            game,
                            routeTitle: routeTitle,
                            routeGames: games,
                          ),
                    );
                  },
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

class _ScorecardGameRow extends StatefulWidget {
  const _ScorecardGameRow({
    required this.game,
    required this.locked,
    required this.onOpen,
  });

  final GamesTourModel game;
  final bool locked;
  final VoidCallback onOpen;

  @override
  State<_ScorecardGameRow> createState() => _ScorecardGameRowState();
}

class _ScorecardGameRowState extends State<_ScorecardGameRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final moves = game.boardNr;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.only(right: 12),
          decoration: librarySelectedRowDecoration(
            selected: false,
            hovered: _hovered,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Center(
                  child:
                      widget.locked
                          ? const DesktopLockGlyph(
                            reason: kMiniatureLockedReason,
                          )
                          : null,
                ),
              ),
              Expanded(
                child: DesktopDesaturated(
                  enabled: widget.locked,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: LibraryTablePlayerCell(
                          name: game.whitePlayer.name,
                          federation: game.whitePlayer.federation,
                          title: game.whitePlayer.title,
                          rating:
                              game.whitePlayer.rating > 0
                                  ? '${game.whitePlayer.rating}'
                                  : '',
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: LibraryTableResultPill(
                          result: switch (game.gameStatus) {
                            GameStatus.whiteWins => '1-0',
                            GameStatus.blackWins => '0-1',
                            _ => '',
                          },
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: LibraryTablePlayerCell(
                          name: game.blackPlayer.name,
                          federation: game.blackPlayer.federation,
                          title: game.blackPlayer.title,
                          rating:
                              game.blackPlayer.rating > 0
                                  ? '${game.blackPlayer.rating}'
                                  : '',
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          moves == null ? '' : '$moves moves',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TitleToggle extends StatefulWidget {
  const _TitleToggle({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_TitleToggle> createState() => _TitleToggleState();
}

class _TitleToggleState extends State<_TitleToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          // 34px toggle inside a 40px hit area.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              constraints: const BoxConstraints(minHeight: 34, minWidth: 44),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(
                          alpha: _hovered ? 0.16 : 0.10,
                        )
                        : (_hovered ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.35)
                          : kDividerColor,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color:
                      selected
                          ? kPrimaryColor
                          : (_hovered ? kWhiteColor : kWhiteColor70),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
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
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              DesktopToolbarPillButton(
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
