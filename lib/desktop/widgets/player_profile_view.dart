import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/repository/gamebase/memorial_player.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/fide_rating_history_service.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';
import 'package:chessever/desktop/utils/player_build_tree_filters.dart';
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
import 'package:chessever/desktop/widgets/memorial_player_about_view.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show
        LiveDesktopGameCard,
        buildTournamentBoardTabArgs,
        openTournamentGameTab;
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/player_profile/tabs/player_events_tab.dart'
    show playerEventCardsProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
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

@visibleForTesting
List<PlayerProfileSection> playerProfileSectionsFor({
  required bool isMemorial,
}) =>
    isMemorial
        ? const <PlayerProfileSection>[
          PlayerProfileSection.about,
          PlayerProfileSection.games,
        ]
        : PlayerProfileSection.values;

/// Desktop-native player profile pane.
///
/// The compact identity header keeps profile actions visible while the
/// full-width Overview, Games, and Events tabs use the remaining desktop
/// canvas. Overview follows the public profile hierarchy: three rating cards,
/// performance and colour summaries, openings, and recent events. Official
/// monthly FIDE history is loaded independently so it does not block the
/// profile's first frame.
class PlayerProfileView extends ConsumerStatefulWidget {
  const PlayerProfileView({super.key, required this.tabId, required this.args});

  final String tabId;
  final PlayerProfileArgs args;

  @override
  ConsumerState<PlayerProfileView> createState() => _PlayerProfileViewState();
}

extension on PlayerProfileSection {
  String get label {
    switch (this) {
      case PlayerProfileSection.about:
        return 'Overview';
      case PlayerProfileSection.games:
        return 'Games';
      case PlayerProfileSection.events:
        return 'Events';
    }
  }
}

class _PlayerProfileViewState extends ConsumerState<PlayerProfileView> {
  late PlayerProfileDataSource _dataSource;
  String? _gamebasePlayerId;
  bool _isBuildingProfile = false;
  bool _isBuildingTree = false;

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
        old.args.fideId != widget.args.fideId ||
        old.args.memorialSourceIdentity != widget.args.memorialSourceIdentity) {
      setState(() {
        _dataSource = _profileInitialDataSource();
        _gamebasePlayerId = _normalize(widget.args.gamebasePlayerId);
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
    memorialSourceIdentity: widget.args.memorialSourceIdentity,
  );

  void _setTab(PlayerProfileSection next) {
    final sections = ref.read(playerProfileSectionByTabIdProvider);
    if ((sections[widget.tabId] ?? PlayerProfileSection.about) == next) return;
    ref
        .read(playerProfileSectionByTabIdProvider.notifier)
        .update(
          (current) => <String, PlayerProfileSection>{
            ...current,
            widget.tabId: next,
          },
        );
  }

  Future<PlayerWorkspacePlayer> _ensurePlayerWorkspace(int fideId) async {
    final normalizedFideId = fideId.toString();
    await ref
        .read(playerWorkspaceProvider.notifier)
        .ensurePlayerWorkspaceByFideId(normalizedFideId);
    final workspace = ref
        .read(playerWorkspaceProvider)
        .playerForFideId(normalizedFideId);
    if (workspace == null) {
      throw StateError('The player profile could not be created.');
    }
    return workspace;
  }

  Future<void> _buildChessEverPlayerTree(int fideId) async {
    if (_isBuildingProfile || _isBuildingTree) return;
    setState(() => _isBuildingTree = true);
    try {
      final workspace = await _ensurePlayerWorkspace(fideId);
      if (!mounted) return;

      openPlayerWorkspaceTab(
        ref,
        workspace,
        focus: false,
        reuseExisting: false,
      );
      // Let the background Players tab mount before opening the foreground
      // board. Mounting both tab subtrees in one frame lets their autofocus
      // nodes compete, leaving the board visible without keyboard ownership.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await openOrBuildPlayerWorkspaceSourceTree(
        context: context,
        ref: ref,
        player: workspace,
        source: PlayerWorkspaceSource.chessever,
        preparationSide: PlayerBuildTreePreparationSide.both,
      );
    } catch (error) {
      if (!mounted) return;
      _showToast(_playerWorkspaceErrorText(error), error: true);
    } finally {
      if (mounted) setState(() => _isBuildingTree = false);
    }
  }

  Future<void> _openOrBuildPlayerWorkspace(int fideId) async {
    if (_isBuildingProfile || _isBuildingTree) return;
    final normalizedFideId = fideId.toString();
    var workspace = ref
        .read(playerWorkspaceProvider)
        .playerForFideId(normalizedFideId);

    if (workspace == null) {
      setState(() => _isBuildingProfile = true);
      try {
        workspace = await _ensurePlayerWorkspace(fideId);
      } catch (error) {
        if (!mounted) return;
        _showToast(_playerWorkspaceErrorText(error), error: true);
        return;
      } finally {
        if (mounted) setState(() => _isBuildingProfile = false);
      }
    } else {
      await ref
          .read(playerWorkspaceProvider.notifier)
          .selectPlayer(workspace.id);
    }

    if (!mounted) return;
    openPlayerWorkspaceTab(ref, workspace);
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
            (player) => favoritePlayerMatchesIdentity(
              player,
              fideId: fideStr,
              playerName: playerName,
              memorialSourceIdentity: widget.args.memorialSourceIdentity,
            ),
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
            gamebasePlayerId: widget.args.gamebasePlayerId,
            memorialSourceIdentity: widget.args.memorialSourceIdentity,
            memorialRouteId: widget.args.memorialRouteId,
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
    final isFavorite = favs.maybeWhen(
      data:
          (players) => players.any(
            (player) => favoritePlayerMatchesIdentity(
              player,
              fideId: favoriteFideId,
              playerName: widget.args.playerName,
              memorialSourceIdentity: widget.args.memorialSourceIdentity,
            ),
          ),
      orElse: () => false,
    );

    final gamesState = ref.watch(playerProfileGamesKeyProvider(activeKey));
    final selectedTab = ref.watch(
      playerProfileSectionByTabIdProvider.select(
        (sections) => sections[widget.tabId] ?? PlayerProfileSection.about,
      ),
    );
    final isMemorial =
        widget.args.memorialSourceIdentity?.trim().isNotEmpty == true;
    final currentTab =
        isMemorial && selectedTab == PlayerProfileSection.events
            ? PlayerProfileSection.about
            : selectedTab;
    final hasActiveFilter = gamesState.hasActiveFilters;
    final isTwicLoading =
        _dataSource == PlayerProfileDataSource.twic && gamesState.isLoading;
    final filteredStatsAsync =
        hasActiveFilter && activeKey.source == PlayerProfileDataSource.twic
            ? ref.watch(
              twicPlayerStatsProvider(
                TwicPlayerStatsRequest(
                  playerKey: activeKey,
                  scope: TwicStatsScope.filtered,
                ),
              ),
            )
            : null;
    final authoritativeGameCount =
        hasActiveFilter
            ? filteredStatsAsync?.valueOrNull?.resultStats.totalGames
            : twicSummaryAsync.valueOrNull?.totalGames;
    final filteredGameCount = playerProfileGameCountForTab(
      gamesState,
      authoritativeTotal: authoritativeGameCount,
    );
    final isGameCountLoading =
        hasActiveFilter
            ? (filteredStatsAsync?.isLoading ?? false)
            : twicSummaryAsync.isLoading && authoritativeGameCount == null;

    final ratings = _ProfileRatings(
      classical: activeProfile?.classicalRating ?? widget.args.rating,
      rapid: activeProfile?.rapidRating,
      blitz: activeProfile?.blitzRating,
    );

    final workspacePlayer = ref.watch(
      playerWorkspaceProvider.select(
        (state) => state.playerForFideId(effectiveFideId?.toString()),
      ),
    );
    final hasFideId = effectiveFideId != null && effectiveFideId > 0;

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            name: effectiveName,
            title: effectiveTitle,
            federation: effectiveFederation,
            fideId: effectiveFideId,
            memorialSourceIdentity: widget.args.memorialSourceIdentity,
            birthday: activeProfile?.birthday,
            totalGames: twicSummaryAsync.valueOrNull?.totalGames,
            isSummaryLoading: twicSummaryAsync.isLoading,
            isFavorite: isFavorite,
            hasFideId: hasFideId,
            hasPlayerWorkspace: workspacePlayer != null,
            isBuildingProfile: _isBuildingProfile,
            isBuildingTree: _isBuildingTree,
            hasBuildTree: hasFideId,
            onToggleFavorite: _toggleFavorite,
            onOpenPlayerWorkspace:
                hasFideId
                    ? () => _openOrBuildPlayerWorkspace(effectiveFideId)
                    : null,
            onBuildTree:
                effectiveFideId == null
                    ? () {}
                    : () => _buildChessEverPlayerTree(effectiveFideId),
          ),
          const Divider(height: 1, thickness: 1, color: kDividerColor),
          Expanded(
            child: _RightPane(
              tabId: widget.tabId,
              currentTab: currentTab,
              onSelectTab: _setTab,
              hasActiveFilter: hasActiveFilter,
              isTwicLoading: isTwicLoading,
              filteredGameCount: filteredGameCount,
              isGameCountLoading: isGameCountLoading,
              activeKey: activeKey,
              fideId: effectiveFideId,
              playerName: effectiveName,
              dataSource: _dataSource,
              gamebasePlayerId: _gamebasePlayerId,
              ratings: ratings,
              memorialSourceIdentity: widget.args.memorialSourceIdentity,
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
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
int playerProfileGameCountForTab(
  PlayerProfileGamesState state, {
  int? authoritativeTotal,
}) {
  if (state.playerKey.source == PlayerProfileDataSource.twic) {
    return authoritativeTotal ?? state.totalCount ?? state.filteredGames.length;
  }
  return state.filteredGames.length;
}

String _playerProfileRouteTitle(String playerName) {
  final player = playerName.trim();
  if (player.isEmpty) return 'Player games';
  return '$player games';
}

String _playerWorkspaceErrorText(Object error) {
  final message = error.toString();
  for (final prefix in const <String>[
    'Bad state: ',
    'Invalid argument(s): ',
    'Invalid argument: ',
    'Exception: ',
  ]) {
    if (message.startsWith(prefix)) return message.substring(prefix.length);
  }
  return message;
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
    required this.fideId,
    this.memorialSourceIdentity,
    required this.birthday,
    required this.totalGames,
    required this.isSummaryLoading,
    required this.isFavorite,
    required this.hasFideId,
    required this.hasPlayerWorkspace,
    required this.isBuildingProfile,
    required this.isBuildingTree,
    required this.hasBuildTree,
    required this.onToggleFavorite,
    required this.onOpenPlayerWorkspace,
    required this.onBuildTree,
  });

  final String name;
  final String? title;
  final String? federation;
  final int? fideId;
  final String? memorialSourceIdentity;
  final String? birthday;
  final int? totalGames;
  final bool isSummaryLoading;
  final bool isFavorite;
  final bool hasFideId;
  final bool hasPlayerWorkspace;
  final bool isBuildingProfile;
  final bool isBuildingTree;
  final bool hasBuildTree;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onOpenPlayerWorkspace;
  final VoidCallback onBuildTree;

  @override
  Widget build(BuildContext context) {
    final countryCode =
        federation == null ? '' : CountryUtils.toIso2Code(federation!);
    final showFlag =
        (federation?.toUpperCase() == 'FID') || countryCode.isNotEmpty;
    return Container(
      height: 98,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(color: kBackgroundColor),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ProfileAvatar(
            fideId: fideId,
            name: name,
            memorialSourceIdentity: memorialSourceIdentity,
            size: 68,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if ((title ?? '').isNotEmpty) ...[
                      Text(
                        title!,
                        style: const TextStyle(
                          color: kPrimaryColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.25,
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
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (showFlag)
                      _HeaderMeta(
                        label: federation?.toUpperCase() ?? countryCode,
                        child:
                            federation?.toUpperCase() == 'FID'
                                ? Image.asset(
                                  PngAsset.fideLogo,
                                  height: 14,
                                  width: 20,
                                  cacheWidth:
                                      (20 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                  cacheHeight:
                                      (14 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                )
                                : FederationFlag(
                                  federation: countryCode,
                                  height: 14,
                                  width: 20,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                      ),
                    if (fideId != null && fideId! > 0)
                      _HeaderMeta(label: 'FIDE $fideId'),
                    if ((birthday ?? '').trim().isNotEmpty)
                      _HeaderMeta(label: 'Born ${birthday!.trim()}'),
                    if (totalGames != null && totalGames! > 0)
                      _HeaderMeta(
                        label: '${formatCompactCount(totalGames!)} games',
                      )
                    else if (isSummaryLoading)
                      const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.4,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          DesktopFavoriteButton(
            selected: isFavorite,
            onPress: onToggleFavorite,
          ),
          if (hasFideId) ...[
            const SizedBox(width: 8),
            DesktopHeaderActionButton(
              label: hasPlayerWorkspace ? 'Player Profile' : 'Build Profile',
              icon:
                  hasPlayerWorkspace
                      ? Icons.person_outline_rounded
                      : Icons.person_add_alt_1_outlined,
              onPress: isBuildingTree ? null : onOpenPlayerWorkspace,
              tooltip:
                  hasPlayerWorkspace
                      ? 'Open this player in Players'
                      : 'Create this FIDE player in Players',
              accented: hasPlayerWorkspace,
              loading: isBuildingProfile,
            ),
          ],
          if (hasBuildTree) ...[
            const SizedBox(width: 8),
            DesktopHeaderActionButton(
              label: 'Build Tree',
              icon: Icons.account_tree_outlined,
              onPress: isBuildingProfile ? null : onBuildTree,
              tooltip: 'Build the ChessEver source tree in Players',
              loading: isBuildingTree,
            ),
          ],
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

class _HeaderMeta extends StatelessWidget {
  const _HeaderMeta({required this.label, this.child});

  final String label;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (child != null) ...[child!, const SizedBox(width: 6)],
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Profile avatar and rating overview
// ---------------------------------------------------------------------

class _ProfileAvatar extends StatefulWidget {
  const _ProfileAvatar({
    required this.fideId,
    required this.name,
    this.memorialSourceIdentity,
    required this.size,
  });

  final int? fideId;
  final String name;
  final String? memorialSourceIdentity;
  final double size;

  @override
  State<_ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<_ProfileAvatar> {
  Future<String?>? _photoFuture;

  @override
  void initState() {
    super.initState();
    _configurePhotoFuture();
  }

  @override
  void didUpdateWidget(covariant _ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fideId != widget.fideId ||
        oldWidget.name != widget.name ||
        oldWidget.memorialSourceIdentity != widget.memorialSourceIdentity) {
      _configurePhotoFuture();
    }
  }

  void _configurePhotoFuture() {
    final fideId = widget.fideId;
    final memorialUrl = memorialPlayerPhotoUrl(
      playerName: widget.name,
      sourceIdentity: widget.memorialSourceIdentity,
    );
    _photoFuture =
        fideId != null && fideId > 0
            ? (() async =>
                await FidePhotoService.getPhotoUrlOrNull(fideId.toString()) ??
                memorialUrl)()
            : Future<String?>.value(memorialUrl);
  }

  @override
  Widget build(BuildContext context) {
    final initials = getPlayerInitials(widget.name);

    return FutureBuilder<String?>(
      future: _photoFuture,
      builder: (context, snapshot) {
        return PlayerInitialsAvatar(
          photoUrl: snapshot.data,
          initials: initials,
          size: widget.size,
          borderRadius: 10,
        );
      },
    );
  }
}

class _RatingOverviewRow extends StatelessWidget {
  const _RatingOverviewRow({
    required this.ratings,
    required this.history,
    required this.historyLoading,
    required this.selected,
    required this.onSelect,
  });

  final _ProfileRatings ratings;
  final FideRatingHistory? history;
  final bool historyLoading;
  final GameTimeControlFilter selected;
  final ValueChanged<GameTimeControlFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final classical = history?.cardTrend(FideRatingHistoryType.classical);
    final rapid = history?.cardTrend(FideRatingHistoryType.rapid);
    final blitz = history?.cardTrend(FideRatingHistoryType.blitz);
    return Row(
      children: [
        Expanded(
          child: _OverviewRatingCard(
            label: 'Classical',
            asset: PngAsset.classicalIcon,
            value: classical?.current ?? ratings.classical,
            games: classical?.games,
            change: classical?.change,
            trend: classical?.series ?? const [],
            historyLoading: historyLoading,
            accent: kPrimaryColor,
            selected: selected == GameTimeControlFilter.classical,
            onTap: () => onSelect(GameTimeControlFilter.classical),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _OverviewRatingCard(
            label: 'Rapid',
            asset: PngAsset.rapidIcon,
            value: rapid?.current ?? ratings.rapid,
            games: rapid?.games,
            change: rapid?.change,
            trend: rapid?.series ?? const [],
            historyLoading: historyLoading,
            accent: const Color(0xFFF4B942),
            selected: selected == GameTimeControlFilter.rapid,
            onTap: () => onSelect(GameTimeControlFilter.rapid),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _OverviewRatingCard(
            label: 'Blitz',
            asset: PngAsset.blitzIcon,
            value: blitz?.current ?? ratings.blitz,
            games: blitz?.games,
            change: blitz?.change,
            trend: blitz?.series ?? const [],
            historyLoading: historyLoading,
            accent: const Color(0xFFD16DF0),
            selected: selected == GameTimeControlFilter.blitz,
            onTap: () => onSelect(GameTimeControlFilter.blitz),
          ),
        ),
      ],
    );
  }
}

class _OverviewRatingCard extends StatefulWidget {
  const _OverviewRatingCard({
    required this.label,
    required this.asset,
    required this.value,
    required this.games,
    required this.change,
    required this.trend,
    required this.historyLoading,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String asset;
  final int? value;
  final int? games;
  final int? change;
  final List<FideRatingHistoryPoint> trend;
  final bool historyLoading;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_OverviewRatingCard> createState() => _OverviewRatingCardState();
}

class _OverviewRatingCardState extends State<_OverviewRatingCard> {
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
              value: _hover ? 1.008 : 1.0,
              motion: DesktopMotion.hover,
              builder:
                  (context, scale, child) => Transform.scale(
                    scale: scale,
                    filterQuality: FilterQuality.medium,
                    child: child,
                  ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                height: 112,
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 13),
                decoration: BoxDecoration(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.12)
                          : (_hover ? kBlack3Color : kBlack2Color),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        selected
                            ? kPrimaryColor.withValues(alpha: 0.62)
                            : (_hover
                                ? kPrimaryColor.withValues(alpha: 0.3)
                                : kDividerColor),
                    width: selected ? 1.2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Image.asset(
                                widget.asset,
                                width: 14,
                                height: 14,
                                cacheWidth:
                                    (14 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                                cacheHeight:
                                    (14 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                widget.label.toUpperCase(),
                                style: TextStyle(
                                  color:
                                      selected ? kPrimaryColor : kWhiteColor70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.75,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.value?.toString() ?? '—',
                            style: TextStyle(
                              color:
                                  widget.value == null
                                      ? kLightGreyColor
                                      : kWhiteColor,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              height: 1,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 7),
                          _RatingCardFootnote(
                            change: widget.change,
                            games: widget.games,
                            historyLoading: widget.historyLoading,
                            accent: widget.accent,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        height: 58,
                        child:
                            widget.historyLoading && widget.trend.isEmpty
                                ? Center(
                                  child: SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                      color: widget.accent,
                                    ),
                                  ),
                                )
                                : widget.trend.length < 2
                                ? const Center(
                                  child: Text(
                                    'History unavailable',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: kLightGreyColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                )
                                : _InteractiveRatingSparkline(
                                  points: widget.trend,
                                  color: _ratingTrendColor(
                                    widget.change,
                                    widget.accent,
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
      ),
    );
  }
}

class _RatingCardFootnote extends StatelessWidget {
  const _RatingCardFootnote({
    required this.change,
    required this.games,
    required this.historyLoading,
    required this.accent,
  });

  final int? change;
  final int? games;
  final bool historyLoading;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (historyLoading) {
      return const Text(
        'Loading history...',
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Row(
      children: [
        if (change != null) ...[
          Text(
            '${change! >= 0 ? '+' : ''}$change in 12M',
            style: TextStyle(
              color: _ratingTrendColor(change, accent),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (games != null) const SizedBox(width: 9),
        ],
        if (games != null)
          Flexible(
            child: Text(
              '${formatCompactCount(games!)} rated games in 12M',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          )
        else
          const Text(
            'Current FIDE rating',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

Color _ratingTrendColor(int? change, Color accent) {
  if (change == null || change == 0) return accent;
  if (change > 0) return kGreenColor;
  return kRedColor;
}

class _InteractiveRatingSparkline extends StatefulWidget {
  const _InteractiveRatingSparkline({
    required this.points,
    required this.color,
  });

  final List<FideRatingHistoryPoint> points;
  final Color color;

  @override
  State<_InteractiveRatingSparkline> createState() =>
      _InteractiveRatingSparklineState();
}

class _InteractiveRatingSparklineState
    extends State<_InteractiveRatingSparkline> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return MouseRegion(
          onExit: (_) {
            if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
          },
          onHover: (event) {
            const inset = 4.0;
            final plotWidth = constraints.maxWidth - inset * 2;
            if (plotWidth <= 0) return;
            final next = closestRatingPointIndex(
              event.localPosition.dx,
              inset,
              constraints.maxWidth - inset,
              widget.points.length,
            );
            if (next != _hoveredIndex) setState(() => _hoveredIndex = next);
          },
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _RatingSparklinePainter(
              points: widget.points,
              color: widget.color,
              hoveredIndex: _hoveredIndex,
            ),
          ),
        );
      },
    );
  }
}

class _RatingSparklinePainter extends CustomPainter {
  const _RatingSparklinePainter({
    required this.points,
    required this.color,
    required this.hoveredIndex,
  });

  final List<FideRatingHistoryPoint> points;
  final Color color;
  final int? hoveredIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || points.length < 2) return;
    final values = points.map((point) => point.rating).toList(growable: false);
    final minValue = values.reduce((a, b) => a < b ? a : b).toDouble();
    final maxValue = values.reduce((a, b) => a > b ? a : b).toDouble();
    final spread = (maxValue - minValue).abs();
    final ratingPadding = spread < 40 ? 8.0 : spread * 0.16;
    final domainMin = minValue - ratingPadding;
    final domainSpread = spread + ratingPadding * 2;
    const horizontalInset = 4.0;
    const verticalInset = 5.0;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x =
          horizontalInset +
          (size.width - horizontalInset * 2) * i / (values.length - 1);
      final normalized = (values[i].toDouble() - domainMin) / domainSpread;
      final y =
          size.height -
          verticalInset -
          normalized * (size.height - verticalInset * 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    final hover = hoveredIndex;
    if (hover != null && hover >= 0 && hover < points.length) {
      final x =
          horizontalInset +
          (size.width - horizontalInset * 2) * hover / (points.length - 1);
      final normalized =
          (points[hover].rating.toDouble() - domainMin) / domainSpread;
      final y =
          size.height -
          verticalInset -
          normalized * (size.height - verticalInset * 2);
      final point = Offset(x, y);
      canvas.drawLine(
        Offset(x, verticalInset),
        Offset(x, size.height - verticalInset),
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.16)
          ..strokeWidth = 0.8,
      );
      canvas.drawCircle(
        point,
        5,
        Paint()..color = kBackgroundColor.withValues(alpha: 0.94),
      );
      canvas.drawCircle(point, 2.8, Paint()..color = color);
      _paintRatingTooltip(
        canvas,
        Rect.fromLTRB(0, 0, size.width, size.height),
        point,
        points[hover],
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RatingSparklinePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.hoveredIndex != hoveredIndex ||
        oldDelegate.points != points;
  }
}

enum _RatingHistoryRange {
  oneYear(12, '1Y'),
  twoYears(24, '2Y'),
  threeYears(36, '3Y'),
  all(null, 'All');

  const _RatingHistoryRange(this.months, this.label);

  final int? months;
  final String label;
}

class _RatingHistoryPanel extends StatefulWidget {
  const _RatingHistoryPanel({
    required this.history,
    required this.loading,
    required this.initialTimeControl,
  });

  final FideRatingHistory? history;
  final bool loading;
  final GameTimeControlFilter initialTimeControl;

  @override
  State<_RatingHistoryPanel> createState() => _RatingHistoryPanelState();
}

class _RatingHistoryPanelState extends State<_RatingHistoryPanel> {
  late FideRatingHistoryType _type;
  _RatingHistoryRange _range = _RatingHistoryRange.all;

  @override
  void initState() {
    super.initState();
    _type = _historyTypeForFilter(widget.initialTimeControl);
  }

  @override
  void didUpdateWidget(covariant _RatingHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTimeControl != widget.initialTimeControl &&
        widget.initialTimeControl != GameTimeControlFilter.all) {
      _type = _historyTypeForFilter(widget.initialTimeControl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final series =
        widget.history?.chartSeries(_type, months: _range.months) ?? const [];
    final accent = _ratingHistoryAccent(_type);
    final current = series.isEmpty ? null : series.last.rating;

    return Container(
      height: 292,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final controls = <Widget>[
            SizedBox(
              width: 286,
              child: DesktopSegmentedTabs<FideRatingHistoryType>(
                tabs: const [
                  DesktopSegmentedTab(
                    value: FideRatingHistoryType.classical,
                    label: 'Classical',
                  ),
                  DesktopSegmentedTab(
                    value: FideRatingHistoryType.rapid,
                    label: 'Rapid',
                  ),
                  DesktopSegmentedTab(
                    value: FideRatingHistoryType.blitz,
                    label: 'Blitz',
                  ),
                ],
                selected: _type,
                expand: true,
                onChanged: (value) => setState(() => _type = value),
              ),
            ),
            const SizedBox(width: 8, height: 8),
            SizedBox(
              width: 226,
              child: DesktopSegmentedTabs<_RatingHistoryRange>(
                tabs: [
                  for (final range in _RatingHistoryRange.values)
                    DesktopSegmentedTab(value: range, label: range.label),
                ],
                selected: _range,
                expand: true,
                onChanged: (value) => setState(() => _range = value),
              ),
            ),
          ];
          final title = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Rating history',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (current != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      '$current',
                      style: TextStyle(
                        color: accent,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              const Text(
                'Official monthly FIDE ratings',
                style: TextStyle(
                  color: kLightGreyColor,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );
          final header =
              constraints.maxWidth >= 760
                  ? Row(children: [title, const Spacer(), ...controls])
                  : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: controls),
                      ),
                    ],
                  );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 10),
              Expanded(
                child:
                    widget.loading
                        ? Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: accent,
                            ),
                          ),
                        )
                        : series.length < 2
                        ? const Center(
                          child: Text(
                            'Rating history is unavailable for this format.',
                            style: TextStyle(
                              color: kLightGreyColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                        : _InteractiveRatingHistoryChart(
                          points: series,
                          color: accent,
                        ),
              ),
            ],
          );
        },
      ),
    );
  }
}

FideRatingHistoryType _historyTypeForFilter(GameTimeControlFilter filter) {
  switch (filter) {
    case GameTimeControlFilter.rapid:
      return FideRatingHistoryType.rapid;
    case GameTimeControlFilter.blitz:
      return FideRatingHistoryType.blitz;
    case GameTimeControlFilter.classical:
    case GameTimeControlFilter.all:
      return FideRatingHistoryType.classical;
  }
}

Color _ratingHistoryAccent(FideRatingHistoryType type) {
  switch (type) {
    case FideRatingHistoryType.classical:
      return kPrimaryColor;
    case FideRatingHistoryType.rapid:
      return const Color(0xFFF4B942);
    case FideRatingHistoryType.blitz:
      return const Color(0xFFD16DF0);
  }
}

class _InteractiveRatingHistoryChart extends StatefulWidget {
  const _InteractiveRatingHistoryChart({
    required this.points,
    required this.color,
  });

  final List<FideRatingHistoryPoint> points;
  final Color color;

  @override
  State<_InteractiveRatingHistoryChart> createState() =>
      _InteractiveRatingHistoryChartState();
}

class _InteractiveRatingHistoryChartState
    extends State<_InteractiveRatingHistoryChart> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return MouseRegion(
          onExit: (_) {
            if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
          },
          onHover: (event) {
            const plotLeft = 46.0;
            final plotRight = constraints.maxWidth - 10;
            if (event.localPosition.dx < plotLeft ||
                event.localPosition.dx > plotRight) {
              if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
              return;
            }
            final next = closestRatingPointIndex(
              event.localPosition.dx,
              plotLeft,
              plotRight,
              widget.points.length,
            );
            if (next != _hoveredIndex) setState(() => _hoveredIndex = next);
          },
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _RatingHistoryChartPainter(
              points: widget.points,
              color: widget.color,
              hoveredIndex: _hoveredIndex,
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
int closestRatingPointIndex(
  double x,
  double plotLeft,
  double plotRight,
  int pointCount,
) {
  if (pointCount <= 1 || plotRight <= plotLeft) return 0;
  final ratio = ((x - plotLeft) / (plotRight - plotLeft)).clamp(0.0, 1.0);
  return (ratio * (pointCount - 1)).round();
}

class _RatingHistoryChartPainter extends CustomPainter {
  const _RatingHistoryChartPainter({
    required this.points,
    required this.color,
    required this.hoveredIndex,
  });

  final List<FideRatingHistoryPoint> points;
  final Color color;
  final int? hoveredIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.width < 100 || size.height < 80) return;

    final ratings = points.map((point) => point.rating).toList(growable: false);
    final minRating = ratings.reduce((a, b) => a < b ? a : b).toDouble();
    final maxRating = ratings.reduce((a, b) => a > b ? a : b).toDouble();
    final spread = (maxRating - minRating).abs();
    final padding = spread < 40 ? 12.0 : spread * 0.1;
    final domainMin = minRating - padding;
    final domainMax = maxRating + padding;
    final domainSpread = domainMax - domainMin;
    final plot = Rect.fromLTRB(46, 8, size.width - 10, size.height - 25);
    final gridPaint =
        Paint()
          ..color = kDividerColor.withValues(alpha: 0.72)
          ..strokeWidth = 0.8;

    for (var index = 0; index < 4; index++) {
      final ratio = index / 3;
      final y = plot.bottom - plot.height * ratio;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final value = (domainMin + domainSpread * ratio).round();
      _paintChartLabel(
        canvas,
        '$value',
        Offset(plot.left - 8, y),
        alignRight: true,
        centerVertically: true,
      );
    }

    final line = Path();
    for (var index = 0; index < points.length; index++) {
      final x = plot.left + plot.width * index / (points.length - 1);
      final normalized = (points[index].rating - domainMin) / domainSpread;
      final y = plot.bottom - plot.height * normalized;
      if (index == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final area =
        Path.from(line)
          ..lineTo(plot.right, plot.bottom)
          ..lineTo(plot.left, plot.bottom)
          ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.24),
            color.withValues(alpha: 0.015),
          ],
        ).createShader(plot),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    final labelIndexes =
        <int>{
            0,
            ((points.length - 1) / 3).round(),
            ((points.length - 1) * 2 / 3).round(),
            points.length - 1,
          }.toList()
          ..sort();
    final spansSeveralYears =
        points.last.month.year - points.first.month.year >= 3;
    for (var label = 0; label < labelIndexes.length; label++) {
      final pointIndex = labelIndexes[label];
      final x = plot.left + plot.width * pointIndex / (points.length - 1);
      _paintChartLabel(
        canvas,
        _ratingMonthLabel(points[pointIndex].month, spansSeveralYears),
        Offset(x, plot.bottom + 8),
        centerHorizontally: label > 0 && label < labelIndexes.length - 1,
        alignRight: label == labelIndexes.length - 1,
      );
    }

    final last = Offset(
      plot.right,
      plot.bottom -
          plot.height * (points.last.rating - domainMin) / domainSpread,
    );
    canvas.drawCircle(
      last,
      6.2,
      Paint()
        ..color = color.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(last, 3.4, Paint()..color = color);

    final hover = hoveredIndex;
    if (hover != null && hover >= 0 && hover < points.length) {
      final point = points[hover];
      final pointOffset = Offset(
        plot.left + plot.width * hover / (points.length - 1),
        plot.bottom - plot.height * (point.rating - domainMin) / domainSpread,
      );
      canvas.drawLine(
        Offset(pointOffset.dx, plot.top),
        Offset(pointOffset.dx, plot.bottom),
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.18)
          ..strokeWidth = 0.9,
      );
      canvas.drawCircle(
        pointOffset,
        6,
        Paint()..color = kBackgroundColor.withValues(alpha: 0.92),
      );
      canvas.drawCircle(pointOffset, 3.5, Paint()..color = color);
      _paintRatingTooltip(canvas, plot, pointOffset, point);
    }
  }

  @override
  bool shouldRepaint(covariant _RatingHistoryChartPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.points != points ||
        oldDelegate.hoveredIndex != hoveredIndex;
  }
}

void _paintRatingTooltip(
  Canvas canvas,
  Rect plot,
  Offset point,
  FideRatingHistoryPoint rating,
) {
  final textPainter = TextPainter(
    text: TextSpan(
      children: [
        TextSpan(
          text: _ratingMonthLabel(rating.month, false),
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        TextSpan(
          text: '   ${rating.rating}',
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final tooltipSize = Size(textPainter.width + 16, textPainter.height + 12);
  var left = point.dx + 10;
  if (left + tooltipSize.width > plot.right) {
    left = point.dx - tooltipSize.width - 10;
  }
  final top =
      (point.dy - tooltipSize.height - 9)
          .clamp(plot.top, plot.bottom - tooltipSize.height)
          .toDouble();
  final rect = Rect.fromLTWH(left, top, tooltipSize.width, tooltipSize.height);
  final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
  canvas.drawRRect(rrect, Paint()..color = kBlack3Color);
  canvas.drawRRect(
    rrect,
    Paint()
      ..color = kWhiteColor.withValues(alpha: 0.16)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke,
  );
  textPainter.paint(canvas, Offset(left + 8, top + 6));
}

void _paintChartLabel(
  Canvas canvas,
  String text,
  Offset anchor, {
  bool alignRight = false,
  bool centerHorizontally = false,
  bool centerVertically = false,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  var dx = anchor.dx;
  var dy = anchor.dy;
  if (alignRight) dx -= painter.width;
  if (centerHorizontally) dx -= painter.width / 2;
  if (centerVertically) dy -= painter.height / 2;
  painter.paint(canvas, Offset(dx, dy));
}

String _ratingMonthLabel(DateTime month, bool yearOnly) {
  if (yearOnly) return '${month.year}';
  const labels = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${labels[month.month - 1]} ${month.year}';
}

// ---------------------------------------------------------------------
// Right pane (tabs + body)
// ---------------------------------------------------------------------

class _RightPane extends StatelessWidget {
  const _RightPane({
    required this.tabId,
    required this.currentTab,
    required this.onSelectTab,
    required this.hasActiveFilter,
    required this.isTwicLoading,
    required this.filteredGameCount,
    required this.isGameCountLoading,
    required this.activeKey,
    required this.fideId,
    required this.playerName,
    required this.dataSource,
    required this.gamebasePlayerId,
    required this.ratings,
    required this.memorialSourceIdentity,
    required this.currentTimeControl,
    required this.onSelectTimeControl,
  });

  final String tabId;
  final PlayerProfileSection currentTab;
  final ValueChanged<PlayerProfileSection> onSelectTab;
  final bool hasActiveFilter;
  final bool isTwicLoading;
  final int filteredGameCount;
  final bool isGameCountLoading;
  final PlayerProfileKey activeKey;
  final int? fideId;
  final String playerName;
  final PlayerProfileDataSource dataSource;
  final String? gamebasePlayerId;
  final _ProfileRatings ratings;
  final String? memorialSourceIdentity;
  final GameTimeControlFilter currentTimeControl;
  final ValueChanged<GameTimeControlFilter> onSelectTimeControl;

  @override
  Widget build(BuildContext context) {
    final memorialIdentity = memorialSourceIdentity?.trim();
    final isMemorial = memorialIdentity?.isNotEmpty == true;
    final sections = playerProfileSectionsFor(isMemorial: isMemorial);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          current: currentTab,
          onSelect: onSelectTab,
          gameCount: filteredGameCount,
          gameCountLoading: isGameCountLoading,
          hasActiveFilter: hasActiveFilter,
          sections: sections,
        ),
        _IndicatorBar(
          hasActiveFilter: hasActiveFilter,
          isLoading: isTwicLoading,
        ),
        Expanded(
          child: PersistentIndexedStack(
            index: sections.indexOf(currentTab),
            sizing: StackFit.expand,
            children: [
              if (isMemorial)
                MemorialPlayerAboutView(
                  sourceIdentity: memorialIdentity!,
                  playerName: playerName,
                )
              else
                _AboutBody(
                  activeKey: activeKey,
                  fideId: fideId,
                  playerName: playerName,
                  ratings: ratings,
                  currentTimeControl: currentTimeControl,
                  onSelectTimeControl: onSelectTimeControl,
                  onShowEvents: () => onSelectTab(PlayerProfileSection.events),
                ),
              _GamesBody(
                tabId: tabId,
                activeKey: activeKey,
                playerName: playerName,
                dataSource: dataSource,
                isActive: currentTab == PlayerProfileSection.games,
              ),
              if (!isMemorial)
                _EventsBody(
                  activeKey: activeKey,
                  fideId: fideId,
                  dataSource: dataSource,
                  isActive: currentTab == PlayerProfileSection.events,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.current,
    required this.onSelect,
    required this.gameCount,
    required this.gameCountLoading,
    required this.hasActiveFilter,
    required this.sections,
  });
  final PlayerProfileSection current;
  final ValueChanged<PlayerProfileSection> onSelect;
  final int gameCount;
  final bool gameCountLoading;
  final bool hasActiveFilter;
  final List<PlayerProfileSection> sections;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final t in sections)
            _TabUnderlineItem(
              label: t.label,
              badge:
                  t == PlayerProfileSection.games
                      ? (gameCountLoading ? '…' : formatCompactCount(gameCount))
                      : null,
              emphasizeBadge:
                  t == PlayerProfileSection.games && hasActiveFilter,
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
    this.badge,
    this.emphasizeBadge = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final bool emphasizeBadge;

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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 0.1,
                    ),
                  ),
                  if (widget.badge != null) ...[
                    const SizedBox(width: 7),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      constraints: const BoxConstraints(minWidth: 24),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color:
                            widget.emphasizeBadge
                                ? kPrimaryColor.withValues(alpha: 0.14)
                                : kWhiteColor.withValues(alpha: 0.055),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color:
                              widget.emphasizeBadge
                                  ? kPrimaryColor.withValues(alpha: 0.32)
                                  : kDividerColor,
                        ),
                      ),
                      child: Text(
                        widget.badge!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color:
                              widget.emphasizeBadge
                                  ? kPrimaryColor
                                  : kWhiteColor70,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
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
    required this.ratings,
    required this.currentTimeControl,
    required this.onSelectTimeControl,
    required this.onShowEvents,
  });

  final PlayerProfileKey activeKey;
  final int? fideId;
  final String playerName;
  final _ProfileRatings ratings;
  final GameTimeControlFilter currentTimeControl;
  final ValueChanged<GameTimeControlFilter> onSelectTimeControl;
  final VoidCallback onShowEvents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerProfileGamesKeyProvider(activeKey));
    final isTwic = activeKey.source == PlayerProfileDataSource.twic;
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
    final eventsAsync = ref.watch(playerEventsKeyProvider(activeKey));
    final historyAsync =
        fideId != null && fideId! > 0
            ? ref.watch(fideRatingHistoryProvider(fideId!))
            : null;

    Widget details;
    if (analytics != null) {
      details = _OverviewDashboard(
        analytics: analytics,
        ratingHistory: historyAsync?.valueOrNull,
        ratingHistoryLoading: historyAsync?.isLoading ?? false,
        currentTimeControl: currentTimeControl,
        selectedResult: state.playerResultFilter,
        selectedColor: state.filter.color,
        selectedEco: state.filter.eco,
        recentEvents: eventsAsync.valueOrNull ?? const [],
        eventsLoading: eventsAsync.isLoading,
        onSelectResult: (filter) {
          final next =
              state.playerResultFilter == filter
                  ? PlayerResultFilter.all
                  : filter;
          ref
              .read(playerProfileGamesKeyProvider(activeKey).notifier)
              .mergeFilter(playerResultFilter: next);
        },
        onSelectColor: (color) {
          final next =
              state.filter.color == color ? GameColorFilter.all : color;
          ref
              .read(playerProfileGamesKeyProvider(activeKey).notifier)
              .mergeFilter(
                color: next,
                eco: next == GameColorFilter.all ? null : GameEcoFilter.all,
              );
        },
        onSelectEco: (eco) {
          final current = state.filter.eco.code?.toUpperCase();
          final next =
              current == eco.toUpperCase()
                  ? GameEcoFilter.all
                  : GameEcoFilter.forCode(eco);
          ref
              .read(playerProfileGamesKeyProvider(activeKey).notifier)
              .mergeFilter(eco: next);
        },
        onShowEvents: onShowEvents,
      );
    } else if (analyticsAsync.hasError ||
        (state.error != null && state.allGames.isEmpty)) {
      details = _OverviewStatusPanel(
        message:
            analyticsAsync.hasError
                ? analyticsAsync.error.toString()
                : state.error!,
        isError: true,
      );
    } else if (analyticsAsync.isLoading || state.isLoading) {
      details = const _OverviewStatusPanel(
        message: 'Loading player statistics…',
        isLoading: true,
      );
    } else {
      details = const _OverviewStatusPanel(
        message: 'No completed games are available for this overview yet.',
      );
    }

    return SingleChildScrollView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RatingOverviewRow(
            ratings: ratings,
            history: historyAsync?.valueOrNull,
            historyLoading: historyAsync?.isLoading ?? false,
            selected: currentTimeControl,
            onSelect: onSelectTimeControl,
          ),
          const SizedBox(height: 14),
          details,
        ],
      ),
    );
  }
}

class _OverviewStatusPanel extends StatelessWidget {
  const _OverviewStatusPanel({
    required this.message,
    this.isError = false,
    this.isLoading = false,
  });

  final String message;
  final bool isError;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 112,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError ? kRedColor.withValues(alpha: 0.42) : kDividerColor,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isError)
            const Icon(Icons.error_outline_rounded, size: 17, color: kRedColor)
          else if (isLoading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            )
          else
            const Icon(
              Icons.info_outline_rounded,
              size: 17,
              color: kLightGreyColor,
            ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isError ? kRedColor : kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewDashboard extends StatelessWidget {
  const _OverviewDashboard({
    required this.analytics,
    required this.ratingHistory,
    required this.ratingHistoryLoading,
    required this.currentTimeControl,
    required this.selectedResult,
    required this.selectedColor,
    required this.selectedEco,
    required this.recentEvents,
    required this.eventsLoading,
    required this.onSelectResult,
    required this.onSelectColor,
    required this.onSelectEco,
    required this.onShowEvents,
  });

  final PlayerAnalytics analytics;
  final FideRatingHistory? ratingHistory;
  final bool ratingHistoryLoading;
  final GameTimeControlFilter currentTimeControl;
  final PlayerResultFilter selectedResult;
  final GameColorFilter selectedColor;
  final GameEcoFilter selectedEco;
  final List<PlayerEventData> recentEvents;
  final bool eventsLoading;
  final ValueChanged<PlayerResultFilter> onSelectResult;
  final ValueChanged<GameColorFilter> onSelectColor;
  final ValueChanged<String> onSelectEco;
  final VoidCallback onShowEvents;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1040;
        final performance = DesktopPlayerProfileResultSummary(
          stats: analytics.resultStats,
          title: 'Overall performance',
          embedded: true,
          selected: selectedResult,
          avgOpponentRating: analytics.avgOpponentRating,
          recentForm: analytics.recentForm,
          onSelect: onSelectResult,
        );
        final colors = _ColorStatsRow(
          stats: analytics.colorStats,
          selected: selectedColor,
          onSelect: onSelectColor,
        );
        final chart = _RatingHistoryPanel(
          history: ratingHistory,
          loading: ratingHistoryLoading,
          initialTimeControl: currentTimeControl,
        );
        final performanceColumn = Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              performance,
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1, color: kDividerColor),
              ),
              const _SectionTitle(title: 'Performance by color'),
              const SizedBox(height: 8),
              colors,
            ],
          ),
        );
        final top =
            wide
                ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 62, child: chart),
                    const SizedBox(width: 12),
                    Expanded(flex: 38, child: performanceColumn),
                  ],
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chart,
                    const SizedBox(height: 12),
                    performanceColumn,
                  ],
                );

        final openings = _OpeningTable(
          stats: analytics.openingStats,
          selected: selectedEco,
          onSelect: onSelectEco,
        );
        final recentEventsPanel = _RecentEventsPanel(
          events: recentEvents,
          loading: eventsLoading,
          onShowAll: onShowEvents,
        );
        final lower =
            wide
                ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: openings),
                    const SizedBox(width: 12),
                    Expanded(flex: 4, child: recentEventsPanel),
                  ],
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    openings,
                    const SizedBox(height: 12),
                    recentEventsPanel,
                  ],
                );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [top, const SizedBox(height: 12), lower],
        );
      },
    );
  }
}

class _RecentEventsPanel extends StatelessWidget {
  const _RecentEventsPanel({
    required this.events,
    required this.loading,
    required this.onShowAll,
  });

  final List<PlayerEventData> events;
  final bool loading;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final visible = events.take(4).toList(growable: false);
    return _OverviewPanel(
      title: 'Recent tournaments',
      actionLabel: events.isEmpty ? null : 'View all',
      onAction: events.isEmpty ? null : onShowAll,
      child:
          loading && visible.isEmpty
              ? const _CompactLoadingRow(label: 'Loading tournaments…')
              : visible.isEmpty
              ? const _CompactEmptyRow(label: 'No tournaments on file yet.')
              : Column(
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const SizedBox(height: 5),
                    _RecentEventRow(event: visible[i], onTap: onShowAll),
                  ],
                ],
              ),
    );
  }
}

class _RecentEventRow extends StatefulWidget {
  const _RecentEventRow({required this.event, required this.onTap});

  final PlayerEventData event;
  final VoidCallback onTap;

  @override
  State<_RecentEventRow> createState() => _RecentEventRowState();
}

class _RecentEventRowState extends State<_RecentEventRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final games = widget.event.gamesPlayed;
    final score = widget.event.score;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 9),
            decoration: BoxDecoration(
              color: kBlack3Color.withValues(alpha: _hover ? 0.78 : 0.42),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    _hover
                        ? kPrimaryColor.withValues(alpha: 0.24)
                        : kDividerColor.withValues(alpha: 0.58),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.event.tourName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _formatProfileEventDates(
                          widget.event.startDate,
                          widget.event.endDate,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: kWhiteColor.withValues(alpha: 0.055),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    score == null
                        ? '$games games'
                        : '${_fmtScoreValue(score)}/$games',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
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

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({
    required this.title,
    required this.child,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _SectionTitle(title: title)),
              if (actionLabel != null && onAction != null)
                ClickCursor(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onAction,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 3,
                      ),
                      child: Text(
                        actionLabel!,
                        style: const TextStyle(
                          color: kPrimaryColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          child,
        ],
      ),
    );
  }
}

class _CompactLoadingRow extends StatelessWidget {
  const _CompactLoadingRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(color: kLightGreyColor, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

class _CompactEmptyRow extends StatelessWidget {
  const _CompactEmptyRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(color: kLightGreyColor, fontSize: 10.5),
      ),
    );
  }
}

String _fmtScoreValue(double score) {
  return score == score.roundToDouble()
      ? score.toInt().toString()
      : score.toStringAsFixed(1);
}

String _formatProfileEventDates(DateTime? start, DateTime? end) {
  if (start == null && end == null) return 'Date unavailable';
  final first = start ?? end!;
  final last = end ?? start!;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (first.year == last.year && first.month == last.month) {
    if (first.day == last.day) {
      return '${months[first.month - 1]} ${first.day}, ${first.year}';
    }
    return '${months[first.month - 1]} ${first.day}–${last.day}, ${first.year}';
  }
  return '${months[first.month - 1]} ${first.day}, ${first.year} – '
      '${months[last.month - 1]} ${last.day}, ${last.year}';
}

/// The first section of the desktop player-profile About tab.
///
/// Result filters deliberately stay in one horizontal row at every desktop
/// width. This makes the W/D/L comparison scannable and avoids the previous
/// triangular wrapping pattern in narrower profile panes.
class DesktopPlayerProfileResultSummary extends StatelessWidget {
  const DesktopPlayerProfileResultSummary({
    super.key,
    required this.stats,
    required this.selected,
    required this.onSelect,
    this.title = 'Results',
    this.embedded = false,
    this.avgOpponentRating,
    this.recentForm = const [],
  });
  final ResultStatistics stats;
  final PlayerResultFilter selected;
  final ValueChanged<PlayerResultFilter> onSelect;
  final String title;
  final bool embedded;
  final int? avgOpponentRating;
  final List<double> recentForm;

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
        color: kPrimaryColor,
        pct: winPct,
        selected: selected == PlayerResultFilter.win,
        onTap: () => onSelect(PlayerResultFilter.win),
      ),
      _ResultPill(
        label: 'Draw',
        value: stats.draws,
        color: const Color(0xFF8B93A7),
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

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: title, subtitle: '$total completed games'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: pills[0]),
            const SizedBox(width: 8),
            Expanded(child: pills[1]),
            const SizedBox(width: 8),
            Expanded(child: pills[2]),
          ],
        ),
        const SizedBox(height: 12),
        _ProfileResultDistribution(stats: stats),
        const SizedBox(height: 10),
        Row(
          children: [
            _MicroStat(label: 'Total games', value: '$total'),
            const SizedBox(width: 14),
            if ((avgOpponentRating ?? 0) > 0)
              _MicroStat(label: 'Avg opponent', value: '$avgOpponentRating'),
            const Spacer(),
            if (recentForm.isNotEmpty)
              _RecentFormStrip(form: recentForm.take(10).toList()),
          ],
        ),
      ],
    );
    if (embedded) return content;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: content,
    );
  }
}

class _ProfileResultDistribution extends StatelessWidget {
  const _ProfileResultDistribution({required this.stats});

  final ResultStatistics stats;

  @override
  Widget build(BuildContext context) {
    if (stats.totalGames <= 0) {
      return Container(
        height: 7,
        decoration: BoxDecoration(
          color: kDividerColor,
          borderRadius: BorderRadius.circular(999),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 7,
        child: Row(
          children: [
            if (stats.wins > 0)
              Expanded(
                flex: stats.wins,
                child: const ColoredBox(color: kPrimaryColor),
              ),
            if (stats.draws > 0)
              Expanded(
                flex: stats.draws,
                child: const ColoredBox(color: Color(0xFF6D7487)),
              ),
            if (stats.losses > 0)
              Expanded(
                flex: stats.losses,
                child: const ColoredBox(color: kRedColor),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecentFormStrip extends StatelessWidget {
  const _RecentFormStrip({required this.form});

  final List<double> form;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'FORM',
          style: TextStyle(
            color: kLightGreyColor,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.55,
          ),
        ),
        const SizedBox(width: 7),
        for (final result in form) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color:
                  result >= 0.75
                      ? kPrimaryColor
                      : (result <= 0.25 ? kRedColor : const Color(0xFF747B8D)),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
        ],
      ],
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
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: selected ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: color.withValues(alpha: selected ? 0.72 : 0.4),
              ),
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(pct * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: color,
                        fontSize: 16,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$value',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
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
                      : kBlack3Color.withValues(alpha: 0.72),
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
                    _MicroStat(
                      label: 'W',
                      value: '$wins',
                      color: kPrimaryColor,
                    ),
                    _MicroStat(
                      label: 'D',
                      value: '$draws',
                      color: const Color(0xFF8B93A7),
                    ),
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
    final groups = playerProfileOpeningResultGroups(stats);
    if (groups.best.isEmpty && groups.worst.isEmpty) {
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
          const _SectionTitle(
            title: 'Opening results',
            subtitle:
                'Frequently played openings ranked relative to this player',
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final best = _OpeningResultGroup(
                title: 'Best results',
                color: kGreenColor,
                stats: groups.best,
                selected: selected,
                onSelect: onSelect,
              );
              final worst = _OpeningResultGroup(
                title: 'Lowest scores',
                color: kRedColor,
                stats: groups.worst,
                selected: selected,
                onSelect: onSelect,
              );
              if (constraints.maxWidth < 720 || groups.worst.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    best,
                    if (groups.worst.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      worst,
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: best),
                  const SizedBox(width: 14),
                  Expanded(child: worst),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
({List<OpeningStatistic> best, List<OpeningStatistic> worst})
playerProfileOpeningResultGroups(
  Iterable<OpeningStatistic> stats, {
  int limit = 4,
}) {
  final known = stats.where(shouldShowPlayerProfileOpening).toList();
  if (known.isEmpty || limit <= 0) return (best: const [], worst: const []);

  final maxCount = known
      .map((stat) => stat.count)
      .reduce((a, b) => a > b ? a : b);
  final proportionalFloor = (maxCount / 10).ceil();
  final sampleFloor = proportionalFloor < 3 ? 3 : proportionalFloor;
  var eligible = known.where((stat) => stat.count >= sampleFloor).toList();
  if (eligible.length < 2) eligible = known;
  eligible.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : b.count.compareTo(a.count);
  });

  final perSide = eligible.length >= limit * 2 ? limit : (eligible.length ~/ 2);
  if (perSide == 0) {
    return (best: [eligible.first], worst: const []);
  }
  return (
    best: eligible.take(perSide).toList(growable: false),
    worst: eligible.reversed.take(perSide).toList(growable: false),
  );
}

@visibleForTesting
bool shouldShowPlayerProfileOpening(OpeningStatistic stat) {
  final eco = stat.eco.trim().toLowerCase();
  final opening = stat.openingName?.trim().toLowerCase() ?? '';
  return eco.isNotEmpty &&
      eco != 'unknown' &&
      !eco.startsWith('unknown') &&
      opening.isNotEmpty &&
      opening != 'unknown' &&
      !opening.startsWith('unknown');
}

class _OpeningResultGroup extends StatelessWidget {
  const _OpeningResultGroup({
    required this.title,
    required this.color,
    required this.stats,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final Color color;
  final List<OpeningStatistic> stats;
  final GameEcoFilter selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 1, 4, 7),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          for (final stat in stats)
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
                  SizedBox(width: 72, child: _OpeningResultBar(stat: stat)),
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

class _OpeningResultBar extends StatelessWidget {
  const _OpeningResultBar({required this.stat});

  final OpeningStatistic stat;

  @override
  Widget build(BuildContext context) {
    if (stat.count <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            if (stat.wins > 0)
              Expanded(
                flex: stat.wins,
                child: const ColoredBox(color: kPrimaryColor),
              ),
            if (stat.draws > 0)
              Expanded(
                flex: stat.draws,
                child: const ColoredBox(color: Color(0xFF6D7487)),
              ),
            if (stat.losses > 0)
              Expanded(
                flex: stat.losses,
                child: const ColoredBox(color: kRedColor),
              ),
          ],
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
    required this.tabId,
    required this.activeKey,
    required this.playerName,
    required this.dataSource,
    required this.isActive,
  });

  final String tabId;
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
        const DesktopContextMenuItem(
          value: _RowAction.openNewWindow,
          icon: Icons.open_in_browser_rounded,
          label: 'Open in new window',
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
      case _RowAction.openNewWindow:
        await openBoardGameWindow(
          ref,
          buildTournamentBoardTabArgs(
            game,
            '',
            routeTitle: routeTitle,
            routeGames: routeGames,
            routeGamesContinuation: routeGamesContinuation,
            viewSource: ChessboardView.playerProfile,
          ),
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
                  if (_showDatabaseTable) return;
                  setState(() => _showDatabaseTable = true);
                },
              ),
              const SizedBox(width: 8),
              GameViewModeToggle(
                showSelectedState: !_showDatabaseTable,
                onSelected: (_) {
                  if (!_showDatabaseTable) return;
                  setState(() => _showDatabaseTable = false);
                },
              ),
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
      tabId: widget.tabId,
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
  late final FocusNode _startFocusNode;
  late final FocusNode _endFocusNode;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: widget.start.toString());
    _endController = TextEditingController(text: widget.end.toString());
    _startFocusNode = FocusNode();
    _endFocusNode = FocusNode();
    _startFocusNode.addListener(_handleStartFocusChanged);
    _endFocusNode.addListener(_handleEndFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _NumberRangeFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(_startController, widget.start, _startFocusNode);
    _syncController(_endController, widget.end, _endFocusNode);
  }

  void _syncController(
    TextEditingController controller,
    int value,
    FocusNode focusNode,
  ) {
    if (focusNode.hasFocus) return;
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
    _startFocusNode.removeListener(_handleStartFocusChanged);
    _endFocusNode.removeListener(_handleEndFocusChanged);
    _startFocusNode.dispose();
    _endFocusNode.dispose();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  void _handleStartFocusChanged() {
    if (!_startFocusNode.hasFocus) _commit();
  }

  void _handleEndFocusChanged() {
    if (!_endFocusNode.hasFocus) _commit();
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
    _startController.text = start.toString();
    _endController.text = end.toString();
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
                focusNode: _startFocusNode,
                hint: widget.startHint,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmit: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FTextField(
                controller: _endController,
                focusNode: _endFocusNode,
                hint: widget.endHint,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmit: (_) => _commit(),
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
              ? 'Database table view is active'
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
      hiddenColumnIds: const {'round', 'site'},
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
    required this.tabId,
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

  final String tabId;
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
  static const Duration _scrollIdleDelay = Duration(milliseconds: 180);

  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'PlayerProfileEventGameCards',
  );
  final Map<int, GlobalKey> _sectionKeys = <int, GlobalKey>{};
  final Map<String, GlobalKey> _gameKeys = <String, GlobalKey>{};
  Timer? _scrollIdleTimer;
  EventGameCardFocus? _focus;
  bool _liveCardsPausedForScroll = false;

  // Captured once (see TournamentGamesView): freeze the pause reason so a
  // changing widget.tabId can't strand a stale reason in the global pause set.
  late final String _liveCardsPauseReason =
      'desktop_player_profile_scroll_${widget.tabId}';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _GroupedGamesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
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
    widget.controller.removeListener(_onScroll);
    _scrollIdleTimer?.cancel();
    _setLiveCardsPausedForScroll(false);
    _focusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    _markLiveCardsScrolling();
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
    final streamingEnabled =
        widget.enabled &&
        ref.watch(
          desktopTabsProvider.select((state) => state.activeId == widget.tabId),
        );
    final cardStreamingEnabled = streamingEnabled;
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
                  streamingEnabled: cardStreamingEnabled,
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
    required this.streamingEnabled,
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
  final bool streamingEnabled;

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
                streamingEnabled: streamingEnabled,
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
    required this.streamingEnabled,
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
  final bool streamingEnabled;

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
                streamingEnabled: streamingEnabled,
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
                (context, scale, child) => Transform.scale(
                  scale: scale,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
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
  openNewWindow,
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
                (context, scale, child) => Transform.scale(
                  scale: scale,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
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
