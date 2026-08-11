import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/global_search_query.dart';
import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';
import 'package:chessever/desktop/utils/list_keyboard_nav.dart';
import 'package:chessever/desktop/utils/tournament_event_grid_layout.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_event_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_event_favorite_button.dart';
import 'package:chessever/desktop/widgets/desktop_event_countdown.dart';
import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_game_context.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_team_match_grouping.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
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
import 'package:chessever/providers/group_event_category.dart' as ge;
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/group_event/providers/supabase_combined_search_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_state.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/group_event_filter_provider.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
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
  return forYouEventLiveBatchKey(
    eventId: eventId,
    tourId: tourId,
    games: games,
  );
}

/// The bounded RPC snapshot is authoritative for both the visible strip and
/// board navigation. The For You surface never hydrates a full tour locally.
DesktopForYouGameContext _forYouGameContext(ForYouEventGamesSnapshot snapshot) {
  return buildDesktopForYouGameContext(
    snapshotGames: snapshot.visibleGames,
    fullVisibleGames: const [],
    fullEventGames: const [],
  );
}

String _smartCollectionTitle(PremiumGamesType type) {
  return switch (type) {
    PremiumGamesType.live => 'Live',
    PremiumGamesType.gm => 'GM',
    PremiumGamesType.classical => 'Classical',
    PremiumGamesType.miniatures => 'Miniatures',
    PremiumGamesType.favorites => 'Favorites',
    PremiumGamesType.countrymen => 'Countrymen',
  };
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
                  ? LayoutBuilder(
                    builder: (context, constraints) {
                      final paneWidth =
                          constraints.maxWidth.isFinite
                              ? constraints.maxWidth
                              : 0.0;
                      return _ForYouFeed(
                        tabId: tabId,
                        paneWidth: paneWidth,
                        onOpenTournament: openTournament,
                      );
                    },
                  )
                  : asyncTournaments.when(
                    data:
                        (tournaments) => _TournamentEventGridKeyboardHost(
                          focusNode: listFocusNode,
                          tournaments: tournaments,
                          selectedId: selectedTournamentId.value,
                          onSelectedIdChanged: (id) {
                            selectedTournamentId.value = id;
                          },
                          onActivate: openTournament,
                          tileKeys: tileKeys.value,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kBlack2Color,
          border: Border.all(color: kWhiteColor.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 6,
              child: _EventCardMedia(event: event, padding: 12),
            ),
            _EventPosterInfoPanel(event: event),
          ],
        ),
      ),
    );
  }
}

class _EventCardMedia extends StatelessWidget {
  const _EventCardMedia({
    required this.event,
    required this.padding,
    this.imageFit = BoxFit.cover,
    this.showFavorite = true,
  });

  final GroupEventCardModel event;
  final double padding;
  final BoxFit imageFit;
  final bool showFavorite;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _DesktopEventVisual(
          event: event,
          borderRadius: BorderRadius.zero,
          fit: imageFit,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                kBlackColor.withValues(alpha: 0.56),
                kBlackColor.withValues(alpha: 0.08),
                kBlackColor.withValues(alpha: 0.18),
              ],
              stops: const [0, 0.58, 1],
            ),
          ),
        ),
        // Only the favorite icon sits on the photo — an icon reads on any
        // artwork. The status badge + time control were unreadable overlaid on
        // the image, so they move to the solid info panel below.
        if (showFavorite)
          Positioned(
            top: padding,
            right: padding,
            child: DesktopEventFavoriteIconButton(event: event, compact: true),
          ),
      ],
    );
  }
}

class _EventPosterInfoPanel extends StatelessWidget {
  const _EventPosterInfoPanel({required this.event});

  final GroupEventCardModel event;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(event.tourEventCategory);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border(
          top: BorderSide(color: kWhiteColor.withValues(alpha: 0.08)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status + time control, on the solid panel where they read (were
            // unreadable overlaid on the poster image).
            Row(
              children: [
                if (_shouldShowStatusBadge(event.tourEventCategory))
                  _StatusBadge(category: event.tourEventCategory),
                if (event.timeControl.isNotEmpty) ...[
                  if (_shouldShowStatusBadge(event.tourEventCategory))
                    const SizedBox(width: 8),
                  Flexible(
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
                ],
              ],
            ),
            const SizedBox(height: 9),
            Text(
              event.title,
              maxLines: 2,
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
                if (event.maxAvgElo > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    'Avg ${event.maxAvgElo}',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Icon(Icons.open_in_new_rounded, size: 14, color: color),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopEventVisual extends ConsumerWidget {
  const _DesktopEventVisual({
    required this.event,
    required this.borderRadius,
    this.fit = BoxFit.cover,
  });

  final GroupEventCardModel event;
  final BorderRadius borderRadius;
  final BoxFit fit;

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
              return _EventFallbackVisual(
                event: event,
                countryCode: fallbackCountry,
              );
            }

            final dpr = MediaQuery.devicePixelRatioOf(context);
            final logicalWidth =
                constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : (constraints.maxHeight.isFinite
                        ? constraints.maxHeight * 1.6
                        : 360.0);
            // Width-only: ResizeImage decodes to an exact width x height box
            // when both are given, squashing the source photo to the card's
            // aspect ratio before the selected BoxFit is applied. One free
            // axis keeps the source aspect intact through decode.
            final cacheWidth =
                (logicalWidth * dpr).round().clamp(96, 900).toInt();
            final image = ref.watch(eventImageProvider(event.id));

            return image.when(
              data: (data) {
                final countryCode = data.fallbackCountryCode ?? fallbackCountry;
                if (data.hasImage) {
                  return CachedNetworkImage(
                    imageUrl: data.imageUrl!,
                    fit: fit,
                    memCacheWidth: cacheWidth,
                    fadeInDuration: const Duration(milliseconds: 180),
                    fadeOutDuration: const Duration(milliseconds: 120),
                    placeholder: (_, __) => const _EventImageSkeleton(),
                    errorWidget:
                        (_, __, ___) => _EventFallbackVisual(
                          event: event,
                          countryCode: countryCode,
                        ),
                  );
                }
                return _EventFallbackVisual(
                  event: event,
                  countryCode: countryCode,
                );
              },
              loading: () => const _EventImageSkeleton(),
              error:
                  (_, __) => _EventFallbackVisual(
                    event: event,
                    countryCode: fallbackCountry,
                  ),
            );
          },
        ),
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
  const _EventFallbackVisual({required this.event, required this.countryCode});

  final GroupEventCardModel event;
  final String? countryCode;

  @override
  Widget build(BuildContext context) {
    final accent = _eventFallbackAccent(event);
    final secondary = _eventFallbackSecondary(event);
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
          Positioned(
            left: 10,
            bottom: 10,
            child: _EventFallbackInitialBadge(event: event, accent: accent),
          ),
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(accent, kBlackColor, 0.58)!,
            Color.lerp(secondary, kBlackColor, 0.48)!,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 0.16,
            child: ColoredBox(
              color: accent,
              child: const LogoPatternFallback(),
            ),
          ),
          Positioned(
            right: -34,
            top: -36,
            child: Transform.rotate(
              angle: -0.18,
              child: Container(
                width: 108,
                height: 210,
                decoration: BoxDecoration(
                  color: secondary.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: kWhiteColor.withValues(alpha: 0.06),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: _EventFallbackInitialBadge(event: event, accent: accent),
          ),
        ],
      ),
    );
  }
}

class _EventFallbackInitialBadge extends StatelessWidget {
  const _EventFallbackInitialBadge({required this.event, required this.accent});

  final GroupEventCardModel event;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBlackColor.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.72)),
      ),
      child: Text(
        _eventInitials(event.title),
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 14,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

const List<Color> _eventFallbackPalette = [
  Color(0xFF355A46),
  Color(0xFF40506F),
  Color(0xFF694A3D),
  Color(0xFF5D4D74),
  Color(0xFF35616A),
  Color(0xFF686139),
  Color(0xFF6A3F4B),
  Color(0xFF3E6654),
];

Color _eventFallbackAccent(GroupEventCardModel event) {
  final hash = _stableEventHash(event);
  final base = _eventFallbackPalette[hash % _eventFallbackPalette.length];
  return Color.lerp(base, _categoryColor(event.tourEventCategory), 0.22)!;
}

Color _eventFallbackSecondary(GroupEventCardModel event) {
  final hash = _stableEventHash(event) + 3;
  return _eventFallbackPalette[hash % _eventFallbackPalette.length];
}

int _stableEventHash(GroupEventCardModel event) {
  var hash = 0;
  final source = '${event.id}:${event.title}';
  for (final unit in source.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash;
}

String _eventInitials(String title) {
  final matches = RegExp(r'[A-Za-z0-9]+').allMatches(title);
  final parts = [
    for (final match in matches)
      if ((match.group(0) ?? '').isNotEmpty) match.group(0)!,
  ];
  if (parts.isEmpty) return 'EV';
  if (parts.length == 1) {
    return parts.first
        .substring(0, parts.first.length.clamp(1, 2))
        .toUpperCase();
  }
  return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
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
    return DesktopTooltip(
      message: isActive ? '$activeCount active event filters' : 'Event filters',
      // Render as a one-segment sibling of the DesktopSegmentedTabs beside it:
      // the identical 38px dark-zinc forui pill (surface, radius, divider
      // border) wrapping a segment-styled FButton, reusing the tabs' own
      // segment style. So Filters belongs to the same forui chrome instead of
      // reading as a stray, differently-shaped button.
      child: FTheme(
        data: FThemes.zinc.dark,
        child: Container(
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: kDividerColor),
          ),
          child: FButton(
            style: desktopSegmentButtonStyle(selected: isActive),
            mainAxisSize: MainAxisSize.min,
            onPress: onPressed,
            prefix: const Icon(Icons.tune_rounded),
            child: Text(isActive ? 'Filters · $activeCount' : 'Filters'),
          ),
        ),
      ),
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
      title: Row(
        children: [
          const Expanded(child: Text('Event filters')),
          FButton.icon(
            style: FButtonStyle.ghost(),
            onPress: () => Navigator.of(context).maybePop(),
            child: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
      body: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.travel_explore_rounded,
                      size: 16,
                      color: kWhiteColor70,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        initialCategory == ge.GroupEventCategory.forYou
                            ? 'For You feed'
                            : 'Current and Past events',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
    // Same forui pill as the segmented tabs + Filters button: selected reads
    // as a primary tint, not a heavy outline/solid FButton. Keeps the dialog
    // consistent with the rest of the desktop chrome. No check-icon prefix —
    // it shifted width on toggle; the tint already signals selection.
    return FButton(
      style: desktopSegmentButtonStyle(selected: selected, wrap: true),
      mainAxisSize: MainAxisSize.min,
      onPress: onPressed,
      child: Text(label),
    );
  }
}

class _TournamentBrowser extends StatelessWidget {
  const _TournamentBrowser({
    required this.tournaments,
    required this.storageKey,
    required this.selectedId,
    required this.onSelect,
    required this.onActivate,
    required this.loadingId,
    required this.tileKeys,
    required this.scrollController,
  });

  final List<GroupEventCardModel> tournaments;
  final PageStorageKey<String> storageKey;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<GroupEventCardModel> onActivate;
  final String? loadingId;
  final Map<String, GlobalKey> tileKeys;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    if (tournaments.isEmpty) {
      return const _EmptyTournamentList();
    }

    final selectedIndex = resolveTournamentEventGridSelectionIndex(
      ids: [for (final tournament in tournaments) tournament.id],
      selectedId: selectedId,
    );

    return _TournamentEventGrid(
      tournaments: tournaments,
      storageKey: storageKey,
      selectedId: tournaments[selectedIndex].id,
      loadingId: loadingId,
      onSelect: onSelect,
      onActivate: onActivate,
      tileKeys: tileKeys,
      scrollController: scrollController,
    );
  }
}

/// Owns arrow/Page/Home/End/Enter for the Current/Past event grid the same
/// way For You owns its selection host: local [Focus] first, with a
/// [HardwareKeyboard] fallback when shell chrome (or [PaneKeyboardScroll])
/// holds primary focus so selection still moves instead of bare scrolling.
class _TournamentEventGridKeyboardHost extends StatefulWidget {
  const _TournamentEventGridKeyboardHost({
    required this.focusNode,
    required this.tournaments,
    required this.selectedId,
    required this.onSelectedIdChanged,
    required this.onActivate,
    required this.tileKeys,
    required this.child,
  });

  final FocusNode focusNode;
  final List<GroupEventCardModel> tournaments;
  final String? selectedId;
  final ValueChanged<String> onSelectedIdChanged;
  final ValueChanged<GroupEventCardModel> onActivate;
  final Map<String, GlobalKey> tileKeys;
  final Widget child;

  @override
  State<_TournamentEventGridKeyboardHost> createState() =>
      _TournamentEventGridKeyboardHostState();
}

class _TournamentEventGridKeyboardHostState
    extends State<_TournamentEventGridKeyboardHost> {
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyboard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (TickerMode.valuesOf(context).enabled) {
        widget.focusNode.requestFocus();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // PersistentIndexedStack wraps inactive tabs in TickerMode+ExcludeFocus.
    // Reclaim focus when this pane becomes the live tab again.
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_handleTickerModeChanged);
      _tickerMode = notifier..addListener(_handleTickerModeChanged);
    }
  }

  void _handleTickerModeChanged() {
    if (_tickerMode?.value.enabled != true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && TickerMode.valuesOf(context).enabled) {
        widget.focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_handleTickerModeChanged);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyboard);
    super.dispose();
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

  bool _hasEditableTextFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _handleGlobalKeyboard(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    final isRelevant =
        _isGridNavigationKey(key) || _isActivationKey(key);
    // Inactive tabs stay mounted under TickerMode(false). Must not steal
    // arrow/Page/Home/End from the active pane (For You activeId /
    // PaneKeyboardScroll TickerMode contract).
    if (!shouldTournamentEventGridHandleGlobalKey(
      mounted: mounted,
      tickerModeEnabled: TickerMode.valuesOf(context).enabled,
      hostHasFocus: widget.focusNode.hasFocus,
      hasNavigationModifier: _hasNavigationModifier(),
      hasEditableTextFocus: _hasEditableTextFocus(),
      isRelevantKey: isRelevant,
    )) {
      return false;
    }
    final result = _handleKeyEvent(event);
    if (result == KeyEventResult.handled) return true;
    // Active host only: never fall back to PaneKeyboardScroll pixel-scroll.
    return _isGridNavigationKey(key);
  }

  bool _isGridNavigationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
  }

  bool _isActivationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final tournaments = widget.tournaments;
    if (tournaments.isEmpty) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isEnter = _isActivationKey(key);
    if (!_isGridNavigationKey(key) && !isEnter) {
      return KeyEventResult.ignored;
    }

    final tournamentIds = [
      for (final tournament in tournaments) tournament.id,
    ];
    final base = resolveTournamentEventGridSelectionIndex(
      ids: tournamentIds,
      selectedId: widget.selectedId,
    );
    final currentTournament = tournaments[base];

    void scrollEventIntoView(String id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = widget.tileKeys[id]?.currentContext;
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
      if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
      widget.onActivate(currentTournament);
      return KeyEventResult.handled;
    }

    final paneWidth =
        context.size?.width ?? MediaQuery.sizeOf(context).width;
    final columns = calculateTournamentEventGridColumns(paneWidth);
    final intent = switch (key) {
      LogicalKeyboardKey.arrowRight =>
        TournamentEventGridNavigationIntent.right,
      LogicalKeyboardKey.arrowLeft => TournamentEventGridNavigationIntent.left,
      LogicalKeyboardKey.arrowDown => TournamentEventGridNavigationIntent.down,
      LogicalKeyboardKey.arrowUp => TournamentEventGridNavigationIntent.up,
      LogicalKeyboardKey.pageDown =>
        TournamentEventGridNavigationIntent.pageDown,
      LogicalKeyboardKey.pageUp => TournamentEventGridNavigationIntent.pageUp,
      LogicalKeyboardKey.home => TournamentEventGridNavigationIntent.home,
      LogicalKeyboardKey.end => TournamentEventGridNavigationIntent.end,
      _ => null,
    };
    if (intent == null) return KeyEventResult.ignored;

    final newId = nextTournamentEventGridSelectedId(
      ids: tournamentIds,
      selectedId: widget.selectedId,
      columns: columns,
      intent: intent,
      pageRows: kDesktopListPageStep,
    );
    if (newId == null) return KeyEventResult.handled;
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
    // Edge clamp: resolved target is the same card already highlighted.
    if (newId == currentTournament.id) {
      // Persist the visual default (index 0) so subsequent moves have a
      // concrete selectedId even if the user never clicked a card.
      if (widget.selectedId == null) {
        widget.onSelectedIdChanged(newId);
      }
      return KeyEventResult.handled;
    }
    widget.onSelectedIdChanged(newId);
    scrollEventIntoView(newId);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: true,
      canRequestFocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
        },
        child: widget.child,
      ),
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
  });

  final List<GroupEventCardModel> tournaments;
  final PageStorageKey<String> storageKey;
  final String selectedId;
  final String? loadingId;
  final ValueChanged<String> onSelect;
  final ValueChanged<GroupEventCardModel> onActivate;
  final Map<String, GlobalKey> tileKeys;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = calculateTournamentEventGridColumns(
          constraints.maxWidth,
        );
        return GridView.builder(
          key: storageKey,
          controller: scrollController,
          // Selection border + glow paint outside the card bounds; do not
          // hard-clip each grid cell or the primary ring is shaved at edges.
          clipBehavior: Clip.none,
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          itemCount: tournaments.length,
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
            final tournament = tournaments[i];
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
              borderRadius: 10,
              // Selection border + glow must NOT share a clip with content.
              // Clip.antiAlias on the same Container crops the ring/shadow
              // (especially corners). Outer shell paints chrome; inner
              // ClipRRect keeps media/content rounded — same layering as
              // For You / desktop_game_card.dart.
              child: Container(
                decoration: BoxDecoration(
                  color: highlight ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        widget.selected
                            ? kPrimaryColor.withValues(alpha: 0.96)
                            : (_hovered
                                ? kWhiteColor.withValues(alpha: 0.12)
                                : kDividerColor),
                    width: widget.selected ? 2 : 1,
                  ),
                  boxShadow:
                      widget.selected
                          ? [
                            BoxShadow(
                              color: kPrimaryColor.withValues(alpha: 0.16),
                              blurRadius: 8,
                              spreadRadius: 0.5,
                            ),
                          ]
                          : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TournamentTileMedia(
                        event: t,
                        statusColor: categoryColor,
                        selected: widget.selected,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Category badge, moved off the photo onto the
                                  // solid body where its colours read.
                                  _StatusBadge(category: t.tourEventCategory),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      t.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kWhiteColor,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                        height: 1.17,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  DesktopEventFavoriteIconButton(
                                    event: t,
                                    compact: true,
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Text(
                                _eventMetaLine(t),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  if (t.timeControl.isNotEmpty)
                                    Flexible(
                                      child: _TournamentTilePill(
                                        label: t.timeControl,
                                        icon: Icons.schedule_rounded,
                                      ),
                                    ),
                                  if (t.maxAvgElo > 0) ...[
                                    const SizedBox(width: 8),
                                    _TournamentTilePill(
                                      label: 'Avg ${t.maxAvgElo}',
                                      icon: Icons.leaderboard_rounded,
                                    ),
                                  ],
                                  const Spacer(),
                                  if (widget.loading)
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.6,
                                        valueColor: AlwaysStoppedAnimation(
                                          kPrimaryColor,
                                        ),
                                      ),
                                    )
                                  else
                                    Icon(
                                      Icons.open_in_new_rounded,
                                      size: 14,
                                      color: categoryColor,
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
      ),
    );
  }
}

class _TournamentTileMedia extends StatelessWidget {
  const _TournamentTileMedia({
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
      width: 122,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _DesktopEventVisual(event: event, borderRadius: BorderRadius.zero),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  kBlackColor.withValues(alpha: 0.46),
                  kBlackColor.withValues(alpha: 0.04),
                  kBlackColor.withValues(alpha: 0.18),
                ],
                stops: const [0, 0.56, 1],
              ),
            ),
          ),
          // Category badge removed from the photo — it was unreadable against
          // the artwork. The labelled badge now sits on the solid body.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color:
                        selected
                            ? statusColor.withValues(alpha: 0.32)
                            : kWhiteColor.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TournamentTilePill extends StatelessWidget {
  const _TournamentTilePill({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: kWhiteColor70),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
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

String _eventTimeControlAsset(String timeControl) {
  final normalized = timeControl.toLowerCase();
  if (normalized.contains('ultra')) return 'assets/pngs/ultra_bullet.png';
  if (normalized.contains('bullet')) return 'assets/pngs/bullet.png';
  if (normalized.contains('blitz')) return 'assets/pngs/blitz.png';
  if (normalized.contains('rapid')) return 'assets/pngs/rapid.png';
  return 'assets/pngs/classical.png';
}

bool _shouldShowStatusBadge(TourEventCategory category) {
  return category != TourEventCategory.ongoing;
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
    this.gameId,
  });

  final String eventId;
  final EventGameCardFocusColumn column;
  final int gameIndex;
  final String? gameId;

  bool get isEvent => column == EventGameCardFocusColumn.event;
  bool get isGame => column == EventGameCardFocusColumn.game;

  bool matches(_ForYouCardSelection other) {
    return eventId == other.eventId &&
        column == other.column &&
        gameIndex == other.gameIndex &&
        gameId == other.gameId;
  }
}

class _ForYouNavigationBookmark {
  const _ForYouNavigationBookmark({this.selection, this.scrollOffset = 0});

  final _ForYouCardSelection? selection;
  final double scrollOffset;
}

final _forYouNavigationBookmarkProvider =
    StateProvider.family<_ForYouNavigationBookmark, String>(
      (ref, tabId) => const _ForYouNavigationBookmark(),
    );

/// Full-width desktop version of the tablet For You hierarchy: compact
/// destination cards, then one event per row with a responsive line of larger
/// board previews.
///
/// Sources:
///   - `forYouEventsProvider`         → paginated events
///   - `forYouEventSnapshotProvider`  → per-event games (lazily watched per row)
class _ForYouFeed extends ConsumerStatefulWidget {
  const _ForYouFeed({
    required this.tabId,
    required this.paneWidth,
    required this.onOpenTournament,
  });

  final String tabId;
  final double paneWidth;
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
  static const double _kCompactCacheExtent = 900;
  static const double _kBoardCacheExtent = 360;

  final FocusNode _focusNode = FocusNode(
    debugLabel: 'DesktopForYouEventGameCards',
  );
  late final ScrollController _scroll;
  final Set<String> _animatedEventIds = <String>{};
  final Map<String, GlobalKey> _eventKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _selectionItemKeys = <String, GlobalKey>{};
  final Map<String, List<String>> _visibleGameIds = <String, List<String>>{};
  final Map<String, bool> _eventVisibility = <String, bool>{};
  Timer? _scrollIdleTimer;
  _ForYouCardSelection? _selection;
  bool _liveCardsPausedForScroll = false;
  bool _keyboardScrollingActive = false;
  int? _middleDragPointer;
  double? _middleDragLastY;
  double _lastScrollOffset = 0;
  int _visibilityRequestSerial = 0;
  bool _restoreSelectionPending = false;
  int _eventColumns = 2;
  late final StateController<_ForYouNavigationBookmark>
  _navigationBookmarkController;
  late final StateController<Set<String>> _liveCardsPauseReasonsController;

  String get _liveCardsPauseReason => 'desktop_for_you_scroll_${widget.tabId}';

  @override
  void initState() {
    super.initState();
    _navigationBookmarkController = ref.read(
      _forYouNavigationBookmarkProvider(widget.tabId).notifier,
    );
    _liveCardsPauseReasonsController = ref.read(
      liveGameCardsPauseReasonsProvider.notifier,
    );
    final bookmark = ref.read(_forYouNavigationBookmarkProvider(widget.tabId));
    _selection = bookmark.selection;
    _lastScrollOffset = bookmark.scrollOffset;
    _restoreSelectionPending = bookmark.selection != null;
    _scroll = ScrollController(
      initialScrollOffset:
          bookmark.scrollOffset.clamp(0.0, double.infinity).toDouble(),
    );
    _scroll.addListener(_onScroll);
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyboardScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _restoreSavedSelectionIfPossible();
    });
  }

  @override
  void dispose() {
    _persistNavigationBookmark();
    _scrollIdleTimer?.cancel();
    _setLiveCardsPausedForScroll(false);
    _scroll.removeListener(_onScroll);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyboardScroll);
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    _lastScrollOffset = _scroll.position.pixels;
    _markScrolling();
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    if (max - cur <= 300) {
      ref.read(forYouEventsProvider.notifier).loadMore();
    }
  }

  void _persistNavigationBookmark() {
    _navigationBookmarkController.state = _ForYouNavigationBookmark(
      selection: _selection,
      scrollOffset: _lastScrollOffset,
    );
  }

  void _restoreSavedSelectionIfPossible() {
    final selection = _selection;
    if (!_restoreSelectionPending || selection == null) return;
    if (_selectionItemKeyFor(selection)?.currentContext == null) return;
    _restoreSelectionPending = false;
    _ensureSelectionVisible(selection);
  }

  void _markScrolling() {
    _setLiveCardsPausedForScroll(true);
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(_kScrollIdleDelay, _markLiveCardsIdle);
  }

  void _markLiveCardsIdle() {
    if (!mounted) return;
    _setLiveCardsPausedForScroll(false);
  }

  void _setLiveCardsPausedForScroll(bool paused) {
    if (_liveCardsPausedForScroll == paused) return;
    _liveCardsPausedForScroll = paused;
    setLiveGameCardsPausedWithNotifier(
      _liveCardsPauseReasonsController,
      reason: _liveCardsPauseReason,
      paused: paused,
    );
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

  GlobalKey _selectionItemKey(String eventId, [String? gameId]) {
    final identity =
        gameId == null
            ? 'event\u0000$eventId'
            : 'game\u0000$eventId\u0000$gameId';
    return _selectionItemKeys.putIfAbsent(
      identity,
      () => GlobalKey(
        debugLabel:
            gameId == null
                ? 'desktop-for-you-event-selection-$eventId'
                : 'desktop-for-you-game-selection-$eventId-$gameId',
      ),
    );
  }

  GlobalKey? _selectionItemKeyFor(_ForYouCardSelection selection) {
    if (selection.isEvent) return _selectionItemKey(selection.eventId);
    var gameId = selection.gameId;
    if (gameId == null) {
      final gameIds = _gameIdsForEventId(selection.eventId);
      if (gameIds.isEmpty) return null;
      gameId =
          gameIds[selection.gameIndex.clamp(0, gameIds.length - 1).toInt()];
    }
    return _selectionItemKey(selection.eventId, gameId);
  }

  List<String> _gameIdsForEventId(String eventId) {
    final events = ref.read(forYouEventsProvider).events;
    for (final event in events) {
      if (event.id == eventId) return _gameIdsFor(event);
    }
    return const <String>[];
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
    if (!visible) {
      _syncSelectionWithEvents(ref.read(forYouEventsProvider).events);
      _persistNavigationBookmark();
    }
  }

  void _setVisibleGameIds(String eventId, List<String> gameIds) {
    if (!mounted) return;
    final previous = _visibleGameIds[eventId] ?? const <String>[];
    if (previous.length == gameIds.length) {
      var unchanged = true;
      for (var i = 0; i < previous.length; i++) {
        if (previous[i] != gameIds[i]) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return;
    }
    setState(() {
      _visibleGameIds[eventId] = List<String>.unmodifiable(gameIds);
      final selection = _selection;
      if (selection?.eventId == eventId && selection!.isGame) {
        if (gameIds.isEmpty) {
          _selection = _ForYouCardSelection(
            eventId: eventId,
            column: EventGameCardFocusColumn.event,
          );
        } else {
          final savedIndex =
              selection.gameId == null
                  ? -1
                  : gameIds.indexOf(selection.gameId!);
          final resolvedIndex =
              savedIndex >= 0
                  ? savedIndex
                  : selection.gameIndex.clamp(0, gameIds.length - 1).toInt();
          _selection = _ForYouCardSelection(
            eventId: eventId,
            column: EventGameCardFocusColumn.game,
            gameIndex: resolvedIndex,
            gameId: gameIds[resolvedIndex],
          );
        }
      }
    });
    _persistNavigationBookmark();
    if (_restoreSelectionPending && _selection?.eventId == eventId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreSavedSelectionIfPossible();
      });
    }
  }

  List<String> _gameIdsFor(GroupEventCardModel event) {
    final reported = _visibleGameIds[event.id];
    final snapshot = _snapshotFor(event.id);
    final snapshotIds =
        snapshot == null
            ? const <String>[]
            : selectDesktopForYouPreviewRoundGames(
              snapshot.visibleGames,
            ).map((game) => game.gameId).toList();
    if (reported == null) return snapshotIds;
    // The rendered strip reports exactly which game cards fit after layout,
    // but that callback can briefly lag behind provider updates or keep a stale
    // empty pass. If a snapshot already has games, let Right Arrow enter the
    // first board card instead of appearing dead.
    return reported.isNotEmpty ? reported : snapshotIds;
  }

  ForYouEventGamesSnapshot? _snapshotFor(String eventId) {
    // The visible strip can render immediately from the prefetched cache while
    // the auto-disposed snapshot provider is being re-established after
    // returning from an event/game tab. Keyboard navigation and activation
    // must use the same snapshot the user can already see.
    return ref.read(forYouEventSnapshotProvider(eventId)).valueOrNull ??
        ref.read(forYouTopGamesSnapshotCacheProvider)[eventId];
  }

  int _gameCountFor(GroupEventCardModel event) {
    return _gameIdsFor(event).length;
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

  int _gameColumnCountFor(DesktopCardLayout layout) {
    final gameAreaWidth =
        (widget.paneWidth -
                40 -
                _ForYouEventSection.eventCardWidth -
                _ForYouEventSection.eventToGamesGap)
            .clamp(0.0, double.infinity)
            .toDouble();
    if (layout == DesktopCardLayout.grid) {
      return DesktopForYouStripLayout.compute(
        available: gameAreaWidth,
        gameCount: 6,
      ).visibleCount;
    }
    return DesktopGameCardsFlow.columnCountForWidth(layout, gameAreaWidth);
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

  bool _handleGlobalKeyboardScroll(KeyEvent event) {
    if (!mounted || !_keyboardScrollingActive || _hasNavigationModifier()) {
      return false;
    }
    // When the For You focus host (or one of its descendants) owns focus,
    // `Focus.onKeyEvent` below will receive this same physical key. Handling
    // it here as well advances the structured cursor twice: event -> board ->
    // next event, or board -> board two places away. The hardware hook is only
    // the fallback for focus parked on sibling shell chrome after navigation.
    if (_focusNode.hasFocus) return false;
    final key = event.logicalKey;
    final isNavigationKey =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    final isActivationKey =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if ((!isNavigationKey && !isActivationKey) || _hasEditableTextFocus()) {
      return false;
    }
    // Own repeat events without advancing the structured selection again.
    // Otherwise they bubble to PaneKeyboardScroll and move the viewport away
    // from the highlighted event or board.
    if (event is KeyRepeatEvent) return true;
    if (event is! KeyDownEvent) return false;
    final events = ref.read(forYouEventsProvider).events;
    final result = _handleKeyboard(event, events);
    if (result == KeyEventResult.handled) return true;
    // A selection host must never fall back to raw pixel scrolling. That can
    // move the viewport while leaving the highlight behind. Consume the
    // navigation key and wait for a valid event/game target instead.
    return isNavigationKey;
  }

  bool _hasEditableTextFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _startMiddleDrag(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons & kMiddleMouseButton == 0) {
      return;
    }
    _focusNode.requestFocus();
    setState(() {
      _middleDragPointer = event.pointer;
      _middleDragLastY = event.position.dy;
    });
  }

  void _updateMiddleDrag(PointerMoveEvent event) {
    if (event.pointer != _middleDragPointer || !_scroll.hasClients) return;
    final previousY = _middleDragLastY;
    _middleDragLastY = event.position.dy;
    if (previousY == null) return;
    final position = _scroll.position;
    final target =
        (position.pixels + previousY - event.position.dy)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    if ((target - position.pixels).abs() > 0.1) {
      position.jumpTo(target);
    }
  }

  void _stopMiddleDrag(PointerEvent event) {
    if (event.pointer != _middleDragPointer) return;
    setState(() {
      _middleDragPointer = null;
      _middleDragLastY = null;
    });
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
      final firstEvent = visibleEvents.first;
      _selection = _ForYouCardSelection(
        eventId: firstEvent.id,
        column: EventGameCardFocusColumn.event,
      );
    }
  }

  KeyEventResult _handleKeyboard(
    KeyEvent event,
    List<GroupEventCardModel> events,
  ) {
    if (_hasNavigationModifier()) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isActivationKey =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final isMoveKey =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    if (!isActivationKey && !isMoveKey) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (isActivationKey) {
      _activateSelection(events);
      return KeyEventResult.handled;
    }

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
      gameLayout: EventGameCardNavigationLayout.grid,
      gameColumnCountForEvent: (index) => _gameColumnCountFor(layout),
      eventColumnCount: _eventColumns,
      hierarchicalGroups: true,
    );
    if (nextFocus == null) return KeyEventResult.ignored;

    final nextEvent = visibleEvents[nextFocus.eventIndex];
    final nextGameIds = _gameIdsFor(nextEvent);
    final nextGameId =
        nextFocus.isGame &&
                nextFocus.gameIndex >= 0 &&
                nextFocus.gameIndex < nextGameIds.length
            ? nextGameIds[nextFocus.gameIndex]
            : null;
    final nextSelection = _ForYouCardSelection(
      eventId: nextEvent.id,
      column: nextFocus.column,
      gameIndex: nextFocus.gameIndex,
      gameId: nextGameId,
    );
    setState(() {
      _selection = nextSelection;
    });
    _persistNavigationBookmark();
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    if (nextFocus.eventIndex >= visibleEvents.length - 2) {
      ref.read(forYouEventsProvider.notifier).loadMore();
    }
    _ensureSelectionVisible(nextSelection, navigationKey: key);
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
        _openEvent(event);
        return;
      case EventGameCardActivationTarget.inGameView:
        // Right Arrow moves For You focus onto a game; Enter there opens the
        // selected game into the board + notation in-game view.
        break;
    }

    final snapshot = _snapshotFor(event.id);
    if (snapshot == null) return;
    final gameContext = _forYouGameContext(snapshot);
    final gameIds = _gameIdsFor(event);
    if (gameIds.isEmpty) return;
    final gamesById = {
      for (final game in gameContext.stripGames) game.gameId: game,
    };
    final games = [
      for (final gameId in gameIds)
        if (gamesById[gameId] != null) gamesById[gameId]!,
    ];
    if (games.isEmpty) return;
    final savedGameIndex =
        selection.gameId == null
            ? -1
            : games.indexWhere((game) => game.gameId == selection.gameId);
    final gameIndex =
        savedGameIndex >= 0
            ? savedGameIndex
            : _clampIndex(selection.gameIndex, 0, games.length - 1);
    _persistNavigationBookmark();
    openTournamentGameTab(
      ref,
      games[gameIndex],
      event.title,
      eventGames: gameContext.boardGames,
      viewSource: ChessboardView.forYou,
      eventBroadcastId: event.id,
    );
  }

  void _openEvent(GroupEventCardModel event) {
    _persistNavigationBookmark();
    widget.onOpenTournament(event);
  }

  void _selectGame(GroupEventCardModel event, String gameId) {
    final gameIds = _gameIdsFor(event);
    final gameIndex = gameIds.indexOf(gameId);
    if (gameIndex < 0) return;
    final selection = _ForYouCardSelection(
      eventId: event.id,
      column: EventGameCardFocusColumn.game,
      gameIndex: gameIndex,
      gameId: gameId,
    );
    if (_selection?.matches(selection) != true) {
      setState(() {
        _selection = selection;
      });
    }
    _persistNavigationBookmark();
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
  }

  int _clampIndex(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _ensureSelectionVisible(
    _ForYouCardSelection expected, {
    LogicalKeyboardKey? navigationKey,
    int attempt = 0,
    int? requestSerial,
  }) {
    final serial = requestSerial ?? ++_visibilityRequestSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || serial != _visibilityRequestSerial) return;
      final current = _selection;
      if (current == null || !current.matches(expected)) return;
      final selectedContext = _selectionItemKeyFor(expected)?.currentContext;
      if (selectedContext != null) {
        Scrollable.ensureVisible(
          selectedContext,
          duration: Duration.zero,
          alignmentPolicy:
              _isBackwardNavigationKey(navigationKey)
                  ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
                  : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        if (_restoreSelectionPending) _restoreSelectionPending = false;
        return;
      }
      if (navigationKey == null ||
          attempt >= 2 ||
          !_scroll.hasClients ||
          navigationKey == LogicalKeyboardKey.arrowLeft ||
          navigationKey == LogicalKeyboardKey.arrowRight) {
        return;
      }

      final position = _scroll.position;
      final isBackward = _isBackwardNavigationKey(navigationKey);
      final target = switch (navigationKey) {
        LogicalKeyboardKey.home => position.minScrollExtent,
        LogicalKeyboardKey.end => position.maxScrollExtent,
        _ =>
          (position.pixels +
                  (isBackward ? -1 : 1) *
                      position.viewportDimension *
                      (navigationKey == LogicalKeyboardKey.pageUp ||
                              navigationKey == LogicalKeyboardKey.pageDown
                          ? 0.9
                          : 0.45))
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble(),
      };
      if ((target - position.pixels).abs() < 0.5) return;
      _scroll.jumpTo(target);
      _ensureSelectionVisible(
        expected,
        navigationKey: navigationKey,
        attempt: attempt + 1,
        requestSerial: serial,
      );
    });
  }

  bool _isBackwardNavigationKey(LogicalKeyboardKey? key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home;
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
    final streamingEnabled = ref.watch(
      desktopTabsProvider.select((state) => state.activeId == widget.tabId),
    );
    _keyboardScrollingActive = streamingEnabled;

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
    final showTrailingSpinner = state.hasMore && !state.isLoading;
    _eventColumns = 1;
    final visibleEvents = _visibleEvents(events);
    // +1 for the collection cards header, +1 for the trailing spinner.
    final itemCount = 1 + visibleEvents.length + (showTrailingSpinner ? 1 : 0);

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
        child: MouseRegion(
          cursor:
              _middleDragPointer == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.grabbing,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _startMiddleDrag,
            onPointerMove: _updateMiddleDrag,
            onPointerUp: _stopMiddleDrag,
            onPointerCancel: _stopMiddleDrag,
            child: RefreshIndicator(
              onRefresh:
                  () => ref.read(forYouEventsProvider.notifier).refresh(),
              color: kPrimaryColor,
              backgroundColor: kBlack2Color,
              child: ListView.builder(
                key: PageStorageKey<String>(
                  'desktop_for_you_feed_${widget.tabId}',
                ),
                controller: _scroll,
                physics: const DesktopScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                itemCount: itemCount,
                // ignore: deprecated_member_use
                cacheExtent: _cacheExtentFor(viewMode),
                // Each For You row owns real chessboard previews plus a bounded
                // live batch for the cards that fit the row. AutomaticKeepAlive
                // forces those subscriptions to stay live for off-screen rows the
                // viewport has already left behind. Disable it so the cache window
                // is the only thing keeping nearby rows hot.
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
                      onSmartCollectionTap: (type) {
                        final tabId = ref
                            .read(desktopTabsProvider.notifier)
                            .open(
                              TabKind.smartGames,
                              title: _smartCollectionTitle(type),
                              reuseExisting: false,
                            );
                        ref
                            .read(desktopSmartGamesTypeByTabIdProvider.notifier)
                            .update((types) => {...types, tabId: type});
                      },
                    );
                  }
                  final eventIndex = index - 1;
                  if (eventIndex >= visibleEvents.length) {
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
                  final event = visibleEvents[eventIndex];
                  // RepaintBoundary isolates each row's repaints from the scrolling
                  // list so live clock ticks and PV/board updates don't repaint the
                  // whole viewport. Cheap to add — Flutter inserts these for grid
                  // tiles by default but not for ListView.builder children.
                  return _buildEventRow(
                    event,
                    streamingEnabled,
                    isFirst: eventIndex == 0,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEventRow(
    GroupEventCardModel event,
    bool streamingEnabled, {
    required bool isFirst,
  }) {
    return RepaintBoundary(
      child: _ForYouEventSection(
        key: _eventKey(event.id),
        event: event,
        isFirst: isFirst,
        selection: _selection?.eventId == event.id ? _selection : null,
        eventItemKey: _selectionItemKey(event.id),
        gameItemKeyFor: (gameId) => _selectionItemKey(event.id, gameId),
        animatedEventIds: _animatedEventIds,
        streamingEnabled: streamingEnabled,
        onOpen: () => _openEvent(event),
        onSelectGame: (gameId) => _selectGame(event, gameId),
        onVisibilityChanged:
            (visible) => _setEventVisibility(event.id, visible),
        onVisibleGameIdsChanged:
            (gameIds) => _setVisibleGameIds(event.id, gameIds),
      ),
    );
  }
}

/// One event in the For You feed.
///
/// Layout: one event summary on the left followed by one responsive row of
/// real chessboard previews. The section keeps the familiar desktop hierarchy
/// while retaining the denser board cards and keyboard behavior.
/// The preview count follows the available board area so cards do not become
/// cramped on narrower laptops. Hides itself when the snapshot resolves empty.
class _ForYouEventSection extends ConsumerWidget {
  const _ForYouEventSection({
    super.key,
    required this.event,
    required this.isFirst,
    required this.selection,
    required this.eventItemKey,
    required this.gameItemKeyFor,
    required this.animatedEventIds,
    required this.streamingEnabled,
    required this.onOpen,
    required this.onSelectGame,
    required this.onVisibilityChanged,
    required this.onVisibleGameIdsChanged,
  });

  static const double eventCardWidth = 280;
  static const double eventToGamesGap = 18;

  final GroupEventCardModel event;
  final bool isFirst;
  final _ForYouCardSelection? selection;
  final Key eventItemKey;
  final Key Function(String gameId) gameItemKeyFor;
  final Set<String> animatedEventIds;
  final bool streamingEnabled;
  final VoidCallback onOpen;
  final ValueChanged<String> onSelectGame;
  final ValueChanged<bool> onVisibilityChanged;
  final ValueChanged<List<String>> onVisibleGameIdsChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cachedSnapshot = ref.watch(
      forYouTopGamesSnapshotCacheProvider.select((cache) => cache[event.id]),
    );
    final watchedSnapshotAsync = ref.watch(
      streamingEnabled
          ? forYouEventGamesWithAutoRefreshProvider(event.id)
          : forYouEventSnapshotProvider(event.id),
    );
    // RPC-selected membership is authoritative. Realtime only updates the
    // bounded rendered rows and requests a targeted RPC refresh on finish.
    final AsyncValue<ForYouEventGamesSnapshot> snapshotAsync =
        watchedSnapshotAsync.when<AsyncValue<ForYouEventGamesSnapshot>>(
          data: AsyncValue.data,
          loading:
              () =>
                  cachedSnapshot != null
                      ? AsyncValue.data(cachedSnapshot)
                      : const AsyncValue.loading(),
          error:
              (error, stack) =>
                  cachedSnapshot != null
                      ? AsyncValue.data(cachedSnapshot)
                      : AsyncValue.error(error, stack),
        );
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

    final row = Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : 28),
      child: SizedBox(
        height: _rowHeightFor(layout),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeyedSubtree(
              key: eventItemKey,
              child: SizedBox(
                width: eventCardWidth,
                child: _ForYouEventSummaryCard(
                  event: event,
                  selected: selection?.isEvent ?? false,
                  onOpen: onOpen,
                ),
              ),
            ),
            const SizedBox(width: eventToGamesGap),
            Expanded(
              child: _GamesStrip(
                eventId: event.id,
                tournamentTitle: event.title,
                snapshotAsync: snapshotAsync,
                layout: layout,
                streamingEnabled: streamingEnabled,
                selectedGameIndex:
                    selection?.isGame == true ? selection!.gameIndex : null,
                gameItemKeyFor: gameItemKeyFor,
                onSelectGame: onSelectGame,
                onVisibleGameIdsChanged: onVisibleGameIdsChanged,
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
              borderRadius: 10,
              // Selection border + glow must NOT share a clip with content.
              // Clip.antiAlias on the same Container crops the ring/shadow
              // (especially corners). Outer shell paints chrome; inner
              // ClipRRect keeps media/content rounded — same layering as
              // desktop_game_card.dart.
              child: Container(
                decoration: BoxDecoration(
                  color: highlighted ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        widget.selected
                            ? kPrimaryColor.withValues(alpha: 0.96)
                            : _hovered
                            ? kWhiteColor.withValues(alpha: 0.12)
                            : kDividerColor,
                    width: widget.selected ? 2 : 1,
                  ),
                  boxShadow:
                      widget.selected
                          ? [
                            BoxShadow(
                              color: kPrimaryColor.withValues(alpha: 0.16),
                              blurRadius: 8,
                              spreadRadius: 0.5,
                            ),
                          ]
                          : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mediaHeight =
                          (constraints.maxHeight * 0.42)
                              .clamp(104.0, 150.0)
                              .toDouble();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: mediaHeight,
                            child: _EventCardMedia(
                              event: event,
                              padding: 8,
                              imageFit: BoxFit.cover,
                              showFavorite: false,
                            ),
                          ),
                          Expanded(child: _ForYouEventInfoPanel(event: event)),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForYouEventInfoPanel extends StatelessWidget {
  const _ForYouEventInfoPanel({required this.event});

  final GroupEventCardModel event;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: kBlack2Color),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DesktopEventFavoriteIconButton(event: event, compact: true),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Image.asset(
                  _eventTimeControlAsset(event.timeControl),
                  width: 17,
                  height: 17,
                  fit: BoxFit.contain,
                  cacheWidth:
                      (17 * MediaQuery.devicePixelRatioOf(context)).round(),
                  cacheHeight:
                      (17 * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
                if (event.maxAvgElo > 0) ...[
                  const SizedBox(width: 7),
                  Text(
                    'Avg ${event.maxAvgElo}',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 12, color: kDividerColor),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _eventMetaLine(event),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 10.5,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            DesktopEventCountdownLine(event: event),
          ],
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
    required this.streamingEnabled,
    required this.selectedGameIndex,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.onVisibleGameIdsChanged,
  });

  final String eventId;
  final String tournamentTitle;
  final AsyncValue<ForYouEventGamesSnapshot> snapshotAsync;
  final DesktopCardLayout layout;
  final bool streamingEnabled;
  final int? selectedGameIndex;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final ValueChanged<List<String>> onVisibleGameIdsChanged;

  Widget _selectionTarget(String gameId, Widget child) {
    return KeyedSubtree(key: gameItemKeyFor(gameId), child: child);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardStreamingEnabled = streamingEnabled;

    return snapshotAsync.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (snapshot) {
        if (snapshot.visibleGames.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onVisibleGameIdsChanged(const <String>[]);
          });
          return const SizedBox.shrink();
        }
        final gameContext = _forYouGameContext(snapshot);
        if (layout != DesktopCardLayout.grid) {
          if (snapshot.isGroupEvent) {
            return _TeamGamesStrip(
              eventId: eventId,
              tournamentTitle: tournamentTitle,
              snapshot: snapshot,
              boardGames: gameContext.boardGames,
              layout: layout,
              streamingEnabled: cardStreamingEnabled,
              selectedGameIndex: selectedGameIndex,
              gameItemKeyFor: gameItemKeyFor,
              onSelectGame: onSelectGame,
              onVisibleGameIdsChanged: onVisibleGameIdsChanged,
            );
          }
          if (snapshot.isKnockoutTournament) {
            return _KnockoutGamesStrip(
              eventId: eventId,
              tournamentTitle: tournamentTitle,
              snapshot: snapshot,
              boardGames: gameContext.boardGames,
              layout: layout,
              streamingEnabled: cardStreamingEnabled,
              selectedGameIndex: selectedGameIndex,
              gameItemKeyFor: gameItemKeyFor,
              onSelectGame: onSelectGame,
              onVisibleGameIdsChanged: onVisibleGameIdsChanged,
            );
          }
          // Render only the bounded, server-selected category snapshot.
          final allGames = gameContext.stripGames;
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
                games: snapshot.visibleGames,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onVisibleGameIdsChanged(
                  games.map((game) => game.gameId).toList(growable: false),
                );
              });
              return DesktopGameCardsFlow(
                layout: layout,
                itemCount: games.length,
                embedded: true,
                itemBuilder:
                    (context, i) => _selectionTarget(
                      games[i].gameId,
                      LiveDesktopGameCard(
                        game: games[i],
                        eventGames: gameContext.boardGames,
                        tournamentTitle: tournamentTitle,
                        layout: layout,
                        selected: selectedGameIndex == i,
                        onSelect: () => onSelectGame(games[i].gameId),
                        viewSource: ChessboardView.forYou,
                        liveBatchKey: liveBatchKey,
                        streamingEnabled: cardStreamingEnabled,
                        allowStockfishFallback: true,
                      ),
                    ),
              );
            },
          );
        }

        final stripGames = gameContext.stripGames;
        return LayoutBuilder(
          builder: (context, constraints) {
            final strip = DesktopForYouStripLayout.compute(
              available: constraints.maxWidth,
              gameCount: stripGames.length,
            );
            final games = stripGames
                .take(strip.visibleCount)
                .toList(growable: false);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onVisibleGameIdsChanged(
                games.map((game) => game.gameId).toList(growable: false),
              );
            });
            final liveBatchKey = _desktopForYouLiveBatchKey(
              eventId: eventId,
              tourId: snapshot.tourId,
              games: snapshot.visibleGames,
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < games.length; i++) ...[
                  if (i > 0)
                    const SizedBox(width: DesktopForYouStripLayout.gap),
                  SizedBox(
                    width: strip.cardWidth,
                    child: _selectionTarget(
                      games[i].gameId,
                      LiveDesktopGameCard(
                        game: games[i],
                        eventGames: gameContext.boardGames,
                        tournamentTitle: tournamentTitle,
                        layout: DesktopCardLayout.grid,
                        selected: selectedGameIndex == i,
                        onSelect: () => onSelectGame(games[i].gameId),
                        viewSource: ChessboardView.forYou,
                        liveBatchKey: liveBatchKey,
                        streamingEnabled: cardStreamingEnabled,
                        allowStockfishFallback: true,
                      ),
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

const double _kForYouGroupGap = 10;
const double _kForYouGroupMinWidth = 284;
const double _kForYouGroupMaxWidth = 420;
const double _kForYouGroupHeaderHeight = 54;
const double _kForYouGroupHeaderGap = 8;

int _forYouGroupPanelCount(double maxWidth, int groupCount) {
  if (groupCount <= 0) return 0;
  if (!maxWidth.isFinite || maxWidth <= 0) return 1;
  return ((maxWidth + _kForYouGroupGap) /
          (_kForYouGroupMinWidth + _kForYouGroupGap))
      .floor()
      .clamp(1, groupCount)
      .toInt();
}

double _forYouGroupPanelWidth(double maxWidth, int panelCount) {
  if (!maxWidth.isFinite || maxWidth <= 0 || panelCount <= 0) {
    return _kForYouGroupMinWidth;
  }
  final available = maxWidth - (_kForYouGroupGap * (panelCount - 1));
  return (available / panelCount).clamp(
    _kForYouGroupMinWidth,
    _kForYouGroupMaxWidth,
  );
}

int _forYouGamesPerGroupPanel(double maxHeight, DesktopCardLayout layout) {
  final rowHeight =
      maxHeight.isFinite
          ? maxHeight
          : _ForYouEventSection._rowHeightFor(layout);
  final metrics = DesktopGameCardsFlow.metricsFor(DesktopCardLayout.compact);
  final available =
      rowHeight - _kForYouGroupHeaderHeight - _kForYouGroupHeaderGap;
  return ((available + metrics.spacing) /
          (metrics.tileHeight + metrics.spacing))
      .floor()
      .clamp(1, 3)
      .toInt();
}

class _TeamGamesStrip extends StatelessWidget {
  const _TeamGamesStrip({
    required this.eventId,
    required this.tournamentTitle,
    required this.snapshot,
    required this.boardGames,
    required this.layout,
    required this.streamingEnabled,
    required this.selectedGameIndex,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.onVisibleGameIdsChanged,
  });

  final String eventId;
  final String tournamentTitle;
  final ForYouEventGamesSnapshot snapshot;
  final List<GamesTourModel> boardGames;
  final DesktopCardLayout layout;
  final bool streamingEnabled;
  final int? selectedGameIndex;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final ValueChanged<List<String>> onVisibleGameIdsChanged;

  @override
  Widget build(BuildContext context) {
    final groups = buildDesktopTeamMatchGroups(snapshot.visibleGames);
    if (groups.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onVisibleGameIdsChanged(const <String>[]);
      });
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelCount = _forYouGroupPanelCount(
          constraints.maxWidth,
          groups.length,
        );
        final gamesPerPanel = _forYouGamesPerGroupPanel(
          constraints.maxHeight,
          layout,
        );
        final displayedGroups = groups.take(panelCount).toList(growable: false);
        final displayedGameIds = <String>[];
        final panelGames = <DesktopTeamMatchGroup, List<GamesTourModel>>{};
        for (final group in displayedGroups) {
          final games = group.gameModels
              .take(gamesPerPanel)
              .toList(growable: false);
          panelGames[group] = games;
          displayedGameIds.addAll(games.map((game) => game.gameId));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onVisibleGameIdsChanged(List<String>.unmodifiable(displayedGameIds));
        });
        final selectedGameId =
            selectedGameIndex != null &&
                    selectedGameIndex! >= 0 &&
                    selectedGameIndex! < displayedGameIds.length
                ? displayedGameIds[selectedGameIndex!]
                : null;
        final liveBatchKey = _desktopForYouLiveBatchKey(
          eventId: eventId,
          tourId: snapshot.tourId,
          games: snapshot.visibleGames,
        );
        final panelWidth = _forYouGroupPanelWidth(
          constraints.maxWidth,
          displayedGroups.length,
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < displayedGroups.length; i++) ...[
              if (i > 0) const SizedBox(width: _kForYouGroupGap),
              SizedBox(
                width: panelWidth,
                child: _ForYouTeamMatchPanel(
                  group: displayedGroups[i],
                  games: panelGames[displayedGroups[i]] ?? const [],
                  selectedGameId: selectedGameId,
                  gameItemKeyFor: gameItemKeyFor,
                  onSelectGame: onSelectGame,
                  tournamentTitle: tournamentTitle,
                  eventGames: boardGames,
                  liveBatchKey: liveBatchKey,
                  streamingEnabled: streamingEnabled,
                ),
              ),
            ],
            const Spacer(),
          ],
        );
      },
    );
  }
}

class _KnockoutGamesStrip extends StatelessWidget {
  const _KnockoutGamesStrip({
    required this.eventId,
    required this.tournamentTitle,
    required this.snapshot,
    required this.boardGames,
    required this.layout,
    required this.streamingEnabled,
    required this.selectedGameIndex,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.onVisibleGameIdsChanged,
  });

  final String eventId;
  final String tournamentTitle;
  final ForYouEventGamesSnapshot snapshot;
  final List<GamesTourModel> boardGames;
  final DesktopCardLayout layout;
  final bool streamingEnabled;
  final int? selectedGameIndex;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final ValueChanged<List<String>> onVisibleGameIdsChanged;

  @override
  Widget build(BuildContext context) {
    final groupedByMatch = KnockoutMatchDetector.groupByMatches(
      snapshot.visibleGames,
    );
    final headers = [
      for (final entry in groupedByMatch.entries)
        KnockoutMatchDetector.createMatchHeader(entry.key, entry.value),
    ];
    if (headers.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onVisibleGameIdsChanged(const <String>[]);
      });
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelCount = _forYouGroupPanelCount(
          constraints.maxWidth,
          headers.length,
        );
        final gamesPerPanel = _forYouGamesPerGroupPanel(
          constraints.maxHeight,
          layout,
        );
        final displayedHeaders = headers
            .take(panelCount)
            .toList(growable: false);
        final displayedGameIds = <String>[];
        final panelGames = <MatchHeaderModel, List<GamesTourModel>>{};
        for (final header in displayedHeaders) {
          final games = header.games
              .take(gamesPerPanel)
              .toList(growable: false);
          panelGames[header] = games;
          displayedGameIds.addAll(games.map((game) => game.gameId));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onVisibleGameIdsChanged(List<String>.unmodifiable(displayedGameIds));
        });
        final selectedGameId =
            selectedGameIndex != null &&
                    selectedGameIndex! >= 0 &&
                    selectedGameIndex! < displayedGameIds.length
                ? displayedGameIds[selectedGameIndex!]
                : null;
        final liveBatchKey = _desktopForYouLiveBatchKey(
          eventId: eventId,
          tourId: snapshot.tourId,
          games: snapshot.visibleGames,
        );
        final panelWidth = _forYouGroupPanelWidth(
          constraints.maxWidth,
          displayedHeaders.length,
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < displayedHeaders.length; i++) ...[
              if (i > 0) const SizedBox(width: _kForYouGroupGap),
              SizedBox(
                width: panelWidth,
                child: _ForYouKnockoutMatchPanel(
                  header: displayedHeaders[i],
                  games: panelGames[displayedHeaders[i]] ?? const [],
                  selectedGameId: selectedGameId,
                  gameItemKeyFor: gameItemKeyFor,
                  onSelectGame: onSelectGame,
                  tournamentTitle: tournamentTitle,
                  eventGames: boardGames,
                  liveBatchKey: liveBatchKey,
                  streamingEnabled: streamingEnabled,
                ),
              ),
            ],
            const Spacer(),
          ],
        );
      },
    );
  }
}

class _ForYouTeamMatchPanel extends StatelessWidget {
  const _ForYouTeamMatchPanel({
    required this.group,
    required this.games,
    required this.selectedGameId,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.tournamentTitle,
    required this.eventGames,
    required this.liveBatchKey,
    required this.streamingEnabled,
  });

  final DesktopTeamMatchGroup group;
  final List<GamesTourModel> games;
  final String? selectedGameId;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final String tournamentTitle;
  final List<GamesTourModel> eventGames;
  final LiveGamesBatchKey liveBatchKey;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context) {
    return _ForYouGroupedPanelFrame(
      header: _ForYouTeamMatchHeader(group: group),
      games: games,
      selectedGameId: selectedGameId,
      gameItemKeyFor: gameItemKeyFor,
      onSelectGame: onSelectGame,
      tournamentTitle: tournamentTitle,
      eventGames: eventGames,
      liveBatchKey: liveBatchKey,
      streamingEnabled: streamingEnabled,
    );
  }
}

class _ForYouKnockoutMatchPanel extends StatelessWidget {
  const _ForYouKnockoutMatchPanel({
    required this.header,
    required this.games,
    required this.selectedGameId,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.tournamentTitle,
    required this.eventGames,
    required this.liveBatchKey,
    required this.streamingEnabled,
  });

  final MatchHeaderModel header;
  final List<GamesTourModel> games;
  final String? selectedGameId;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final String tournamentTitle;
  final List<GamesTourModel> eventGames;
  final LiveGamesBatchKey liveBatchKey;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context) {
    return _ForYouGroupedPanelFrame(
      header: _ForYouKnockoutMatchHeader(header: header),
      games: games,
      selectedGameId: selectedGameId,
      gameItemKeyFor: gameItemKeyFor,
      onSelectGame: onSelectGame,
      tournamentTitle: tournamentTitle,
      eventGames: eventGames,
      liveBatchKey: liveBatchKey,
      streamingEnabled: streamingEnabled,
    );
  }
}

class _ForYouGroupedPanelFrame extends StatelessWidget {
  const _ForYouGroupedPanelFrame({
    required this.header,
    required this.games,
    required this.selectedGameId,
    required this.gameItemKeyFor,
    required this.onSelectGame,
    required this.tournamentTitle,
    required this.eventGames,
    required this.liveBatchKey,
    required this.streamingEnabled,
  });

  final Widget header;
  final List<GamesTourModel> games;
  final String? selectedGameId;
  final Key Function(String gameId) gameItemKeyFor;
  final ValueChanged<String> onSelectGame;
  final String tournamentTitle;
  final List<GamesTourModel> eventGames;
  final LiveGamesBatchKey liveBatchKey;
  final bool streamingEnabled;

  @override
  Widget build(BuildContext context) {
    final metrics = DesktopGameCardsFlow.metricsFor(DesktopCardLayout.compact);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: _kForYouGroupHeaderHeight, child: header),
            const SizedBox(height: _kForYouGroupHeaderGap),
            for (var i = 0; i < games.length; i++) ...[
              if (i > 0) SizedBox(height: metrics.spacing),
              SizedBox(
                height: metrics.tileHeight,
                child: KeyedSubtree(
                  key: gameItemKeyFor(games[i].gameId),
                  child: LiveDesktopGameCard(
                    game: games[i],
                    eventGames: eventGames,
                    tournamentTitle: tournamentTitle,
                    layout: DesktopCardLayout.compact,
                    selected: selectedGameId == games[i].gameId,
                    onSelect: () => onSelectGame(games[i].gameId),
                    viewSource: ChessboardView.forYou,
                    liveBatchKey: liveBatchKey,
                    streamingEnabled: streamingEnabled,
                    allowStockfishFallback: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ForYouTeamMatchHeader extends StatelessWidget {
  const _ForYouTeamMatchHeader({required this.group});

  final DesktopTeamMatchGroup group;

  @override
  Widget build(BuildContext context) {
    final score = group.score;
    final leftColor =
        score.isDraw
            ? kWhiteColor
            : score.left > score.right
            ? kPrimaryColor
            : kRedColor;
    final rightColor =
        score.isDraw
            ? kWhiteColor
            : score.right > score.left
            ? kPrimaryColor
            : kRedColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Expanded(child: _ForYouTeamName(group.leftTeam, TextAlign.start)),
          _ForYouScorePill(
            label: formatDesktopTeamMatchScore(score.left),
            color: leftColor,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 7),
            child: Text(
              'VS',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
              ),
            ),
          ),
          _ForYouScorePill(
            label: formatDesktopTeamMatchScore(score.right),
            color: rightColor,
          ),
          Expanded(child: _ForYouTeamName(group.rightTeam, TextAlign.end)),
        ],
      ),
    );
  }
}

class _ForYouKnockoutMatchHeader extends StatelessWidget {
  const _ForYouKnockoutMatchHeader({required this.header});

  final MatchHeaderModel header;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
            ),
            child: const Text(
              'MATCH',
              style: TextStyle(
                color: kPrimaryColor,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              header.matchTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            header.scoreDisplay,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ForYouTeamName extends StatelessWidget {
  const _ForYouTeamName(this.name, this.textAlign);

  final String name;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        height: 1.1,
      ),
    );
  }
}

class _ForYouScorePill extends StatelessWidget {
  const _ForYouScorePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
