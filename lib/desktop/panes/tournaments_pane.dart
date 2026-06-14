import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/global_search_query.dart';
import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';
import 'package:chessever/desktop/utils/list_keyboard_nav.dart';
import 'package:chessever/desktop/utils/tournament_event_grid_layout.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_event_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_event_favorite_button.dart';
import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/screens/favorites/provider/favorites_mode_provider.dart';
import 'package:chessever/screens/group_event/group_event_screen.dart' as ge;
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/group_event/providers/supabase_combined_search_provider.dart';
import 'package:chessever/screens/group_event/smart_level_event.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_state.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/group_event_filter_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/location_service_provider.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/logo_pattern_fallback.dart';
import 'package:chessever/widgets/search/enhanced_group_broadcast_local_storage.dart';
import 'package:flutter_animate/flutter_animate.dart';

LiveGamesBatchKey _desktopForYouLiveBatchKey({
  required String eventId,
  required String tourId,
  required List<GamesTourModel> games,
}) {
  return LiveGamesBatchKey(
    scopeId: 'desktop_for_you:$eventId:$tourId',
    gameIds: games.map((game) => game.gameId),
  );
}

/// Desktop tournaments pane.
///
/// Wraps the same `groupEventScreenProvider` the mobile screen drives. The
/// difference is purely presentational: instead of a swipable PageView of
/// large cards, we render top Forui tabs, search, a For You feed, and a
/// responsive Current/Past event-card grid for desktop tournament discovery.
///
/// This is the first pane fed by real Supabase data; until the user is
/// signed in (or the provider can fetch anonymously) the list shows the
/// loading or empty state coming straight off the existing AsyncValue.
class TournamentsPane extends HookConsumerWidget {
  const TournamentsPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTournamentId = useState<String?>(null);
    final loadingId = useState<String?>(null);
    final selectedCategory = ref.watch(ge.selectedGroupCategoryProvider);
    final forYouFilterState = ref.watch(forYouAppliedFilterProvider);
    final currentPastFilterState = ref.watch(currentPastAppliedFilterProvider);
    final selectedFilterState =
        selectedCategory == ge.GroupEventCategory.forYou
            ? forYouFilterState
            : currentPastFilterState;
    final activeFilterCount = _activeEventFilterCount(selectedFilterState);
    final globalSearchQuery = ref.watch(desktopGlobalSearchQueryProvider);
    // Stable per-tournament-id GlobalKeys so we can `Scrollable.ensureVisible`
    // the highlighted row when the user navigates with the arrow keys.
    final tileKeys = useRef(<String, GlobalKey>{});
    final listFocusNode = useFocusNode(debugLabel: 'tournaments-list');
    final listScrollController = useScrollController();

    // The "For You" tab is fed by a different provider in the mobile app —
    // forYouEventsProvider holds personalized recommendations rather than
    // the global Current/Past list. Mirror that wiring on desktop so the
    // category actually surfaces useful data.
    final asyncTournaments =
        selectedCategory == ge.GroupEventCategory.forYou
            ? ref.watch(forYouEventsProvider).toAsyncValue()
            : ref.watch(groupEventScreenProvider);

    // Match the mobile screen: refresh stale data when the user lands on
    // the For You tab.
    useEffect(() {
      if (selectedCategory == ge.GroupEventCategory.forYou) {
        Future<void>(() async {
          await ref.read(forYouEventsProvider.notifier).refreshIfStale();
        });
      }
      return null;
    }, [selectedCategory]);
    useEffect(() {
      selectedTournamentId.value = null;
      return null;
    }, [selectedCategory, globalSearchQuery]);

    Future<void> openTournament(GroupEventCardModel tournament) async {
      // Plain click navigates the current Tournaments tab into the event's
      // game-list scene. Cmd/Ctrl-click takes the browser-style new-tab path.
      setActiveTournament(
        ref,
        tournament,
        openInNewTab: isNewTabModifierPressed(),
      );
    }

    final searchQuery = globalSearchQuery?.trim() ?? '';
    final hasQuery = searchQuery.length >= 2;

    void openFilters() {
      ref.read(filterPopupProvider.notifier).setState(selectedFilterState);
      showFDialog<void>(
        context: context,
        builder:
            (dialogContext, _, animation) => _DesktopEventFilterDialog(
              animation: animation,
              initialCategory: selectedCategory,
              onApply: (filterState) {
                if (selectedCategory == ge.GroupEventCategory.forYou) {
                  ref.read(forYouAppliedFilterProvider.notifier).state =
                      filterState;
                  ref.invalidate(forYouEventsProvider);
                } else {
                  ref.read(currentPastAppliedFilterProvider.notifier).state =
                      filterState;
                }
                Navigator.of(dialogContext).pop();
              },
              onReset: () {
                if (selectedCategory == ge.GroupEventCategory.forYou) {
                  ref.read(forYouAppliedFilterProvider.notifier).state =
                      defaultFilterPopupState;
                  ref.invalidate(forYouEventsProvider);
                } else {
                  ref.read(currentPastAppliedFilterProvider.notifier).state =
                      defaultFilterPopupState;
                }
                ref
                    .read(filterPopupProvider.notifier)
                    .setState(defaultFilterPopupState);
                Navigator.of(dialogContext).pop();
              },
            ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DesktopSegmentedTabs<ge.GroupEventCategory>(
                    tabs: _categoryTabs,
                    selected: selectedCategory,
                    onChanged: (category) {
                      ref
                          .read(desktopGlobalSearchQueryProvider.notifier)
                          .state = null;
                      ref
                          .read(ge.selectedGroupCategoryProvider.notifier)
                          .state = category;
                    },
                  ),
                  const SizedBox(width: 10),
                  _DesktopEventFilterButton(
                    activeCount: activeFilterCount,
                    onPressed: openFilters,
                  ),
                  const Spacer(),
                  if (selectedCategory == ge.GroupEventCategory.forYou)
                    const GameViewModeToggle(),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child:
              hasQuery
                  ? _SearchResultsView(
                    query: searchQuery,
                    pendingQuery: null,
                    onClearSearch: () {
                      ref
                          .read(desktopGlobalSearchQueryProvider.notifier)
                          .state = null;
                    },
                    onOpenTournament: openTournament,
                  )
                  : selectedCategory == ge.GroupEventCategory.forYou
                  ? _ForYouFeed(tabId: tabId, onOpenTournament: openTournament)
                  : asyncTournaments.when(
                    data:
                        (tournaments) => Focus(
                          focusNode: listFocusNode,
                          autofocus: true,
                          canRequestFocus: true,
                          onKeyEvent: (node, event) {
                            if (tournaments.isEmpty) {
                              return KeyEventResult.ignored;
                            }
                            if (event is! KeyDownEvent &&
                                event is! KeyRepeatEvent) {
                              return KeyEventResult.ignored;
                            }
                            final key = event.logicalKey;
                            final isDown = key == LogicalKeyboardKey.arrowDown;
                            final isUp = key == LogicalKeyboardKey.arrowUp;
                            final isRight =
                                key == LogicalKeyboardKey.arrowRight;
                            final isLeft = key == LogicalKeyboardKey.arrowLeft;
                            final isPageDown =
                                key == LogicalKeyboardKey.pageDown;
                            final isPageUp = key == LogicalKeyboardKey.pageUp;
                            final isHome = key == LogicalKeyboardKey.home;
                            final isEnd = key == LogicalKeyboardKey.end;
                            final isEnter =
                                key == LogicalKeyboardKey.enter ||
                                key == LogicalKeyboardKey.numpadEnter;
                            if (!isDown &&
                                !isUp &&
                                !isRight &&
                                !isLeft &&
                                !isPageDown &&
                                !isPageUp &&
                                !isHome &&
                                !isEnd &&
                                !isEnter) {
                              return KeyEventResult.ignored;
                            }
                            final tournamentIds = [
                              for (final tournament in tournaments)
                                tournament.id,
                            ];
                            final base =
                                resolveTournamentEventGridSelectionIndex(
                                  ids: tournamentIds,
                                  selectedId: selectedTournamentId.value,
                                );
                            final currentTournament = tournaments[base];

                            void scrollEventIntoView(String id) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                final ctx = tileKeys.value[id]?.currentContext;
                                if (ctx != null) {
                                  Scrollable.ensureVisible(
                                    ctx,
                                    alignment: 0.5,
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOut,
                                  );
                                }
                              });
                            }

                            if (isEnter) {
                              openTournament(currentTournament);
                              return KeyEventResult.handled;
                            }

                            final paneWidth =
                                context.size?.width ??
                                MediaQuery.sizeOf(context).width;
                            final columns = calculateTournamentEventGridColumns(
                              paneWidth,
                            );
                            final intent = switch (key) {
                              LogicalKeyboardKey.arrowRight =>
                                TournamentEventGridNavigationIntent.right,
                              LogicalKeyboardKey.arrowLeft =>
                                TournamentEventGridNavigationIntent.left,
                              LogicalKeyboardKey.arrowDown =>
                                TournamentEventGridNavigationIntent.down,
                              LogicalKeyboardKey.arrowUp =>
                                TournamentEventGridNavigationIntent.up,
                              LogicalKeyboardKey.pageDown =>
                                TournamentEventGridNavigationIntent.pageDown,
                              LogicalKeyboardKey.pageUp =>
                                TournamentEventGridNavigationIntent.pageUp,
                              LogicalKeyboardKey.home =>
                                TournamentEventGridNavigationIntent.home,
                              LogicalKeyboardKey.end =>
                                TournamentEventGridNavigationIntent.end,
                              _ => null,
                            };
                            if (intent == null) {
                              return KeyEventResult.ignored;
                            }
                            final newIdx =
                                moveTournamentEventGridSelectionIndex(
                                  currentIndex: base,
                                  itemCount: tournaments.length,
                                  columns: columns,
                                  intent: intent,
                                  pageRows: kDesktopListPageStep,
                                );
                            if (newIdx == base) {
                              return KeyEventResult.handled;
                            }
                            final newTournament = tournaments[newIdx];
                            selectedTournamentId.value = newTournament.id;
                            scrollEventIntoView(newTournament.id);
                            return KeyEventResult.handled;
                          },
                          child: _TournamentBrowser(
                            tournaments: tournaments,
                            storageKey: PageStorageKey<String>(
                              'desktop_tournament_rows_${tabId}_${selectedCategory.name}',
                            ),
                            selectedId: selectedTournamentId.value,
                            onSelect: (id) {
                              selectedTournamentId.value = id;
                              listFocusNode.requestFocus();
                            },
                            onActivate: openTournament,
                            loadingId: loadingId.value,
                            tileKeys: tileKeys.value,
                            scrollController: listScrollController,
                            showSmartLevelEvent:
                                selectedCategory ==
                                ge.GroupEventCategory.current,
                          ),
                        ),
                    loading: () => const _LoadingState(),
                    error:
                        (e, _) => _ErrorState(
                          message: e.toString(),
                          onRetry: () => ref.refresh(groupEventScreenProvider),
                        ),
                  ),
        ),
      ],
    );
  }
}

/// Live search results body that hits [supabaseCombinedSearchProvider] and
/// renders both tournament hits and player hits inline. Replaces the
/// category sidebar + grid layout while a query is active.
class _SearchResultsView extends ConsumerWidget {
  const _SearchResultsView({
    required this.query,
    required this.pendingQuery,
    required this.onClearSearch,
    required this.onOpenTournament,
  });

  final String query;
  final String? pendingQuery;
  final VoidCallback onClearSearch;
  final void Function(GroupEventCardModel) onOpenTournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(supabaseCombinedSearchProvider(query));
    final isPending = pendingQuery != null;

    return async.when(
      loading: () => const _LoadingState(),
      error:
          (e, _) => _ErrorState(
            message: 'Search failed: $e',
            onRetry:
                () => ref.invalidate(supabaseCombinedSearchProvider(query)),
          ),
      data: (result) {
        if (result.isEmpty && !isPending) {
          return _EmptySearch(query: query);
        }
        return _SearchResultsBody(
          result: result,
          query: query,
          isPending: isPending,
          onClearSearch: onClearSearch,
          onOpenTournament: onOpenTournament,
          onOpenPlayer:
              (player) => openPlayerProfile(
                ref,
                PlayerProfileArgs(
                  playerName: player.name,
                  fideId: player.fideId,
                  title: player.title,
                  federation: player.fed,
                  rating: player.rating,
                ),
              ),
        );
      },
    );
  }
}

class _SearchResultsBody extends StatelessWidget {
  const _SearchResultsBody({
    required this.result,
    required this.query,
    required this.isPending,
    required this.onClearSearch,
    required this.onOpenTournament,
    required this.onOpenPlayer,
  });

  final EnhancedSearchResult result;
  final String query;
  final bool isPending;
  final VoidCallback onClearSearch;
  final void Function(GroupEventCardModel) onOpenTournament;
  final void Function(SearchPlayer) onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final tournaments = result.tournamentResults;
    final players = result.playerResults;
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        _SearchResultsHeader(query: query, onClear: onClearSearch),
        const SizedBox(height: 12),
        if (isPending)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Refreshing…',
                  style: TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
              ],
            ),
          ),
        if (players.isNotEmpty) ...[
          _SectionHeading(
            label: 'Players',
            icon: Icons.person_rounded,
            count: players.length,
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cols = width >= 1100 ? 4 : (width >= 800 ? 3 : 2);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 3.4,
                ),
                itemCount: players.length.clamp(0, 12),
                itemBuilder: (context, i) {
                  final r = players[i];
                  final p = r.player;
                  if (p == null) return const SizedBox.shrink();
                  return _PlayerSearchCard(
                    player: p,
                    onTap: () => onOpenPlayer(p),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 24),
        ],
        if (tournaments.isNotEmpty) ...[
          _SectionHeading(
            label: 'Events',
            icon: Icons.emoji_events_rounded,
            count: tournaments.length,
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cols = width >= 1280 ? 4 : (width >= 960 ? 3 : 2);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.35,
                ),
                itemCount: tournaments.length,
                itemBuilder: (context, i) {
                  final r = tournaments[i];
                  return _TournamentSearchTile(
                    tournament: r.tournament,
                    onTap: () => onOpenTournament(r.tournament),
                  );
                },
              );
            },
          ),
        ],
      ],
    );
  }
}

class _SearchResultsHeader extends StatelessWidget {
  const _SearchResultsHeader({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Search results for "$query"',
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ClickCursor(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child: const Text(
                'Clear',
                style: TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.label,
    required this.icon,
    required this.count,
  });

  final String label;
  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: kWhiteColor70),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kDividerColor),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 10,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _PlayerSearchCard extends StatefulWidget {
  const _PlayerSearchCard({required this.player, required this.onTap});
  final SearchPlayer player;
  final VoidCallback onTap;

  @override
  State<_PlayerSearchCard> createState() => _PlayerSearchCardState();
}

class _PlayerSearchCardState extends State<_PlayerSearchCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final pieces = <String>[
      if (p.fed != null && p.fed!.isNotEmpty) p.fed!.toUpperCase(),
      if (p.fideId != null && p.fideId! > 0) 'FIDE ${p.fideId}',
    ];
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: MotionCard(
            borderRadius: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _hovered ? kPrimaryColor : kDividerColor,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kBackgroundColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: kDividerColor),
                    ),
                    child: Text(
                      p.title ?? p.name.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        color: kPrimaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (p.fed != null && p.fed!.isNotEmpty) ...[
                              FederationFlag(
                                federation: p.fed,
                                width: 16,
                                height: 11,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
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
                        const SizedBox(height: 2),
                        Text(
                          pieces.isEmpty ? 'Player' : pieces.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (p.rating != null && p.rating! > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kBackgroundColor,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: kDividerColor),
                      ),
                      child: Text(
                        p.rating.toString(),
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
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

/// Wraps an event card (or any equivalent rectangular tappable) in the
/// same hover + press motion vocabulary the rest of the desktop tappables
/// use: a `motor` spring lifts the card a hair on hover, presses it back
/// in on tap, and the surrounding `AnimatedContainer` blooms a faint
/// primary-tinted halo + border so cursor presence is unmistakable.
///
/// Lives here (rather than inside the shared `widgets/event_card/`) so
/// the mobile app — which has no cursor — keeps using its existing
/// `TappableScale`-only treatment unchanged.
class _DesktopEventCardShell extends StatefulWidget {
  const _DesktopEventCardShell({
    required this.child,
    required this.onTap,
    this.onDoubleTap,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  // Matches the event card's own corner radius so the hover halo overlays
  // cleanly without a visible square edge.
  static const double _borderRadius = 12.0;

  @override
  State<_DesktopEventCardShell> createState() => _DesktopEventCardShellState();
}

class _DesktopEventCardShellState extends State<_DesktopEventCardShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(_DesktopEventCardShell._borderRadius);

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          child: MotionCard(
            borderRadius: _DesktopEventCardShell._borderRadius,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                widget.child,
                // Hover/selected overlay sits *above* the card so the
                // halo is visible even on the dark image-as-background
                // tablet layout. IgnorePointer keeps clicks falling
                // through to the gesture detector below. Hover/press
                // shadow is now owned by MotionCard; the border tint
                // stays here.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color:
                              _hovered
                                  ? kWhiteColor.withValues(alpha: 0.12)
                                  : Colors.transparent,
                          width: 1.5,
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

class _TournamentSearchTile extends StatelessWidget {
  const _TournamentSearchTile({required this.tournament, required this.onTap});

  final GroupEventCardModel tournament;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DesktopEventContextMenu(
      event: tournament,
      onOpen: onTap,
      child: _DesktopEventCardShell(
        onTap: onTap,
        onDoubleTap: onTap,
        child: _EventPosterCard(event: tournament),
      ),
    );
  }
}

class _EventPosterCard extends StatelessWidget {
  const _EventPosterCard({required this.event});

  final GroupEventCardModel event;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(event.tourEventCategory);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _DesktopEventVisual(event: event, borderRadius: BorderRadius.zero),
          DecoratedBox(
            decoration: BoxDecoration(
              color: kBlackColor.withValues(alpha: 0.5),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            right: 12,
            child: Row(
              children: [
                _StatusBadge(category: event.tourEventCategory),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.timeControl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DesktopEventFavoriteIconButton(event: event, compact: true),
              ],
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  event.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.18,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _eventMetaLine(event),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.open_in_new_rounded, size: 14, color: color),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopEventVisual extends ConsumerWidget {
  const _DesktopEventVisual({required this.event, required this.borderRadius});

  final GroupEventCardModel event;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: kBlack3Color,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fallbackCountry = _countryCodeFromLocation(
              ref,
              event.location,
            );
            if (event.eventSource == EventSource.communityEvent) {
              return _EventFallbackVisual(countryCode: fallbackCountry);
            }

            final width =
                constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : (constraints.maxHeight.isFinite
                        ? constraints.maxHeight * 1.6
                        : 360.0);
            final cacheWidth =
                (width * MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(160, 1800)
                    .toInt();
            final image = ref.watch(eventImageProvider(event.id));

            return image.when(
              data: (data) {
                final countryCode = data.fallbackCountryCode ?? fallbackCountry;
                if (data.hasImage) {
                  return CachedNetworkImage(
                    imageUrl: data.imageUrl!,
                    fit: BoxFit.cover,
                    memCacheWidth: cacheWidth,
                    fadeInDuration: const Duration(milliseconds: 180),
                    fadeOutDuration: const Duration(milliseconds: 120),
                    placeholder: (_, __) => const _EventImageSkeleton(),
                    errorWidget:
                        (_, __, ___) =>
                            _EventFallbackVisual(countryCode: countryCode),
                  );
                }
                return _EventFallbackVisual(countryCode: countryCode);
              },
              loading: () => const _EventImageSkeleton(),
              error:
                  (_, __) => _EventFallbackVisual(countryCode: fallbackCountry),
            );
          },
        ),
      ),
    );
  }
}

class _EventThumbnailVisual extends StatelessWidget {
  const _EventThumbnailVisual({
    required this.event,
    required this.statusColor,
    required this.selected,
  });

  final GroupEventCardModel event;
  final Color statusColor;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      height: 58,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _DesktopEventVisual(
            event: event,
            borderRadius: BorderRadius.circular(7),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(7),
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    selected
                        ? statusColor.withValues(alpha: 0.34)
                        : kWhiteColor.withValues(alpha: 0.08),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventImageSkeleton extends StatelessWidget {
  const _EventImageSkeleton();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(decoration: BoxDecoration(color: kBlack3Color));
  }
}

class _EventFallbackVisual extends StatelessWidget {
  const _EventFallbackVisual({required this.countryCode});

  final String? countryCode;

  @override
  Widget build(BuildContext context) {
    final code = countryCode;
    if (code != null && code.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 90,
              height: 60,
              child: CountryFlag.fromCountryCode(code),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: kBlackColor.withValues(alpha: 0.18),
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(decoration: BoxDecoration(color: Color(0xFF1B2024))),
        const LogoPatternFallback(),
        Center(
          child: Icon(
            Icons.emoji_events_rounded,
            size: 28,
            color: kWhiteColor.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}

String? _countryCodeFromLocation(WidgetRef ref, String? location) {
  if (location == null || location.trim().isEmpty) return null;
  final locationService = ref.read(locationServiceProvider);
  final direct = locationService.getValidCountryCode(location.trim());
  if (direct.isNotEmpty) return direct.toUpperCase();

  for (final part in location.split(RegExp(r'[,|/]'))) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;

    final fromCode = locationService.getValidCountryCode(trimmed);
    if (fromCode.isNotEmpty) return fromCode.toUpperCase();

    final fromName = locationService.getValidCountryCodeFromName(trimmed);
    if (fromName.isNotEmpty) return fromName.toUpperCase();
  }

  return null;
}

class _EmptySearch extends StatelessWidget {
  const _EmptySearch({required this.query});
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
              'No matches for "$query"',
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try a player surname, an event keyword, or a country code.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Adapter that lets us drop a `ForYouState` (the State, not AsyncValue) into
/// the same `.when(data, loading, error)` switch the rest of the pane uses.
extension on ForYouState {
  AsyncValue<List<GroupEventCardModel>> toAsyncValue() {
    if (error != null) return AsyncValue.error(error!, StackTrace.empty);
    if (isLoading && events.isEmpty) return const AsyncValue.loading();
    return AsyncValue.data(events);
  }
}

const List<DesktopSegmentedTab<ge.GroupEventCategory>> _categoryTabs = [
  DesktopSegmentedTab(
    value: ge.GroupEventCategory.forYou,
    label: 'For You',
    icon: Icons.auto_awesome_outlined,
  ),
  DesktopSegmentedTab(
    value: ge.GroupEventCategory.current,
    label: 'Current',
    icon: Icons.bolt_outlined,
  ),
  DesktopSegmentedTab(
    value: ge.GroupEventCategory.past,
    label: 'Past',
    icon: Icons.history_outlined,
  ),
];

int _activeEventFilterCount(FilterPopupState state) {
  final rangeChanged =
      state.eloRange.start > defaultFilterPopupState.eloRange.start ||
      state.eloRange.end < defaultFilterPopupState.eloRange.end;
  return state.formatsAndStates.length + (rangeChanged ? 1 : 0);
}

class _DesktopEventFilterButton extends StatelessWidget {
  const _DesktopEventFilterButton({
    required this.activeCount,
    required this.onPressed,
  });

  final int activeCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isActive = activeCount > 0;
    return FButton(
      style: isActive ? FButtonStyle.primary() : FButtonStyle.outline(),
      prefix: const Icon(Icons.tune_rounded, size: 14),
      onPress: onPressed,
      child: Text(isActive ? 'Filters $activeCount' : 'Filters'),
    );
  }
}

class _DesktopEventFilterDialog extends ConsumerWidget {
  const _DesktopEventFilterDialog({
    required this.animation,
    required this.initialCategory,
    required this.onApply,
    required this.onReset,
  });

  final Animation<double> animation;
  final ge.GroupEventCategory initialCategory;
  final ValueChanged<FilterPopupState> onApply;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(filterPopupProvider);
    final filterController = ref.read(groupEventFilterProvider);
    final formatLabels = filterController.getReadableFormats();
    final formats = filterController.getFormats();
    final statusLabels = filterController.getReadableGameState();
    final statuses = filterController.getGameState();

    return FDialog(
      animation: animation,
      direction: Axis.horizontal,
      title: const Text('Event filters'),
      body: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              initialCategory == ge.GroupEventCategory.forYou
                  ? 'For You feed'
                  : 'Current and Past events',
              style: const TextStyle(color: kLightGreyColor, fontSize: 12),
            ),
            const SizedBox(height: 16),
            const _DesktopFilterSectionLabel('Format'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < formats.length; i++)
                  _DesktopFilterChip(
                    label: formatLabels[i],
                    selected: state.formatsAndStates.contains(formats[i]),
                    onPressed:
                        () => ref
                            .read(filterPopupProvider.notifier)
                            .toggleFormatOrState(formats[i]),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const _DesktopFilterSectionLabel('Event status'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < statuses.length; i++)
                  _DesktopFilterChip(
                    label: statusLabels[i],
                    selected: state.formatsAndStates.contains(statuses[i]),
                    onPressed:
                        () => ref
                            .read(filterPopupProvider.notifier)
                            .toggleFormatOrState(statuses[i]),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const _DesktopFilterSectionLabel('Average rating'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DesktopRatingPresetChip(
                  label: 'All ratings',
                  range: defaultFilterPopupState.eloRange,
                  state: state,
                ),
                _DesktopRatingPresetChip(
                  label: '2600+',
                  range: const RangeValues(2600, 3200),
                  state: state,
                ),
                _DesktopRatingPresetChip(
                  label: '2400–2599',
                  range: const RangeValues(2400, 2599),
                  state: state,
                ),
                _DesktopRatingPresetChip(
                  label: 'Under 2400',
                  range: const RangeValues(0, 2399),
                  state: state,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FButton(
          style: FButtonStyle.outline(),
          onPress: onReset,
          child: const Text('Reset'),
        ),
        FButton(
          style: FButtonStyle.primary(),
          onPress: () => onApply(state),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _DesktopFilterSectionLabel extends StatelessWidget {
  const _DesktopFilterSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _DesktopRatingPresetChip extends ConsumerWidget {
  const _DesktopRatingPresetChip({
    required this.label,
    required this.range,
    required this.state,
  });

  final String label;
  final RangeValues range;
  final FilterPopupState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected =
        state.eloRange.start == range.start && state.eloRange.end == range.end;
    return _DesktopFilterChip(
      label: label,
      selected: selected,
      onPressed:
          () => ref.read(filterPopupProvider.notifier).setEloRange(range),
    );
  }
}

class _DesktopFilterChip extends StatelessWidget {
  const _DesktopFilterChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: selected ? FButtonStyle.primary() : FButtonStyle.outline(),
      onPress: onPressed,
      child: Text(label),
    );
  }
}

class _TournamentBrowser extends ConsumerWidget {
  const _TournamentBrowser({
    required this.tournaments,
    required this.storageKey,
    required this.selectedId,
    required this.onSelect,
    required this.onActivate,
    required this.loadingId,
    required this.tileKeys,
    required this.scrollController,
    this.showSmartLevelEvent = false,
  });

  final List<GroupEventCardModel> tournaments;
  final PageStorageKey<String> storageKey;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<GroupEventCardModel> onActivate;
  final String? loadingId;
  final Map<String, GlobalKey> tileKeys;
  final ScrollController scrollController;
  final bool showSmartLevelEvent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final levelTier =
        showSmartLevelEvent
            ? SmartLevelTier.fromFilter(
              ref.watch(currentPastAppliedFilterProvider),
            )
            : null;
    if (tournaments.isEmpty && levelTier == null) {
      return const _EmptyTournamentList();
    }

    final selectedIndex =
        tournaments.isEmpty
            ? 0
            : resolveTournamentEventGridSelectionIndex(
              ids: [for (final tournament in tournaments) tournament.id],
              selectedId: selectedId,
            );

    return _TournamentEventGrid(
      tournaments: tournaments,
      storageKey: storageKey,
      selectedId: tournaments.isEmpty ? '' : tournaments[selectedIndex].id,
      loadingId: loadingId,
      onSelect: onSelect,
      onActivate: onActivate,
      tileKeys: tileKeys,
      scrollController: scrollController,
      levelTier: levelTier,
    );
  }
}

class _TournamentEventGrid extends StatelessWidget {
  const _TournamentEventGrid({
    required this.tournaments,
    required this.storageKey,
    required this.selectedId,
    required this.loadingId,
    required this.onSelect,
    required this.onActivate,
    required this.tileKeys,
    required this.scrollController,
    this.levelTier,
  });

  final List<GroupEventCardModel> tournaments;
  final PageStorageKey<String> storageKey;
  final String selectedId;
  final String? loadingId;
  final ValueChanged<String> onSelect;
  final ValueChanged<GroupEventCardModel> onActivate;
  final Map<String, GlobalKey> tileKeys;
  final ScrollController scrollController;
  final SmartLevelTier? levelTier;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = calculateTournamentEventGridColumns(
          constraints.maxWidth,
        );
        final smartCardCount = levelTier != null ? 1 : 0;
        return GridView.builder(
          key: storageKey,
          controller: scrollController,
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          itemCount: tournaments.length + smartCardCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: tournamentEventGridChildAspectRatio(
              width: constraints.maxWidth - 40,
              columns: columns,
            ),
          ),
          itemBuilder: (context, i) {
            if (levelTier != null && i == 0) {
              return SmartLevelEventCard(tier: levelTier!);
            }
            final tournament = tournaments[i - smartCardCount];
            final key = tileKeys.putIfAbsent(
              tournament.id,
              () => GlobalKey(debugLabel: 'tournament-tile-${tournament.id}'),
            );
            return KeyedSubtree(
              key: key,
              child: _TournamentRowTile(
                tournament: tournament,
                selected: tournament.id == selectedId,
                loading: tournament.id == loadingId,
                onTap: () {
                  onSelect(tournament.id);
                  onActivate(tournament);
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _TournamentRowTile extends StatefulWidget {
  const _TournamentRowTile({
    required this.tournament,
    required this.selected,
    required this.loading,
    required this.onTap,
  });

  final GroupEventCardModel tournament;
  final bool selected;
  final bool loading;
  final VoidCallback onTap;

  @override
  State<_TournamentRowTile> createState() => _TournamentRowTileState();
}

class _TournamentRowTileState extends State<_TournamentRowTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;
    final highlight = widget.selected || _hovered;
    final categoryColor = _categoryColor(t.tourEventCategory);
    return DesktopEventContextMenu(
      event: t,
      onOpen: widget.onTap,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: MotionCard(
              borderRadius: 8,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                decoration: BoxDecoration(
                  color: highlight ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        widget.selected
                            ? categoryColor.withValues(alpha: 0.36)
                            : (_hovered
                                ? kWhiteColor.withValues(alpha: 0.12)
                                : kDividerColor),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _EventThumbnailVisual(
                      event: t,
                      statusColor: categoryColor,
                      selected: widget.selected,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              _StatusBadge(category: t.tourEventCategory),
                              const SizedBox(width: 8),
                              if (t.timeControl.isNotEmpty)
                                Flexible(
                                  child: Text(
                                    t.timeControl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: kLightGreyColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 7),
                          Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _eventMetaLine(t),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kLightGreyColor,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              if (t.maxAvgElo > 0) ...[
                                const SizedBox(width: 10),
                                Text(
                                  '${t.maxAvgElo}',
                                  style: const TextStyle(
                                    color: kWhiteColor70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DesktopEventFavoriteIconButton(event: t, compact: true),
                    if (widget.loading) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      ),
                    ],
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

Color _categoryColor(TourEventCategory category) {
  return switch (category) {
    TourEventCategory.live => kPrimaryColor,
    TourEventCategory.ongoing => kGreenColor,
    TourEventCategory.upcoming => kPrimaryColor,
    TourEventCategory.completed => kLightGreyColor,
  };
}

String _eventMetaLine(GroupEventCardModel tournament) {
  final parts = <String>[
    if (tournament.dates.trim().isNotEmpty) tournament.dates.trim(),
    if ((tournament.location ?? '').trim().isNotEmpty)
      tournament.location!.trim(),
  ];
  return parts.isEmpty ? 'No schedule metadata' : parts.join(' · ');
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.category});

  final TourEventCategory category;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (category) {
      TourEventCategory.live => ('LIVE', kPrimaryColor),
      TourEventCategory.ongoing => ('Ongoing', kGreenColor),
      TourEventCategory.upcoming => ('Upcoming', kPrimaryColor),
      TourEventCategory.completed => ('Completed', kLightGreyColor),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: kRedColor, size: 28),
            const SizedBox(height: 12),
            const Text(
              'Could not load tournaments',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kLightGreyColor, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FTheme(
              data: FThemes.zinc.dark,
              child: FButton(
                style: FButtonStyle.ghost(),
                onPress: onRetry,
                child: const Text('Retry'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTournamentList extends StatelessWidget {
  const _EmptyTournamentList();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy_outlined, color: kLightGreyColor, size: 28),
            SizedBox(height: 12),
            Text(
              'No tournaments in this view',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              'Try a different category or sign in to load For You.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// FOR YOU FEED
// ============================================================================

class _ForYouCardSelection {
  const _ForYouCardSelection({
    required this.eventId,
    required this.column,
    this.gameIndex = 0,
  });

  final String eventId;
  final EventGameCardFocusColumn column;
  final int gameIndex;

  bool get isEvent => column == EventGameCardFocusColumn.event;
  bool get isGame => column == EventGameCardFocusColumn.game;
}

/// Single-column "feed" version of the For You category — mirrors the mobile
/// For You tab structure: a top strip of `DesktopCollectionCards`
/// (Favorites + Countrymen), then each event paired with its top games.
///
/// Sources:
///   - `forYouEventsProvider`         → paginated events
///   - `forYouEventSnapshotProvider`  → per-event games (lazily watched per row)
class _ForYouFeed extends ConsumerStatefulWidget {
  const _ForYouFeed({required this.tabId, required this.onOpenTournament});

  final String tabId;
  final void Function(GroupEventCardModel) onOpenTournament;

  @override
  ConsumerState<_ForYouFeed> createState() => _ForYouFeedState();
}

class _ForYouFeedState extends ConsumerState<_ForYouFeed> {
  static const Duration _kScrollIdleDelay = Duration(milliseconds: 180);
  // Mode-aware cache extents. Board-grid rows pre-render real chessboards
  // off-screen; keep that window small so the cache doesn't quietly own a
  // dozen heavy cards. Compact rows are cheap, so we can keep a wider cache
  // for smoother scrolls.
  static const double _kCompactCacheExtent = 1500;
  static const double _kBoardCacheExtent = 600;

  final FocusNode _focusNode = FocusNode(
    debugLabel: 'DesktopForYouEventGameCards',
  );
  final ScrollController _scroll = ScrollController();
  final Set<String> _animatedEventIds = <String>{};
  final Map<String, GlobalKey> _eventKeys = <String, GlobalKey>{};
  final Map<String, int> _visibleGameCounts = <String, int>{};
  final Map<String, bool> _eventVisibility = <String, bool>{};
  Timer? _scrollIdleTimer;
  _ForYouCardSelection? _selection;
  bool _isScrolling = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _markScrolling();
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    if (max - cur <= 300) {
      ref.read(forYouEventsProvider.notifier).loadMore();
    }
  }

  void _markScrolling() {
    if (!_isScrolling && mounted) {
      setState(() => _isScrolling = true);
    }
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(_kScrollIdleDelay, () {
      if (!mounted || !_isScrolling) return;
      setState(() => _isScrolling = false);
    });
  }

  double _cacheExtentFor(GamesListViewMode mode) {
    return mode == GamesListViewMode.gamesCard
        ? _kCompactCacheExtent
        : _kBoardCacheExtent;
  }

  GlobalKey _eventKey(String eventId) {
    return _eventKeys.putIfAbsent(
      eventId,
      () => GlobalKey(debugLabel: 'desktop-for-you-event-$eventId'),
    );
  }

  List<GroupEventCardModel> _visibleEvents(List<GroupEventCardModel> events) {
    return [
      for (final event in events)
        if (_eventVisibility[event.id] ?? true) event,
    ];
  }

  void _setEventVisibility(String eventId, bool visible) {
    if (!mounted) return;
    if (_eventVisibility[eventId] == visible) return;
    setState(() {
      _eventVisibility[eventId] = visible;
      if (!visible && _selection?.eventId == eventId) {
        _selection = null;
      }
    });
  }

  void _setVisibleGameCount(String eventId, int count) {
    if (!mounted) return;
    if (_visibleGameCounts[eventId] == count) return;
    setState(() {
      _visibleGameCounts[eventId] = count;
      final selection = _selection;
      if (selection?.eventId == eventId && selection!.isGame) {
        if (count <= 0) {
          _selection = _ForYouCardSelection(
            eventId: eventId,
            column: EventGameCardFocusColumn.event,
          );
        } else if (selection.gameIndex >= count) {
          _selection = _ForYouCardSelection(
            eventId: eventId,
            column: EventGameCardFocusColumn.game,
            gameIndex: count - 1,
          );
        }
      }
    });
  }

  int _gameCountFor(GroupEventCardModel event) {
    final reported = _visibleGameCounts[event.id];
    final snapshot =
        ref.read(forYouEventSnapshotProvider(event.id)).valueOrNull;
    final snapshotCount = snapshot?.visibleGames.length ?? 0;
    if (reported == null) return snapshotCount;
    // The rendered strip reports how many game cards fit after layout, but that
    // callback can briefly lag behind provider updates or keep a stale zero from
    // a prior loading/empty pass. If a snapshot already has games, let Right
    // Arrow enter the first board card instead of appearing dead.
    return reported > 0 ? reported : snapshotCount;
  }

  int _eventPageStrideFor(DesktopCardLayout layout) {
    final viewport =
        _scroll.hasClients ? _scroll.position.viewportDimension : 0.0;
    final rowExtent = _ForYouEventSection._rowHeightFor(layout) + 28.0;
    return eventGameCardPageStrideForViewport(
      viewportExtent: viewport,
      rowExtent: rowExtent,
      fallback: 1,
      maxStride: 4,
    );
  }

  bool _hasNavigationModifier() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
  }

  void _syncSelectionWithEvents(List<GroupEventCardModel> events) {
    final visibleEvents = _visibleEvents(events);
    if (visibleEvents.isEmpty) {
      _selection = null;
      return;
    }
    final selection = _selection;
    final selectedStillVisible =
        selection != null &&
        visibleEvents.any((event) => event.id == selection.eventId);
    if (!selectedStillVisible) {
      _selection = _ForYouCardSelection(
        eventId: visibleEvents.first.id,
        column: EventGameCardFocusColumn.event,
      );
    }
  }

  KeyEventResult _handleKeyboard(
    KeyEvent event,
    List<GroupEventCardModel> events,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_hasNavigationModifier()) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activateSelection(events);
      return KeyEventResult.handled;
    }

    final isMoveKey =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    if (!isMoveKey) return KeyEventResult.ignored;

    final visibleEvents = _visibleEvents(events);
    if (visibleEvents.isEmpty) return KeyEventResult.ignored;

    final selected = _selection;
    final selectedIndex =
        selected == null
            ? -1
            : visibleEvents.indexWhere((event) => event.id == selected.eventId);
    final currentFocus =
        selectedIndex < 0
            ? null
            : EventGameCardFocus(
              eventIndex: selectedIndex,
              column: selected!.column,
              gameIndex: selected.gameIndex,
            );
    final layout = ref.read(gamesListViewModeProvider).desktopLayout;
    final nextFocus = moveEventGameCardFocus(
      current: currentFocus,
      key: key,
      eventCount: visibleEvents.length,
      eventPageStride: _eventPageStrideFor(layout),
      gameCountForEvent: (index) => _gameCountFor(visibleEvents[index]),
      gameLayout:
          layout == DesktopCardLayout.grid
              ? EventGameCardNavigationLayout.horizontalRow
              : EventGameCardNavigationLayout.verticalList,
    );
    if (nextFocus == null) return KeyEventResult.ignored;

    final nextEvent = visibleEvents[nextFocus.eventIndex];
    setState(() {
      _selection = _ForYouCardSelection(
        eventId: nextEvent.id,
        column: nextFocus.column,
        gameIndex: nextFocus.gameIndex,
      );
    });
    if (nextFocus.eventIndex >= visibleEvents.length - 2) {
      ref.read(forYouEventsProvider.notifier).loadMore();
    }
    _ensureSelectionVisible(
      nextEvent.id,
      pageDirection:
          key == LogicalKeyboardKey.pageDown
              ? 1
              : key == LogicalKeyboardKey.pageUp
              ? -1
              : 0,
    );
    return KeyEventResult.handled;
  }

  void _activateSelection(List<GroupEventCardModel> events) {
    final selection = _selection;
    if (selection == null) return;

    GroupEventCardModel? event;
    for (final candidate in events) {
      if (candidate.id == selection.eventId) {
        event = candidate;
        break;
      }
    }
    if (event == null) return;

    final activationTarget = eventGameCardActivationTarget(
      EventGameCardFocus(
        eventIndex: 0,
        column: selection.column,
        gameIndex: selection.gameIndex,
      ),
    );
    switch (activationTarget) {
      case EventGameCardActivationTarget.eventGameList:
        // For You is event-first: Enter on the event opens that event's
        // tournament Games tab / game list view.
        widget.onOpenTournament(event);
        return;
      case EventGameCardActivationTarget.inGameView:
        // Right Arrow moves For You focus onto a game; Enter there opens the
        // selected game into the board + notation in-game view.
        break;
    }

    final snapshot =
        ref.read(forYouEventSnapshotProvider(event.id)).valueOrNull;
    if (snapshot == null) return;
    final count = _gameCountFor(event);
    if (count <= 0) return;
    final games = snapshot.visibleGames.take(count).toList(growable: false);
    final gameIndex = _clampIndex(selection.gameIndex, 0, games.length - 1);
    openTournamentGameTab(
      ref,
      games[gameIndex],
      event.title,
      eventGames: snapshot.visibleGames,
      viewSource: ChessboardView.forYou,
    );
  }

  int _clampIndex(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _ensureSelectionVisible(String eventId, {int pageDirection = 0}) {
    if (pageDirection != 0 && _scroll.hasClients) {
      final position = _scroll.position;
      final target =
          (position.pixels + position.viewportDimension * pageDirection)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      if ((target - position.pixels).abs() > 1) {
        unawaited(
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          ),
        );
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _eventKeys[eventId]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  void _navigateToTab(TabKind kind) {
    ref.read(desktopTabsProvider.notifier).navigateActive(kind);
  }

  @override
  Widget build(BuildContext context) {
    // Sync the selection cursor off-frame so we never mutate state during
    // build. ref.listen's callback fires after the state change, outside
    // the build phase. Without this, calling `_syncSelectionWithEvents`
    // inside `build()` would assert if any downstream codepath ever
    // triggered `setState`.
    ref.listen<ForYouState>(forYouEventsProvider, (prev, next) {
      _syncSelectionWithEvents(next.events);
    });
    final state = ref.watch(forYouEventsProvider);
    final viewMode = ref.watch(gamesListViewModeProvider);

    if (state.isLoading && state.events.isEmpty) {
      return const _LoadingState();
    }

    if (state.error != null && state.events.isEmpty) {
      return _ErrorState(
        message: state.error!,
        onRetry: () => ref.read(forYouEventsProvider.notifier).refresh(),
      );
    }

    final events = state.events;
    // Initial sync for first build: ref.listen only fires on subsequent
    // state changes, so we still need to seed the selection on mount.
    // _syncSelectionWithEvents is idempotent — calling it again when the
    // selection is already valid is a no-op.
    if (_selection == null && events.isNotEmpty) {
      _syncSelectionWithEvents(events);
    }
    final levelTier = SmartLevelTier.fromFilter(
      ref.watch(forYouAppliedFilterProvider),
    );
    final smartCardCount = levelTier != null ? 1 : 0;
    final showTrailingSpinner = state.hasMore && !state.isLoading;
    // +1 for the collection cards header, +1 for the smart level card if selected,
    // +1 for the trailing spinner.
    final itemCount =
        1 + smartCardCount + events.length + (showTrailingSpinner ? 1 : 0);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      canRequestFocus: true,
      onKeyEvent: (_, event) => _handleKeyboard(event, events),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: RefreshIndicator(
          onRefresh: () => ref.read(forYouEventsProvider.notifier).refresh(),
          color: kPrimaryColor,
          backgroundColor: kBlack2Color,
          child: ListView.builder(
            key: PageStorageKey<String>('desktop_for_you_feed_${widget.tabId}'),
            controller: _scroll,
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            itemCount: itemCount,
            // ignore: deprecated_member_use
            cacheExtent: _cacheExtentFor(viewMode),
            // Each For You row owns up to 4 live game cards, each with its own
            // realtime stream + chessboard preview. AutomaticKeepAlive forces
            // those subscriptions to stay live for off-screen rows the viewport
            // has already left behind. Disable it so the cache window is the
            // only thing keeping nearby rows hot.
            addAutomaticKeepAlives: false,
            itemBuilder: (context, index) {
              if (index == 0) {
                return DesktopCollectionCards(
                  onFavoritesTap: () {
                    ref
                        .read(selectedFavoritesModeProvider.notifier)
                        .update((_) => FavoritesScreenMode.games);
                    _navigateToTab(TabKind.favorites);
                  },
                  onCountrymenTap: () {
                    ref
                        .read(selectedCountrymenModeProvider.notifier)
                        .update((_) => CountrymenScreenMode.games);
                    _navigateToTab(TabKind.countrymen);
                  },
                );
              }
              if (levelTier != null && index == 1) {
                return SmartLevelEventCard(tier: levelTier);
              }
              final eventIdx = index - 1 - smartCardCount;
              if (eventIdx >= events.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
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
              final event = events[eventIdx];
              // RepaintBoundary isolates each row's repaints from the scrolling
              // list so live clock ticks and PV/board updates don't repaint the
              // whole viewport. Cheap to add — Flutter inserts these for grid
              // tiles by default but not for ListView.builder children.
              return RepaintBoundary(
                child: _ForYouEventSection(
                  key: _eventKey(event.id),
                  event: event,
                  isFirst: eventIdx == 0,
                  selection:
                      _selection?.eventId == event.id ? _selection : null,
                  animatedEventIds: _animatedEventIds,
                  isScrolling: _isScrolling,
                  onOpen: () => widget.onOpenTournament(event),
                  onVisibilityChanged:
                      (visible) => _setEventVisibility(event.id, visible),
                  onVisibleGameCountChanged:
                      (count) => _setVisibleGameCount(event.id, count),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One event in the For You feed.
///
/// Layout: a single horizontal row — the event card sits on the left at a
/// fixed footprint, the top games flow to the right as a strip of grid-
/// style cards (each with a real chessboard preview). Width-adaptive:
/// renders as many games as fit at [DesktopForYouStripLayout.minCardWidth],
/// individual card width clamped to [DesktopForYouStripLayout.maxCardWidth]
/// so nothing stretches. No hard game-count cap. Hides itself when the
/// snapshot resolves empty.
class _ForYouEventSection extends ConsumerWidget {
  const _ForYouEventSection({
    super.key,
    required this.event,
    required this.isFirst,
    required this.selection,
    required this.animatedEventIds,
    required this.isScrolling,
    required this.onOpen,
    required this.onVisibilityChanged,
    required this.onVisibleGameCountChanged,
  });

  static const double eventCardWidth = 280;
  static const double eventToGamesGap = 18;

  final GroupEventCardModel event;
  final bool isFirst;
  final _ForYouCardSelection? selection;
  final Set<String> animatedEventIds;
  final bool isScrolling;
  final VoidCallback onOpen;
  final ValueChanged<bool> onVisibilityChanged;
  final ValueChanged<int> onVisibleGameCountChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshotAsync = ref.watch(forYouEventSnapshotProvider(event.id));
    final layout = ref.watch(gamesListViewModeProvider).desktopLayout;

    final shouldHide = snapshotAsync.maybeWhen(
      data: (s) => !s.hasGames,
      orElse: () => false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onVisibilityChanged(!shouldHide);
    });

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child:
          shouldHide
              ? const SizedBox.shrink()
              : _buildContent(context, ref, snapshotAsync, layout),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<ForYouEventGamesSnapshot> snapshotAsync,
    DesktopCardLayout layout,
  ) {
    final shouldAnimate = !animatedEventIds.contains(event.id);
    if (shouldAnimate) {
      animatedEventIds.add(event.id);
    }

    final rowHeight = _rowHeightFor(layout);
    final row = Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : 28),
      child: SizedBox(
        height: rowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: eventCardWidth,
              child: _ForYouEventSummaryCard(
                event: event,
                selected: selection?.isEvent ?? false,
                onOpen: onOpen,
              ),
            ),
            const SizedBox(width: eventToGamesGap),
            Expanded(
              child: _GamesStrip(
                eventId: event.id,
                tournamentTitle: event.title,
                snapshotAsync: snapshotAsync,
                layout: layout,
                isScrolling: isScrolling,
                selectedGameIndex:
                    selection?.isGame == true ? selection!.gameIndex : null,
                onVisibleGameCountChanged: onVisibleGameCountChanged,
              ),
            ),
          ],
        ),
      ),
    );

    if (shouldAnimate) {
      return row
          .animate()
          .fadeIn(duration: 220.ms)
          .slideY(begin: 0.02, end: 0, duration: 220.ms);
    }
    return row;
  }

  static double _rowHeightFor(DesktopCardLayout layout) {
    return switch (layout) {
      DesktopCardLayout.grid => 292,
      DesktopCardLayout.list => 286,
      DesktopCardLayout.compact => 220,
    };
  }
}

class _ForYouEventSummaryCard extends StatefulWidget {
  const _ForYouEventSummaryCard({
    required this.event,
    required this.selected,
    required this.onOpen,
  });

  final GroupEventCardModel event;
  final bool selected;
  final VoidCallback onOpen;

  @override
  State<_ForYouEventSummaryCard> createState() =>
      _ForYouEventSummaryCardState();
}

class _ForYouEventSummaryCardState extends State<_ForYouEventSummaryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final highlighted = widget.selected || _hovered;
    return DesktopEventContextMenu(
      event: event,
      onOpen: widget.onOpen,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpen,
            child: MotionCard(
              borderRadius: 9,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: highlighted ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color:
                        widget.selected
                            ? kPrimaryColor.withValues(alpha: 0.42)
                            : _hovered
                            ? kWhiteColor.withValues(alpha: 0.12)
                            : kDividerColor,
                  ),
                  // selection keeps a persistent shadow; hover/press shadow
                  // now owned by MotionCard.
                  boxShadow:
                      widget.selected
                          ? [
                            BoxShadow(
                              color: kPrimaryColor.withValues(alpha: 0.08),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ]
                          : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 82,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _DesktopEventVisual(
                            event: event,
                            borderRadius: BorderRadius.zero,
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: kBlackColor.withValues(alpha: 0.4),
                            ),
                          ),
                          Positioned(
                            left: 10,
                            top: 10,
                            right: 10,
                            child: Row(
                              children: [
                                _StatusBadge(category: event.tourEventCategory),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    event.timeControl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: kWhiteColor70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                DesktopEventFavoriteIconButton(
                                  event: event,
                                  compact: true,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              event.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                height: 1.16,
                                letterSpacing: 0,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _eventMetaLine(event),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kLightGreyColor,
                                fontSize: 11,
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                if (event.maxAvgElo > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: kBackgroundColor,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: kDividerColor),
                                    ),
                                    child: Text(
                                      'Avg ${event.maxAvgElo}',
                                      style: const TextStyle(
                                        color: kWhiteColor70,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                                Icon(
                                  Icons.open_in_new_rounded,
                                  size: 15,
                                  color: kWhiteColor70,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
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

/// Horizontal strip of square grid-style game cards next to the event card.
/// Adaptive: chooses card count + width based on available space, with a
/// `Spacer()` mopping up leftover room so cards never stretch.
class _GamesStrip extends ConsumerWidget {
  const _GamesStrip({
    required this.eventId,
    required this.tournamentTitle,
    required this.snapshotAsync,
    required this.layout,
    required this.isScrolling,
    required this.selectedGameIndex,
    required this.onVisibleGameCountChanged,
  });

  final String eventId;
  final String tournamentTitle;
  final AsyncValue<ForYouEventGamesSnapshot> snapshotAsync;
  final DesktopCardLayout layout;
  final bool isScrolling;
  final int? selectedGameIndex;
  final ValueChanged<int> onVisibleGameCountChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return snapshotAsync.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (snapshot) {
        if (snapshot.visibleGames.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onVisibleGameCountChanged(0);
          });
          return const SizedBox.shrink();
        }
        if (layout != DesktopCardLayout.grid) {
          final allGames = snapshot.visibleGames.toList(growable: false);
          // Each event's strip has BOUNDED vertical space — the For You
          // feed gives every event the same hard-coded row height (see
          // _ForYouEventSection._rowHeightFor) and never lets a single
          // event grow its own scroller. Cap the visible games to what
          // actually fits a cols × rows grid of the current tile
          // dimensions so a busy round doesn't shove its cards past the
          // event's footer. Uses the known row-height constant rather
          // than constraints.maxHeight so a transient unbounded pass
          // (e.g. before the SizedBox propagates) can't render too many.
          final tileMetrics = DesktopGameCardsFlow.metricsFor(layout);
          final rowHeight = _ForYouEventSection._rowHeightFor(layout);
          final rows =
              ((rowHeight + tileMetrics.spacing) /
                      (tileMetrics.tileHeight + tileMetrics.spacing))
                  .floor()
                  .clamp(1, 100)
                  .toInt();
          return LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth;
              final cols =
                  ((maxW + tileMetrics.spacing) /
                          (tileMetrics.targetWidth + tileMetrics.spacing))
                      .floor()
                      .clamp(tileMetrics.minCols, tileMetrics.maxCols)
                      .toInt();
              final capacity = (cols * rows).clamp(1, allGames.length);
              final games = allGames.take(capacity).toList(growable: false);
              final liveBatchKey = _desktopForYouLiveBatchKey(
                eventId: eventId,
                tourId: snapshot.tourId,
                games: games,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onVisibleGameCountChanged(games.length);
              });
              return DesktopGameCardsFlow(
                layout: layout,
                itemCount: games.length,
                embedded: true,
                itemBuilder:
                    (context, i) => LiveDesktopGameCard(
                      game: games[i],
                      tournamentTitle: tournamentTitle,
                      layout: layout,
                      selected: selectedGameIndex == i,
                      viewSource: ChessboardView.forYou,
                      liveBatchKey: liveBatchKey,
                      allowStockfishFallback: !isScrolling,
                    ),
              );
            },
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final strip = DesktopForYouStripLayout.compute(
              available: constraints.maxWidth,
              gameCount: snapshot.visibleGames.length,
            );
            final games = snapshot.visibleGames
                .take(strip.visibleCount)
                .toList(growable: false);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onVisibleGameCountChanged(games.length);
            });
            final liveBatchKey = _desktopForYouLiveBatchKey(
              eventId: eventId,
              tourId: snapshot.tourId,
              games: games,
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < strip.visibleCount; i++) ...[
                  if (i > 0)
                    const SizedBox(width: DesktopForYouStripLayout.gap),
                  SizedBox(
                    width: strip.cardWidth,
                    child: LiveDesktopGameCard(
                      game: games[i],
                      tournamentTitle: tournamentTitle,
                      layout: DesktopCardLayout.grid,
                      selected: selectedGameIndex == i,
                      viewSource: ChessboardView.forYou,
                      liveBatchKey: liveBatchKey,
                      allowStockfishFallback: !isScrolling,
                    ),
                  ),
                ],
                const Spacer(),
              ],
            );
          },
        );
      },
      loading:
          () => LayoutBuilder(
            builder: (context, constraints) {
              if (layout != DesktopCardLayout.grid) {
                // Match the data-state cap: cols × rows fits the bounded
                // event row, skeletons render at the same density as the
                // real cards will.
                final tileMetrics = DesktopGameCardsFlow.metricsFor(layout);
                final rowHeight = _ForYouEventSection._rowHeightFor(layout);
                final rows =
                    ((rowHeight + tileMetrics.spacing) /
                            (tileMetrics.tileHeight + tileMetrics.spacing))
                        .floor()
                        .clamp(1, 100)
                        .toInt();
                final cols =
                    ((constraints.maxWidth + tileMetrics.spacing) /
                            (tileMetrics.targetWidth + tileMetrics.spacing))
                        .floor()
                        .clamp(tileMetrics.minCols, tileMetrics.maxCols)
                        .toInt();
                final count = (cols * rows).clamp(1, 24);
                return DesktopGameCardsFlow(
                  layout: layout,
                  itemCount: count,
                  embedded: true,
                  itemBuilder:
                      (context, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: kBlack2Color,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: kDividerColor),
                        ),
                      ),
                );
              }
              final strip = DesktopForYouStripLayout.compute(
                available: constraints.maxWidth,
                gameCount: 6,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < strip.visibleCount; i++) ...[
                    if (i > 0)
                      const SizedBox(width: DesktopForYouStripLayout.gap),
                    SizedBox(
                      width: strip.cardWidth,
                      child: Container(
                        decoration: BoxDecoration(
                          color: kBlack2Color,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: kDividerColor),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                ],
              );
            },
          ),
      error:
          (_, __) => const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                'Could not load games',
                style: TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
            ),
          ),
    );
  }
}
