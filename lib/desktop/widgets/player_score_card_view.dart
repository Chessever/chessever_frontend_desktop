import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/player_score_card_board_context.dart';
import 'package:chessever/desktop/utils/list_keyboard_nav.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/panes/player_score_card_pane.dart'
    show synthesizePlayerStandingModel;
import 'package:chessever/desktop/services/tournament_pgn_loader.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/providers/player_ratings_provider.dart'
    show AllRatingsRequest, AllRatingsResult, allRatingsProvider;
import 'package:chessever/screens/standings/providers/player_utils_provider.dart';
import 'package:chessever/screens/standings/providers/twic_scorecard_event_games_provider.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardHasEventContextProvider,
        scoreCardPlayerProfileDataSourceProvider,
        selectedPlayerProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/favorite_limit_guard.dart';
import 'package:chessever/utils/location_service_provider.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

/// Desktop-native score card view.
///
/// Replaces the mobile `ScoreCardScreen` with a Chrome-tab-shaped layout:
///
/// ```text
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ Header  flag · TITLE · Name              [☆]  [Open profile ›]   │
/// ├───────────────────────┬──────────────────────────────────────────┤
/// │  Avatar               │  Round · Opponent · Result · Δ           │
/// │  ─────────            │  …                                       │
/// │  Cls / Rapid / Blitz  │  scrollable games list                   │
/// │  Performance card     │                                          │
/// │  Open Profile button  │                                          │
/// └───────────────────────┴──────────────────────────────────────────┘
/// ```
///
/// Mouse semantics on the games list mirror `desktop_tab_bar`:
/// - Left click: open the game in the active tab (Chrome-style "follow link")
/// - Middle click: open in a background board tab
/// - Right click: context menu (Open / Open in background / Profile / Copy id)
/// - Wheel: native vertical scroll
///
/// Keyboard (focus on the list):
/// - Arrow Up/Down: move selection
/// - Home / End: jump to first / last
/// - Enter / Space: open the selected game
class PlayerScoreCardView extends ConsumerStatefulWidget {
  const PlayerScoreCardView({super.key, required this.player, this.tabContext});

  final PlayerStandingModel player;
  final PlayerScoreCardTabContext? tabContext;

  @override
  ConsumerState<PlayerScoreCardView> createState() =>
      _PlayerScoreCardViewState();
}

class _PlayerScoreCardViewState extends ConsumerState<PlayerScoreCardView>
    with SingleTickerProviderStateMixin {
  final ScrollController _listController = ScrollController();
  final FocusNode _listFocus = FocusNode(debugLabel: 'scorecard-games');
  late final FPopoverController _switcherController = FPopoverController(
    vsync: this,
  );
  int _selectedIndex = -1;

  @override
  void dispose() {
    _listController.dispose();
    _listFocus.dispose();
    _switcherController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Elo math (preserved verbatim from the mobile screen — see
  // lib/screens/standings/score_card_screen.dart for original docs).
  // ---------------------------------------------------------------------

  double? _extractRatingFromPGN(String? pgn, bool isWhite) {
    if (pgn == null || pgn.isEmpty) return null;
    final patterns =
        isWhite
            ? [
              RegExp(r'\[WhiteElo "(\d+(?:\.\d+)?)"\]'),
              RegExp(r'\[WhiteElo (\d+(?:\.\d+)?)\]'),
              RegExp(r'WhiteElo\s+(\d+(?:\.\d+)?)'),
            ]
            : [
              RegExp(r'\[BlackElo "(\d+(?:\.\d+)?)"\]'),
              RegExp(r'\[BlackElo (\d+(?:\.\d+)?)\]'),
              RegExp(r'BlackElo\s+(\d+(?:\.\d+)?)'),
            ];
    for (final p in patterns) {
      final m = p.firstMatch(pgn);
      if (m != null && m.group(1) != null) {
        final r = double.tryParse(m.group(1)!);
        if (r != null && r > 0) return r;
      }
    }
    return null;
  }

  double _ratingForSide(GamesTourModel game, bool isWhite) {
    final card = isWhite ? game.whitePlayer : game.blackPlayer;
    if (card.rating > 0) return card.rating.toDouble();
    final pgn = _extractRatingFromPGN(game.pgn, isWhite);
    if (pgn != null && pgn > 0) return pgn;
    return 1500.0;
  }

  // FIDE per-time-control K. Falls back to a sane heuristic when chess_players
  // doesn't carry an authoritative K for the event's time control.
  int _heuristicK(double rating, {String? title, String? timeControl}) {
    final tc = timeControl?.toLowerCase();
    if (tc == 'rapid' || tc == 'blitz') return 20;
    if (rating >= 2400) return 10;
    if (title != null) {
      final t = title.toUpperCase();
      if (t == 'GM' || t == 'IM') return 10;
    }
    return 20;
  }

  double _eloChange(
    double playerRating,
    double opponentRating,
    GameStatus status,
    bool isWhite,
    GamesTourModel game, {
    int? fideK,
    double? playerRatingOverride,
  }) {
    double actual;
    switch (status) {
      case GameStatus.whiteWins:
        actual = isWhite ? 1.0 : 0.0;
        break;
      case GameStatus.blackWins:
        actual = isWhite ? 0.0 : 1.0;
        break;
      case GameStatus.draw:
        actual = 0.5;
        break;
      default:
        return 0;
    }
    final effective = playerRatingOverride ?? playerRating;
    final diff = (opponentRating - effective).clamp(-400.0, 400.0);
    final expected = 1 / (1 + math.pow(10, diff / 400.0));
    final title = isWhite ? game.whitePlayer.title : game.blackPlayer.title;
    final k =
        fideK ??
        _heuristicK(effective, title: title, timeControl: game.timeControl);
    return k * (actual - expected);
  }

  String _resultGlyph(GamesTourModel game, bool isWhite) {
    switch (game.gameStatus) {
      case GameStatus.whiteWins:
        return isWhite ? '1' : '0';
      case GameStatus.blackWins:
        return isWhite ? '0' : '1';
      case GameStatus.draw:
        return '½';
      case GameStatus.ongoing:
        return '–';
      case GameStatus.unknown:
        return '-';
    }
  }

  int? _extractRound(String? source) {
    if (source == null || source.isEmpty) return null;
    const pats = [
      r'round[-\s]?(\d+)',
      r'rapid[-\s]?(\d+)',
      r'blitz[-\s]?(\d+)',
      r'^(\d+)$',
      r'r(\d+)',
      r'game[-\s]?(\d+)',
      r'tiebreak[-\s]?(\d+)',
      r'losers[-\s]?r?(\d+)',
    ];
    for (final pat in pats) {
      final m = RegExp(pat, caseSensitive: false).firstMatch(source);
      if (m != null && m.groupCount >= 1) {
        final n = m.group(1);
        if (n != null && n.isNotEmpty) return int.tryParse(n);
      }
    }
    return null;
  }

  String? _roundLabel(GamesTourModel game) {
    final r = _extractRound(game.roundSlug) ?? _extractRound(game.roundId);
    return r == null ? null : '$r';
  }

  // ---------------------------------------------------------------------
  // Open / activate flows.
  // ---------------------------------------------------------------------

  Future<void> _openGameTab(
    GamesTourModel game,
    String tournamentTitle, {
    bool background = false,
    List<GamesTourModel> eventGames = const <GamesTourModel>[],
  }) async {
    String? pgn = game.pgn;
    if (pgn == null || pgn.trim().isEmpty) {
      try {
        pgn = await TournamentPgnLoader(ref).fetchPgnOnly(game.gameId);
      } catch (_) {
        pgn = null;
      }
    }
    final args = BoardTabGameArgs(
      gameId: game.gameId,
      pgn: pgn ?? '',
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
      sourceGame: game.copyWith(pgn: pgn),
      viewSource: ref.read(chessboardViewFromProviderNew),
      tournamentTitle: tournamentTitle,
      eventGames: _summariesFromGames(
        eventGames.isEmpty ? <GamesTourModel>[game] : eventGames,
      ),
      gameListSelectedId: game.gameId,
    );
    // Set the chessboard view bucket so the underlying live-stream provider
    // resolves to the right context (favScorecard for For You-mode, otherwise
    // the regular tour context).
    ref.read(chessboardViewFromProviderNew.notifier).state =
        ref.read(selectedBroadcastModelProvider) == null
            ? ChessboardView.favScorecard
            : ChessboardView.tour;

    openBoardGameTab(
      ref,
      args,
      focus: !background,
      reuseExisting: false,
      replaceActive: !background,
    );
  }

  void _openOpponentScoreCard(GamesTourModel game, bool playerIsWhite) {
    final opponent = playerIsWhite ? game.blackPlayer : game.whitePlayer;
    if (opponent.name.trim().isEmpty) return;
    openPlayerScoreCard(
      ref,
      synthesizePlayerStandingModel(
        name: opponent.name,
        title: opponent.title,
        countryCode: opponent.federation,
        rating: opponent.rating,
        fideId: opponent.fideId,
      ),
    );
  }

  void _openProfile(PlayerStandingModel player) {
    final PlayerProfileDataSource source =
        widget.tabContext?.profileDataSource ??
        ref.read(scoreCardPlayerProfileDataSourceProvider) ??
        PlayerProfileDataSource.supabase;
    openPlayerProfile(
      ref,
      PlayerProfileArgs(
        playerName: player.name,
        fideId: player.fideId,
        title: player.title,
        federation: player.countryCode,
        rating: player.score.round(),
        dataSource: source,
        gamebasePlayerId: player.gamebasePlayerId,
      ),
    );
  }

  Future<void> _showRowContextMenu({
    required Offset globalPos,
    required GamesTourModel game,
    required bool playerIsWhite,
    required String tournamentTitle,
    required List<GamesTourModel> eventGames,
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
          value: _RowAction.openOpponent,
          icon: Icons.person_search_outlined,
          label: 'Open opponent score card',
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
          value: _RowAction.copyId,
          icon: Icons.tag_rounded,
          label: 'Copy game ID',
        ),
        const DesktopContextMenuItem(
          value: _RowAction.copyFen,
          icon: Icons.short_text_rounded,
          label: 'Copy current FEN',
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case _RowAction.open:
        await _openGameTab(game, tournamentTitle, eventGames: eventGames);
      case _RowAction.openOpponent:
        _openOpponentScoreCard(game, playerIsWhite);
      case _RowAction.saveToLibrary:
        await saveDesktopGameToLibrary(
          context: context,
          ref: ref,
          game: game,
          sourceLabel:
              tournamentTitle.trim().isEmpty
                  ? widget.player.name
                  : tournamentTitle,
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
      case _RowAction.copyId:
        await Clipboard.setData(ClipboardData(text: game.gameId));
      case _RowAction.copyFen:
        final fen = game.fen?.trim();
        if (fen != null && fen.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: fen));
        }
    }
  }

  Future<void> _toggleFavorite(PlayerStandingModel player) async {
    final allowed = await requireFullAuthGuard(context);
    if (!allowed) return;
    try {
      final hydrated = await ref.read(
        backfilledStandingPlayerProvider(player).future,
      );
      final favs = ref.read(favoritePlayersProviderNew);
      final hydratedFideId = hydrated.fideId?.toString();
      final hydratedName = hydrated.name.trim();
      final already = favs.maybeWhen(
        data:
            (players) => players.any(
              (p) =>
                  (hydratedFideId != null &&
                      hydratedFideId.isNotEmpty &&
                      p.fideId == hydratedFideId) ||
                  p.playerName.trim() == hydratedName,
            ),
        orElse: () => false,
      );
      if (!already) {
        if (!mounted) return;
        final canAdd = await canAddMoreFavorites(context, ref);
        if (!canAdd) return;
      }
      await ref
          .read(favoritePlayersProviderNew.notifier)
          .toggleFavorite(
            fideId: hydrated.fideId?.toString(),
            playerName: hydrated.name,
            countryCode: hydrated.countryCode,
            rating: hydrated.score,
            title: hydrated.title,
          );
    } on FavoriteLimitExceededException {
      // Desktop is premium-only — this branch should never trip in
      // production. Toast as a defensive fallback if it does.
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

  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final selected = widget.player;
    final hydratedAsync = ref.watch(backfilledStandingPlayerProvider(selected));
    final player = hydratedAsync.valueOrNull ?? selected;

    final ratingsAsync = ref.watch(
      allRatingsProvider(
        AllRatingsRequest(fideId: player.fideId, playerName: player.name),
      ),
    );

    final tabContext = widget.tabContext;
    final selectedBroadcast =
        tabContext == null
            ? ref.watch(selectedBroadcastModelProvider)
            : tabContext.selectedBroadcast;
    final hasEventContext =
        tabContext == null
            ? selectedBroadcast != null ||
                ref.watch(scoreCardHasEventContextProvider)
            : tabContext.hasEventContext;
    final gamesContext =
        tabContext == null
            ? ref.watch(scoreCardGamesContextProvider)
            : tabContext.gamesContext;
    final profileDataSource =
        tabContext == null
            ? ref.watch(scoreCardPlayerProfileDataSourceProvider)
            : tabContext.profileDataSource;

    final games = _resolveGames(
      ref: ref,
      player: player,
      hasEventContext: hasEventContext,
      gamesContext: gamesContext,
      profileDataSource: profileDataSource,
      selectedBroadcast: selectedBroadcast,
    );
    final boardContextTitle = _eventTitleFromGames(
      selectedBroadcast?.name ?? '',
      games.games,
    );

    final filtered = _filterAndSort(
      ref: ref,
      games: games.games,
      player: player,
      hasEventContext: hasEventContext,
    );
    final boardRailGames = selectPlayerScoreCardBoardRailGames(
      displayedGames: filtered,
      resolvedGames: games.games,
    );

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            player: player,
            hasTournamentContext: selectedBroadcast != null,
            switcherController: _switcherController,
            onOpenProfile: () => _openProfile(player),
            onToggleFavorite: () => _toggleFavorite(player),
          ),
          const Divider(height: 1, thickness: 1, color: kDividerColor),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LeftIdentityColumn(
                  player: player,
                  ratingsAsync: ratingsAsync,
                  hasEventContext: hasEventContext,
                  games: filtered,
                  ratings: ratingsAsync.valueOrNull,
                  onOpenProfile: () => _openProfile(player),
                  ratingForSide: _ratingForSide,
                  eloChange: _eloChange,
                ),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: kDividerColor,
                ),
                Expanded(
                  child: _GamesPanel(
                    player: player,
                    games: filtered,
                    isLoading: games.isLoading,
                    hasEventContext: hasEventContext,
                    listController: _listController,
                    listFocus: _listFocus,
                    selectedIndex: _selectedIndex,
                    onSelect: (i) => setState(() => _selectedIndex = i),
                    roundLabel: _roundLabel,
                    resultGlyph: _resultGlyph,
                    ratingForSide: _ratingForSide,
                    eloChange: _eloChange,
                    ratings: ratingsAsync.valueOrNull,
                    onOpen:
                        (g, isWhite) => _openGameTab(
                          g,
                          boardContextTitle,
                          eventGames: boardRailGames,
                        ),
                    onOpenBackground:
                        (g, isWhite) => _openGameTab(
                          g,
                          boardContextTitle,
                          background: true,
                          eventGames: boardRailGames,
                        ),
                    onContext:
                        (pos, g, isWhite) => _showRowContextMenu(
                          globalPos: pos,
                          game: g,
                          playerIsWhite: isWhite,
                          tournamentTitle: boardContextTitle,
                          eventGames: boardRailGames,
                        ),
                    onOpenOpponent: _openOpponentScoreCard,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Resolve which games provider to read for the active context. Mirrors
  // the priority chain the mobile screen uses.
  // ---------------------------------------------------------------------

  _ResolvedGames _resolveGames({
    required WidgetRef ref,
    required PlayerStandingModel player,
    required bool hasEventContext,
    required List<GamesTourModel>? gamesContext,
    required PlayerProfileDataSource profileDataSource,
    required Object? selectedBroadcast,
  }) {
    final contextTourId =
        (gamesContext != null && gamesContext.isNotEmpty)
            ? gamesContext.first.tourId.trim()
            : null;
    final hasExplicitEvent =
        hasEventContext && contextTourId != null && contextTourId.isNotEmpty;
    final gamebaseId = player.gamebasePlayerId?.trim();

    final shouldFetchTwic =
        hasExplicitEvent &&
        profileDataSource == PlayerProfileDataSource.twic &&
        gamebaseId != null &&
        gamebaseId.isNotEmpty;
    final shouldFetchEvent =
        hasExplicitEvent && profileDataSource != PlayerProfileDataSource.twic;

    if (hasEventContext && _hasMultipleTourIds(gamesContext)) {
      return _ResolvedGames(games: gamesContext!, isLoading: false);
    }

    if (shouldFetchTwic) {
      final req = TwicScorecardEventGamesRequest(
        playerId: gamebaseId,
        event: contextTourId,
      );
      final async = ref.watch(twicScorecardEventGamesProvider(req));
      return async.when(
        data:
            (g) => _ResolvedGames(
              games: g.isNotEmpty ? g : (gamesContext ?? const []),
              isLoading: false,
            ),
        loading:
            () => _ResolvedGames(
              games: gamesContext ?? const [],
              isLoading: true,
            ),
        error:
            (_, __) => _ResolvedGames(
              games: gamesContext ?? const [],
              isLoading: false,
            ),
      );
    }

    if (selectedBroadcast != null) {
      final merged = ref.watch(mergedTournamentGamesProvider);
      final tourAsync = ref.watch(gamesTourScreenProvider);
      return tourAsync.when(
        data: (_) => _ResolvedGames(games: merged, isLoading: false),
        loading: () => const _ResolvedGames(games: [], isLoading: true),
        error: (_, __) => const _ResolvedGames(games: [], isLoading: false),
      );
    }

    if (shouldFetchEvent) {
      final async = ref.watch(gamesTourProvider(contextTourId));
      return async.when(
        data: (rows) {
          final converted = <GamesTourModel>[];
          for (final g in rows) {
            try {
              converted.add(GamesTourModel.fromGame(g));
            } catch (_) {}
          }
          return _ResolvedGames(
            games:
                converted.isNotEmpty ? converted : (gamesContext ?? const []),
            isLoading: false,
          );
        },
        loading:
            () => _ResolvedGames(
              games: gamesContext ?? const [],
              isLoading: true,
            ),
        error:
            (_, __) => _ResolvedGames(
              games: gamesContext ?? const [],
              isLoading: false,
            ),
      );
    }

    if (gamesContext != null && gamesContext.isNotEmpty) {
      return _ResolvedGames(games: gamesContext, isLoading: false);
    }

    // No valid game source — score cards only show event-context games.
    return const _ResolvedGames(games: [], isLoading: false);
  }

  bool _hasMultipleTourIds(List<GamesTourModel>? games) {
    if (games == null || games.length <= 1) return false;
    final tourIds = <String>{};
    for (final game in games) {
      final tourId = game.tourId.trim();
      if (tourId.isEmpty) continue;
      tourIds.add(tourId);
      if (tourIds.length > 1) return true;
    }
    return false;
  }

  List<GamesTourModel> _filterAndSort({
    required WidgetRef ref,
    required List<GamesTourModel> games,
    required PlayerStandingModel player,
    required bool hasEventContext,
  }) {
    final utils = ref.read(playerUtilsProvider);
    final mine =
        games.where((g) {
          return utils.isSamePlayerWithFideId(
                g.whitePlayer.name,
                player.name,
                fideId1: g.whitePlayer.fideId,
                fideId2: player.fideId,
              ) ||
              utils.isSamePlayerWithFideId(
                g.blackPlayer.name,
                player.name,
                fideId1: g.blackPlayer.fideId,
                fideId2: player.fideId,
              );
        }).toList();

    // Deduplicate by gameId, keep richest opponent metadata.
    final byId = <String, GamesTourModel>{};
    for (final g in mine) {
      final existing = byId[g.gameId];
      if (existing == null) {
        byId[g.gameId] = g;
      } else {
        final isWhite = utils.isSamePlayerWithFideId(
          g.whitePlayer.name,
          player.name,
          fideId1: g.whitePlayer.fideId,
          fideId2: player.fideId,
        );
        final opp = isWhite ? g.blackPlayer : g.whitePlayer;
        final exIsWhite = utils.isSamePlayerWithFideId(
          existing.whitePlayer.name,
          player.name,
          fideId1: existing.whitePlayer.fideId,
          fideId2: player.fideId,
        );
        final exOpp = exIsWhite ? existing.blackPlayer : existing.whitePlayer;
        int score(p) {
          var s = 0;
          if (p.rating > 0) s += 2;
          if (p.countryCode.isNotEmpty) s += 1;
          if (p.title.isNotEmpty) s += 1;
          return s;
        }

        if (score(opp) > score(exOpp)) byId[g.gameId] = g;
      }
    }
    final result = byId.values.toList();

    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (hasEventContext) {
      result.sort((a, b) {
        final ar =
            _extractRound(a.roundSlug) ?? _extractRound(a.roundId) ?? 9999;
        final br =
            _extractRound(b.roundSlug) ?? _extractRound(b.roundId) ?? 9999;
        if (ar != br) return ar.compareTo(br);
        final ab = a.boardNr ?? 9999;
        final bb = b.boardNr ?? 9999;
        if (ab != bb) return ab.compareTo(bb);
        return (a.lastMoveTime ?? epoch).compareTo(b.lastMoveTime ?? epoch);
      });
    } else {
      result.sort(
        (a, b) => (b.lastMoveTime ?? epoch).compareTo(a.lastMoveTime ?? epoch),
      );
    }
    return result;
  }
}

List<TournamentGameSummary> _summariesFromGames(List<GamesTourModel> games) {
  final byId = <String, TournamentGameSummary>{};
  for (final game in games) {
    final id = game.gameId.trim();
    if (id.isEmpty) continue;
    byId[id] = TournamentGameSummary.fromGamesTourModel(game);
  }
  return byId.values.toList(growable: false);
}

String _eventTitleFromGames(String explicitTitle, List<GamesTourModel> games) {
  final explicit = explicitTitle.trim();
  if (explicit.isNotEmpty) return explicit;

  for (final game in games) {
    final slug = game.tourSlug?.trim() ?? '';
    if (slug.isNotEmpty) return slug;
  }
  return '';
}

class _ResolvedGames {
  const _ResolvedGames({required this.games, required this.isLoading});
  final List<GamesTourModel> games;
  final bool isLoading;
}

enum _RowAction {
  open,
  openOpponent,
  saveToLibrary,
  share,
  copyShareLink,
  copyId,
  copyFen,
}

// ---------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------

class _Header extends ConsumerWidget {
  const _Header({
    required this.player,
    required this.hasTournamentContext,
    required this.switcherController,
    required this.onOpenProfile,
    required this.onToggleFavorite,
  });

  final PlayerStandingModel player;
  final bool hasTournamentContext;
  final FPopoverController switcherController;
  final VoidCallback onOpenProfile;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.read(locationServiceProvider);
    final validCountry = loc.getValidCountryCode(player.countryCode);
    final favs = ref.watch(favoritePlayersProviderNew);
    final favoriteFideId = player.fideId?.toString();
    final favoritePlayerName = player.name.trim();
    final isFavorite = favs.maybeWhen(
      data:
          (players) => players.any(
            (p) =>
                (favoriteFideId != null &&
                    favoriteFideId.isNotEmpty &&
                    p.fideId == favoriteFideId) ||
                p.playerName.trim() == favoritePlayerName,
          ),
      orElse: () => false,
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
    );

    final flag =
        (player.countryCode.trim().isNotEmpty || validCountry.isNotEmpty)
            ? FederationFlag(
              federation:
                  player.countryCode.trim().isNotEmpty
                      ? player.countryCode
                      : validCountry,
              height: 16,
              width: 22,
              borderRadius: BorderRadius.circular(2),
            )
            : const SizedBox(width: 22, height: 16);

    final nameRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        flag,
        const SizedBox(width: 10),
        if ((player.title ?? '').isNotEmpty) ...[
          Text(
            player.title!,
            style: const TextStyle(
              color: kLightYellowColor,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(
            player.name,
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
        if (hasTournamentContext) ...[
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: kWhiteColor70),
        ],
      ],
    );

    final nameWidget =
        hasTournamentContext
            ? FTheme(
              data: FThemes.zinc.dark,
              child: FPopover(
                controller: switcherController,
                popoverBuilder:
                    (context, _) =>
                        _PlayerSwitcherPopover(controller: switcherController),
                child: ClickCursor(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: switcherController.toggle,
                    child: nameRow,
                  ),
                ),
              ),
            )
            : nameRow;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(color: kBackgroundColor),
      child: Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: nameWidget),
          ),
          DesktopFavoriteButton(
            selected: isFavorite,
            onPress: onToggleFavorite,
          ),
          const SizedBox(width: 8),
          DesktopHeaderActionButton(
            label: 'Open profile',
            icon: Icons.person_outline_rounded,
            onPress: onOpenProfile,
          ),
        ],
      ),
    );
  }
}

class _PlayerSwitcherPopover extends ConsumerWidget {
  const _PlayerSwitcherPopover({required this.controller});

  final FPopoverController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedPlayerProvider);
    final players = ref.watch(playerTourScreenProvider).valueOrNull ?? const [];
    if (players.isEmpty) {
      return const _PopoverShell(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No other players in this tournament.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
        ),
      );
    }
    return _PopoverShell(
      child: SizedBox(
        width: 320,
        height: math.min(420.0, players.length * 36.0 + 16),
        child: ListView.builder(
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: players.length,
          itemBuilder: (context, i) {
            final p = players[i];
            final active =
                selected?.name == p.name && selected?.fideId == p.fideId;
            return ClickCursor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  controller.hide();
                  // Re-open via the tab system so the active score-card tab
                  // re-points to the new player and per-tab args stay in sync.
                  openPlayerScoreCard(ref, p);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color:
                      active
                          ? kPrimaryColor.withValues(alpha: 0.12)
                          : Colors.transparent,
                  child: Row(
                    children: [
                      if (p.countryCode.trim().isNotEmpty)
                        FederationFlag(
                          federation: p.countryCode,
                          height: 12,
                          width: 18,
                          borderRadius: BorderRadius.circular(2),
                        )
                      else
                        const SizedBox(width: 18, height: 12),
                      const SizedBox(width: 10),
                      if ((p.title ?? '').isNotEmpty) ...[
                        Text(
                          p.title!,
                          style: const TextStyle(
                            color: kLightYellowColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: active ? kPrimaryColor : kWhiteColor,
                            fontSize: 12,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${p.score}',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 11,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PopoverShell extends StatelessWidget {
  const _PopoverShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------
// Left identity column
// ---------------------------------------------------------------------

class _LeftIdentityColumn extends StatelessWidget {
  const _LeftIdentityColumn({
    required this.player,
    required this.ratingsAsync,
    required this.hasEventContext,
    required this.games,
    required this.ratings,
    required this.onOpenProfile,
    required this.ratingForSide,
    required this.eloChange,
  });

  final PlayerStandingModel player;
  final AsyncValue<AllRatingsResult> ratingsAsync;
  final bool hasEventContext;
  final List<GamesTourModel> games;
  final AllRatingsResult? ratings;
  final VoidCallback onOpenProfile;
  final double Function(GamesTourModel game, bool isWhite) ratingForSide;
  final double Function(
    double playerRating,
    double opponentRating,
    GameStatus status,
    bool isWhite,
    GamesTourModel game, {
    int? fideK,
    double? playerRatingOverride,
  })
  eloChange;

  @override
  Widget build(BuildContext context) {
    final initials = _initialsFor(player.name);
    final perf =
        hasEventContext
            ? _computePerformance(
              games: games,
              player: player,
              ratings: ratings,
            )
            : null;
    return SizedBox(
      width: 360,
      child: SingleChildScrollView(
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: FutureBuilder<String?>(
                  future: FidePhotoService.getPhotoUrlOrNull(
                    player.fideId?.toString(),
                  ),
                  builder: (context, snap) {
                    return PlayerInitialsAvatar(
                      photoUrl: snap.data,
                      initials: initials,
                      size: 200,
                      borderRadius: 14,
                      title: player.title,
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _RatingTile(
                    label: 'Classical',
                    asset: PngAsset.classicalIcon,
                    value: ratings?.getRating('standard'),
                    loading: ratingsAsync.isLoading,
                    onTap: onOpenProfile,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _RatingTile(
                    label: 'Rapid',
                    asset: PngAsset.rapidIcon,
                    value: ratings?.getRating('rapid'),
                    loading: ratingsAsync.isLoading,
                    onTap: onOpenProfile,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _RatingTile(
                    label: 'Blitz',
                    asset: PngAsset.blitzIcon,
                    value: ratings?.getRating('blitz'),
                    loading: ratingsAsync.isLoading,
                    onTap: onOpenProfile,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _PerformanceCard(perf: perf, hasEventContext: hasEventContext),
            const SizedBox(height: 14),
            DesktopHeaderActionButton(
              label: 'Open player profile',
              icon: Icons.person_outline_rounded,
              onPress: onOpenProfile,
              tooltip: 'Open player profile',
              fillWidth: true,
            ),
            const SizedBox(height: 12),
            _ContextNote(hasEventContext: hasEventContext),
          ],
        ),
      ),
    );
  }

  // Performance / Score / Δ rating computation, mirrors mobile screen.
  _PerformanceData? _computePerformance({
    required List<GamesTourModel> games,
    required PlayerStandingModel player,
    required AllRatingsResult? ratings,
  }) {
    double totalOpp = 0.0;
    double playerScore = 0.0;
    int valid = 0;
    double totalDiff = 0.0;
    for (final g in games) {
      if (g.gameStatus == GameStatus.ongoing ||
          g.gameStatus == GameStatus.unknown) {
        continue;
      }
      // We compare on names — fideId-aware matching already happened upstream
      // when filtering this player's rows.
      final isWhite =
          g.whitePlayer.name == player.name ||
          g.whitePlayer.fideId == player.fideId;
      final oppRating = ratingForSide(g, !isWhite);
      if (oppRating <= 0) continue;
      totalOpp += oppRating;
      valid += 1;
      switch (g.gameStatus) {
        case GameStatus.whiteWins:
          playerScore += isWhite ? 1.0 : 0.0;
        case GameStatus.blackWins:
          playerScore += isWhite ? 0.0 : 1.0;
        case GameStatus.draw:
          playerScore += 0.5;
        default:
          break;
      }
      final pRating = ratingForSide(g, isWhite);
      if (pRating > 0) {
        final tc = g.timeControl;
        final fideK = tc != null ? ratings?.getK(tc) : null;
        final pOverride =
            tc != null ? ratings?.getRating(tc)?.toDouble() : null;
        totalDiff += eloChange(
          pRating,
          oppRating,
          g.gameStatus,
          isWhite,
          g,
          fideK: fideK,
          playerRatingOverride: pOverride,
        );
      }
    }
    if (valid == 0) return null;
    final avg = totalOpp / valid;
    final pct = playerScore / valid;
    final double dp =
        pct >= 1.0 ? 800.0 : (pct <= 0.0 ? -800.0 : 400.0 * (2 * pct - 1));
    return _PerformanceData(
      performance: (avg + dp).round(),
      score: playerScore,
      games: valid,
      ratingDiff:
          player.scoreChange != 0 ? player.scoreChange : totalDiff.round(),
    );
  }
}

class _PerformanceData {
  const _PerformanceData({
    required this.performance,
    required this.score,
    required this.games,
    required this.ratingDiff,
  });
  final int performance;
  final double score;
  final int games;
  final int ratingDiff;
}

String _initialsFor(String name) {
  final parts = name.split(',');
  if (parts.length > 1) {
    final a = parts[0].trim();
    final b = parts[1].trim();
    return '${a.isNotEmpty ? a[0] : ''}${b.isNotEmpty ? b[0] : ''}';
  }
  final t = name.trim();
  if (t.isEmpty) return '';
  return t.substring(0, math.min(2, t.length));
}

class _ContextNote extends StatelessWidget {
  const _ContextNote({required this.hasEventContext});
  final bool hasEventContext;

  @override
  Widget build(BuildContext context) {
    // Score cards are only shown with event context — remove misleading
    // fallback message.
    if (!hasEventContext) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 12,
            color: kLightGreyColor,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Showing games from this tournament.',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingTile extends StatefulWidget {
  const _RatingTile({
    required this.label,
    required this.asset,
    required this.value,
    required this.loading,
    required this.onTap,
  });

  final String label;
  final String asset;
  final int? value;
  final bool loading;
  final VoidCallback onTap;

  @override
  State<_RatingTile> createState() => _RatingTileState();
}

class _RatingTileState extends State<_RatingTile> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
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
            value: _pressed ? 0.97 : (_hover ? 1.015 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              height: 92,
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(widget.asset, width: 18, height: 18),
                  const SizedBox(height: 6),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.loading ? '–' : (widget.value?.toString() ?? '–'),
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
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

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.perf, required this.hasEventContext});

  final _PerformanceData? perf;
  final bool hasEventContext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _PerfStat(
            label: 'Performance',
            value: perf?.performance.toString() ?? '–',
            color: kWhiteColor,
          ),
          _PerfStat(
            label: 'Score',
            value:
                perf == null
                    ? '–'
                    : '${_fmtScore(perf!.score)} / ${perf!.games}',
            color: kWhiteColor,
          ),
          _PerfStat(
            label: 'Δ Rating',
            value:
                perf == null
                    ? '–'
                    : (perf!.ratingDiff >= 0
                        ? '+${perf!.ratingDiff}'
                        : '${perf!.ratingDiff}'),
            color:
                perf == null
                    ? kWhiteColor
                    : (perf!.ratingDiff >= 0 ? kGreenColor : kRedColor),
          ),
        ],
      ),
    );
  }

  String _fmtScore(double s) {
    if (s == s.truncate()) return s.truncate().toString();
    return s.toString();
  }
}

class _PerfStat extends StatelessWidget {
  const _PerfStat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Games panel (right column)
// ---------------------------------------------------------------------

class _GamesPanel extends ConsumerWidget {
  const _GamesPanel({
    required this.player,
    required this.games,
    required this.isLoading,
    required this.hasEventContext,
    required this.listController,
    required this.listFocus,
    required this.selectedIndex,
    required this.onSelect,
    required this.roundLabel,
    required this.resultGlyph,
    required this.ratingForSide,
    required this.eloChange,
    required this.ratings,
    required this.onOpen,
    required this.onOpenBackground,
    required this.onContext,
    required this.onOpenOpponent,
  });

  final PlayerStandingModel player;
  final List<GamesTourModel> games;
  final bool isLoading;
  final bool hasEventContext;
  final ScrollController listController;
  final FocusNode listFocus;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final String? Function(GamesTourModel game) roundLabel;
  final String Function(GamesTourModel game, bool isWhite) resultGlyph;
  final double Function(GamesTourModel game, bool isWhite) ratingForSide;
  final double Function(
    double playerRating,
    double opponentRating,
    GameStatus status,
    bool isWhite,
    GamesTourModel game, {
    int? fideK,
    double? playerRatingOverride,
  })
  eloChange;
  final AllRatingsResult? ratings;
  final void Function(GamesTourModel game, bool isWhite) onOpen;
  final void Function(GamesTourModel game, bool isWhite) onOpenBackground;
  final void Function(Offset pos, GamesTourModel game, bool isWhite) onContext;
  final void Function(GamesTourModel game, bool playerIsWhite) onOpenOpponent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GamesHeader(gameCount: games.length, isLoading: isLoading),
        const Divider(height: 1, thickness: 1, color: kDividerColor),
        Expanded(child: _buildBody(context, ref)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final utils = ref.read(playerUtilsProvider);
    if (isLoading && games.isEmpty) {
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
    if (games.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.menu_book_outlined,
                size: 32,
                color: kLightGreyColor,
              ),
              const SizedBox(height: 12),
              const Text(
                'No games in this tournament yet',
                style: TextStyle(color: kWhiteColor70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                'Games will appear here as the rounds are played.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kLightGreyColor, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    return Focus(
      focusNode: listFocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown) {
          final next = (selectedIndex + 1).clamp(0, games.length - 1);
          onSelect(next);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          final next = (selectedIndex - 1).clamp(0, games.length - 1);
          onSelect(next);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.pageDown) {
          final next = (selectedIndex + kDesktopListPageStep).clamp(
            0,
            games.length - 1,
          );
          onSelect(next);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.pageUp) {
          final next = (selectedIndex - kDesktopListPageStep).clamp(
            0,
            games.length - 1,
          );
          onSelect(next);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.home) {
          onSelect(0);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.end) {
          onSelect(games.length - 1);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          if (selectedIndex >= 0 && selectedIndex < games.length) {
            final g = games[selectedIndex];
            final isWhite = utils.isSamePlayerWithFideId(
              g.whitePlayer.name,
              player.name,
              fideId1: g.whitePlayer.fideId,
              fideId2: player.fideId,
            );
            onOpen(g, isWhite);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListView.builder(
        controller: listController,
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: games.length,
        itemBuilder: (context, index) {
          final g = games[index];
          final isWhite = utils.isSamePlayerWithFideId(
            g.whitePlayer.name,
            player.name,
            fideId1: g.whitePlayer.fideId,
            fideId2: player.fideId,
          );
          final pRating = ratingForSide(g, isWhite);
          final oRating = ratingForSide(g, !isWhite);
          double change = 0.0;
          if (pRating > 0 && oRating > 0) {
            final tc = g.timeControl;
            final fideK = tc != null ? ratings?.getK(tc) : null;
            final pOverride =
                tc != null ? ratings?.getRating(tc)?.toDouble() : null;
            change = eloChange(
              pRating,
              oRating,
              g.gameStatus,
              isWhite,
              g,
              fideK: fideK,
              playerRatingOverride: pOverride,
            );
          }
          return _GameRow(
            index: index,
            game: g,
            playerIsWhite: isWhite,
            playerName: player.name,
            roundLabel: hasEventContext ? roundLabel(g) : null,
            opponentRatingChange: change != 0.0 ? change : null,
            result: resultGlyph(g, isWhite),
            selected: index == selectedIndex,
            onTap: () {
              onSelect(index);
              onOpen(g, isWhite);
            },
            onMiddleClick: () => onOpenBackground(g, isWhite),
            onContext: (pos) => onContext(pos, g, isWhite),
            onOpenOpponent: () => onOpenOpponent(g, isWhite),
          );
        },
      ),
    );
  }
}

class _GamesHeader extends StatelessWidget {
  const _GamesHeader({required this.gameCount, required this.isLoading});

  final int gameCount;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: [
          const Text(
            'Tournament games',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kDividerColor),
            ),
            child: Text(
              '$gameCount',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const Spacer(),
          if (isLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
          if (isLoading) const SizedBox(width: 8),
          const Text(
            hasEventContextHint,
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

const String hasEventContextHint =
    'click · open  ·  middle-click · background  ·  right-click · menu';

class _GameRow extends StatefulWidget {
  const _GameRow({
    required this.index,
    required this.game,
    required this.playerIsWhite,
    required this.playerName,
    required this.roundLabel,
    required this.opponentRatingChange,
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onMiddleClick,
    required this.onContext,
    required this.onOpenOpponent,
  });

  final int index;
  final GamesTourModel game;
  final bool playerIsWhite;
  final String playerName;
  final String? roundLabel;
  final double? opponentRatingChange;
  final String result;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onMiddleClick;
  final ValueChanged<Offset> onContext;
  final VoidCallback onOpenOpponent;

  @override
  State<_GameRow> createState() => _GameRowState();
}

class _GameRowState extends State<_GameRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final opponent = widget.playerIsWhite ? game.blackPlayer : game.whitePlayer;
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.10)
            : (_hover ? kBlack3Color : Colors.transparent);

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            final btn = event.buttons;
            if (btn & kPrimaryMouseButton != 0) {
              if (isNewTabModifierPressed()) {
                widget.onMiddleClick();
              } else {
                widget.onTap();
              }
            } else if (btn & kTertiaryButton != 0) {
              widget.onMiddleClick();
            } else if (btn & kSecondaryMouseButton != 0) {
              widget.onContext(event.position);
            }
          },
          child: MotionCard(
            borderRadius: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                border: const Border(
                  bottom: BorderSide(color: kDividerColor, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 42,
                    child: Text(
                      widget.roundLabel ?? '${widget.index + 1}.',
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (opponent.federation.trim().isNotEmpty) ...[
                    FederationFlag(
                      federation: opponent.federation,
                      height: 12,
                      width: 18,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(width: 8),
                  ] else
                    const SizedBox(width: 26),
                  if (opponent.title.isNotEmpty) ...[
                    Text(
                      opponent.title,
                      style: const TextStyle(
                        color: kLightYellowColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Flexible(
                          child: ClickCursor(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onOpenOpponent,
                              child: Text(
                                opponent.name.isEmpty ? '—' : opponent.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 13,
                                  fontWeight:
                                      widget.selected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (opponent.rating > 0)
                          Text(
                            '${opponent.rating}',
                            style: const TextStyle(
                              color: kWhiteColor70,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          )
                        else
                          const Text(
                            '—',
                            style: TextStyle(
                              color: kLightGreyColor,
                              fontSize: 12,
                            ),
                          ),
                        if (widget.opponentRatingChange != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            widget.opponentRatingChange! > 0
                                ? '+${widget.opponentRatingChange!.toStringAsFixed(0)}'
                                : widget.opponentRatingChange!.toStringAsFixed(
                                  0,
                                ),
                            style: TextStyle(
                              color:
                                  widget.opponentRatingChange! > 0
                                      ? kGreenColor
                                      : kRedColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                        _ResultBadge(
                          result: widget.result,
                          playerIsWhite: widget.playerIsWhite,
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

class _ResultBadge extends StatelessWidget {
  const _ResultBadge({required this.result, required this.playerIsWhite});

  final String result;
  final bool playerIsWhite;

  @override
  Widget build(BuildContext context) {
    final fill = playerIsWhite ? Colors.white : Colors.black;
    final foreground = playerIsWhite ? Colors.black : Colors.white;
    final border =
        playerIsWhite
            ? kWhiteColor.withValues(alpha: 0.18)
            : kWhiteColor.withValues(alpha: 0.38);

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        result,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: foreground,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          height: 1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
