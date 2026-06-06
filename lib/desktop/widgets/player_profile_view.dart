import 'dart:async';

import 'package:cue/cue.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/default_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard, openTournamentGameTab;
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/player_profile/tabs/player_events_tab.dart'
    show playerEventCardsProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/favorite_limit_guard.dart';
import 'package:chessever/utils/number_format_utils.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

/// Desktop-native player profile pane.
///
/// Ground-up rewrite of the previous shell that wrapped the mobile/tablet
/// `Player*Tab` widgets. Layout:
///
/// ```text
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ Header  flag · TITLE · Name      [♥]  [Build tree]  [Save]       │
/// ├───────────────────────┬──────────────────────────────────────────┤
/// │  Ratings tiles        │  About | Games | Events                  │
/// │  TWIC source badge    │  ──── tab body ────                      │
/// │  Bio rows             │                                          │
/// └───────────────────────┴──────────────────────────────────────────┘
/// ```
///
/// Mobile responsive helpers (`.h/.w/.sp`) are gone — fixed pixels chosen for
/// a 1440p desktop viewport.
class PlayerProfileView extends ConsumerStatefulWidget {
  const PlayerProfileView({super.key, required this.args});

  final PlayerProfileArgs args;

  @override
  ConsumerState<PlayerProfileView> createState() => _PlayerProfileViewState();
}

enum _ProfileTab { about, games, events }

extension on _ProfileTab {
  String get label {
    switch (this) {
      case _ProfileTab.about:
        return 'About';
      case _ProfileTab.games:
        return 'Games';
      case _ProfileTab.events:
        return 'Events';
    }
  }
}

class _PlayerProfileViewState extends ConsumerState<PlayerProfileView> {
  static const String _startingFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  late PlayerProfileDataSource _dataSource;
  String? _gamebasePlayerId;
  _ProfileTab _tab = _ProfileTab.about;

  @override
  void initState() {
    super.initState();
    _dataSource = _profileInitialDataSource();
    _gamebasePlayerId = _normalize(widget.args.gamebasePlayerId);
  }

  @override
  void didUpdateWidget(covariant PlayerProfileView old) {
    super.didUpdateWidget(old);
    if (old.args.playerName != widget.args.playerName ||
        old.args.fideId != widget.args.fideId) {
      setState(() {
        _dataSource = _profileInitialDataSource();
        _gamebasePlayerId = _normalize(widget.args.gamebasePlayerId);
        _tab = _ProfileTab.about;
      });
    }
  }

  String? _normalize(String? raw) {
    final t = raw?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  PlayerProfileDataSource _profileInitialDataSource() {
    // Player cards/profiles should always open on TWIC. ChessEver/Supabase
    // remains a backend source for other flows, but this surface must not
    // expose it or default to it.
    return PlayerProfileDataSource.twic;
  }

  PlayerProfileKey _keyFor(PlayerProfileDataSource source) => PlayerProfileKey(
    fideId: widget.args.fideId,
    playerName: widget.args.playerName,
    source: source,
    gamebasePlayerId: _gamebasePlayerId,
  );

  void _setTab(_ProfileTab next) {
    if (_tab == next) return;
    setState(() => _tab = next);
  }

  String? _resolveGamebasePlayerId() {
    if (_gamebasePlayerId != null) return _gamebasePlayerId;
    final twicLookupKey = _keyFor(PlayerProfileDataSource.twic);
    return _normalize(
      ref
          .read(twicProfileSummaryProvider(twicLookupKey))
          .valueOrNull
          ?.gamebasePlayerId,
    );
  }

  PlayerGender _mapSexToGender(String? sex) {
    final normalized = sex?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return PlayerGender.male;
    if (normalized == 'f' || normalized.startsWith('female')) {
      return PlayerGender.female;
    }
    return PlayerGender.male;
  }

  GamebasePlayer _buildExplorerFallbackPlayer(String id) {
    final cached = ref.read(playerByIdProvider(id)).valueOrNull;
    if (cached != null) return cached;

    final activePlayerKey = _keyFor(_dataSource);
    final activeProfile =
        ref.read(playerProfileDataKeyProvider(activePlayerKey)).valueOrNull;
    final fallbackChessPlayer =
        ref.read(chessPlayerByFideIdProvider(widget.args.fideId)).valueOrNull;

    final name =
        (activeProfile?.name.trim().isNotEmpty ?? false)
            ? activeProfile!.name.trim()
            : ((fallbackChessPlayer?.name.trim().isNotEmpty ?? false)
                ? fallbackChessPlayer!.name.trim()
                : widget.args.playerName);

    final fed =
        (activeProfile?.federation?.trim().isNotEmpty ?? false)
            ? activeProfile!.federation!.trim()
            : ((widget.args.federation?.trim().isNotEmpty ?? false)
                ? widget.args.federation!.trim()
                : (fallbackChessPlayer?.country?.trim() ?? ''));

    final title =
        (activeProfile?.title?.trim().isNotEmpty ?? false)
            ? activeProfile!.title?.trim()
            : ((widget.args.title?.trim().isNotEmpty ?? false)
                ? widget.args.title?.trim()
                : fallbackChessPlayer?.title?.trim());

    return GamebasePlayer(
      id: id,
      fideId: widget.args.fideId?.toString() ?? '',
      name: name,
      gender: _mapSexToGender(activeProfile?.sex),
      fed: fed,
      title: title,
      ratingClassical: activeProfile?.classicalRating ?? widget.args.rating,
      ratingRapid: activeProfile?.rapidRating,
      ratingBlitz: activeProfile?.blitzRating,
    );
  }

  void _openBuildTreeGame() {
    if (!mounted) return;
    final playerKey = _keyFor(_dataSource);
    final playerId = _resolveGamebasePlayerId();
    if (playerId == null || playerId.isEmpty) {
      _showToast('Player games are still loading.');
      return;
    }

    final player = _buildExplorerFallbackPlayer(playerId);
    final gameFilter =
        ref.read(playerProfileGamesKeyProvider(playerKey)).filter;
    final baseFilters =
        gameFilter.hasExplorerMappableFilters
            ? gameFilter.toGamebaseFilters()
            : const GamebaseFilters();

    final title = _playerProfileTreeTitle(player.name);
    final tabsNotifier = ref.read(desktopTabsProvider.notifier);
    final tabId =
        tabsNotifier.navigateActive(TabKind.board, title: title) ??
        tabsNotifier.open(TabKind.board, title: title, reuseExisting: false);
    tabsNotifier.rename(tabId, title: title);

    ref.read(boardTabFenProvider.notifier).clear(tabId);
    ref.read(boardPaneSessionByTabIdProvider.notifier).clear(tabId);
    ref
        .read(boardTabGameArgsByTabIdProvider.notifier)
        .update(
          (m) => <String, BoardTabGameArgs>{
            ...m,
            tabId: BoardTabGameArgs(
              pgn: '',
              label: title,
              whiteName: '',
              blackName: '',
              fenSeed: _startingFen,
              initialFen: _startingFen,
              viewSource: ChessboardView.playerProfile,
            ),
          },
        );
    ref
        .read(boardExplorerScopeByTabIdProvider.notifier)
        .update(
          (m) => <String, BoardExplorerScope>{
            ...m,
            tabId: BoardExplorerScope(
              player: player,
              initialFilters: baseFilters,
            ),
          },
        );
    ref.read(rightRailActivePageProvider(tabId).notifier).state = 1;

    unawaited(
      ref.read(playerByIdProvider(playerId).future).catchError((_) => null),
    );
  }

  Future<void> _toggleFavorite() async {
    final allowed = await requireFullAuthGuard(context);
    if (!allowed) return;
    final fideStr = widget.args.fideId?.toString();
    final playerName = widget.args.playerName.trim();
    final favs = ref.read(favoritePlayersProviderNew);
    final already = favs.maybeWhen(
      data:
          (players) => players.any(
            (p) =>
                (fideStr != null &&
                    fideStr.isNotEmpty &&
                    p.fideId == fideStr) ||
                p.playerName.trim() == playerName,
          ),
      orElse: () => false,
    );
    if (!already) {
      if (!mounted) return;
      final canAdd = await canAddMoreFavorites(context, ref);
      if (!canAdd) return;
    }
    try {
      await ref
          .read(favoritePlayersProviderNew.notifier)
          .toggleFavorite(
            fideId: widget.args.fideId?.toString(),
            playerName: widget.args.playerName,
            countryCode: widget.args.federation,
            rating: widget.args.rating,
            title: widget.args.title,
          );
    } on FavoriteLimitExceededException {
      // Desktop is premium-only, so this branch should never trip in
      // production. Surface a toast as a defensive fallback if it does.
      if (mounted) {
        showDesktopToast(
          context,
          'Could not add favorite. Please try again.',
          error: true,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showDesktopToast(
        context,
        'Failed to update favorite. Please try again.',
        error: true,
      );
    }
  }

  Future<void> _openSaveToLibrary({
    required PlayerProfileKey playerKey,
    int? knownTotalCount,
  }) async {
    final state = ref.read(playerProfileGamesKeyProvider(playerKey));
    final action = await _showPlayerProfileSaveActions(
      context: context,
      playerName: playerKey.playerName,
      hasActiveFilters: state.hasActiveFilters,
      visibleCount: state.filteredGames.length,
      knownTotalCount: state.totalCount ?? knownTotalCount,
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _PlayerProfileSaveAction.chooseManually:
        _setTab(_ProfileTab.games);
        ref.read(playerGamesSelectionModeProvider(playerKey).notifier).state =
            true;
        break;
      case _PlayerProfileSaveAction.addAll:
        await _saveCurrentGamesToLibrary(
          playerKey: playerKey,
          knownTotalCount: knownTotalCount,
        );
        break;
    }
  }

  Future<void> _saveCurrentGamesToLibrary({
    required PlayerProfileKey playerKey,
    int? knownTotalCount,
  }) async {
    var state = ref.read(playerProfileGamesKeyProvider(playerKey));
    if (!mounted) return;

    try {
      if (playerKey.source == PlayerProfileDataSource.twic &&
          state.hasMorePages) {
        _showToast('Preparing ${playerKey.playerName} games…');
        await ref
            .read(playerProfileGamesKeyProvider(playerKey).notifier)
            .loadAllRemainingPages(maxPages: _resolveBulkMaxPages(state));
      }

      state = ref.read(playerProfileGamesKeyProvider(playerKey));
      final games = state.filteredGames;
      if (games.isEmpty) {
        _showToast('No games found to save.');
        return;
      }

      if (!mounted) return;
      await _saveGamesToLibrary(
        context: context,
        ref: ref,
        games: games,
        sourceLabel: playerKey.playerName,
      );
    } catch (e) {
      if (!mounted) return;
      _showToast('Failed to prepare games: $e', error: true);
    }
  }

  int _resolveBulkMaxPages(PlayerProfileGamesState state) {
    const defaultMaxPages = 250;
    const fallbackPageSize = 60;
    final totalCount = state.totalCount;
    if (totalCount == null || totalCount <= 0) return defaultMaxPages;
    final remaining = totalCount - state.allGames.length;
    if (remaining <= 0) return defaultMaxPages;
    return (remaining / fallbackPageSize)
        .ceil()
        .clamp(defaultMaxPages, 5000)
        .toInt();
  }

  void _showToast(String message, {bool error = false}) {
    if (!mounted) return;
    showDesktopToast(context, message, error: error);
  }

  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final activeKey = _keyFor(_dataSource);
    final twicLookupKey = _keyFor(PlayerProfileDataSource.twic);
    final activeProfileAsync = ref.watch(
      playerProfileDataKeyProvider(activeKey),
    );
    final activeProfile = activeProfileAsync.valueOrNull;

    final fallbackChessPlayer =
        ref.watch(chessPlayerByFideIdProvider(widget.args.fideId)).valueOrNull;

    final effectiveName =
        (activeProfile?.name.trim().isNotEmpty ?? false)
            ? activeProfile!.name
            : ((fallbackChessPlayer?.name.trim().isNotEmpty ?? false)
                ? fallbackChessPlayer!.name
                : widget.args.playerName);
    final effectiveTitle =
        (activeProfile?.title?.trim().isNotEmpty ?? false)
            ? activeProfile!.title
            : ((widget.args.title?.trim().isNotEmpty ?? false)
                ? widget.args.title
                : ((fallbackChessPlayer?.title?.trim().isNotEmpty ?? false)
                    ? fallbackChessPlayer!.title
                    : widget.args.title));
    final effectiveFederation =
        (activeProfile?.federation?.trim().isNotEmpty ?? false)
            ? activeProfile!.federation
            : ((widget.args.federation?.trim().isNotEmpty ?? false)
                ? widget.args.federation
                : ((fallbackChessPlayer?.country?.trim().isNotEmpty ?? false)
                    ? fallbackChessPlayer!.country
                    : widget.args.federation));
    final activeFideId = activeProfile?.fideId;
    final effectiveFideId =
        activeFideId != null && activeFideId > 0
            ? activeFideId
            : widget.args.fideId;

    final twicSummaryAsync = ref.watch(
      twicProfileSummaryProvider(twicLookupKey),
    );

    final favs = ref.watch(favoritePlayersProviderNew);
    final favoriteFideId = effectiveFideId?.toString();
    final favoritePlayerNames =
        {
          effectiveName.trim(),
          widget.args.playerName.trim(),
        }.where((name) => name.isNotEmpty).toSet();
    final isFavorite = favs.maybeWhen(
      data:
          (players) => players.any(
            (p) =>
                (favoriteFideId != null &&
                    favoriteFideId.isNotEmpty &&
                    p.fideId == favoriteFideId) ||
                favoritePlayerNames.contains(p.playerName.trim()),
          ),
      orElse: () => false,
    );

    final gamesState = ref.watch(playerProfileGamesKeyProvider(activeKey));
    final hasActiveFilter = gamesState.hasActiveFilters;
    final isTwicLoading =
        _dataSource == PlayerProfileDataSource.twic && gamesState.isLoading;

    final showEventCounts = _tab == _ProfileTab.events;

    final ratings = _ProfileRatings(
      classical: activeProfile?.classicalRating ?? widget.args.rating,
      rapid: activeProfile?.rapidRating,
      blitz: activeProfile?.blitzRating,
    );

    final hasBuildTreeTarget = _resolveGamebasePlayerId() != null;

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            name: effectiveName,
            title: effectiveTitle,
            federation: effectiveFederation,
            isFavorite: isFavorite,
            hasBuildTree: hasBuildTreeTarget,
            hasActiveFilter: hasActiveFilter,
            onToggleFavorite: _toggleFavorite,
            onBuildTree: _openBuildTreeGame,
            onSaveToLibrary: () {
              _openSaveToLibrary(
                playerKey: activeKey,
                knownTotalCount:
                    _dataSource == PlayerProfileDataSource.twic
                        ? twicSummaryAsync.valueOrNull?.totalGames
                        : null,
              );
            },
          ),
          const Divider(height: 1, thickness: 1, color: kDividerColor),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _IdentityRail(
                  ratings: ratings,
                  fideId: effectiveFideId,
                  name: effectiveName,
                  title: effectiveTitle,
                  activeProfile: activeProfile,
                  twicSummaryAsync: twicSummaryAsync,
                  isTwicLoading: isTwicLoading,
                  showEventCounts: showEventCounts,
                  dataSource: _dataSource,
                  federation: effectiveFederation,
                  currentTimeControl: gamesState.filter.timeControl,
                  onSelectTimeControl: (timeControl) {
                    final next =
                        gamesState.filter.timeControl == timeControl
                            ? GameTimeControlFilter.all
                            : timeControl;
                    ref
                        .read(playerProfileGamesKeyProvider(activeKey).notifier)
                        .mergeFilter(timeControl: next);
                  },
                ),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: kDividerColor,
                ),
                Expanded(
                  child: _RightPane(
                    currentTab: _tab,
                    onSelectTab: _setTab,
                    hasActiveFilter: hasActiveFilter,
                    isTwicLoading: isTwicLoading,
                    activeKey: activeKey,
                    fideId: widget.args.fideId,
                    playerName: widget.args.playerName,
                    dataSource: _dataSource,
                    gamebasePlayerId: _gamebasePlayerId,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _playerProfileRouteTitle(String playerName) {
  final player = playerName.trim();
  if (player.isEmpty) return 'Player games';
  return '$player games';
}

String _playerProfileTreeTitle(String playerName) {
  final player = playerName.trim();
  if (player.isEmpty) return 'Player Tree';
  return '$player Tree';
}

class _ProfileRatings {
  const _ProfileRatings({this.classical, this.rapid, this.blitz});
  final int? classical;
  final int? rapid;
  final int? blitz;
}

// ---------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.title,
    required this.federation,
    required this.isFavorite,
    required this.hasBuildTree,
    required this.hasActiveFilter,
    required this.onToggleFavorite,
    required this.onBuildTree,
    required this.onSaveToLibrary,
  });

  final String name;
  final String? title;
  final String? federation;
  final bool isFavorite;
  final bool hasBuildTree;
  final bool hasActiveFilter;
  final VoidCallback onToggleFavorite;
  final VoidCallback onBuildTree;
  final VoidCallback onSaveToLibrary;

  @override
  Widget build(BuildContext context) {
    final countryCode =
        federation == null ? '' : CountryUtils.toIso2Code(federation!);
    final showFlag =
        (federation?.toUpperCase() == 'FID') || countryCode.isNotEmpty;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(color: kBackgroundColor),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showFlag) ...[
                  federation?.toUpperCase() == 'FID'
                      ? Image.asset(PngAsset.fideLogo, height: 16, width: 22)
                      : FederationFlag(
                        federation: countryCode,
                        height: 16,
                        width: 22,
                        borderRadius: BorderRadius.circular(2),
                      ),
                  const SizedBox(width: 10),
                ],
                if ((title ?? '').isNotEmpty) ...[
                  Text(
                    title!,
                    style: const TextStyle(
                      color: kLightYellowColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    _formatDisplayName(name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          DesktopFavoriteButton(
            selected: isFavorite,
            onPress: onToggleFavorite,
          ),
          if (hasBuildTree) ...[
            const SizedBox(width: 8),
            DesktopHeaderActionButton(
              label: 'Build tree',
              icon: Icons.account_tree_outlined,
              onPress: onBuildTree,
              tooltip: 'Open the top listed player game on the board',
              accented: hasActiveFilter,
            ),
          ],
          const SizedBox(width: 8),
          DesktopHeaderActionButton(
            label: 'Save',
            icon: Icons.library_add_outlined,
            onPress: onSaveToLibrary,
            tooltip: 'Save this player\'s games to your library',
            accented: hasActiveFilter,
          ),
        ],
      ),
    );
  }

  static String _formatDisplayName(String name) {
    if (!name.contains(',')) return name;
    final parts = name.split(',');
    if (parts.length < 2) return name;
    return '${parts[1].trim()} ${parts[0].trim()}';
  }
}

// ---------------------------------------------------------------------
// Identity rail (left column)
// ---------------------------------------------------------------------

class _IdentityRail extends StatelessWidget {
  const _IdentityRail({
    required this.ratings,
    required this.fideId,
    required this.name,
    required this.title,
    required this.activeProfile,
    required this.twicSummaryAsync,
    required this.isTwicLoading,
    required this.showEventCounts,
    required this.dataSource,
    required this.federation,
    required this.currentTimeControl,
    required this.onSelectTimeControl,
  });

  final _ProfileRatings ratings;
  final int? fideId;
  final String name;
  final String? title;
  final PlayerProfileData? activeProfile;
  final AsyncValue<TwicProfileSummary?> twicSummaryAsync;
  final bool isTwicLoading;
  final bool showEventCounts;
  final PlayerProfileDataSource dataSource;
  final String? federation;
  final GameTimeControlFilter currentTimeControl;
  final ValueChanged<GameTimeControlFilter> onSelectTimeControl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 320,
      child: SingleChildScrollView(
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileAvatarCard(fideId: fideId, name: name, title: title),
            const SizedBox(height: 16),
            Cue.onMount(
              motion: const CueMotion.smooth(),
              acts: const [Act.fadeIn(), Act.slideY(from: 0.15)],
              child: Row(
                children: [
                  Expanded(
                    child: _RatingTile(
                      label: 'Classical',
                      asset: PngAsset.classicalIcon,
                      value: ratings.classical,
                      selected:
                          currentTimeControl == GameTimeControlFilter.classical,
                      onTap:
                          () => onSelectTimeControl(
                            GameTimeControlFilter.classical,
                          ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RatingTile(
                      label: 'Rapid',
                      asset: PngAsset.rapidIcon,
                      value: ratings.rapid,
                      selected:
                          currentTimeControl == GameTimeControlFilter.rapid,
                      onTap:
                          () =>
                              onSelectTimeControl(GameTimeControlFilter.rapid),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RatingTile(
                      label: 'Blitz',
                      asset: PngAsset.blitzIcon,
                      value: ratings.blitz,
                      selected:
                          currentTimeControl == GameTimeControlFilter.blitz,
                      onTap:
                          () =>
                              onSelectTimeControl(GameTimeControlFilter.blitz),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _DataSourceCard(
              dataSource: dataSource,
              twicSummaryAsync: twicSummaryAsync,
              isTwicLoading: isTwicLoading,
              showEventCounts: showEventCounts,
            ),
            const SizedBox(height: 16),
            _BioCard(profile: activeProfile, federation: federation),
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatarCard extends StatefulWidget {
  const _ProfileAvatarCard({
    required this.fideId,
    required this.name,
    required this.title,
  });

  final int? fideId;
  final String name;
  final String? title;

  @override
  State<_ProfileAvatarCard> createState() => _ProfileAvatarCardState();
}

class _ProfileAvatarCardState extends State<_ProfileAvatarCard> {
  Future<String?>? _photoFuture;

  @override
  void initState() {
    super.initState();
    _configurePhotoFuture();
  }

  @override
  void didUpdateWidget(covariant _ProfileAvatarCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fideId != widget.fideId) _configurePhotoFuture();
  }

  void _configurePhotoFuture() {
    final fideId = widget.fideId;
    _photoFuture =
        fideId != null && fideId > 0
            ? FidePhotoService.getPhotoUrlOrNull(fideId.toString())
            : null;
  }

  @override
  Widget build(BuildContext context) {
    final initials = getPlayerInitials(widget.name);
    final title = widget.title?.trim();

    return Cue.onMount(
      motion: const CueMotion.smooth(),
      acts: const [Act.fadeIn(), Act.slideY(from: 0.12)],
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: FutureBuilder<String?>(
              future: _photoFuture,
              builder: (context, snapshot) {
                return PlayerInitialsAvatar(
                  photoUrl: snapshot.data,
                  initials: initials,
                  size: 184,
                  borderRadius: 14,
                  title: title != null && title.isNotEmpty ? title : null,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RatingTile extends StatefulWidget {
  const _RatingTile({
    required this.label,
    required this.asset,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String asset;
  final int? value;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RatingTile> createState() => _RatingTileState();
}

class _RatingTileState extends State<_RatingTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ClickCursor(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DesktopTooltip(
            message:
                selected
                    ? 'Clear ${widget.label.toLowerCase()} filter'
                    : 'Filter games by ${widget.label.toLowerCase()}',
            child: SingleMotionBuilder(
              value: _hover ? 1.015 : 1.0,
              motion: DesktopMotion.hover,
              builder:
                  (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                height: 104,
                decoration: BoxDecoration(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.15)
                          : (_hover ? kBlack3Color : kBlack2Color),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        selected
                            ? kPrimaryColor.withValues(alpha: 0.6)
                            : (_hover
                                ? kPrimaryColor.withValues(alpha: 0.35)
                                : kDividerColor),
                    width: selected ? 1.2 : 1.0,
                  ),
                  boxShadow:
                      selected
                          ? [
                            BoxShadow(
                              color: kPrimaryColor.withValues(alpha: 0.22),
                              blurRadius: 18,
                              spreadRadius: -2,
                              offset: const Offset(0, 4),
                            ),
                          ]
                          : (_hover
                              ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ]
                              : null),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(widget.asset, width: 14, height: 14),
                        const SizedBox(width: 6),
                        Text(
                          widget.label.toUpperCase(),
                          style: TextStyle(
                            color: selected ? kPrimaryColor : kLightGreyColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.value?.toString() ?? '–',
                      style: TextStyle(
                        color:
                            widget.value == null
                                ? kLightGreyColor
                                : kWhiteColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      height: 2,
                      width: selected ? 26 : 10,
                      decoration: BoxDecoration(
                        color:
                            selected
                                ? kPrimaryColor
                                : kDividerColor.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(2),
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

class _DataSourceCard extends StatelessWidget {
  const _DataSourceCard({
    required this.dataSource,
    required this.twicSummaryAsync,
    required this.isTwicLoading,
    required this.showEventCounts,
  });

  final PlayerProfileDataSource dataSource;
  final AsyncValue<TwicProfileSummary?> twicSummaryAsync;
  final bool isTwicLoading;
  final bool showEventCounts;

  @override
  Widget build(BuildContext context) {
    final summary = twicSummaryAsync.valueOrNull;
    final twicTotal =
        showEventCounts ? summary?.totalEvents : summary?.totalGames;
    final twicLabel =
        twicTotal != null ? 'TWIC - ${formatCompactCount(twicTotal)}' : 'TWIC';

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SourceChip(
              label: twicLabel,
              isActive: dataSource == PlayerProfileDataSource.twic,
              loading: twicSummaryAsync.isLoading || isTwicLoading,
              onTap: null,
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceChip extends StatefulWidget {
  const _SourceChip({
    required this.label,
    required this.isActive,
    required this.onTap,
    this.loading = false,
  });

  final String label;
  final bool isActive;
  final bool loading;
  final VoidCallback? onTap;

  @override
  State<_SourceChip> createState() => _SourceChipState();
}

class _SourceChipState extends State<_SourceChip> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return ClickCursor(
      enabled: enabled,
      child: MouseRegion(
        onEnter: (_) => enabled ? setState(() => _hover = true) : null,
        onExit:
            (_) =>
                enabled
                    ? setState(() {
                      _hover = false;
                      _pressed = false;
                    })
                    : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          child: SingleMotionBuilder(
            value: enabled ? (_pressed ? 0.95 : (_hover ? 1.02 : 1.0)) : 1.0,
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color:
                    widget.isActive
                        ? kPrimaryColor.withValues(alpha: 0.14)
                        : (_hover ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color:
                      widget.isActive
                          ? kPrimaryColor.withValues(alpha: 0.3)
                          : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.loading) ...[
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.4,
                        valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            widget.isActive
                                ? kWhiteColor
                                : (enabled ? kWhiteColor70 : kLightGreyColor),
                        fontSize: 11,
                        fontWeight:
                            widget.isActive ? FontWeight.w700 : FontWeight.w500,
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

class _BioCard extends StatelessWidget {
  const _BioCard({required this.profile, required this.federation});
  final PlayerProfileData? profile;
  final String? federation;

  @override
  Widget build(BuildContext context) {
    final rows = <_BioRow>[];
    if ((federation ?? '').trim().isNotEmpty) {
      rows.add(_BioRow(label: 'Federation', value: federation!.trim()));
    }
    if ((profile?.birthday ?? '').trim().isNotEmpty) {
      rows.add(_BioRow(label: 'Born', value: profile!.birthday!.trim()));
    }
    if ((profile?.sex ?? '').trim().isNotEmpty) {
      rows.add(_BioRow(label: 'Sex', value: _humanSex(profile!.sex!)));
    }
    final classical = profile?.classicalRating;
    final rapid = profile?.rapidRating;
    final blitz = profile?.blitzRating;
    if (classical != null || rapid != null || blitz != null) {
      final peak = [classical, rapid, blitz].whereType<int>().fold<int?>(
        null,
        (acc, v) => acc == null ? v : (v > acc ? v : acc),
      );
      if (peak != null) {
        rows.add(_BioRow(label: 'Peak', value: peak.toString()));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rows) ...[
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    row.label.toUpperCase(),
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    row.value,
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
            if (row != rows.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  String _humanSex(String raw) {
    final n = raw.trim().toLowerCase();
    if (n == 'm' || n.startsWith('male')) return 'Male';
    if (n == 'f' || n.startsWith('female')) return 'Female';
    return raw.trim();
  }
}

class _BioRow {
  const _BioRow({required this.label, required this.value});
  final String label;
  final String value;
}

// ---------------------------------------------------------------------
// Right pane (tabs + body)
// ---------------------------------------------------------------------

class _RightPane extends StatelessWidget {
  const _RightPane({
    required this.currentTab,
    required this.onSelectTab,
    required this.hasActiveFilter,
    required this.isTwicLoading,
    required this.activeKey,
    required this.fideId,
    required this.playerName,
    required this.dataSource,
    required this.gamebasePlayerId,
  });

  final _ProfileTab currentTab;
  final ValueChanged<_ProfileTab> onSelectTab;
  final bool hasActiveFilter;
  final bool isTwicLoading;
  final PlayerProfileKey activeKey;
  final int? fideId;
  final String playerName;
  final PlayerProfileDataSource dataSource;
  final String? gamebasePlayerId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(current: currentTab, onSelect: onSelectTab),
        _IndicatorBar(
          hasActiveFilter: hasActiveFilter,
          isLoading: isTwicLoading,
        ),
        Expanded(
          child: PersistentIndexedStack(
            index: _ProfileTab.values.indexOf(currentTab),
            sizing: StackFit.expand,
            children: [
              _AboutBody(
                activeKey: activeKey,
                fideId: fideId,
                playerName: playerName,
                onShowGames: () => onSelectTab(_ProfileTab.games),
              ),
              _GamesBody(
                activeKey: activeKey,
                playerName: playerName,
                dataSource: dataSource,
                isActive: currentTab == _ProfileTab.games,
              ),
              _EventsBody(
                activeKey: activeKey,
                fideId: fideId,
                dataSource: dataSource,
                isActive: currentTab == _ProfileTab.events,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.current, required this.onSelect});
  final _ProfileTab current;
  final ValueChanged<_ProfileTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final t in _ProfileTab.values)
            _TabUnderlineItem(
              label: t.label,
              selected: t == current,
              onTap: () => onSelect(t),
            ),
        ],
      ),
    );
  }
}

class _TabUnderlineItem extends StatefulWidget {
  const _TabUnderlineItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabUnderlineItem> createState() => _TabUnderlineItemState();
}

class _TabUnderlineItemState extends State<_TabUnderlineItem> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg =
        selected ? kPrimaryColor : (_hover ? kWhiteColor : kWhiteColor70);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit:
            (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? -1.5 : (_hover ? -0.5 : 0.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, dy, child) =>
                    Transform.translate(offset: Offset(0, dy), child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? kPrimaryColor : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IndicatorBar extends StatelessWidget {
  const _IndicatorBar({required this.hasActiveFilter, required this.isLoading});

  final bool hasActiveFilter;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    if (!hasActiveFilter && !isLoading) return const SizedBox(height: 2);
    if (isLoading) {
      return const SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          backgroundColor: Color(0x33B36F00),
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      );
    }
    return Container(height: 2, color: kPrimaryColor.withValues(alpha: 0.7));
  }
}

// ---------------------------------------------------------------------
// About body
// ---------------------------------------------------------------------

class _AboutBody extends ConsumerWidget {
  const _AboutBody({
    required this.activeKey,
    required this.fideId,
    required this.playerName,
    required this.onShowGames,
  });

  final PlayerProfileKey activeKey;
  final int? fideId;
  final String playerName;
  final VoidCallback onShowGames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerProfileGamesKeyProvider(activeKey));
    final isTwic = activeKey.source == PlayerProfileDataSource.twic;
    if (!isTwic && state.isLoading && state.allGames.isEmpty) {
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
    if (!isTwic && state.error != null && state.allGames.isEmpty) {
      return _ErrorState(message: state.error!);
    }
    final analyticsAsync =
        isTwic
            ? ref.watch(
              twicPlayerStatsProvider(
                TwicPlayerStatsRequest(
                  playerKey: activeKey,
                  scope: TwicStatsScope.allGames,
                ),
              ),
            )
            : AsyncValue<PlayerAnalytics?>.data(
              state.allGames.isEmpty
                  ? null
                  : ref.watch(
                    playerAnalyticsProvider(
                      PlayerAnalyticsRequest(
                        fideId: fideId,
                        playerName: playerName,
                        games: state.allGames,
                      ),
                    ),
                  ),
            );

    final analytics = analyticsAsync.valueOrNull;
    if (analytics == null) {
      if (analyticsAsync.isLoading ||
          (isTwic && state.isLoading && state.allGames.isEmpty)) {
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
      if (analyticsAsync.hasError) {
        return _ErrorState(message: analyticsAsync.error.toString());
      }
      if (state.error != null) {
        return _ErrorState(message: state.error!);
      }
      return const _EmptyAbout();
    }

    final browseTotal =
        isTwic ? analytics.resultStats.totalGames : state.allGames.length;

    return SingleChildScrollView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Cue.onMount(
            motion: const CueMotion.smooth(),
            acts: const [Act.fadeIn(), Act.slideY(from: 0.08)],
            child: _BrowseGamesCta(total: browseTotal, onTap: onShowGames),
          ),
          const SizedBox(height: 16),
          Cue.onMount(
            motion: const CueMotion.smooth(),
            acts: const [Act.fadeIn(), Act.slideY(from: 0.1)],
            child: _ResultDonut(
              stats: analytics.resultStats,
              selected: state.playerResultFilter,
              onSelect: (filter) {
                final next =
                    state.playerResultFilter == filter
                        ? PlayerResultFilter.all
                        : filter;
                ref
                    .read(playerProfileGamesKeyProvider(activeKey).notifier)
                    .mergeFilter(playerResultFilter: next);
                if (next != PlayerResultFilter.all) onShowGames();
              },
            ),
          ),
          const SizedBox(height: 16),
          Cue.onMount(
            motion: const CueMotion.smooth(),
            acts: const [Act.fadeIn(), Act.slideY(from: 0.1)],
            child: _ColorStatsRow(
              stats: analytics.colorStats,
              selected: state.filter.color,
              onSelect: (color) {
                final next =
                    state.filter.color == color ? GameColorFilter.all : color;
                ref
                    .read(playerProfileGamesKeyProvider(activeKey).notifier)
                    .mergeFilter(
                      color: next,
                      eco:
                          next == GameColorFilter.all
                              ? null
                              : GameEcoFilter.all,
                    );
              },
            ),
          ),
          const SizedBox(height: 16),
          Cue.onMount(
            motion: const CueMotion.smooth(),
            acts: const [Act.fadeIn(), Act.slideY(from: 0.1)],
            child: _OpeningTable(
              stats: analytics.openingStats,
              selected: state.filter.eco,
              onSelect: (eco) {
                final current = state.filter.eco.code?.toUpperCase();
                final next =
                    current == eco.toUpperCase()
                        ? GameEcoFilter.all
                        : GameEcoFilter.forCode(eco);
                ref
                    .read(playerProfileGamesKeyProvider(activeKey).notifier)
                    .mergeFilter(eco: next);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseGamesCta extends StatefulWidget {
  const _BrowseGamesCta({required this.total, required this.onTap});

  final int total;
  final VoidCallback onTap;

  @override
  State<_BrowseGamesCta> createState() => _BrowseGamesCtaState();
}

class _BrowseGamesCtaState extends State<_BrowseGamesCta> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final headline =
        total == 0 ? 'No games on record yet' : 'Step into the game history';
    final detail =
        total == 0
            ? 'New games will appear here as they arrive.'
            : total == 1
            ? 'One game waits for you to relive.'
            : 'Browse all $total games — every move, every result, every story.';
    final glow = _hover || _pressed;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit:
            (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: total == 0 ? null : widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.985 : (glow ? 1.004 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
              decoration: BoxDecoration(
                color:
                    glow ? kPrimaryColor.withValues(alpha: 0.12) : kBlack2Color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      glow
                          ? kPrimaryColor.withValues(alpha: 0.7)
                          : kDividerColor,
                ),
                boxShadow:
                    glow
                        ? [
                          BoxShadow(
                            color: kPrimaryColor.withValues(alpha: 0.18),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ]
                        : null,
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: kPrimaryColor.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Icon(
                      Icons.history_rounded,
                      size: 20,
                      color: kPrimaryColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          headline,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.1,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          detail,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color:
                          glow
                              ? kPrimaryColor.withValues(alpha: 0.22)
                              : kPrimaryColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: kPrimaryColor.withValues(
                          alpha: glow ? 0.9 : 0.6,
                        ),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Open game history',
                          style: TextStyle(
                            color: kPrimaryColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                        SizedBox(width: 6),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 14,
                          color: kPrimaryColor,
                        ),
                      ],
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

class _ResultDonut extends StatelessWidget {
  const _ResultDonut({
    required this.stats,
    required this.selected,
    required this.onSelect,
  });
  final ResultStatistics stats;
  final PlayerResultFilter selected;
  final ValueChanged<PlayerResultFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final total = stats.totalGames;
    final winPct = total == 0 ? 0.0 : stats.wins / total;
    final drawPct = total == 0 ? 0.0 : stats.draws / total;
    final lossPct = total == 0 ? 0.0 : stats.losses / total;
    final pills = [
      _ResultPill(
        label: 'Won',
        value: stats.wins,
        color: kGreenColor,
        pct: winPct,
        selected: selected == PlayerResultFilter.win,
        onTap: () => onSelect(PlayerResultFilter.win),
      ),
      _ResultPill(
        label: 'Drew',
        value: stats.draws,
        color: kLightGreyColor,
        pct: drawPct,
        selected: selected == PlayerResultFilter.draw,
        onTap: () => onSelect(PlayerResultFilter.draw),
      ),
      _ResultPill(
        label: 'Lost',
        value: stats.losses,
        color: kRedColor,
        pct: lossPct,
        selected: selected == PlayerResultFilter.loss,
        onTap: () => onSelect(PlayerResultFilter.loss),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pillWrap = Wrap(spacing: 10, runSpacing: 8, children: pills);
          final title = _SectionTitle(
            title: 'Results',
            subtitle: '$total completed games',
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 12), pillWrap],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              const Spacer(),
              Flexible(
                child: Align(alignment: Alignment.centerRight, child: pillWrap),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ResultPill extends StatelessWidget {
  const _ResultPill({
    required this.label,
    required this.value,
    required this.color,
    required this.pct,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int value;
  final Color color;
  final double pct;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DesktopTooltip(
          message: selected ? 'Clear result filter' : 'Filter games by $label',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: selected ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: color.withValues(alpha: selected ? 0.72 : 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$value',
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${(pct * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
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

class _ColorStatsRow extends StatelessWidget {
  const _ColorStatsRow({
    required this.stats,
    required this.selected,
    required this.onSelect,
  });
  final ColorStatistics stats;
  final GameColorFilter selected;
  final ValueChanged<GameColorFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final whiteCard = _ColorCard(
      isWhite: true,
      games: stats.whiteGames,
      wins: stats.whiteWins,
      draws: stats.whiteDraws,
      losses: stats.whiteLosses,
      score: stats.whiteScore,
      selected: selected == GameColorFilter.white,
      onTap: () => onSelect(GameColorFilter.white),
    );
    final blackCard = _ColorCard(
      isWhite: false,
      games: stats.blackGames,
      wins: stats.blackWins,
      draws: stats.blackDraws,
      losses: stats.blackLosses,
      score: stats.blackScore,
      selected: selected == GameColorFilter.black,
      onTap: () => onSelect(GameColorFilter.black),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520) {
          return Column(
            children: [whiteCard, const SizedBox(height: 10), blackCard],
          );
        }
        return Row(
          children: [
            Expanded(child: whiteCard),
            const SizedBox(width: 10),
            Expanded(child: blackCard),
          ],
        );
      },
    );
  }
}

class _ColorCard extends StatelessWidget {
  const _ColorCard({
    required this.isWhite,
    required this.games,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.score,
    required this.selected,
    required this.onTap,
  });

  final bool isWhite;
  final int games;
  final int wins;
  final int draws;
  final int losses;
  final double score;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DesktopTooltip(
          message:
              selected
                  ? 'Clear color filter'
                  : 'Filter games played as ${isWhite ? 'White' : 'Black'}',
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.1)
                      : kBlack2Color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.48)
                        : kDividerColor,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: isWhite ? Colors.white : Colors.black,
                        shape: BoxShape.circle,
                        border:
                            isWhite
                                ? null
                                : Border.all(
                                  color: kWhiteColor.withValues(alpha: 0.4),
                                ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isWhite ? 'As White' : 'As Black',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(score * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: kPrimaryColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _MicroStat(label: 'Games', value: '$games'),
                    _MicroStat(label: 'W', value: '$wins', color: kGreenColor),
                    _MicroStat(label: 'D', value: '$draws'),
                    _MicroStat(label: 'L', value: '$losses', color: kRedColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroStat extends StatelessWidget {
  const _MicroStat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: color ?? kWhiteColor,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _OpeningTable extends StatelessWidget {
  const _OpeningTable({
    required this.stats,
    required this.selected,
    required this.onSelect,
  });
  final List<OpeningStatistic> stats;
  final GameEcoFilter selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        child: const Text(
          'No opening data yet.',
          style: TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      );
    }
    final top = [...stats]..sort((a, b) => b.count.compareTo(a.count));
    final visible = top.take(8).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle(title: 'Top openings'),
          const SizedBox(height: 10),
          for (final stat in visible)
            _OpeningRow(
              stat: stat,
              selected: selected.code?.toUpperCase() == stat.eco.toUpperCase(),
              onTap: () => onSelect(stat.eco),
            ),
        ],
      ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  const _OpeningRow({
    required this.stat,
    required this.selected,
    required this.onTap,
  });
  final OpeningStatistic stat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scorePct = stat.score;
    final scoreColor =
        scorePct >= 0.55
            ? kGreenColor
            : (scorePct <= 0.45 ? kRedColor : kLightGreyColor);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClickCursor(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DesktopTooltip(
            message:
                selected
                    ? 'Clear ${stat.eco} opening filter'
                    : 'Filter games by ${stat.eco}',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.1)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.42)
                          : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      stat.eco,
                      style: const TextStyle(
                        color: kPrimaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      stat.openingName ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${stat.count}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(scorePct * 100).toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: scoreColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _EmptyAbout extends StatelessWidget {
  const _EmptyAbout();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.menu_book_outlined, size: 32, color: kLightGreyColor),
            SizedBox(height: 12),
            Text(
              'No data yet',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              'Player insights appear once games are loaded.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 32, color: kRedColor),
            const SizedBox(height: 12),
            const Text(
              'Failed to load',
              style: TextStyle(color: kWhiteColor, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Games body
// ---------------------------------------------------------------------

class _GamesBody extends ConsumerStatefulWidget {
  const _GamesBody({
    required this.activeKey,
    required this.playerName,
    required this.dataSource,
    required this.isActive,
  });

  final PlayerProfileKey activeKey;
  final String playerName;
  final PlayerProfileDataSource dataSource;
  final bool isActive;

  @override
  ConsumerState<_GamesBody> createState() => _GamesBodyState();
}

class _GamesBodyState extends ConsumerState<_GamesBody> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounce;
  final Set<String> _selectedGameIds = <String>{};
  bool _isLoadingAllPagesForSelection = false;
  bool _showDatabaseTable = true;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (widget.dataSource != PlayerProfileDataSource.twic) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 480) return;
    ref
        .read(playerProfileGamesKeyProvider(widget.activeKey).notifier)
        .loadMore();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      ref
          .read(playerProfileGamesKeyProvider(widget.activeKey).notifier)
          .setSearchQuery(value);
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    ref
        .read(playerProfileGamesKeyProvider(widget.activeKey).notifier)
        .setSearchQuery('');
  }

  Future<void> _showRowContextMenu({
    required Offset globalPos,
    required GamesTourModel game,
  }) async {
    final shareUrl = buildDesktopGameShareUrl(game: game);
    final canSaveToLibrary = canSaveDesktopGameToLibrary(game);
    final picked = await showDesktopContextMenu<_RowAction>(
      context: context,
      position: globalPos,
      width: 248,
      entries: [
        const DesktopContextMenuItem(
          value: _RowAction.open,
          icon: Icons.open_in_new_rounded,
          label: 'Open game',
        ),
        const DesktopContextMenuItem(
          value: _RowAction.openBackground,
          icon: Icons.tab_unselected_rounded,
          label: 'Open in background',
        ),
        if (canSaveToLibrary) ...[
          const DesktopContextMenuDivider(),
          const DesktopContextMenuItem(
            value: _RowAction.saveToLibrary,
            icon: Icons.library_add_outlined,
            label: 'Save to library',
          ),
        ],
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: _RowAction.share,
          icon: Icons.share_rounded,
          label: 'Share Game',
        ),
        DesktopContextMenuItem(
          value: _RowAction.copyShareLink,
          icon: Icons.copy_rounded,
          label: 'Copy share link',
          enabled: shareUrl != null,
        ),
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: _RowAction.openWhiteProfile,
          icon: Icons.person_outline_rounded,
          label: 'Open White profile',
        ),
        const DesktopContextMenuItem(
          value: _RowAction.openBlackProfile,
          icon: Icons.person_2_outlined,
          label: 'Open Black profile',
        ),
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: _RowAction.copyId,
          icon: Icons.tag_rounded,
          label: 'Copy game ID',
        ),
      ],
    );
    if (picked == null || !mounted) return;
    final routeGames = _currentRouteGames();
    final routeTitle = _currentRouteTitle();
    final routeGamesContinuation = BoardTabGamesContinuation.playerProfile(
      widget.activeKey,
    );
    switch (picked) {
      case _RowAction.open:
        await openTournamentGameTab(
          ref,
          game,
          '',
          routeTitle: routeTitle,
          routeGames: routeGames,
          routeGamesContinuation: routeGamesContinuation,
          viewSource: ChessboardView.playerProfile,
        );
      case _RowAction.openBackground:
        await openTournamentGameTab(
          ref,
          game,
          '',
          routeTitle: routeTitle,
          routeGames: routeGames,
          routeGamesContinuation: routeGamesContinuation,
          focus: false,
          reuseExisting: false,
          viewSource: ChessboardView.playerProfile,
        );
      case _RowAction.saveToLibrary:
        await saveDesktopGameToLibrary(
          context: context,
          ref: ref,
          game: game,
          sourceLabel: widget.playerName,
        );
      case _RowAction.share:
        await showDesktopGameShareDialog(
          context: context,
          ref: ref,
          game: game,
        );
      case _RowAction.copyShareLink:
        await copyDesktopShareUrl(
          context,
          shareUrl,
          copiedLabel: 'Game link copied to clipboard',
          missingLabel: 'This game has no shareable link yet.',
        );
      case _RowAction.openWhiteProfile:
        _openContextPlayerProfile(ref, game.whitePlayer);
      case _RowAction.openBlackProfile:
        _openContextPlayerProfile(ref, game.blackPlayer);
      case _RowAction.copyId:
        await Clipboard.setData(ClipboardData(text: game.gameId));
    }
  }

  void _toggleGameSelection(String gameId) {
    if (!ref.read(playerGamesSelectionModeProvider(widget.activeKey))) return;
    setState(() {
      if (!_selectedGameIds.add(gameId)) {
        _selectedGameIds.remove(gameId);
      }
    });
  }

  void _replaceGameSelection(Set<String> gameIds) {
    if (!ref.read(playerGamesSelectionModeProvider(widget.activeKey))) return;
    setState(() {
      _selectedGameIds
        ..clear()
        ..addAll(gameIds);
    });
  }

  Future<void> _selectAllFilteredGames(PlayerProfileGamesState state) async {
    if (_isLoadingAllPagesForSelection) return;
    if (!mounted) return;

    setState(() => _isLoadingAllPagesForSelection = true);
    try {
      if (widget.dataSource == PlayerProfileDataSource.twic &&
          state.hasMorePages) {
        await ref
            .read(playerProfileGamesKeyProvider(widget.activeKey).notifier)
            .loadAllRemainingPages(maxPages: _resolveBulkMaxPages(state));
      }
      final refreshed = ref.read(
        playerProfileGamesKeyProvider(widget.activeKey),
      );
      final ids = refreshed.filteredGames.map((g) => g.gameId).toSet();
      if (!mounted) return;
      setState(() {
        _selectedGameIds
          ..clear()
          ..addAll(ids);
      });
    } finally {
      if (mounted) setState(() => _isLoadingAllPagesForSelection = false);
    }
  }

  int _resolveBulkMaxPages(PlayerProfileGamesState state) {
    const defaultMaxPages = 250;
    const fallbackPageSize = 60;
    final totalCount = state.totalCount;
    if (totalCount == null || totalCount <= 0) return defaultMaxPages;
    final remaining = totalCount - state.allGames.length;
    if (remaining <= 0) return defaultMaxPages;
    return (remaining / fallbackPageSize)
        .ceil()
        .clamp(defaultMaxPages, 5000)
        .toInt();
  }

  Future<void> _addSelectedToLibrary(PlayerProfileGamesState state) async {
    final selected = state.filteredGames
        .where((game) => _selectedGameIds.contains(game.gameId))
        .toList(growable: false);
    if (selected.isEmpty) {
      _showToast('Select at least one game.');
      return;
    }
    await _saveGamesToLibrary(
      context: context,
      ref: ref,
      games: selected,
      sourceLabel: widget.playerName,
    );
  }

  void _showToast(String message, {bool error = false}) {
    if (!mounted) return;
    showDesktopToast(context, message, error: error);
  }

  List<GamesTourModel> _currentRouteGames() {
    final state = ref.read(playerProfileGamesKeyProvider(widget.activeKey));
    return List<GamesTourModel>.of(state.filteredGames, growable: false);
  }

  String _currentRouteTitle() {
    return _playerProfileRouteTitle(widget.playerName);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerProfileGamesKeyProvider(widget.activeKey));
    final selectionMode = ref.watch(
      playerGamesSelectionModeProvider(widget.activeKey),
    );

    ref.listen<bool>(playerGamesSelectionModeProvider(widget.activeKey), (
      previous,
      next,
    ) {
      if (previous == true && next == false && mounted) {
        setState(() {
          _selectedGameIds.clear();
          _isLoadingAllPagesForSelection = false;
        });
      }
    });

    // Keep the search field controller in sync if the upstream state shifts
    // (e.g. clearFilter from another surface).
    if (!_searchFocusNode.hasFocus &&
        _searchController.text != state.searchQuery) {
      _searchController.value = TextEditingValue(
        text: state.searchQuery,
        selection: TextSelection.collapsed(offset: state.searchQuery.length),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: DesktopSearchField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  hintText: 'Find a game by event, opponent, or opening',
                  onChanged: _onSearchChanged,
                  onClear: _clearSearch,
                ),
              ),
              const SizedBox(width: 8),
              _FilterButton(
                hasActive: state.hasActiveFilters,
                count: state.activeFilterCount,
                onTap:
                    () => setState(() {
                      _showFilters = !_showFilters;
                    }),
                onLongPress:
                    state.hasActiveFilters
                        ? () =>
                            ref
                                .read(
                                  playerProfileGamesKeyProvider(
                                    widget.activeKey,
                                  ).notifier,
                                )
                                .clearFilter()
                        : null,
              ),
              const SizedBox(width: 8),
              _PlayerGamesTableToggle(
                selected: _showDatabaseTable,
                onTap: () {
                  setState(() => _showDatabaseTable = !_showDatabaseTable);
                },
              ),
              const SizedBox(width: 8),
              const GameViewModeToggle(),
            ],
          ),
        ),
        if (selectionMode)
          _SelectionToolbar(
            selectedCount: _selectedGameIds.length,
            visibleCount: state.filteredGames.length,
            isLoadingAll: _isLoadingAllPagesForSelection,
            onSelectAll: () => _selectAllFilteredGames(state),
            onAddSelected: () => _addSelectedToLibrary(state),
            onCancel: () {
              ref
                  .read(
                    playerGamesSelectionModeProvider(widget.activeKey).notifier,
                  )
                  .state = false;
            },
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildBody(state, selectionMode: selectionMode)),
              if (_showFilters) ...[
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: kDividerColor,
                ),
                SizedBox(
                  width: 304,
                  child: _PlayerGamesFilterRail(
                    state: state,
                    showFormatFilter:
                        widget.dataSource == PlayerProfileDataSource.twic,
                    onFilterChanged: (filter) {
                      ref
                          .read(
                            playerProfileGamesKeyProvider(
                              widget.activeKey,
                            ).notifier,
                          )
                          .applyFilter(filter);
                    },
                    onPlayerResultChanged: (result) {
                      ref
                          .read(
                            playerProfileGamesKeyProvider(
                              widget.activeKey,
                            ).notifier,
                          )
                          .setPlayerResultFilter(result);
                    },
                    onClear: () {
                      ref
                          .read(
                            playerProfileGamesKeyProvider(
                              widget.activeKey,
                            ).notifier,
                          )
                          .clearFilter();
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    PlayerProfileGamesState state, {
    required bool selectionMode,
  }) {
    final isTwicBlocking =
        widget.dataSource == PlayerProfileDataSource.twic && state.isLoading;
    if (isTwicBlocking || (state.isLoading && state.allGames.isEmpty)) {
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
    if (state.error != null && state.allGames.isEmpty) {
      return _ErrorState(message: state.error!);
    }
    if (state.allGames.isEmpty) {
      return const _EmptyGames();
    }

    final games = state.filteredGames;
    if (games.isEmpty) {
      return const _NoFilterResults();
    }

    if (_showDatabaseTable) {
      return _PlayerGamesDatabaseTable(
        active: widget.isActive,
        games: games,
        routeTitle: _currentRouteTitle(),
        routeGamesContinuation: BoardTabGamesContinuation.playerProfile(
          widget.activeKey,
        ),
        controller: _scrollController,
        footer: _twicFooter(state),
        selectionMode: selectionMode,
        selectedIds: _selectedGameIds,
        onToggleSelection: _toggleGameSelection,
        onReplaceSelection: _replaceGameSelection,
        onContext: _showRowContextMenu,
      );
    }

    final viewMode = ref.watch(gamesListViewModeProvider);
    final layout = viewMode.desktopLayout;
    final eventCardsAsync =
        widget.dataSource == PlayerProfileDataSource.twic
            ? ref.watch(playerTwicEventCardsProvider(widget.activeKey))
            : widget.activeKey.fideId != null
            ? ref.watch(playerEventCardsProvider(widget.activeKey.fideId!))
            : const AsyncValue<Map<String, GroupEventCardModel>>.data({});
    final eventsAsync = ref.watch(playerEventsKeyProvider(widget.activeKey));
    final sections = _buildEventSections(
      games: games,
      eventCards: eventCardsAsync.valueOrNull ?? const {},
      events: eventsAsync.valueOrNull ?? const [],
    );

    final countrymanIso2 =
        ref.watch(countryDropdownProvider).valueOrNull?.countryCode;

    return _GroupedGamesList(
      autofocus: widget.isActive,
      enabled: widget.isActive,
      sections: sections,
      routeTitle: _currentRouteTitle(),
      routeGames: games,
      routeGamesContinuation: BoardTabGamesContinuation.playerProfile(
        widget.activeKey,
      ),
      layout: layout,
      controller: _scrollController,
      onContext: _showRowContextMenu,
      selectionMode: selectionMode,
      selectedIds: _selectedGameIds,
      onToggleSelection: _toggleGameSelection,
      profilePlayerName: widget.playerName,
      profileFederationFallback: countrymanIso2,
      footer: _twicFooter(state),
    );
  }

  List<_PlayerGameEventSection> _buildEventSections({
    required List<GamesTourModel> games,
    required Map<String, GroupEventCardModel> eventCards,
    required List<PlayerEventData> events,
  }) {
    final eventDataById = {for (final event in events) event.tourId: event};
    final grouped = <String, List<GamesTourModel>>{};
    for (final game in games) {
      final key = game.tourId.trim().isNotEmpty ? game.tourId : game.tourSlug;
      grouped.putIfAbsent(key ?? 'unknown', () => <GamesTourModel>[]).add(game);
    }

    return [
      for (final entry in grouped.entries)
        _PlayerGameEventSection(
          tourId: entry.key,
          title: _eventTitle(
            tourId: entry.key,
            games: entry.value,
            card: eventCards[entry.key],
            event: eventDataById[entry.key],
          ),
          card: eventCards[entry.key],
          event: eventDataById[entry.key],
          games: entry.value,
          playerScore:
              eventDataById[entry.key]?.score ??
              _computePlayerScore(entry.value),
          canOpenEvent: eventCards[entry.key] != null,
        ),
    ];
  }

  String _eventTitle({
    required String tourId,
    required List<GamesTourModel> games,
    GroupEventCardModel? card,
    PlayerEventData? event,
  }) {
    final fromCard = card?.title.trim();
    if (fromCard != null && fromCard.isNotEmpty) return fromCard;
    final fromEvent = event?.tourName.trim();
    if (fromEvent != null && fromEvent.isNotEmpty) return fromEvent;
    final fromGame = games.isEmpty ? null : games.first.tourSlug?.trim();
    if (fromGame != null && fromGame.isNotEmpty) return fromGame;
    return tourId;
  }

  double _computePlayerScore(List<GamesTourModel> eventGames) {
    double score = 0;
    final fideId = widget.activeKey.fideId;
    final playerName = widget.playerName.trim().toLowerCase();

    for (final game in eventGames) {
      var isWhite = false;
      var isBlack = false;
      if (fideId != null) {
        isWhite = game.whitePlayer.fideId == fideId;
        isBlack = game.blackPlayer.fideId == fideId;
      }
      if (!isWhite && !isBlack && playerName.isNotEmpty) {
        isWhite = game.whitePlayer.name.toLowerCase().contains(playerName);
        isBlack = game.blackPlayer.name.toLowerCase().contains(playerName);
      }
      if (!isWhite && !isBlack) continue;

      if ((isWhite && game.gameStatus == GameStatus.whiteWins) ||
          (isBlack && game.gameStatus == GameStatus.blackWins)) {
        score += 1;
      } else if (game.gameStatus == GameStatus.draw) {
        score += 0.5;
      }
    }
    return score;
  }

  Widget? _twicFooter(PlayerProfileGamesState state) {
    if (widget.dataSource != PlayerProfileDataSource.twic) return null;
    if (state.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            ),
          ),
        ),
      );
    }
    if (state.hasMorePages) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: ClickCursor(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap:
                  () =>
                      ref
                          .read(
                            playerProfileGamesKeyProvider(
                              widget.activeKey,
                            ).notifier,
                          )
                          .loadMore(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kDividerColor),
                ),
                child: const Text(
                  'Load more',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (state.totalCount != null && state.totalCount! > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            'Loaded ${formatCompactCount(state.totalCount!)} games',
            style: const TextStyle(color: kLightGreyColor, fontSize: 11),
          ),
        ),
      );
    }
    return null;
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.selectedCount,
    required this.visibleCount,
    required this.isLoadingAll,
    required this.onSelectAll,
    required this.onAddSelected,
    required this.onCancel,
  });

  final int selectedCount;
  final int visibleCount;
  final bool isLoadingAll;
  final VoidCallback onSelectAll;
  final VoidCallback onAddSelected;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.checklist_rounded,
              size: 16,
              color: kPrimaryColor.withValues(alpha: 0.95),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                selectedCount == 0
                    ? 'Choose games to save'
                    : '$selectedCount selected',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            DesktopDialogButton(
              label:
                  isLoadingAll
                      ? 'Selecting...'
                      : 'Select filtered (${formatCompactCount(visibleCount)})',
              onPress: isLoadingAll ? null : onSelectAll,
              prefix:
                  isLoadingAll
                      ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      )
                      : const Icon(Icons.select_all_rounded),
            ),
            const SizedBox(width: 8),
            DesktopDialogButton(
              label: 'Add selected',
              tone: DesktopDialogButtonTone.primary,
              icon: Icons.library_add_outlined,
              onPress: selectedCount == 0 ? null : onAddSelected,
            ),
            const SizedBox(width: 8),
            DesktopDialogIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Cancel selection',
              onPress: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerGamesFilterRail extends StatelessWidget {
  const _PlayerGamesFilterRail({
    required this.state,
    required this.showFormatFilter,
    required this.onFilterChanged,
    required this.onPlayerResultChanged,
    required this.onClear,
  });

  final PlayerProfileGamesState state;
  final bool showFormatFilter;
  final ValueChanged<GameFilter> onFilterChanged;
  final ValueChanged<PlayerResultFilter> onPlayerResultChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final filter = state.filter;
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBlack2Color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.tune_rounded,
                    size: 15,
                    color: kPrimaryColor,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Filters',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (state.hasActiveFilters) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kRedColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: kRedColor.withValues(alpha: 0.32),
                        ),
                      ),
                      child: Text(
                        '${state.activeFilterCount}',
                        style: const TextStyle(
                          color: kRedColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (state.hasActiveFilters)
                    FButton(
                      style: FButtonStyle.ghost(),
                      onPress: onClear,
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            const FDivider(),
            Expanded(
              child: SingleChildScrollView(
                physics: const DesktopScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _RailSection(
                      title: 'Played as',
                      child: DesktopSegmentedTabs<GameColorFilter>(
                        wrap: true,
                        selected: filter.color,
                        onChanged:
                            (v) => onFilterChanged(
                              filter.copyWith(
                                color: v,
                                eco:
                                    v == GameColorFilter.all
                                        ? null
                                        : GameEcoFilter.all,
                              ),
                            ),
                        tabs: const [
                          DesktopSegmentedTab(
                            value: GameColorFilter.all,
                            label: 'All',
                            icon: Icons.all_inclusive_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: GameColorFilter.white,
                            label: 'White',
                            icon: Icons.circle,
                          ),
                          DesktopSegmentedTab(
                            value: GameColorFilter.black,
                            label: 'Black',
                            icon: Icons.circle_outlined,
                          ),
                        ],
                      ),
                    ),
                    _RailSection(
                      title: 'Time control',
                      child: DesktopSegmentedTabs<GameTimeControlFilter>(
                        wrap: true,
                        selected: filter.timeControl,
                        onChanged:
                            (v) => onFilterChanged(
                              filter.copyWith(timeControl: v),
                            ),
                        tabs: const [
                          DesktopSegmentedTab(
                            value: GameTimeControlFilter.all,
                            label: 'All',
                            icon: Icons.all_inclusive_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: GameTimeControlFilter.classical,
                            label: 'Classical',
                            icon: Icons.hourglass_top_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: GameTimeControlFilter.rapid,
                            label: 'Rapid',
                            icon: Icons.timer_outlined,
                          ),
                          DesktopSegmentedTab(
                            value: GameTimeControlFilter.blitz,
                            label: 'Blitz',
                            icon: Icons.bolt_rounded,
                          ),
                        ],
                      ),
                    ),
                    if (showFormatFilter)
                      _RailSection(
                        title: 'Format',
                        child: DesktopSegmentedTabs<GameOnlineFilter>(
                          wrap: true,
                          selected: filter.online,
                          onChanged:
                              (v) =>
                                  onFilterChanged(filter.copyWith(online: v)),
                          tabs: const [
                            DesktopSegmentedTab(
                              value: GameOnlineFilter.all,
                              label: 'All',
                              icon: Icons.all_inclusive_rounded,
                            ),
                            DesktopSegmentedTab(
                              value: GameOnlineFilter.online,
                              label: 'Online',
                              icon: Icons.language_rounded,
                            ),
                            DesktopSegmentedTab(
                              value: GameOnlineFilter.otb,
                              label: 'OTB',
                              icon: Icons.event_seat_outlined,
                            ),
                          ],
                        ),
                      ),
                    _RailSection(
                      title: 'Player result',
                      child: DesktopSegmentedTabs<PlayerResultFilter>(
                        wrap: true,
                        selected: state.playerResultFilter,
                        onChanged: onPlayerResultChanged,
                        tabs: const [
                          DesktopSegmentedTab(
                            value: PlayerResultFilter.all,
                            label: 'All',
                            icon: Icons.all_inclusive_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: PlayerResultFilter.win,
                            label: 'Wins',
                            icon: Icons.trending_up_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: PlayerResultFilter.draw,
                            label: 'Draws',
                            icon: Icons.drag_handle_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: PlayerResultFilter.loss,
                            label: 'Losses',
                            icon: Icons.trending_down_rounded,
                          ),
                        ],
                      ),
                    ),
                    _RailSection(
                      title: 'Game result',
                      child: DesktopSegmentedTabs<GameResultFilter>(
                        wrap: true,
                        selected: filter.result,
                        onChanged:
                            (v) => onFilterChanged(filter.copyWith(result: v)),
                        tabs: const [
                          DesktopSegmentedTab(
                            value: GameResultFilter.all,
                            label: 'All',
                            icon: Icons.all_inclusive_rounded,
                          ),
                          DesktopSegmentedTab(
                            value: GameResultFilter.whiteWins,
                            label: '1-0',
                            icon: Icons.flag_outlined,
                          ),
                          DesktopSegmentedTab(
                            value: GameResultFilter.draw,
                            label: '½',
                            icon: Icons.handshake_outlined,
                          ),
                          DesktopSegmentedTab(
                            value: GameResultFilter.blackWins,
                            label: '0-1',
                            icon: Icons.flag_rounded,
                          ),
                        ],
                      ),
                    ),
                    _RailSection(
                      title: 'Opening',
                      child: _EcoFilterField(
                        value: filter.eco,
                        onChanged:
                            (eco) => onFilterChanged(filter.copyWith(eco: eco)),
                      ),
                    ),
                    _RailSection(
                      title: 'Year',
                      child: _NumberRangeFields(
                        start: filter.minYear,
                        end: filter.maxYear,
                        minValue: GameFilter.absoluteMinYear,
                        maxValue: DateTime.now().year,
                        defaultStart: GameFilter.defaultMinYear,
                        defaultEnd: DateTime.now().year,
                        startHint: 'From',
                        endHint: 'To',
                        onChanged:
                            (start, end) => onFilterChanged(
                              filter.copyWith(minYear: start, maxYear: end),
                            ),
                      ),
                    ),
                    _RailSection(
                      title: 'Rating',
                      child: _NumberRangeFields(
                        start: filter.minRating,
                        end: filter.maxRating,
                        minValue: GameFilter.absoluteMinRating,
                        maxValue: GameFilter.absoluteMaxRating,
                        defaultStart: GameFilter.defaultMinRating,
                        defaultEnd: GameFilter.absoluteMaxRating,
                        startHint: 'Min',
                        endHint: 'Max',
                        onChanged:
                            (start, end) => onFilterChanged(
                              filter.copyWith(minRating: start, maxRating: end),
                            ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatCompactCount(state.filteredGames.length)} games match current filters',
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailSection extends StatelessWidget {
  const _RailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _EcoFilterField extends StatefulWidget {
  const _EcoFilterField({required this.value, required this.onChanged});

  final GameEcoFilter value;
  final ValueChanged<GameEcoFilter> onChanged;

  @override
  State<_EcoFilterField> createState() => _EcoFilterFieldState();
}

class _EcoFilterFieldState extends State<_EcoFilterField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.code ?? '');
  }

  @override
  void didUpdateWidget(covariant _EcoFilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.value.code ?? '';
    if (_controller.text.toUpperCase() != next.toUpperCase()) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final value = raw.trim().toUpperCase();
    if (value.isEmpty) {
      widget.onChanged(GameEcoFilter.all);
      return;
    }
    if (RegExp(r'^[A-E][0-9]{0,2}$').hasMatch(value)) {
      widget.onChanged(GameEcoFilter.forCode(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          controller: _controller,
          hint: 'A00-E99 or category',
          onChange: _onChanged,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Ea-e0-9]')),
            LengthLimitingTextInputFormatter(3),
          ],
        ),
        if (!widget.value.isAll) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: FButton(
              style: FButtonStyle.ghost(),
              onPress: () {
                _controller.clear();
                widget.onChanged(GameEcoFilter.all);
              },
              child: const Text('Clear opening'),
            ),
          ),
        ],
      ],
    );
  }
}

class _NumberRangeFields extends StatefulWidget {
  const _NumberRangeFields({
    required this.start,
    required this.end,
    required this.minValue,
    required this.maxValue,
    required this.defaultStart,
    required this.defaultEnd,
    required this.startHint,
    required this.endHint,
    required this.onChanged,
  });

  final int start;
  final int end;
  final int minValue;
  final int maxValue;
  final int defaultStart;
  final int defaultEnd;
  final String startHint;
  final String endHint;
  final void Function(int start, int end) onChanged;

  @override
  State<_NumberRangeFields> createState() => _NumberRangeFieldsState();
}

class _NumberRangeFieldsState extends State<_NumberRangeFields> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: widget.start.toString());
    _endController = TextEditingController(text: widget.end.toString());
  }

  @override
  void didUpdateWidget(covariant _NumberRangeFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(_startController, widget.start);
    _syncController(_endController, widget.end);
  }

  void _syncController(TextEditingController controller, int value) {
    final next = value.toString();
    if (controller.text != next) {
      controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  void _commit() {
    var start = int.tryParse(_startController.text) ?? widget.defaultStart;
    var end = int.tryParse(_endController.text) ?? widget.defaultEnd;
    start = start.clamp(widget.minValue, widget.maxValue).toInt();
    end = end.clamp(widget.minValue, widget.maxValue).toInt();
    if (start > end) {
      final tmp = start;
      start = end;
      end = tmp;
    }
    widget.onChanged(start, end);
  }

  void _reset() {
    _startController.text = widget.defaultStart.toString();
    _endController.text = widget.defaultEnd.toString();
    widget.onChanged(widget.defaultStart, widget.defaultEnd);
  }

  @override
  Widget build(BuildContext context) {
    final isDefault =
        widget.start == widget.defaultStart && widget.end == widget.defaultEnd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FTextField(
                controller: _startController,
                hint: widget.startHint,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChange: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FTextField(
                controller: _endController,
                hint: widget.endHint,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChange: (_) => _commit(),
              ),
            ),
          ],
        ),
        if (!isDefault) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: FButton(
              style: FButtonStyle.ghost(),
              onPress: _reset,
              child: const Text('Reset range'),
            ),
          ),
        ],
      ],
    );
  }
}

enum _PlayerProfileSaveAction { addAll, chooseManually }

Future<_PlayerProfileSaveAction?> _showPlayerProfileSaveActions({
  required BuildContext context,
  required String playerName,
  required bool hasActiveFilters,
  required int visibleCount,
  int? knownTotalCount,
}) {
  final count = knownTotalCount ?? visibleCount;
  return showGeneralDialog<_PlayerProfileSaveAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Save player games',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder:
        (ctx, _, _) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kDividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.library_add_outlined,
                            color: kPrimaryColor,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Save to library',
                                  style: TextStyle(
                                    color: kWhiteColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${formatCompactCount(count)} ${hasActiveFilters ? 'filtered ' : ''}games from $playerName',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kLightGreyColor,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          DesktopDialogIconButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Close',
                            onPress: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    const FDivider(),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DesktopDialogButton(
                            label:
                                hasActiveFilters
                                    ? 'Add all filtered games'
                                    : 'Add all games',
                            icon: Icons.all_inclusive_rounded,
                            fillWidth: true,
                            onPress:
                                () => Navigator.of(
                                  ctx,
                                ).pop(_PlayerProfileSaveAction.addAll),
                          ),
                          const SizedBox(height: 10),
                          DesktopDialogButton(
                            label: 'Choose games manually',
                            icon: Icons.checklist_rounded,
                            fillWidth: true,
                            onPress:
                                () => Navigator.of(
                                  ctx,
                                ).pop(_PlayerProfileSaveAction.chooseManually),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

Future<void> _saveGamesToLibrary({
  required BuildContext context,
  required WidgetRef ref,
  required List<GamesTourModel> games,
  required String sourceLabel,
}) async {
  if (games.isEmpty) return;
  if (!context.mounted) return;

  showDesktopToast(
    context,
    'Preparing ${formatCompactCount(games.length)} games…',
  );

  try {
    final chessGames = <ChessGame>[];
    for (final game in games) {
      chessGames.add(await _resolveChessGameForLibrary(ref, game));
    }
    if (!context.mounted) return;

    final outcome = await showLibrarySaveToFolderDialog(
      context: context,
      ref: ref,
      games: chessGames,
      sourceLabel: sourceLabel,
    );
    if (!context.mounted || outcome == null || !outcome.didSave) return;
    showDesktopToast(context, outcome.toToastMessage());
  } catch (e) {
    if (!context.mounted) return;
    showDesktopToast(context, 'Failed to prepare games: $e', error: true);
  }
}

Future<ChessGame> _resolveChessGameForLibrary(
  WidgetRef ref,
  GamesTourModel game,
) async {
  final gameRepository = ref.read(gameRepositoryProvider);
  final gamebaseRepository = ref.read(gamebaseRepositoryProvider);

  String? pgn = game.pgn;
  final hasMoves = pgn != null && pgnHasMoves(pgn);

  if (!hasMoves) {
    try {
      final supabasePgn = await gameRepository.getGamePgn(game.gameId);
      if (supabasePgn != null && pgnHasMoves(supabasePgn)) {
        pgn = supabasePgn;
      }
    } catch (_) {}

    if (pgn == null || !pgnHasMoves(pgn)) {
      final fullGame = await gamebaseRepository.getGameWithPgn(game.gameId);
      if (fullGame?.pgn != null && pgnHasMoves(fullGame!.pgn!)) {
        pgn = fullGame.pgn;
      } else if (fullGame?.data != null) {
        final builtPgn = buildPgnFromGamebaseData(fullGame!.data);
        if (builtPgn != null && pgnHasMoves(builtPgn)) {
          pgn = builtPgn;
        }
      }
    }
  }

  if (pgn == null || pgn.trim().isEmpty || !pgnHasMoves(pgn)) {
    throw Exception('PGN not found for game ${game.gameId}');
  }

  final chessGame = ChessGame.fromPgn(game.gameId, pgn);
  final meta = mergeDesktopGameMetadataForLibrary(
    Map<String, dynamic>.from(chessGame.metadata),
    game,
  );

  final resolvedEvent = _resolveLibraryEventName(
    metadataEvent: meta['Event']?.toString(),
    tourSlug: game.tourSlug,
    tourId: game.tourId,
  );
  if (resolvedEvent != null) {
    meta['Event'] = resolvedEvent;
  } else if (_looksLikeOpaqueLibraryEventId(meta['Event']?.toString())) {
    meta.remove('Event');
  }

  return chessGame.copyWith(metadata: meta);
}

String? _resolveLibraryEventName({
  required String? metadataEvent,
  required String? tourSlug,
  required String? tourId,
}) {
  final fromMetadata = metadataEvent?.trim() ?? '';
  if (_isReadableLibraryEventName(fromMetadata)) return fromMetadata;

  final fromSlug = tourSlug?.trim() ?? '';
  if (_isReadableLibraryEventName(fromSlug)) {
    return _humanizeLibrarySlug(fromSlug);
  }

  final fromId = tourId?.trim() ?? '';
  if (_isReadableLibraryEventName(fromId)) return fromId;
  return null;
}

bool _isReadableLibraryEventName(String value) {
  if (value.isEmpty) return false;
  final lower = value.toLowerCase();
  if (lower == 'library' ||
      lower == 'gamebase' ||
      lower == 'opening_explorer') {
    return false;
  }
  return !_looksLikeOpaqueLibraryEventId(value);
}

bool _looksLikeOpaqueLibraryEventId(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return false;
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (uuid.hasMatch(text)) return true;
  if (RegExp(r'^[0-9a-f]{24}$', caseSensitive: false).hasMatch(text)) {
    return true;
  }
  return RegExp(r'^[0-9a-f]{12,64}$', caseSensitive: false).hasMatch(text);
}

String _humanizeLibrarySlug(String value) {
  if (!value.contains('-') && !value.contains('_')) return value;
  final words =
      value.split(RegExp(r'[-_]+')).where((s) => s.isNotEmpty).toList();
  if (words.isEmpty) return value;
  return words
      .map((word) {
        final lower = word.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ');
}

class _PlayerGamesTableToggle extends StatelessWidget {
  const _PlayerGamesTableToggle({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? kPrimaryColor : kWhiteColor70;
    return DesktopTooltip(
      message:
          selected
              ? 'Database table view is active · click for grouped events view'
              : 'Show sortable database table view',
      child: ClickCursor(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.14)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.42)
                        : kDividerColor,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.table_rows_rounded, size: 16, color: color),
                const SizedBox(width: 7),
                Text(
                  'Table',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
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

class _PlayerGamesDatabaseTable extends ConsumerStatefulWidget {
  const _PlayerGamesDatabaseTable({
    required this.active,
    required this.games,
    required this.routeTitle,
    required this.routeGamesContinuation,
    required this.controller,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.onReplaceSelection,
    required this.onContext,
    this.footer,
  });

  final bool active;
  final List<GamesTourModel> games;
  final String routeTitle;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final ScrollController controller;
  final bool selectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelection;
  final ValueChanged<Set<String>> onReplaceSelection;
  final Future<void> Function({
    required Offset globalPos,
    required GamesTourModel game,
  })
  onContext;
  final Widget? footer;

  @override
  ConsumerState<_PlayerGamesDatabaseTable> createState() =>
      _PlayerGamesDatabaseTableState();
}

class _PlayerGamesDatabaseTableState
    extends ConsumerState<_PlayerGamesDatabaseTable> {
  @override
  Widget build(BuildContext context) {
    return DefaultGamesTable(
      active: widget.active,
      games: widget.games,
      controller: widget.controller,
      routeTitle: widget.routeTitle,
      routeGames: widget.games,
      routeGamesContinuation: widget.routeGamesContinuation,
      selectionMode: widget.selectionMode,
      selectedIds: widget.selectedIds,
      onToggleSelection: widget.onToggleSelection,
      onReplaceSelection: widget.onReplaceSelection,
      onContext: widget.onContext,
      footer: widget.footer,
      rowKeyPrefix: 'player-game-table',
    );
  }
}

class _PlayerGameEventSection {
  const _PlayerGameEventSection({
    required this.tourId,
    required this.title,
    required this.card,
    required this.event,
    required this.games,
    required this.playerScore,
    required this.canOpenEvent,
  });

  final String tourId;
  final String title;
  final GroupEventCardModel? card;
  final PlayerEventData? event;
  final List<GamesTourModel> games;
  final double playerScore;
  final bool canOpenEvent;
}

class _GroupedGamesList extends ConsumerStatefulWidget {
  const _GroupedGamesList({
    required this.autofocus,
    required this.enabled,
    required this.sections,
    required this.routeTitle,
    required this.routeGames,
    required this.routeGamesContinuation,
    required this.layout,
    required this.controller,
    required this.onContext,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.profilePlayerName,
    required this.profileFederationFallback,
    this.footer,
  });

  final bool autofocus;
  final bool enabled;
  final List<_PlayerGameEventSection> sections;
  final String routeTitle;
  final List<GamesTourModel> routeGames;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final DesktopCardLayout layout;
  final ScrollController controller;
  final Future<void> Function({
    required Offset globalPos,
    required GamesTourModel game,
  })
  onContext;
  final bool selectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelection;
  final String profilePlayerName;
  final String? profileFederationFallback;
  final Widget? footer;

  @override
  ConsumerState<_GroupedGamesList> createState() => _GroupedGamesListState();
}

class _GroupedGamesListState extends ConsumerState<_GroupedGamesList> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'PlayerProfileEventGameCards',
  );
  final Map<int, GlobalKey> _sectionKeys = <int, GlobalKey>{};
  final Map<String, GlobalKey> _gameKeys = <String, GlobalKey>{};
  EventGameCardFocus? _focus;

  @override
  void didUpdateWidget(covariant _GroupedGamesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled && widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    final focus = _focus;
    if (focus != null && focus.eventIndex >= widget.sections.length) {
      _focus = null;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  GlobalKey _sectionKey(int index) {
    return _sectionKeys.putIfAbsent(
      index,
      () => GlobalKey(debugLabel: 'player-profile-event-games-$index'),
    );
  }

  GlobalKey _gameKey(int sectionIndex, int gameIndex) {
    final key = '$sectionIndex:$gameIndex';
    return _gameKeys.putIfAbsent(
      key,
      () => GlobalKey(debugLabel: 'player-profile-event-game-$key'),
    );
  }

  int _gameColumnCountForSection(int _) {
    if (widget.layout != DesktopCardLayout.grid) return 1;
    final availableWidth =
        ((context.size?.width ?? 600.0) - 40)
            .clamp(0.0, double.infinity)
            .toDouble();
    return (availableWidth / 280).floor().clamp(2, 5).toInt();
  }

  void _scrollBy(double delta) {
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final next = (controller.offset + delta).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(
      next,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (widget.sections.isEmpty) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp) {
      if (widget.controller.hasClients) {
        final delta = widget.controller.position.viewportDimension * 0.9;
        _scrollBy(key == LogicalKeyboardKey.pageDown ? delta : -delta);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activateFocus();
      return KeyEventResult.handled;
    }

    final isMoveKey =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    if (!isMoveKey) return KeyEventResult.ignored;

    final next = moveEventGameCardFocus(
      current: _focus,
      key: key,
      eventCount: widget.sections.length,
      gameCountForEvent: (index) => widget.sections[index].games.length,
      gameLayout:
          widget.layout == DesktopCardLayout.grid
              ? EventGameCardNavigationLayout.grid
              : EventGameCardNavigationLayout.verticalList,
      gameColumnCountForEvent: _gameColumnCountForSection,
    );
    if (next == null) return KeyEventResult.ignored;
    setState(() => _focus = next);
    _ensureFocusVisible(next);
    return KeyEventResult.handled;
  }

  void _activateFocus() {
    final focus = _focus;
    if (focus == null || focus.eventIndex >= widget.sections.length) return;
    final section = widget.sections[focus.eventIndex];
    if (focus.isEvent) {
      final card = section.card;
      if (section.canOpenEvent && card != null) {
        setActiveTournament(ref, card);
      }
      return;
    }
    if (section.games.isEmpty) return;
    final gameIndex =
        focus.gameIndex.clamp(0, section.games.length - 1).toInt();
    final title = section.card?.title ?? section.title;
    openTournamentGameTab(
      ref,
      section.games[gameIndex],
      title,
      routeTitle: widget.routeTitle,
      routeGames: widget.routeGames,
      routeGamesContinuation: widget.routeGamesContinuation,
      viewSource: ChessboardView.playerProfile,
    );
  }

  void _ensureFocusVisible(EventGameCardFocus focus) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key =
          focus.isGame
              ? _gameKeys['${focus.eventIndex}:${focus.gameIndex}']
              : _sectionKeys[focus.eventIndex];
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: true,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: ListView.builder(
          controller: widget.controller,
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          itemCount: widget.sections.length + (widget.footer == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (index >= widget.sections.length) return widget.footer!;
            final section = widget.sections[index];
            final selected = _focus?.eventIndex == index ? _focus : null;
            return KeyedSubtree(
              key: _sectionKey(index),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: index == widget.sections.length - 1 ? 0 : 18,
                ),
                child: _PlayerGamesEventBlock(
                  section: section,
                  routeTitle: widget.routeTitle,
                  routeGames: widget.routeGames,
                  routeGamesContinuation: widget.routeGamesContinuation,
                  layout: widget.layout,
                  keyboardFocus: selected,
                  gameKeyFor: (gameIndex) => _gameKey(index, gameIndex),
                  onContext: widget.onContext,
                  selectionMode: widget.selectionMode,
                  selectedIds: widget.selectedIds,
                  onToggleSelection: widget.onToggleSelection,
                  profilePlayerName: widget.profilePlayerName,
                  profileFederationFallback: widget.profileFederationFallback,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PlayerGamesEventBlock extends StatelessWidget {
  const _PlayerGamesEventBlock({
    required this.section,
    required this.routeTitle,
    required this.routeGames,
    required this.routeGamesContinuation,
    required this.layout,
    required this.keyboardFocus,
    required this.gameKeyFor,
    required this.onContext,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.profilePlayerName,
    required this.profileFederationFallback,
  });

  final _PlayerGameEventSection section;
  final String routeTitle;
  final List<GamesTourModel> routeGames;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final DesktopCardLayout layout;
  final EventGameCardFocus? keyboardFocus;
  final GlobalKey Function(int gameIndex) gameKeyFor;
  final Future<void> Function({
    required Offset globalPos,
    required GamesTourModel game,
  })
  onContext;
  final bool selectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelection;
  final String profilePlayerName;
  final String? profileFederationFallback;

  @override
  Widget build(BuildContext context) {
    final title = section.card?.title ?? section.title;
    final selectedGameIndex =
        keyboardFocus?.isGame == true ? keyboardFocus!.gameIndex : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PlayerGamesEventHeader(
          section: section,
          selected: keyboardFocus?.isEvent ?? false,
        ),
        const SizedBox(height: 10),
        DesktopGameCardsFlow(
          layout: layout,
          embedded: true,
          itemCount: section.games.length,
          itemBuilder: (context, index) {
            return KeyedSubtree(
              key: gameKeyFor(index),
              child: _ContextGameCard(
                game: section.games[index],
                tournamentTitle: title,
                routeTitle: routeTitle,
                routeGames: routeGames,
                routeGamesContinuation: routeGamesContinuation,
                layout: layout,
                onContext: onContext,
                selectionMode: selectionMode,
                selected:
                    selectedIds.contains(section.games[index].gameId) ||
                    selectedGameIndex == index,
                onToggleSelection: onToggleSelection,
                profilePlayerName: profilePlayerName,
                profileFederationFallback: profileFederationFallback,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ContextGameCard extends StatelessWidget {
  const _ContextGameCard({
    required this.game,
    required this.tournamentTitle,
    required this.routeTitle,
    required this.routeGames,
    required this.routeGamesContinuation,
    required this.layout,
    required this.onContext,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelection,
    required this.profilePlayerName,
    required this.profileFederationFallback,
  });

  final GamesTourModel game;
  final String tournamentTitle;
  final String routeTitle;
  final List<GamesTourModel> routeGames;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final DesktopCardLayout layout;
  final Future<void> Function({
    required Offset globalPos,
    required GamesTourModel game,
  })
  onContext;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<String> onToggleSelection;
  final String profilePlayerName;
  final String? profileFederationFallback;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.85)
                      : Colors.transparent,
              width: 1.5,
            ),
            boxShadow:
                selected
                    ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.18),
                        blurRadius: 16,
                      ),
                    ]
                    : null,
          ),
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons & kSecondaryMouseButton != 0) {
                onContext(globalPos: event.position, game: game);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap:
                  selectionMode ? () => onToggleSelection(game.gameId) : null,
              child: LiveDesktopGameCard(
                game: game,
                tournamentTitle: tournamentTitle,
                routeTitle: routeTitle,
                routeGames: routeGames,
                routeGamesContinuation: routeGamesContinuation,
                layout: layout,
                viewSource: ChessboardView.playerProfile,
                enableContextMenu: false,
                federationFallbackForName: profilePlayerName,
                federationFallback: profileFederationFallback,
              ),
            ),
          ),
        ),
        if (selectionMode)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => onToggleSelection(game.gameId),
            ),
          ),
        if (selectionMode)
          Positioned(
            top: -6,
            right: -6,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected ? kPrimaryColor : kBlack2Color,
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected
                          ? kWhiteColor
                          : kWhiteColor.withValues(alpha: 0.28),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Icon(
                selected
                    ? Icons.check_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 14,
                color: kWhiteColor,
              ),
            ),
          ),
      ],
    );
  }
}

class _PlayerGamesEventHeader extends ConsumerStatefulWidget {
  const _PlayerGamesEventHeader({
    required this.section,
    required this.selected,
  });

  final _PlayerGameEventSection section;
  final bool selected;

  @override
  ConsumerState<_PlayerGamesEventHeader> createState() =>
      _PlayerGamesEventHeaderState();
}

class _PlayerGamesEventHeaderState
    extends ConsumerState<_PlayerGamesEventHeader> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final card = section.card;
    final event = section.event;
    final scoreText =
        '${_formatScore(section.playerScore)}/${section.games.length}';
    final dates = _formatDateRange(
      event?.startDate ?? card?.startDate,
      event?.endDate ?? card?.endDate,
    );
    final timeControl =
        (card?.timeControl.trim().isNotEmpty ?? false)
            ? card!.timeControl
            : (event?.dominantTimeControl ?? '');
    final canOpen = section.canOpenEvent && card != null;
    final color = card == null ? kPrimaryColor : _eventStatusColor(card);
    final highlighted = widget.selected || (_hover && canOpen);

    return ClickCursor(
      enabled: canOpen,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit:
            (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canOpen ? () => setActiveTournament(ref, card) : null,
          onTapDown: canOpen ? (_) => setState(() => _pressed = true) : null,
          onTapUp: canOpen ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: canOpen ? () => setState(() => _pressed = false) : null,
          child: SingleMotionBuilder(
            value: _pressed ? 0.992 : (_hover && canOpen ? 1.003 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                color: highlighted ? kBlack3Color : kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      widget.selected
                          ? kPrimaryColor
                          : _hover && canOpen
                          ? color.withValues(alpha: 0.5)
                          : kDividerColor,
                ),
                boxShadow:
                    widget.selected
                        ? [
                          BoxShadow(
                            color: kPrimaryColor.withValues(alpha: 0.16),
                            blurRadius: 16,
                          ),
                        ]
                        : null,
              ),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (dates != null) ...[
                              Flexible(
                                child: Text(
                                  dates,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kLightGreyColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Text(
                              '${section.games.length} game${section.games.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                color: kLightGreyColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (timeControl.trim().isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  timeControl.trim().toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kPrimaryColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: color.withValues(alpha: 0.32)),
                    ),
                    child: Text(
                      scoreText,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (canOpen) ...[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.open_in_new_rounded,
                      size: 15,
                      color: kWhiteColor70,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Color _eventStatusColor(GroupEventCardModel card) {
    return switch (card.tourEventCategory) {
      TourEventCategory.live => kRedColor,
      TourEventCategory.ongoing => kGreenColor,
      TourEventCategory.upcoming => kPrimaryColor,
      TourEventCategory.completed => kLightGreyColor,
    };
  }
}

String _formatScore(double score) {
  if (score == score.truncateToDouble()) return score.toInt().toString();
  return score.toStringAsFixed(1);
}

String? _formatDateRange(DateTime? start, DateTime? end) {
  if (start == null && end == null) return null;
  String fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  if (start != null && end != null) {
    if (start.year == end.year &&
        start.month == end.month &&
        start.day == end.day) {
      return fmt(start);
    }
    return '${fmt(start)} - ${fmt(end)}';
  }
  return fmt(start ?? end!);
}

class _FilterButton extends StatefulWidget {
  const _FilterButton({
    required this.hasActive,
    required this.count,
    required this.onTap,
    this.onLongPress,
  });

  final bool hasActive;
  final int count;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<_FilterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.hasActive ? kRedColor : kWhiteColor70;
    return DesktopTooltip(
      message:
          widget.hasActive
              ? '${widget.count} active filter${widget.count == 1 ? '' : 's'} · click to open/close, long-press to clear'
              : 'Filters are shown in the right rail',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color:
                    widget.hasActive
                        ? kRedColor.withValues(alpha: 0.12)
                        : (_hover ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color:
                      widget.hasActive
                          ? kRedColor.withValues(alpha: 0.45)
                          : kDividerColor,
                ),
              ),
              alignment: Alignment.center,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(Icons.tune_rounded, size: 16, color: color),
                  if (widget.hasActive)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          color: kRedColor,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${widget.count}',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
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

enum _RowAction {
  open,
  openBackground,
  saveToLibrary,
  share,
  copyShareLink,
  openWhiteProfile,
  openBlackProfile,
  copyId,
}

void _openContextPlayerProfile(WidgetRef ref, PlayerCard player) {
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

class _EmptyGames extends StatelessWidget {
  const _EmptyGames();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.sports_esports_outlined,
              size: 32,
              color: kLightGreyColor,
            ),
            SizedBox(height: 12),
            Text(
              'No games to relive — yet',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              'As soon as this player sits down at the board, their games will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoFilterResults extends StatelessWidget {
  const _NoFilterResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.filter_alt_off_outlined,
              size: 32,
              color: kLightGreyColor,
            ),
            SizedBox(height: 12),
            Text(
              'Nothing matches that lens',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              'Loosen the filters or clear your search to widen the horizon.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Events body
// ---------------------------------------------------------------------

class _EventsBody extends ConsumerStatefulWidget {
  const _EventsBody({
    required this.activeKey,
    required this.fideId,
    required this.dataSource,
    required this.isActive,
  });

  final PlayerProfileKey activeKey;
  final int? fideId;
  final PlayerProfileDataSource dataSource;
  final bool isActive;

  @override
  ConsumerState<_EventsBody> createState() => _EventsBodyState();
}

class _EventsBodyState extends ConsumerState<_EventsBody> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eventsAsync = ref.watch(playerEventsKeyProvider(widget.activeKey));
    final cardsAsync =
        widget.dataSource == PlayerProfileDataSource.twic
            ? ref.watch(playerTwicEventCardsProvider(widget.activeKey))
            : (widget.fideId != null
                ? ref.watch(playerEventCardsProvider(widget.fideId!))
                : const AsyncValue<Map<String, GroupEventCardModel>>.data({}));

    return eventsAsync.when(
      loading:
          () => const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
          ),
      error: (e, _) => _ErrorState(message: e.toString()),
      data: (events) {
        if (events.isEmpty) return const _EmptyEvents();
        final cards = cardsAsync.valueOrNull ?? const {};
        return ListKeyboardScrollFocus(
          controller: _scrollController,
          autofocus: widget.isActive,
          enabled: widget.isActive,
          child: ListView.separated(
            controller: _scrollController,
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            itemCount: events.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final event = events[index];
              final card = cards[event.tourId];
              return _EventRow(
                event: event,
                card: card,
                onTap:
                    card == null ? null : () => setActiveTournament(ref, card),
              );
            },
          ),
        );
      },
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();

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
              'No events on file',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              'When this player joins a broadcast tournament, it shows up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventRow extends StatefulWidget {
  const _EventRow({required this.event, required this.card, this.onTap});

  final PlayerEventData event;
  final GroupEventCardModel? card;
  final VoidCallback? onTap;

  @override
  State<_EventRow> createState() => _EventRowState();
}

class _EventRowState extends State<_EventRow> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final score = event.score ?? 0;
    final games = event.gamesPlayed;
    final hasResult = games > 0;
    final pct = hasResult ? score / games : 0.0;
    final scoreColor =
        hasResult
            ? (pct >= 0.55
                ? kGreenColor
                : (pct <= 0.45 ? kRedColor : kLightGreyColor))
            : kLightGreyColor;
    final scoreText = hasResult ? '${_fmtScore(score)}/$games' : '–';
    final dates = _fmtDateRange(event.startDate, event.endDate);
    final tc = (event.dominantTimeControl ?? '').trim();

    return ClickCursor(
      enabled: widget.onTap != null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit:
            (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.985 : (_hover ? 1.005 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: _hover ? kBlack3Color : kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _hover
                          ? kPrimaryColor.withValues(alpha: 0.4)
                          : kDividerColor,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.tourName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (dates != null) ...[
                              const Icon(
                                Icons.calendar_today_outlined,
                                size: 11,
                                color: kLightGreyColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                dates,
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            const Icon(
                              Icons.sports_esports_outlined,
                              size: 11,
                              color: kLightGreyColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$games game${games == 1 ? '' : 's'}',
                              style: const TextStyle(
                                color: kLightGreyColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (tc.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: kPrimaryColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  tc.toUpperCase(),
                                  style: const TextStyle(
                                    color: kPrimaryColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: scoreColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: scoreColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      scoreText,
                      style: TextStyle(
                        color: scoreColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (widget.onTap != null) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: kWhiteColor70,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fmtScore(double s) {
    if (s == s.truncateToDouble()) return s.toInt().toString();
    return s.toStringAsFixed(1);
  }

  String? _fmtDateRange(DateTime? start, DateTime? end) {
    if (start == null && end == null) return null;
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (start != null && end != null) {
      if (start.year == end.year &&
          start.month == end.month &&
          start.day == end.day) {
        return fmt(start);
      }
      return '${fmt(start)} → ${fmt(end)}';
    }
    return fmt(start ?? end!);
  }
}
