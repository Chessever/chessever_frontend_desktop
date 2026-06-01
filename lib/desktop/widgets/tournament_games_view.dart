import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailGamesSearchByTabIdProvider;
import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
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
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/round_expansion_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/theme/app_theme.dart';

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
  });

  final String tabId;
  final String tournamentId;

  @override
  ConsumerState<TournamentGamesView> createState() =>
      _TournamentGamesViewState();
}

class _TournamentGamesViewState extends ConsumerState<TournamentGamesView> {
  late final TextEditingController _searchController;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Seed from the per-tab provider so search text restores after the tab
    // has been flipped to a Board route and back (which disposes this
    // state). The provider survives because it's owned by the
    // ProviderContainer, not the widget tree.
    final persisted = ref.read(
      tournamentDetailGamesSearchByTabIdProvider(widget.tabId),
    );
    _searchController = TextEditingController(text: persisted);
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
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _runSearch(String q) {
    ref.read(tournamentDetailGamesSearchByTabIdProvider(widget.tabId).notifier).state = q;
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

  @override
  Widget build(BuildContext context) {
    final grouped = ref.watch(gamesTourGroupedProvider);
    final tournamentTitle = ref.watch(activeTournamentProvider)?.title ?? '';
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
    // Keyboard nav must only step through games that are currently visible.
    // When a round is collapsed via `roundExpansionProvider` its games stay
    // in `grouped.allGames` but the rows aren't rendered — stepping into
    // those would land the highlight on an invisible item with no
    // `currentContext` for `Scrollable.ensureVisible`. Filter to expanded
    // rounds only. Rounds default to expanded when unset (matches
    // `_RoundSection.build`).
    final roundExpansion = ref.watch(roundExpansionProvider);
    final keyboardGames = <GamesTourModel>[
      for (final round in grouped.filteredRounds)
        if (roundExpansion[round.id] ?? true)
          ...(grouped.gamesByRound[round.id] ?? const <GamesTourModel>[]),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
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
        ),
        if (grouped.isLoading)
          const Expanded(child: _LoadingState())
        else if (grouped.filteredRounds.isEmpty &&
            grouped.matchFormatHeader == null)
          Expanded(
            child:
                _searchController.text.trim().isNotEmpty
                    ? _NoSearchResults(query: _searchController.text.trim())
                    : const _NoRoundsState(),
          )
        else ...[
          Expanded(
            child: DesktopGameKeyboardFocus(
              scopeId: 'tournament:${widget.tournamentId}',
              games: keyboardGames,
              onActivateGame:
                  (game) => openTournamentGameTab(
                    ref,
                    game,
                    tournamentTitle,
                    eventGames: grouped.allGames,
                    roundNameById: roundNameById,
                  ),
              builder:
                  (context, selectedGameId, selectGame, keyForGame) => ListView(
                    key: PageStorageKey<String>(
                      'tournament-detail-games:${widget.tabId}',
                    ),
                    physics: const DesktopScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    children: [
                      // Match-format tournaments (e.g. "12-game Match" — Carlsen vs
                      // Nepo) get a single match summary card on top of the rounds.
                      if (grouped.matchFormatHeader != null)
                        _MatchHeaderBanner(match: grouped.matchFormatHeader!),
                      for (final round in grouped.filteredRounds)
                        _RoundSection(
                          key: ValueKey('round-${round.id}'),
                          scopeId: 'tournament:${widget.tournamentId}',
                          selectedGameId: selectedGameId,
                          onSelectGame: selectGame,
                          keyForGame: keyForGame,
                          round: round,
                          games: grouped.gamesByRound[round.id] ?? const [],
                          eventGames: grouped.allGames,
                          tournamentTitle: tournamentTitle,
                          layout: layout,
                          isKnockout: grouped.isKnockoutTournament,
                          roundStartsAtById: roundStartsAtById,
                          roundNameById: roundNameById,
                        ),
                    ],
                  ),
            ),
          ),
        ],
      ],
    );
  }
}

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

class _RoundSection extends ConsumerWidget {
  const _RoundSection({
    super.key,
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.round,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.isKnockout,
    required this.roundStartsAtById,
    required this.roundNameById,
  });

  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final GamesAppBarModel round;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final bool isKnockout;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(roundExpansionProvider)[round.id] ?? true;

    // For knockout-style stages, group repeated head-to-head games into
    // match cards (Carlsen vs Nepo: Game 1 / Game 2 / Tiebreak).
    final showMatches =
        isKnockout && KnockoutMatchDetector.isKnockoutMatchFormat(games);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RoundHeaderCard(
            round: round,
            gameCount: games.length,
            expanded: expanded,
            onToggle:
                () => ref
                    .read(roundExpansionProvider.notifier)
                    .toggleRound(round.id),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            if (showMatches)
              _MatchesList(
                scopeId: scopeId,
                selectedGameId: selectedGameId,
                onSelectGame: onSelectGame,
                keyForGame: keyForGame,
                games: games,
                eventGames: eventGames,
                tournamentTitle: tournamentTitle,
                layout: layout,
                roundStartsAtById: roundStartsAtById,
                roundNameById: roundNameById,
              )
            else if (layout == DesktopCardLayout.grid)
              _GamesGrid(
                scopeId: scopeId,
                selectedGameId: selectedGameId,
                onSelectGame: onSelectGame,
                keyForGame: keyForGame,
                games: games,
                eventGames: eventGames,
                tournamentTitle: tournamentTitle,
                roundStartsAtById: roundStartsAtById,
                roundNameById: roundNameById,
              )
            else
              _GamesList(
                scopeId: scopeId,
                selectedGameId: selectedGameId,
                onSelectGame: onSelectGame,
                keyForGame: keyForGame,
                games: games,
                eventGames: eventGames,
                tournamentTitle: tournamentTitle,
                layout: layout,
                roundStartsAtById: roundStartsAtById,
                roundNameById: roundNameById,
              ),
          ],
        ],
      ),
    );
  }
}

class _GamesList extends ConsumerWidget {
  const _GamesList({
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.roundStartsAtById,
    required this.roundNameById,
  });
  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;

  /// One of the *vertical* layouts — [DesktopCardLayout.list] or
  /// [DesktopCardLayout.compact]. Grid renders through [_GamesGrid].
  final DesktopCardLayout layout;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopGameCardsFlow(
      layout: layout,
      itemCount: games.length,
      embedded: true,
      itemBuilder: (context, i) {
        final game = games[i];
        return DesktopGameKeyboardItem(
          itemKey: keyForGame(game.gameId),
          gameId: game.gameId,
          onSelect: onSelectGame,
          child: LiveDesktopGameCard(
            game: game,
            eventGames: eventGames,
            tournamentTitle: tournamentTitle,
            layout: layout,
            selected: selectedGameId == game.gameId,
            roundStartsAtById: roundStartsAtById,
            roundNameById: roundNameById,
          ),
        );
      },
    );
  }
}

class _GamesGrid extends ConsumerWidget {
  const _GamesGrid({
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.roundStartsAtById,
    required this.roundNameById,
  });
  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetWidth = 280.0;
        final columns = (constraints.maxWidth / targetWidth).floor().clamp(
          2,
          6,
        );
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: games.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
          ),
          itemBuilder:
              (context, i) => DesktopGameKeyboardItem(
                itemKey: keyForGame(games[i].gameId),
                gameId: games[i].gameId,
                onSelect: onSelectGame,
                child: LiveDesktopGameCard(
                  game: games[i],
                  eventGames: eventGames,
                  tournamentTitle: tournamentTitle,
                  layout: DesktopCardLayout.grid,
                  selected: selectedGameId == games[i].gameId,
                  roundStartsAtById: roundStartsAtById,
                  roundNameById: roundNameById,
                ),
              ),
        );
      },
    );
  }
}

class _MatchesList extends ConsumerWidget {
  const _MatchesList({
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.games,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.roundStartsAtById,
    required this.roundNameById,
  });

  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final List<GamesTourModel> games;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupedByMatch = KnockoutMatchDetector.groupByMatches(games);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in groupedByMatch.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MatchSection(
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
              roundStartsAtById: roundStartsAtById,
              roundNameById: roundNameById,
            ),
          ),
      ],
    );
  }
}

class _MatchSection extends StatefulWidget {
  const _MatchSection({
    required this.scopeId,
    required this.selectedGameId,
    required this.onSelectGame,
    required this.keyForGame,
    required this.header,
    required this.eventGames,
    required this.tournamentTitle,
    required this.layout,
    required this.roundStartsAtById,
    required this.roundNameById,
  });

  final String scopeId;
  final String? selectedGameId;
  final ValueChanged<String> onSelectGame;
  final Key Function(String gameId) keyForGame;
  final MatchHeaderModel header;
  final List<GamesTourModel> eventGames;
  final String tournamentTitle;
  final DesktopCardLayout layout;
  final Map<String, DateTime?> roundStartsAtById;
  final Map<String, String> roundNameById;

  @override
  State<_MatchSection> createState() => _MatchSectionState();
}

class _MatchSectionState extends State<_MatchSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final h = widget.header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MatchSectionHeader(
          header: h,
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          if (widget.layout == DesktopCardLayout.grid)
            _GamesGrid(
              scopeId: widget.scopeId,
              selectedGameId: widget.selectedGameId,
              onSelectGame: widget.onSelectGame,
              keyForGame: widget.keyForGame,
              games: h.games,
              eventGames: widget.eventGames,
              tournamentTitle: widget.tournamentTitle,
              roundStartsAtById: widget.roundStartsAtById,
              roundNameById: widget.roundNameById,
            )
          else
            _GamesList(
              scopeId: widget.scopeId,
              selectedGameId: widget.selectedGameId,
              onSelectGame: widget.onSelectGame,
              keyForGame: widget.keyForGame,
              games: h.games,
              eventGames: widget.eventGames,
              tournamentTitle: widget.tournamentTitle,
              layout: widget.layout,
              roundStartsAtById: widget.roundStartsAtById,
              roundNameById: widget.roundNameById,
            ),
        ],
      ],
    );
  }
}

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
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color:
                        h.isComplete
                            ? kPrimaryColor.withValues(alpha: 0.15)
                            : kGreenColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color:
                          h.isComplete
                              ? kPrimaryColor.withValues(alpha: 0.4)
                              : kGreenColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    h.isComplete ? 'MATCH' : 'IN PROGRESS',
                    style: TextStyle(
                      color: h.isComplete ? kPrimaryColor : kGreenColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    h.matchTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: kBackgroundColor,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: Text(
                    h.scoreDisplay,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
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
/// Opens a Board tab keyed to this game immediately from the tapped card's
/// cached data. Slow PGN / event-list hydration happens after the tab is
/// visible; the BoardPane already hydrates missing PGNs by `gameId`.
///
/// Plain clicks use [replaceActive] so a game opens in the tab the user is
/// currently reading, even if another copy of that game is already open.
/// Explicit new-tab gestures (Cmd/Ctrl-click, middle-click, tab-strip drop)
/// pass `replaceActive: false` and `reuseExisting: false`.
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
}) async {
  // Capture the ProviderContainer up front. `ref` belongs to the widget
  // that owns the tap (often a LiveDesktopGameCard whose live-stream
  // rebuild can dispose the card while we await the PGN fetch below),
  // and Riverpod asserts on `ref.read` once the underlying element is
  // unmounted — which used to swallow the click silently. The container
  // is held by the surrounding ProviderScope and survives card disposal.
  final container = ProviderScope.containerOf(
    ref as BuildContext,
    listen: false,
  );
  final gameRepo = container.read(gameRepositoryProvider);

  final pgn = pgnHasMoves(game.pgn) ? game.pgn!.trim() : '';
  final eventSummaries = _summariesFromModels(
    eventGames.isEmpty ? <GamesTourModel>[game] : eventGames,
    fallbackGame: game,
    roundStartsAtById: roundStartsAtById,
    roundNameById: roundNameById,
  );
  final routeSummaries =
      routeGames.isEmpty
          ? const <TournamentGameSummary>[]
          : _summariesFromModels(
            routeGames,
            fallbackGame: game,
            roundStartsAtById: roundStartsAtById,
            roundNameById: roundNameById,
          );
  // Favorites open paths pass their own multi-tournament list; never
  // overwrite it with the single-tournament hydrate. Otherwise the rail
  // would flip back to "tournament games" the moment the fetch completed.
  final isFavoritesView = viewSource == ChessboardView.favScorecard;
  final shouldHydrateEventGames =
      !isFavoritesView &&
      eventSummaries.length <= 1 &&
      game.tourId.trim().isNotEmpty;
  final args = BoardTabGameArgs(
    gameId: game.gameId,
    pgn: pgn,
    label: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
    whiteName: game.whitePlayer.name,
    blackName: game.blackPlayer.name,
    whiteFederation: game.whitePlayer.federation,
    blackFederation: game.blackPlayer.federation,
    whiteTitle: game.whitePlayer.title,
    blackTitle: game.blackPlayer.title,
    whiteRating: game.whitePlayer.rating,
    blackRating: game.blackPlayer.rating,
    whiteFideId: game.whitePlayer.fideId,
    blackFideId: game.blackPlayer.fideId,
    fenSeed: game.fen,
    sourceGame: game.copyWith(pgn: pgn.isEmpty ? game.pgn : pgn),
    viewSource: viewSource,
    tournamentTitle: tournamentTitle,
    eventGames: eventSummaries,
    eventGamesLoading: shouldHydrateEventGames,
    eventGamesContinuation: eventGamesContinuation,
    routeTitle: routeTitle,
    routeGames: routeSummaries,
    routeGamesContinuation: routeGamesContinuation,
    gameListSelectedId: game.gameId,
  );
  container.read(chessboardViewFromProviderNew.notifier).state = viewSource;
  final tabId = openBoardGameTabFromContainer(
    container,
    args,
    focus: focus,
    reuseExisting: reuseExisting,
    replaceActive: replaceActive,
  );

  if (shouldHydrateEventGames) {
    unawaited(
      _hydrateTournamentGameTabEventContext(
        container: container,
        gameRepo: gameRepo,
        tabId: tabId,
        game: game,
        eventGames: eventGames,
        roundStartsAtById: roundStartsAtById,
        roundNameById: roundNameById,
      ),
    );
  }
}

Future<List<TournamentGameSummary>> _resolveEventGameSummaries(
  GameRepository gameRepo,
  GamesTourModel game,
  List<GamesTourModel> eventGames,
  Map<String, DateTime?> roundStartsAtById,
  Map<String, String> roundNameById,
) async {
  final supplied = _summariesFromModels(
    eventGames.isEmpty ? <GamesTourModel>[game] : eventGames,
    fallbackGame: game,
    roundStartsAtById: roundStartsAtById,
    roundNameById: roundNameById,
  );
  if (supplied.length > 1 || game.tourId.trim().isEmpty) {
    return supplied;
  }

  try {
    final rows = await gameRepo.getGamesByTourId(game.tourId);
    final models = <GamesTourModel>[];
    for (final row in rows) {
      try {
        models.add(GamesTourModel.fromGame(row));
      } catch (_) {
        // Skip malformed rows; the active game summary below remains enough
        // to keep the board tab usable.
      }
    }
    final fetched = _summariesFromModels(
      models,
      fallbackGame: game,
      roundStartsAtById: roundStartsAtById,
      roundNameById: roundNameById,
    );
    return fetched.isEmpty ? supplied : fetched;
  } catch (_) {
    return supplied;
  }
}

Future<void> _hydrateTournamentGameTabEventContext({
  required ProviderContainer container,
  required GameRepository gameRepo,
  required String tabId,
  required GamesTourModel game,
  required List<GamesTourModel> eventGames,
  required Map<String, DateTime?> roundStartsAtById,
  required Map<String, String> roundNameById,
}) async {
  final hydrated = await _resolveEventGameSummaries(
    gameRepo,
    game,
    eventGames,
    roundStartsAtById,
    roundNameById,
  );

  final byTab = container.read(boardTabGameArgsByTabIdProvider);
  final current = byTab[tabId];
  if (current == null || current.gameId != game.gameId) return;
  if (_sameGameSummaryIds(current.eventGames, hydrated) &&
      !current.eventGamesLoading) {
    return;
  }

  container.read(boardTabGameArgsByTabIdProvider.notifier).update((m) {
    final latest = m[tabId];
    if (latest == null || latest.gameId != game.gameId) return m;
    return <String, BoardTabGameArgs>{
      ...m,
      tabId: latest.copyWith(eventGames: hydrated, eventGamesLoading: false),
    };
  });
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

bool _sameGameSummaryIds(
  List<TournamentGameSummary> a,
  List<TournamentGameSummary> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
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
}) {
  return GameTabDragPayload(
    id: game.gameId,
    label: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
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
/// last_move, clock, or status. Each instance creates its own Realtime
/// channel that auto-disposes when the card scrolls out of view, mirroring
/// mobile's `liveGameCardProvider` autoDispose behaviour — so a list with
/// 200 games doesn't keep 200 channels open once you scroll past them.
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
    this.enableContextMenu = true,
    this.viewSource = ChessboardView.tour,
    this.liveBatchKey,
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

  /// When false, the eval bar inside this card suppresses Stockfish fallback.
  /// Pass `false` while the host list is actively scrolling so we don't burn
  /// CPU evaluating boards that are about to leave the viewport.
  final bool allowStockfishFallback;

  /// Tap handler override. Defaults to the standard
  /// [openTournamentGameTab] flow so callers don't have to repeat the
  /// boilerplate; pass a custom callback (e.g. to land on a dedicated
  /// player score-card pane) when needed.
  final VoidCallback? onTap;

  /// When set together with [federationFallback], any side whose name
  /// matches and whose federation is empty inherits the fallback ISO2 code.
  /// Used by the player profile to honour the user's Countrymen selection
  /// when the profile player has no federation on file.
  final String? federationFallbackForName;
  final String? federationFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveGame = watchLiveGame(ref, game, batchKey: liveBatchKey);
    var data = GameCardData.fromGamesTourModel(liveGame);
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
    return DesktopGameCard(
      // Re-derive every rebuild so the eval bar's FEN, the status pill,
      // and the "In play"/result label pick up Realtime deltas.
      data: data,
      onTap:
          onTap ??
          () => openTournamentGameTab(
            ref,
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
          ),
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
      ),
      layout: layout,
      selected: selected,
      allowStockfishFallback: allowStockfishFallback,
    );
  }
}

enum _LiveGameContextAction {
  open,
  openNewTab,
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

class _NoRoundsState extends StatelessWidget {
  const _NoRoundsState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.event_note_outlined, size: 32, color: kLightGreyColor),
            SizedBox(height: 12),
            Text(
              'No rounds yet',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Tournament rounds will appear here once they\'re scheduled.',
              style: TextStyle(color: kLightGreyColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
