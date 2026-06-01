import 'dart:async';

import 'package:chessground/chessground.dart' as cg;
import 'package:country_flags/country_flags.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/current_user_profile.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_setup.dart';
import 'package:chessever/desktop/widgets/board_annotation_layer.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/move_navigation_bar.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/audio_player_service.dart';

/// Active play-vs-bot view: board centered, clocks on each side, move list +
/// game controls on the right. Reads [playSessionProviderFor] for the live
/// state of the owning tab — each Play tab carries its own session, so this
/// view is parameterised by [tabId].
class PlayActiveGameView extends ConsumerStatefulWidget {
  const PlayActiveGameView({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<PlayActiveGameView> createState() => _PlayActiveGameViewState();
}

class _PlayActiveGameViewState extends ConsumerState<PlayActiveGameView> {
  int? _reviewPly;
  int? _lastHistoryLength;

  @override
  Widget build(BuildContext context) {
    final sessionArgs = ref.watch(
      playSessionArgsByTabIdProvider.select((m) => m[widget.tabId]),
    );
    if (sessionArgs == null) {
      return const SizedBox.shrink();
    }

    final sessionProvider = playSessionProviderFor(widget.tabId);
    final state = ref.watch(sessionProvider);
    final totalPlies = state.history.length;
    if (_lastHistoryLength != null && totalPlies < _lastHistoryLength!) {
      _reviewPly = null;
    }
    _lastHistoryLength = totalPlies;
    final reviewPly = _effectiveReviewPly(_reviewPly, totalPlies);
    final currentPly = reviewPly ?? totalPlies;

    void goToPly(int ply) => _setReviewPly(ply, totalPlies);
    void goFirst() {
      if (currentPly > 0) goToPly(0);
    }

    void goPrevious() {
      if (currentPly > 0) goToPly(currentPly - 1);
    }

    void goNext() {
      if (currentPly < totalPlies) goToPly(currentPly + 1);
    }

    void goLast() {
      if (currentPly < totalPlies) goToPly(totalPlies);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.home): goFirst,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): goPrevious,
        const SingleActivator(LogicalKeyboardKey.arrowRight): goNext,
        const SingleActivator(LogicalKeyboardKey.end): goLast,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final boardSize = _resolvePlayBoardSize(constraints);
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Center(
                      child: SizedBox.square(
                        dimension: boardSize,
                        child: _BoardWithIdentities(
                          state: state,
                          tabId: widget.tabId,
                          reviewPly: reviewPly,
                          onReviewPlyChanged: goToPly,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 3,
                    child: _GameSidePanel(
                      state: state,
                      tabId: widget.tabId,
                      reviewPly: reviewPly,
                      onReviewPlyChanged: goToPly,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _setReviewPly(int ply, int totalPlies) {
    final clamped = _clampPly(ply, totalPlies);
    setState(() {
      _reviewPly = clamped >= totalPlies ? null : clamped;
    });
  }
}

/// Keeps side effects for a live play session attached even when the board
/// surface is temporarily unmounted, such as when a tournament player clicks
/// around to observe other games.
class PlaySessionLifecycleListener extends ConsumerWidget {
  const PlaySessionLifecycleListener({
    super.key,
    required this.tabId,
    required this.child,
  });

  final String tabId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSession = ref.watch(
      playSessionArgsByTabIdProvider.select((m) => m.containsKey(tabId)),
    );
    if (!hasSession) return child;
    final container = ProviderScope.containerOf(context, listen: false);

    ref.listen<PlaySessionState>(playSessionProviderFor(tabId), (
      previous,
      next,
    ) {
      if (previous != null && next.history.length > previous.history.length) {
        _playMoveSound(ref, previous, next);
        _publishTournamentProgress(ref, next, tabId);
      }
      if (previous?.isGameOver != true && next.isGameOver) {
        _scheduleFinishPlaySession(container, next, tabId);
      }
    });
    return child;
  }

  void _playMoveSound(
    WidgetRef ref,
    PlaySessionState previous,
    PlaySessionState next,
  ) {
    final settings = ref.read(boardSettingsProviderNew).valueOrNull;
    if (settings?.soundEnabled == false) return;
    try {
      final move = NormalMove.fromUci(next.history.last);
      final san = previous.position.makeSan(move).$2;
      AudioPlayerService.instance.playSfxForSan(san);
    } catch (_) {
      AudioPlayerService.instance.playSound(SfxType.move);
    }
  }
}

double _resolvePlayBoardSize(BoxConstraints c) {
  // Board fills the available square, capped so it doesn't dwarf the
  // side panel on wide monitors. Constraint-driven so panes can stack on
  // narrow windows without manual breakpoints.
  final available = c.maxHeight - 48;
  final widthBudget = (c.maxWidth - 64) * (5 / 8);
  return [available, widthBudget, 720.0].reduce((a, b) => a < b ? a : b);
}

void _publishTournamentProgress(
  WidgetRef ref,
  PlaySessionState state,
  String tabId,
) {
  final tournamentContext =
      ref.read(playSessionArgsByTabIdProvider)[tabId]?.tournamentContext;
  if (tournamentContext == null ||
      state.endReason == PlayEndReason.aborted ||
      state.history.isEmpty) {
    return;
  }
  ref
      .read(tournamentServerProvider.notifier)
      .recordHumanGameProgress(
        gameId: tournamentContext.gameId,
        fen: state.position.fen,
        movesUci: state.history,
        whiteMillis: state.whiteMillis,
        blackMillis: state.blackMillis,
      );
}

void _scheduleFinishPlaySession(
  ProviderContainer container,
  PlaySessionState state,
  String tabId, {
  bool recordGame = true,
}) {
  // Finishing a game swaps the Play tab into a Board tab and invalidates the
  // same play-session provider that is currently notifying this listener.
  // Defer the mutation until StateNotifier has finished walking its listeners.
  scheduleMicrotask(() {
    if (!container.read(playSessionArgsByTabIdProvider).containsKey(tabId)) {
      return;
    }
    _finishPlaySession(container, state, tabId, recordGame: recordGame);
  });
}

Future<void> _recordCompletedGame(
  ProviderContainer container,
  PlaySessionState state,
  PlaySessionArgs? args,
) async {
  final tournamentContext = args?.tournamentContext;
  if (state.endReason == PlayEndReason.aborted) {
    if (tournamentContext != null) {
      container
          .read(tournamentServerProvider.notifier)
          .resetHumanGame(tournamentContext.gameId);
    }
    return;
  }
  final repository = container.read(playProfileRepositoryProvider);
  final stockfishInstall = container.read(
    engineInstallProvider(BotEngineKind.stockfish),
  );
  final stockfishPath =
      engineReady(stockfishInstall) ? stockfishInstall.binaryPath : null;
  final analyzerBinaryPath = stockfishPath ?? args?.engineBinaryPath;
  final analyzerEngine =
      stockfishPath != null ? BotEngineKind.stockfish : state.config.engine;
  final record = await const PlayGameAnalyzer().analyzeSession(
    state,
    analyzerBinaryPath: analyzerBinaryPath,
    analyzerEngine: analyzerEngine,
    userDisplayName: repository.currentDisplayName,
    sourceOverride:
        tournamentContext == null ? null : PlayGameSource.tournament,
    eventTitle: tournamentContext?.tournamentTitle,
    eventRound: tournamentContext?.round,
    tournamentGameId: tournamentContext?.gameId,
  );
  await container
      .read(playAchievementsProvider.notifier)
      .recordSingleGame(state, contributions: record.badgeContributions);
  final achievements = container.read(playAchievementsProvider);
  await repository.saveCompletedGame(record, achievements: achievements);
  if (tournamentContext != null) {
    container
        .read(tournamentServerProvider.notifier)
        .recordHumanGameResult(
          gameId: tournamentContext.gameId,
          result: record.result,
          fen: state.position.fen,
          movesUci: state.history,
          whiteMillis: state.whiteMillis,
          blackMillis: state.blackMillis,
          endReason: state.endReason.banner,
        );
  }
  container.invalidate(playUserProfileProvider);
  container.invalidate(playRecentGamesProvider);
  for (final tc in RatedTimeControl.values) {
    container.invalidate(playRatingHistoryProvider(tc));
  }
}

void _finishPlaySession(
  ProviderContainer container,
  PlaySessionState state,
  String tabId, {
  bool recordGame = true,
}) {
  final args = container.read(playSessionArgsByTabIdProvider)[tabId];
  final tournamentContext = args?.tournamentContext;
  if (state.endReason == PlayEndReason.aborted) {
    if (tournamentContext != null) {
      container
          .read(tournamentServerProvider.notifier)
          .resetHumanGame(tournamentContext.gameId);
    }
    _clearPlaySession(container, tabId);
    return;
  }

  if (state.endReason != PlayEndReason.aborted) {
    if (tournamentContext != null) {
      _recordTournamentGameResult(container, state, tournamentContext);
      _clearPlaySession(container, tabId);
    } else {
      _openFinishedPlayGameBoard(container, state, tabId, args);
    }
  }
  if (recordGame) {
    unawaited(_recordCompletedGame(container, state, args));
  }
}

void _recordTournamentGameResult(
  ProviderContainer container,
  PlaySessionState state,
  PlayTournamentContext tournamentContext,
) {
  final result = _playResultForOutcome(state.outcome);
  if (result == '*') return;
  container
      .read(tournamentServerProvider.notifier)
      .recordHumanGameResult(
        gameId: tournamentContext.gameId,
        result: result,
        fen: state.position.fen,
        movesUci: state.history,
        whiteMillis: state.whiteMillis,
        blackMillis: state.blackMillis,
        endReason: state.endReason.banner,
      );
}

void _openFinishedPlayGameBoard(
  ProviderContainer container,
  PlaySessionState state,
  String tabId,
  PlaySessionArgs? args,
) {
  final tabs = container.read(desktopTabsProvider);
  if (tabs.activeId != tabId || tabs.active?.kind != TabKind.play) return;

  final userDisplayName =
      container.read(playProfileRepositoryProvider).currentDisplayName;
  final boardArgs = _finishedPlayBoardArgs(
    state,
    args,
    userDisplayName: userDisplayName,
  );
  openBoardGameTabFromContainer(
    container,
    boardArgs,
    reuseExisting: false,
    replaceActive: true,
  );
  _clearPlaySession(container, tabId);
}

void _clearPlaySession(ProviderContainer container, String tabId) {
  container.read(playSessionArgsByTabIdProvider.notifier).update((m) {
    if (!m.containsKey(tabId)) return m;
    return <String, PlaySessionArgs>{...m}..remove(tabId);
  });
  container.invalidate(playSessionProviderFor(tabId));
  container.read(playSetupProvider.notifier).clearStartingSeed();
}

BoardTabGameArgs _finishedPlayBoardArgs(
  PlaySessionState state,
  PlaySessionArgs? args, {
  required String userDisplayName,
}) {
  final tournamentContext = args?.tournamentContext;
  final humanIsWhite = state.humanSide == Side.white;
  final bot = state.botIdentity;
  final whiteName = humanIsWhite ? userDisplayName : bot.fullName;
  final blackName = humanIsWhite ? bot.fullName : userDisplayName;
  final result = _playResultForOutcome(state.outcome);
  final game = _playNotationGame(state).copyWith(
    gameId: tournamentContext?.gameId ?? 'play-finished',
    metadata: <String, dynamic>{
      'Event':
          tournamentContext?.tournamentTitle ??
          (state.config.hasStartingPositionSeed
              ? 'ChessEver Play from here'
              : 'ChessEver Play'),
      'Round': tournamentContext?.round.toString() ?? '-',
      'White': whiteName,
      'Black': blackName,
      'Result': result,
      'TimeControl':
          '${state.config.baseSeconds}+${state.config.incrementSeconds}',
      'Termination': state.endReason.banner,
      'ChessEverSource':
          tournamentContext == null
              ? (state.config.hasStartingPositionSeed
                  ? PlayGameSource.playFromHere.value
                  : PlayGameSource.singlePlay.value)
              : PlayGameSource.tournament.value,
      if (tournamentContext == null) ...{
        'ChessEverEngineKind': state.config.engine.name,
        'ChessEverEngineElo': state.config.elo.toString(),
        'ChessEverBaseSeconds': state.config.baseSeconds.toString(),
        'ChessEverIncSeconds': state.config.incrementSeconds.toString(),
        'ChessEverCategory': state.config.category.name,
        'ChessEverHumanColor':
            state.humanSide == Side.white ? 'white' : 'black',
        if (state.config.hasStartingPositionSeed)
          'ChessEverStartingFen': state.startingFen,
      },
      if (tournamentContext != null)
        'ChessEverTournamentGameId': tournamentContext.gameId,
      if (!humanIsWhite) ...{
        'WhiteTitle': bot.title ?? '',
        'WhiteElo': bot.elo.toString(),
        'WhiteFed': bot.countryCode,
      },
      if (humanIsWhite) ...{
        'BlackTitle': bot.title ?? '',
        'BlackElo': bot.elo.toString(),
        'BlackFed': bot.countryCode,
      },
    },
  );
  final pgn = exportGameToPgn(game);
  final whiteTitle = humanIsWhite ? '' : (bot.title ?? '');
  final blackTitle = humanIsWhite ? (bot.title ?? '') : '';
  final whiteRating = humanIsWhite ? 0 : bot.elo;
  final blackRating = humanIsWhite ? bot.elo : 0;
  final label =
      tournamentContext == null
          ? '$whiteName vs $blackName'
          : '${tournamentContext.tournamentTitle}: $whiteName vs $blackName';
  return BoardTabGameArgs(
    pgn: pgn,
    label: label,
    whiteName: whiteName,
    blackName: blackName,
    whiteFederation: humanIsWhite ? '' : bot.countryCode,
    blackFederation: humanIsWhite ? bot.countryCode : '',
    whiteTitle: whiteTitle,
    blackTitle: blackTitle,
    whiteRating: whiteRating,
    blackRating: blackRating,
    initialBoardFlipped: state.humanSide == Side.black,
    initialFen: state.position.fen,
    fenSeed: state.position.fen,
    tournamentTitle: tournamentContext?.tournamentTitle ?? '',
    gameListSelectedId: tournamentContext?.gameId,
  );
}

String _playResultForOutcome(Outcome? outcome) {
  if (outcome == Outcome.whiteWins) return '1-0';
  if (outcome == Outcome.blackWins) return '0-1';
  if (outcome == Outcome.draw) return '1/2-1/2';
  return '*';
}

@visibleForTesting
BoardTabGameArgs debugFinishedPlayBoardArgs(
  PlaySessionState state,
  PlaySessionArgs? args, {
  required String userDisplayName,
}) {
  return _finishedPlayBoardArgs(state, args, userDisplayName: userDisplayName);
}

@visibleForTesting
void debugOpenFinishedPlayGameBoard(
  ProviderContainer container,
  PlaySessionState state,
  String tabId,
  PlaySessionArgs? args,
) {
  _openFinishedPlayGameBoard(container, state, tabId, args);
}

@visibleForTesting
void debugScheduleFinishPlaySession(
  ProviderContainer container,
  PlaySessionState state,
  String tabId,
) {
  _scheduleFinishPlaySession(container, state, tabId, recordGame: false);
}

@visibleForTesting
void debugFinishPlaySession(
  ProviderContainer container,
  PlaySessionState state,
  String tabId,
) {
  _finishPlaySession(container, state, tabId, recordGame: false);
}

class _BoardWithIdentities extends ConsumerWidget {
  const _BoardWithIdentities({
    required this.state,
    required this.tabId,
    required this.reviewPly,
    required this.onReviewPlyChanged,
  });

  final PlaySessionState state;
  final String tabId;
  final int? reviewPly;
  final ValueChanged<int> onReviewPlyChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orientation = state.humanSide;
    final topSide = orientation == Side.white ? Side.black : Side.white;
    final bottomSide = orientation;
    final totalPlies = state.history.length;
    final currentPly = reviewPly ?? totalPlies;
    final notationGame = _playNotationGame(state);
    return Column(
      children: [
        _PlayerRow(
          state: state,
          side: topSide,
          alignment: MainAxisAlignment.start,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _BoardInteractive(
            state: state,
            tabId: tabId,
            reviewPly: reviewPly,
            onReviewPlyChanged: onReviewPlyChanged,
          ),
        ),
        const SizedBox(height: 8),
        MoveNavigationBar(
          canGoBack: currentPly > 0,
          canGoForward: currentPly < totalPlies,
          onFirst: () => onReviewPlyChanged(0),
          onPrevious: () => onReviewPlyChanged(currentPly - 1),
          onNext: () => onReviewPlyChanged(currentPly + 1),
          onLast: () => onReviewPlyChanged(totalPlies),
          showFlipBoard: false,
          moveLabel: _playMoveLabel(notationGame, currentPly),
        ),
        const SizedBox(height: 10),
        _PlayerRow(
          state: state,
          side: bottomSide,
          alignment: MainAxisAlignment.start,
        ),
      ],
    );
  }
}

class _PlayerRow extends ConsumerWidget {
  const _PlayerRow({
    required this.state,
    required this.side,
    required this.alignment,
  });

  final PlaySessionState state;
  final Side side;
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHuman = side == state.humanSide;
    final profile = ref.watch(playUserProfileProvider).valueOrNull;
    final clockMs = side == Side.white ? state.whiteMillis : state.blackMillis;
    final isActive = state.activeClock == side && !state.isGameOver;
    final label =
        isHuman
            ? (profile?.displayName.trim().isNotEmpty == true
                ? profile!.displayName.trim()
                : 'You')
            : state.botIdentity.displayName;
    final countryCode = isHuman ? null : state.botIdentity.countryCode;
    final ratedTc = toRatedTimeControl(state.config.category);
    final humanRating =
        ratedTc != null
            ? (profile?.statsFor(ratedTc).rating ?? 1200)
            : (profile?.headlineRating ?? 1200);
    final ladderSuffix =
        ratedTc != null ? ratedTc.displayName : 'Custom (unrated)';
    final eloLabel =
        isHuman
            ? '$humanRating • $ladderSuffix'
            : '${playStrengthLabel(state.config.engine, state.botIdentity.elo)}'
                ' • ${state.botIdentity.profileLine}';
    final score = state.isGameOver ? _scoreForSide(state.outcome, side) : null;
    final eloDelta =
        (state.isGameOver && isHuman && score != null)
            ? _humanEloDelta(state: state, profile: profile, score: score)
            : null;
    return Row(
      mainAxisAlignment: alignment,
      children: [
        if (isHuman)
          DesktopUserProfileButton(
            size: 36,
            tooltip: 'Open my player profile',
            onPress: () => openCurrentUserProfileTab(ref),
          )
        else
          SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: SizedBox(
                width: 36,
                height: 24,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child:
                      countryCode != null
                          ? CountryFlag.fromCountryCode(countryCode)
                          : Container(color: kBlack3Color),
                ),
              ),
            ),
          ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (eloDelta != null) ...[
                    const SizedBox(width: 8),
                    _EloDeltaPill(
                      key: ValueKey(
                        'elo-${side.name}-${state.endReason.name}-${state.history.length}',
                      ),
                      delta: eloDelta,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                eloLabel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (score != null) ...[
          _PostGameBadge(
            key: ValueKey(
              '${side.name}-${state.endReason.name}-${state.history.length}',
            ),
            score: score,
          ),
          const SizedBox(width: 12),
        ],
        _ClockChip(millis: clockMs, active: isActive),
      ],
    );
  }
}

double? _scoreForSide(Outcome? outcome, Side side) {
  if (outcome == null) return null;
  if (outcome == Outcome.draw) return 0.5;
  final winner = outcome.winner;
  if (winner == null) return null;
  return winner == side ? 1.0 : 0.0;
}

/// Computes the human's ELO delta for the just-finished game using the
/// same FIDE math the persistence layer applies in [saveCompletedGame].
/// Returns null for unrated (custom) time controls or when the profile
/// snapshot isn't loaded yet — in which case the badge shows the score
/// without a delta. Bot-side rows never call this.
int? _humanEloDelta({
  required PlaySessionState state,
  required PlayUserProfile? profile,
  required double score,
}) {
  if (profile == null) return null;
  final rated = toRatedTimeControl(state.config.category);
  if (rated == null) return null;
  final stats = profile.statsFor(rated);
  final update = const FideEloCalculator().compute(
    currentRating: stats.rating,
    opponentRating: state.config.elo,
    score: score,
    gamesPlayedBefore: stats.gamesPlayed,
    peakRating: stats.peak,
  );
  return update.delta;
}

/// Score chip mounted on a [_PlayerRow] the moment a game ends. Mounted
/// fresh on each game-end (parent supplies a keyed identity), so
/// [SingleMotionBuilder] animates from 0 → 1 on first frame.
class _PostGameBadge extends StatefulWidget {
  const _PostGameBadge({super.key, required this.score});

  /// 1.0 = win, 0.5 = draw, 0.0 = loss.
  final double score;

  @override
  State<_PostGameBadge> createState() => _PostGameBadgeState();
}

class _PostGameBadgeState extends State<_PostGameBadge> {
  double _mounted = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _mounted = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color color = switch (widget.score) {
      1.0 => kGreenColor,
      0.0 => kRedColor,
      _ => kWhiteColor70,
    };
    final String label = switch (widget.score) {
      1.0 => '1',
      0.0 => '0',
      _ => '½',
    };
    return SingleMotionBuilder(
      value: _mounted,
      motion: DesktopMotion.arrival,
      builder: (context, t, child) {
        final scale = 0.6 + (0.4 * t);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// ELO change pill — rendered next to the human player's name when a
/// rated game ends. Spring-mounted so it lands rather than pops in.
class _EloDeltaPill extends StatefulWidget {
  const _EloDeltaPill({super.key, required this.delta});

  final int delta;

  @override
  State<_EloDeltaPill> createState() => _EloDeltaPillState();
}

class _EloDeltaPillState extends State<_EloDeltaPill> {
  double _mounted = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _mounted = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final delta = widget.delta;
    final color =
        delta > 0 ? kGreenColor : (delta < 0 ? kRedColor : kWhiteColor70);
    final sign = delta > 0 ? '+' : (delta < 0 ? '−' : '±');
    final magnitude = delta.abs();
    return SingleMotionBuilder(
      value: _mounted,
      motion: DesktopMotion.arrival,
      builder: (context, t, child) {
        final scale = 0.7 + (0.3 * t);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.centerLeft,
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          '$sign$magnitude',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _ClockChip extends StatelessWidget {
  const _ClockChip({required this.millis, required this.active});

  final int millis;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final low = millis < 10000;
    final bg =
        active
            ? (low
                ? kRedColor.withValues(alpha: 0.16)
                : kPrimaryColor.withValues(alpha: 0.16))
            : kBlack3Color;
    final fg = active ? (low ? kRedColor : kPrimaryColor) : kWhiteColor70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: active ? fg : kDividerColor),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        formatClock(millis),
        style: TextStyle(
          color: fg,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _BoardInteractive extends ConsumerStatefulWidget {
  const _BoardInteractive({
    required this.state,
    required this.tabId,
    required this.reviewPly,
    required this.onReviewPlyChanged,
  });

  final PlaySessionState state;
  final String tabId;
  final int? reviewPly;
  final ValueChanged<int> onReviewPlyChanged;

  @override
  ConsumerState<_BoardInteractive> createState() => _BoardInteractiveState();
}

class _BoardInteractiveState extends ConsumerState<_BoardInteractive> {
  NormalMove? _promotionPending;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = ref.read(playSessionProviderFor(widget.tabId).notifier);
    final orientation = state.humanSide;
    final review = _playReviewSnapshot(state, widget.reviewPly);
    final isLiveTip = review.isLiveTip;
    final playerSide =
        state.isGameOver || !isLiveTip
            ? cg.PlayerSide.none
            : (state.humanSide == Side.white
                ? cg.PlayerSide.white
                : cg.PlayerSide.black);
    final annotations = ref.watch(boardAnnotationsProvider(widget.tabId));
    final premoveShapes =
        isLiveTip
            ? _premoveShapes(state.premoves)
            : const ISet<cg.Shape>.empty();
    final mergedShapes =
        annotations.shapes.isEmpty
            ? premoveShapes
            : premoveShapes.addAll(annotations.shapes);
    // Render the post-premove (virtual) board so chessground sees pieces at
    // their queued destinations. Without this, the user can only stack one
    // premove per piece — chessground would still see the original FEN and
    // refuse to grab a pawn that has "already" advanced in the queue.
    final virtualBoard =
        isLiveTip
            ? buildVirtualPlayBoard(state.position.board, state.premoves)
            : review.position.board;
    final boardFen = virtualBoard.fen;
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Use onSecondaryTapUp so plain right-drag (arrow draw via
          // BoardAnnotationLayer) doesn't also fire premove-clear. Tap-up
          // only fires when no drag occurred.
          onSecondaryTapUp:
              isLiveTip && state.premoves.isNotEmpty
                  ? (_) => notifier.clearPremoves()
                  : null,
          child: BoardAnnotationLayer(
            tabId: widget.tabId,
            size: size,
            orientation: orientation,
            child: DesktopChessBoard(
              size: size,
              fen: boardFen,
              orientation: orientation,
              playerSide: playerSide,
              sideToMove: review.position.turn,
              validMoves: makeLegalMoves(review.position),
              lastMove: review.lastMove,
              premove: isLiveTip ? _lastQueuedPremove(state.premoves) : null,
              onSetPremove:
                  isLiveTip
                      ? (move) {
                        if (move == null) {
                          notifier.clearPremoves();
                          return;
                        }
                        if (move is NormalMove) {
                          notifier.queuePremove(move.uci);
                        }
                      }
                      : null,
              promotionMove: isLiveTip ? _promotionPending : null,
              onPromotionSelection: (role) {
                final pending = _promotionPending;
                if (pending == null) return;
                if (role == null) {
                  setState(() => _promotionPending = null);
                  return;
                }
                final promoted = pending.withPromotion(role);
                setState(() => _promotionPending = null);
                notifier.playHumanMove(promoted.uci);
              },
              shapes: mergedShapes,
              squareHighlights:
                  isLiveTip
                      ? _premoveHeatMap(state.premoves)
                      : const IMapConst<Square, cg.SquareHighlight>({}),
              isCheck: review.position.isCheck,
              onMove: (move, {viaDragAndDrop}) {
                if (!isLiveTip) {
                  widget.onReviewPlyChanged(state.history.length);
                  return;
                }
                if (move is! NormalMove) return;
                final isHumansTurn = state.isHumanToMove;
                // If it's the human's turn the engine reply path applies the move
                // directly. Otherwise stack as a premove so chess.com-style
                // pre-input keeps working.
                if (isHumansTurn) {
                  // Detect promotion: pawn reaching the last rank without a role.
                  final piece = state.position.board.pieceAt(move.from);
                  if (piece != null &&
                      piece.role == Role.pawn &&
                      move.promotion == null &&
                      (move.to.rank == Rank.eighth ||
                          move.to.rank == Rank.first)) {
                    setState(() => _promotionPending = move);
                    return;
                  }
                  notifier.playHumanMove(move.uci);
                } else {
                  notifier.queuePremove(move.uci);
                }
              },
            ),
          ),
        );
      },
    );
  }
}

NormalMove? _lastQueuedPremove(List<String> premoves) {
  for (final uci in premoves.reversed) {
    final move = _tryParseNormalMove(uci);
    if (move != null) return move;
  }
  return null;
}

ISet<cg.Shape> _premoveShapes(List<String> premoves) {
  if (premoves.isEmpty) return const ISet<cg.Shape>.empty();
  final shapes = <cg.Shape>[];
  for (var i = 0; i < premoves.length; i++) {
    final move = _tryParseNormalMove(premoves[i]);
    if (move == null || move.from == move.to) continue;
    final alpha = (0.42 + (i * 0.06)).clamp(0.42, 0.78).toDouble();
    final scale = (0.52 + (i * 0.04)).clamp(0.52, 0.78).toDouble();
    shapes.add(
      cg.Arrow(
        color: kPrimaryColor.withValues(alpha: alpha),
        orig: move.from,
        dest: move.to,
        scale: scale,
      ),
    );
  }
  return shapes.toISet();
}

IMap<Square, cg.SquareHighlight> _premoveHeatMap(List<String> premoves) {
  if (premoves.isEmpty) {
    return const IMapConst<Square, cg.SquareHighlight>({});
  }
  final visits = <Square, int>{};
  for (final uci in premoves) {
    final move = _tryParseNormalMove(uci);
    if (move == null) continue;
    visits[move.from] = (visits[move.from] ?? 0) + 1;
    visits[move.to] = (visits[move.to] ?? 0) + 1;
  }
  final highlights = <Square, cg.SquareHighlight>{};
  for (final entry in visits.entries) {
    final alpha =
        (0.14 + ((entry.value - 1) * 0.10)).clamp(0.14, 0.64).toDouble();
    highlights[entry.key] = cg.SquareHighlight(
      details: cg.HighlightDetails(
        solidColor: kPrimaryColor.withValues(alpha: alpha),
      ),
    );
  }
  return highlights.lock;
}

NormalMove? _tryParseNormalMove(String uci) {
  try {
    return NormalMove.fromUci(uci);
  } catch (_) {
    return null;
  }
}

class _GameSidePanel extends ConsumerWidget {
  const _GameSidePanel({
    required this.state,
    required this.tabId,
    required this.reviewPly,
    required this.onReviewPlyChanged,
  });

  final PlaySessionState state;
  final String tabId;
  final int? reviewPly;
  final ValueChanged<int> onReviewPlyChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notationUseFigurine = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.useFigurine ?? const BoardSettingsNew().useFigurine,
      ),
    );
    final notationPieceAssets = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.pieceAssets ?? const BoardSettingsNew().pieceAssets,
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GameHeader(state: state),
          const SizedBox(height: 14),
          const Divider(height: 1, color: kDividerColor),
          const SizedBox(height: 12),
          Expanded(
            child: _PlayNotationPanel(
              state: state,
              reviewPly: reviewPly,
              onReviewPlyChanged: onReviewPlyChanged,
              useFigurine: notationUseFigurine,
              pieceAssets: notationPieceAssets,
            ),
          ),
          const SizedBox(height: 12),
          if (state.premoves.isNotEmpty) ...[
            _PremoveQueue(state: state, tabId: tabId),
            const SizedBox(height: 12),
          ],
          if (state.isGameOver)
            _ResultBanner(state: state, tabId: tabId)
          else
            _GameActions(state: state, tabId: tabId),
        ],
      ),
    );
  }
}

class _GameHeader extends StatelessWidget {
  const _GameHeader({required this.state});

  final PlaySessionState state;

  @override
  Widget build(BuildContext context) {
    final cfg = state.config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${cfg.engine.displayName} • '
          '${playStrengthStartSummary(cfg.engine, cfg.elo)}',
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${cfg.timeControlShorthand} • ${cfg.category.displayName}',
          style: const TextStyle(color: kSecondaryTextColor, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              state.engineReady
                  ? Icons.check_circle_outline
                  : Icons.cached_outlined,
              size: 14,
              color: state.engineReady ? kGreenColor : kSecondaryTextColor,
            ),
            const SizedBox(width: 4),
            Text(
              state.engineStatus,
              style: const TextStyle(color: kSecondaryTextColor, fontSize: 12),
            ),
            if (state.engineThinking) ...[
              const SizedBox(width: 6),
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: kPrimaryColor,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _PlayNotationPanel extends StatelessWidget {
  const _PlayNotationPanel({
    required this.state,
    required this.reviewPly,
    required this.onReviewPlyChanged,
    required this.useFigurine,
    required this.pieceAssets,
  });

  final PlaySessionState state;
  final int? reviewPly;
  final ValueChanged<int> onReviewPlyChanged;
  final bool useFigurine;
  final cg.PieceAssets? pieceAssets;

  @override
  Widget build(BuildContext context) {
    final game = _playNotationGame(state);
    final activePly = reviewPly ?? game.mainline.length;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: NotationLadderView(
        game: game,
        activePointer: _playNotationPointerForPly(game, activePly),
        onJump: (pointer) => onReviewPlyChanged(_playPlyForPointer(pointer)),
        useFigurine: useFigurine,
        pieceAssets: pieceAssets,
      ),
    );
  }
}

ChessGame _playNotationGame(PlaySessionState state) {
  final startingPosition = _playStartingPosition(state.startingFen);
  var position = startingPosition;
  final mainline = <ChessMove>[];

  for (final uci in state.history) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final san = position.makeSan(move).$2;
    final next = position.playUnchecked(move);
    mainline.add(
      ChessMove(
        num: position.fullmoves,
        fen: next.fen,
        san: san,
        uci: move.uci,
        turn: position.turn == Side.black ? ChessColor.black : ChessColor.white,
      ),
    );
    position = next;
  }

  return ChessGame(
    gameId: 'play-active',
    startingFen: startingPosition.fen,
    metadata: <String, dynamic>{
      'Event': 'Play vs ${state.config.engine.displayName}',
      'White':
          state.humanSide == Side.white ? 'You' : state.botIdentity.displayName,
      'Black':
          state.humanSide == Side.black ? 'You' : state.botIdentity.displayName,
      'Result': '*',
      'TimeControl': state.config.timeControlShorthand,
      ChessGame.metadataIsLiveKey: true,
    },
    mainline: List<ChessMove>.unmodifiable(mainline),
  );
}

Position _playStartingPosition(String fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen), ignoreImpossibleCheck: true);
  } catch (_) {
    return Chess.initial;
  }
}

int _clampPly(int ply, int totalPlies) {
  if (ply < 0) return 0;
  if (ply > totalPlies) return totalPlies;
  return ply;
}

int? _effectiveReviewPly(int? reviewPly, int totalPlies) {
  if (reviewPly == null) return null;
  final clamped = _clampPly(reviewPly, totalPlies);
  return clamped >= totalPlies ? null : clamped;
}

ChessMovePointer _playNotationPointerForPly(ChessGame game, int ply) {
  final clamped = _clampPly(ply, game.mainline.length);
  if (clamped <= 0) return const <int>[];
  return <int>[clamped - 1];
}

ChessMovePointer _playNotationActivePointer(ChessGame game) =>
    _playNotationPointerForPly(game, game.mainline.length);

int _playPlyForPointer(ChessMovePointer pointer) {
  if (pointer.isEmpty) return 0;
  return pointer.first + 1;
}

String _playMoveLabel(ChessGame game, int ply) {
  final total = game.mainline.length;
  final clamped = _clampPly(ply, total);
  if (clamped <= 0) return 'Start · 0 / $total';
  final move = game.mainline[clamped - 1];
  final marker =
      clamped.isOdd ? '${(clamped + 1) ~/ 2}. ' : '${clamped ~/ 2}... ';
  return '$marker${move.san} · $clamped / $total';
}

class _PlayReviewSnapshot {
  const _PlayReviewSnapshot({
    required this.position,
    required this.lastMove,
    required this.ply,
    required this.isLiveTip,
  });

  final Position position;
  final NormalMove? lastMove;
  final int ply;
  final bool isLiveTip;
}

_PlayReviewSnapshot _playReviewSnapshot(
  PlaySessionState state,
  int? reviewPly,
) {
  final totalPlies = state.history.length;
  final targetPly =
      reviewPly == null ? totalPlies : _clampPly(reviewPly, totalPlies);
  if (targetPly >= totalPlies) {
    return _PlayReviewSnapshot(
      position: state.position,
      lastMove: state.lastMove,
      ply: totalPlies,
      isLiveTip: true,
    );
  }

  var position = _playStartingPosition(state.startingFen);
  NormalMove? lastMove;
  var replayed = 0;
  for (final uci in state.history.take(targetPly)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    position = position.playUnchecked(move);
    lastMove = move is NormalMove ? move : null;
    replayed += 1;
  }

  return _PlayReviewSnapshot(
    position: position,
    lastMove: lastMove,
    ply: replayed,
    isLiveTip: false,
  );
}

@visibleForTesting
ChessGame debugPlayNotationGame(PlaySessionState state) =>
    _playNotationGame(state);

@visibleForTesting
ChessMovePointer debugPlayNotationActivePointer(ChessGame game) =>
    _playNotationActivePointer(game);

@visibleForTesting
ChessMovePointer debugPlayNotationPointerForPly(ChessGame game, int ply) =>
    _playNotationPointerForPly(game, ply);

@visibleForTesting
String debugPlayReviewFen(PlaySessionState state, int? reviewPly) =>
    _playReviewSnapshot(state, reviewPly).position.fen;

class _PremoveQueue extends ConsumerWidget {
  const _PremoveQueue({required this.state, required this.tabId});

  final PlaySessionState state;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          const Icon(Icons.flash_on_outlined, size: 14, color: kPrimaryColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Premoves: ${state.premoves.join(', ')}',
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
          FTheme(
            data: FThemes.zinc.dark,
            child: FButton.icon(
              style: _premoveClearButtonStyle(),
              onPress:
                  () =>
                      ref
                          .read(playSessionProviderFor(tabId).notifier)
                          .clearPremoves(),
              child: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _premoveClearButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        WidgetState.any: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
      }),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            iconStyle: FWidgetStateMap({
              WidgetState.any: const IconThemeData(
                color: kPrimaryColor,
                size: 14,
              ),
            }),
          ),
    ),
  );
}

class _GameActions extends ConsumerWidget {
  const _GameActions({required this.state, required this.tabId});

  final PlaySessionState state;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Row(
        children: [
          Expanded(
            child: FButton(
              style: playDangerActionButtonStyle(),
              prefix: const Icon(Icons.flag_outlined),
              onPress:
                  () => _confirmAndCall(
                    context,
                    title: 'Resign game?',
                    body:
                        'Your bot will be awarded the win. The game ends immediately.',
                    onConfirm:
                        () =>
                            ref
                                .read(playSessionProviderFor(tabId).notifier)
                                .resign(),
                  ),
              child: const Text('Resign'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.close_rounded),
              onPress:
                  () => _confirmAndCall(
                    context,
                    title: 'Abort game?',
                    body:
                        'Cancel this game with no result. The clocks are discarded.',
                    onConfirm:
                        () => _leavePlaySession(
                          ref,
                          tabId,
                          resetTournamentGame: true,
                        ),
                  ),
              child: const Text('Abort'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndCall(
    BuildContext context, {
    required String title,
    required String body,
    required VoidCallback onConfirm,
  }) async {
    final ok = await showFDialog<bool>(
      context: context,
      builder:
          (ctx, _, animation) => FDialog(
            animation: animation,
            direction: Axis.horizontal,
            title: Text(title),
            body: Text(body),
            actions: [
              FButton(
                style: playSecondaryActionButtonStyle(),
                prefix: const Icon(Icons.close_rounded),
                onPress: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FButton(
                style: playDangerActionButtonStyle(),
                prefix: const Icon(Icons.warning_amber_rounded),
                onPress: () => Navigator.of(ctx).pop(true),
                child: const Text('Confirm'),
              ),
            ],
          ),
    );
    if (ok == true) onConfirm();
  }
}

class _ResultBanner extends ConsumerWidget {
  const _ResultBanner({required this.state, required this.tabId});

  final PlaySessionState state;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final humanWon = state.outcome?.winner == state.humanSide;
    final draw = state.outcome == Outcome.draw;
    final color = draw ? kWhiteColor70 : (humanWon ? kGreenColor : kRedColor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            state.endReason.banner,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          FTheme(
            data: FThemes.zinc.dark,
            child: Row(
              children: [
                Expanded(
                  child: FButton(
                    style: playPrimaryActionButtonStyle(),
                    prefix: const Icon(Icons.replay_rounded),
                    onPress: () {
                      _leavePlaySession(ref, tabId);
                    },
                    child: const Text('Play again'),
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

void _leavePlaySession(
  WidgetRef ref,
  String tabId, {
  bool resetTournamentGame = false,
}) {
  final args = ref.read(playSessionArgsByTabIdProvider)[tabId];
  final tournamentContext = args?.tournamentContext;
  if (resetTournamentGame && tournamentContext != null) {
    ref
        .read(tournamentServerProvider.notifier)
        .resetHumanGame(tournamentContext.gameId);
  }

  ref.read(playSessionArgsByTabIdProvider.notifier).update((m) {
    if (!m.containsKey(tabId)) return m;
    return <String, PlaySessionArgs>{...m}..remove(tabId);
  });
  ref.invalidate(playSessionProviderFor(tabId));
  ref.read(playSetupProvider.notifier).clearStartingSeed();
}

// Re-exports so the Play pane doesn't have to import chessground/dartchess
// directly. Keep the chain short — only what the pane wires up.
typedef ChessgroundValidMoves = cg.ValidMoves;
typedef ChessgroundPlayerSide = cg.PlayerSide;
typedef ChessgroundShape = cg.Shape;
typedef IsetShape = ISet<cg.Shape>;
