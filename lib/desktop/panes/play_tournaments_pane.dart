import 'dart:async';
import 'dart:math';

import 'package:country_flags/country_flags.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' hide File;
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_tournament_history_repository.dart';
import 'package:chessever/desktop/services/play/play_from_here.dart';
import 'package:chessever/desktop/services/tournament_server/eco_library.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_resource_assessor.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_play_from_here_button.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_value_slider.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/audio_player_service.dart';

/// Engine-tournament browser shown when the user flips the Play pane's
/// segmented tab into Tournaments mode.
class PlayTournamentsPane extends ConsumerStatefulWidget {
  const PlayTournamentsPane({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<PlayTournamentsPane> createState() =>
      _PlayTournamentsPaneState();
}

class _PlayTournamentsPaneState extends ConsumerState<PlayTournamentsPane> {
  String? _focusedGameId;
  bool _userFocusedGame = false;
  _TournamentConsoleTab _tab = _TournamentConsoleTab.live;

  @override
  Widget build(BuildContext context) {
    final arena = ref.watch(tournamentServerProvider);
    ref.listen<TournamentServerState>(tournamentServerProvider, (
      previous,
      next,
    ) {
      final before = previous?.snapshot;
      final after = next.snapshot;
      if (after != null && _shouldPersistTournamentEvent(before, after)) {
        unawaited(saveTournamentEventSnapshot(ref, after));
      }
      if (before?.isRunning == true && after != null && !after.isRunning) {
        unawaited(
          ref
              .read(playAchievementsProvider.notifier)
              .recordTournamentCompleted(after),
        );
        unawaited(_saveFinishedTournament(ref, after));
      }
      if (after != null) {
        _syncDefaultHumanBoard(before, after);
      }
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TournamentHeader(state: arena),
        const Divider(height: 1, color: kDividerColor),
        Expanded(
          child:
              arena.snapshot == null
                  ? const _EmptyState()
                  : _TournamentConsole(
                    snapshot: arena.snapshot!,
                    focusedGameId: _focusedGameId,
                    tabId: widget.tabId,
                    selectedTab: _tab,
                    onTabChanged: (tab) => setState(() => _tab = tab),
                    onFocusGame: _focusGameManually,
                  ),
        ),
      ],
    );
  }

  void _focusGameManually(String id) {
    setState(() {
      _focusedGameId = id;
      _userFocusedGame = true;
      _tab = _TournamentConsoleTab.live;
    });
  }

  void _syncDefaultHumanBoard(
    TournamentSnapshot? before,
    TournamentSnapshot snapshot,
  ) {
    final tournamentChanged = before?.config.id != snapshot.config.id;
    final focusedMissing =
        _focusedGameId != null && snapshot.gameById(_focusedGameId!) == null;
    final defaultGame = _defaultFocusedGame(snapshot, _focusedGameId);
    if (defaultGame != null &&
        (tournamentChanged || !_userFocusedGame || focusedMissing) &&
        _focusedGameId != defaultGame.id) {
      setState(() {
        _focusedGameId = defaultGame.id;
        _tab = _TournamentConsoleTab.live;
        _userFocusedGame = false;
      });
    } else if (tournamentChanged) {
      _userFocusedGame = false;
    }

    final started = _autoStartHumanTournamentGame(
      ref,
      snapshot,
      tabId: widget.tabId,
    );
    if (started && defaultGame != null && !_userFocusedGame) {
      setState(() {
        _focusedGameId = defaultGame.id;
        _tab = _TournamentConsoleTab.live;
      });
    }
  }
}

TournamentGame? _defaultFocusedGame(
  TournamentSnapshot snapshot,
  String? currentFocusId,
) {
  if (currentFocusId != null) {
    final current = snapshot.gameById(currentFocusId);
    if (current != null &&
        snapshot.isHumanGame(current) &&
        current.status != TournamentGameStatus.finished) {
      return current;
    }
  }

  final humanGame = _currentHumanGame(snapshot);
  if (humanGame != null) return humanGame;

  final inProgress = snapshot.games.where(
    (game) => game.status == TournamentGameStatus.inProgress,
  );
  if (inProgress.isNotEmpty) return inProgress.first;
  return snapshot.games.isEmpty ? null : snapshot.games.first;
}

TournamentGame? _currentHumanGame(TournamentSnapshot snapshot) {
  final games =
      snapshot.games
          .where(
            (game) =>
                snapshot.isHumanGame(game) &&
                game.status != TournamentGameStatus.finished,
          )
          .toList();
  if (games.isEmpty) return null;
  games.sort((a, b) {
    final currentRoundA = a.round == snapshot.currentRound ? 0 : 1;
    final currentRoundB = b.round == snapshot.currentRound ? 0 : 1;
    final roundBucket = currentRoundA.compareTo(currentRoundB);
    if (roundBucket != 0) return roundBucket;

    final status = _humanGameStatusRank(a).compareTo(_humanGameStatusRank(b));
    if (status != 0) return status;
    return a.round.compareTo(b.round);
  });
  return games.first;
}

int _humanGameStatusRank(TournamentGame game) {
  return switch (game.status) {
    TournamentGameStatus.inProgress => 0,
    TournamentGameStatus.scheduled => 1,
    TournamentGameStatus.finished => 2,
  };
}

bool _autoStartHumanTournamentGame(
  WidgetRef ref,
  TournamentSnapshot snapshot, {
  required String tabId,
}) {
  if (!snapshot.isRunning || !snapshot.hasHumanParticipant) return false;
  final game = _currentHumanGame(snapshot);
  if (game == null || game.status == TournamentGameStatus.finished) {
    return false;
  }

  final sessions = ref.read(playSessionArgsByTabIdProvider);
  final activeArgs = sessions[tabId];
  if (activeArgs != null && activeArgs.tournamentContext == null) {
    return false;
  }
  final activeContext = activeArgs?.tournamentContext;
  if (activeContext?.tournamentId == snapshot.config.id &&
      activeContext?.gameId == game.id) {
    return false;
  }
  if (_hasOtherUnfinishedTournamentSession(sessions, snapshot, game.id)) {
    return false;
  }

  final humanIsWhite = snapshot.isHumanParticipant(game.whiteId);
  final opponent = snapshot.participantById(
    humanIsWhite ? game.blackId : game.whiteId,
  );
  if (opponent == null) return false;
  return _startHumanTournamentGame(
    ref,
    snapshot: snapshot,
    game: game,
    opponent: opponent,
    humanIsWhite: humanIsWhite,
    tabId: tabId,
  );
}

bool _hasOtherUnfinishedTournamentSession(
  Map<String, PlaySessionArgs> sessions,
  TournamentSnapshot snapshot,
  String targetGameId,
) {
  for (final args in sessions.values) {
    final context = args.tournamentContext;
    if (context == null || context.tournamentId != snapshot.config.id) {
      continue;
    }
    if (context.gameId == targetGameId) continue;
    final game = snapshot.gameById(context.gameId);
    if (game == null || game.status != TournamentGameStatus.finished) {
      return true;
    }
  }
  return false;
}

bool _shouldPersistTournamentEvent(
  TournamentSnapshot? before,
  TournamentSnapshot after,
) {
  if (before == null) return true;
  if (before.config.id != after.config.id) return true;
  if (before.isRunning != after.isRunning) return true;
  return _finishedGameCount(before) != _finishedGameCount(after);
}

int _finishedGameCount(TournamentSnapshot snapshot) {
  return snapshot.games
      .where((game) => game.status == TournamentGameStatus.finished)
      .length;
}

Future<void> _saveFinishedTournament(
  WidgetRef ref,
  TournamentSnapshot snapshot,
) async {
  await saveTournamentEventSnapshot(ref, snapshot);
  await ref
      .read(playProfileRepositoryProvider)
      .saveTournamentSnapshot(snapshot);
  ref.invalidate(playRecentGamesProvider);
  ref.invalidate(playUserProfileProvider);
  for (final tc in RatedTimeControl.values) {
    ref.invalidate(playRatingHistoryProvider(tc));
  }
}

enum _TournamentConsoleTab { live, standings, bracket, stream }

extension _TournamentConsoleTabLabel on _TournamentConsoleTab {
  String get label => switch (this) {
    _TournamentConsoleTab.live => 'Live games',
    _TournamentConsoleTab.standings => 'Standings',
    _TournamentConsoleTab.bracket => 'Bracket',
    _TournamentConsoleTab.stream => 'Updates',
  };

  IconData get icon => switch (this) {
    _TournamentConsoleTab.live => Icons.grid_view_rounded,
    _TournamentConsoleTab.standings => Icons.leaderboard_outlined,
    _TournamentConsoleTab.bracket => Icons.account_tree_outlined,
    _TournamentConsoleTab.stream => Icons.sensors_rounded,
  };
}

class _TournamentConsole extends StatelessWidget {
  const _TournamentConsole({
    required this.snapshot,
    required this.focusedGameId,
    required this.tabId,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onFocusGame,
  });

  final TournamentSnapshot snapshot;
  final String? focusedGameId;
  final String tabId;
  final _TournamentConsoleTab selectedTab;
  final ValueChanged<_TournamentConsoleTab> onTabChanged;
  final ValueChanged<String> onFocusGame;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TournamentConsoleTabs(
          selected: selectedTab,
          onChanged: onTabChanged,
          snapshot: snapshot,
        ),
        const Divider(height: 1, color: kDividerColor),
        Expanded(
          child: switch (selectedTab) {
            _TournamentConsoleTab.live => _LiveBrowser(
              snapshot: snapshot,
              focusedGameId: focusedGameId,
              tabId: tabId,
              onFocusGame: onFocusGame,
            ),
            _TournamentConsoleTab.standings => _StandingsBoard(
              snapshot: snapshot,
            ),
            _TournamentConsoleTab.bracket => _BracketBoard(
              snapshot: snapshot,
              onFocusGame: onFocusGame,
            ),
            _TournamentConsoleTab.stream => _StreamBoard(snapshot: snapshot),
          },
        ),
      ],
    );
  }
}

class _TournamentConsoleTabs extends StatelessWidget {
  const _TournamentConsoleTabs({
    required this.selected,
    required this.onChanged,
    required this.snapshot,
  });

  final _TournamentConsoleTab selected;
  final ValueChanged<_TournamentConsoleTab> onChanged;
  final TournamentSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBlack2Color,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            DesktopSegmentedTabs<_TournamentConsoleTab>(
              selected: selected,
              onChanged: onChanged,
              tabs: [
                for (final tab in _TournamentConsoleTab.values)
                  DesktopSegmentedTab(
                    value: tab,
                    label: tab.label,
                    icon: tab.icon,
                  ),
              ],
            ),
            const Spacer(),
            if (snapshot.resourceAssessment.shouldWarn)
              _ResourceBadge(assessment: snapshot.resourceAssessment),
          ],
        ),
      ),
    );
  }
}

class _TournamentHeader extends ConsumerWidget {
  const _TournamentHeader({required this.state});

  final TournamentServerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = state.snapshot;
    final indicator = switch (state.status) {
      TournamentServerStatus.running => kGreenColor,
      TournamentServerStatus.starting ||
      TournamentServerStatus.stopping => kPrimaryColor,
      TournamentServerStatus.error => kRedColor,
      TournamentServerStatus.stopped => kSecondaryTextColor,
    };
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        color: kBlack2Color,
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: indicator,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot == null
                        ? 'Tournament arena: ${_arenaStatusLabel(state.status)}'
                        : '${snapshot.config.title}: ${snapshot.isRunning ? 'Streaming' : 'Stopped'}',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    state.error != null
                        ? _friendlyArenaError(state.error!)
                        : snapshot == null
                        ? _arenaStatusMessage(state.status)
                        : _snapshotStatusMessage(snapshot),
                    style: TextStyle(
                      color:
                          state.error != null ? kRedColor : kSecondaryTextColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            _TournamentRunControl(state: state),
            if (snapshot != null) ...[
              const SizedBox(width: 8),
              _TournamentAbortControl(state: state),
              const SizedBox(width: 8),
              FButton(
                style: playSecondaryActionButtonStyle(),
                prefix: const Icon(Icons.add_circle_outline_rounded),
                onPress:
                    state.status == TournamentServerStatus.starting ||
                            state.status == TournamentServerStatus.stopping
                        ? null
                        : () => _openCreateTournament(context, ref),
                child: const Text('New event'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TournamentRunControl extends ConsumerWidget {
  const _TournamentRunControl({required this.state});

  final TournamentServerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = state.snapshot;
    final busy =
        state.status == TournamentServerStatus.starting ||
        state.status == TournamentServerStatus.stopping;
    final completed = snapshot != null && _snapshotCompleted(snapshot);
    final isRunning = snapshot?.isRunning == true;
    final style =
        isRunning
            ? playDangerActionButtonStyle()
            : playPrimaryActionButtonStyle();
    final icon =
        snapshot == null
            ? Icons.add_circle_outline_rounded
            : isRunning
            ? Icons.stop_circle_outlined
            : completed
            ? Icons.restart_alt_rounded
            : Icons.play_arrow_rounded;
    final label =
        snapshot == null
            ? 'Start tournament'
            : isRunning
            ? 'Stop tournament'
            : completed
            ? 'Restart tournament'
            : 'Continue tournament';
    return FButton(
      style: style,
      prefix: Icon(icon),
      onPress:
          busy
              ? null
              : () {
                if (snapshot == null) {
                  unawaited(_openCreateTournament(context, ref));
                } else if (isRunning) {
                  unawaited(_stopTournamentStream(context, ref));
                } else if (completed) {
                  unawaited(_restartTournamentStream(context, ref));
                } else {
                  unawaited(_continueTournamentStream(context, ref));
                }
              },
      child: Text(label),
    );
  }
}

class _TournamentAbortControl extends ConsumerWidget {
  const _TournamentAbortControl({required this.state});

  final TournamentServerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy =
        state.status == TournamentServerStatus.starting ||
        state.status == TournamentServerStatus.stopping;
    final snapshot = state.snapshot;
    final completed = snapshot != null && _snapshotCompleted(snapshot);
    return FButton(
      style: playDangerActionButtonStyle(),
      prefix: const Icon(Icons.cancel_outlined),
      onPress:
          busy || snapshot == null || completed
              ? null
              : () => unawaited(_abortTournamentStream(context, ref)),
      child: const Text('Abort tournament'),
    );
  }
}

bool _snapshotCompleted(TournamentSnapshot snapshot) {
  return snapshot.games.isNotEmpty &&
      snapshot.games.every(
        (game) => game.status == TournamentGameStatus.finished,
      );
}

String _arenaStatusLabel(TournamentServerStatus status) {
  return switch (status) {
    TournamentServerStatus.running => 'Ready',
    TournamentServerStatus.starting => 'Preparing',
    TournamentServerStatus.stopping => 'Closing',
    TournamentServerStatus.error => 'Needs attention',
    TournamentServerStatus.stopped => 'Ready to create',
  };
}

String _arenaStatusMessage(TournamentServerStatus status) {
  return switch (status) {
    TournamentServerStatus.running => 'Ready for tournaments.',
    TournamentServerStatus.starting => 'Preparing the tournament arena.',
    TournamentServerStatus.stopping => 'Closing the current tournament event.',
    TournamentServerStatus.error =>
      'Create a tournament again when the issue is resolved.',
    TournamentServerStatus.stopped => 'Create a tournament to open the arena.',
  };
}

String _snapshotStatusMessage(TournamentSnapshot snapshot) {
  if (_snapshotCompleted(snapshot)) {
    return 'Event complete. Start a new event or restart this stream.';
  }
  final userGames = snapshot.games.where(snapshot.isHumanGame).length;
  if (snapshot.isRunning && userGames > 0) {
    return 'Your board starts automatically. Use the rail to observe other games.';
  }
  if (snapshot.isRunning) {
    return 'Engine games are streaming. You can stop or restart the stream.';
  }
  return 'Stream stopped. Restart it or create a new event.';
}

String _friendlyArenaError(String error) {
  return error
      .replaceAll('server', 'tournament arena')
      .replaceAll('Server', 'Tournament arena')
      .replaceAll('Start', 'Create');
}

Future<void> _openCreateTournament(BuildContext context, WidgetRef ref) async {
  final state = ref.read(tournamentServerProvider);
  if (state.status != TournamentServerStatus.running) {
    final ready = await ref.read(tournamentServerProvider.notifier).start();
    if (!ready || !context.mounted) return;
  }
  final cfg = await showFDialog<TournamentConfig>(
    context: context,
    builder:
        (ctx, _, animation) => _CreateTournamentDialog(animation: animation),
  );
  if (cfg == null) return;
  await ref.read(tournamentServerProvider.notifier).launchTournament(cfg);
  unawaited(
    ref.read(playAchievementsProvider.notifier).recordTournamentCreated(cfg),
  );
}

Future<void> _stopTournamentStream(BuildContext context, WidgetRef ref) async {
  final ok = await showFDialog<bool>(
    context: context,
    builder:
        (ctx, _, animation) => FDialog(
          animation: animation,
          direction: Axis.horizontal,
          title: const Text('Stop stream?'),
          body: const Text(
            'The current engines stop immediately and the local event record is kept.',
          ),
          actions: [
            FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.close_rounded),
              onPress: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FButton(
              style: playDangerActionButtonStyle(),
              prefix: const Icon(Icons.stop_circle_outlined),
              onPress: () => Navigator.of(ctx).pop(true),
              child: const Text('Stop'),
            ),
          ],
        ),
  );
  if (ok == true) {
    await ref.read(tournamentServerProvider.notifier).stopTournamentStream();
  }
}

Future<void> _abortTournamentStream(BuildContext context, WidgetRef ref) async {
  final ok = await showFDialog<bool>(
    context: context,
    builder:
        (ctx, _, animation) => FDialog(
          animation: animation,
          direction: Axis.horizontal,
          title: const Text('Abort tournament?'),
          body: const Text(
            'This ends the local tournament now, saves the current snapshot to event history, and clears the arena.',
          ),
          actions: [
            FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.close_rounded),
              onPress: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FButton(
              style: playDangerActionButtonStyle(),
              prefix: const Icon(Icons.cancel_outlined),
              onPress: () => Navigator.of(ctx).pop(true),
              child: const Text('Abort'),
            ),
          ],
        ),
  );
  if (ok != true) return;
  final aborted =
      await ref.read(tournamentServerProvider.notifier).abortTournamentStream();
  if (aborted == null) return;
  await saveTournamentEventSnapshot(
    ref,
    aborted,
    statusOverride: PlayedTournamentStatus.aborted,
  );
}

Future<void> _restartTournamentStream(
  BuildContext context,
  WidgetRef ref,
) async {
  final ok = await showFDialog<bool>(
    context: context,
    builder:
        (ctx, _, animation) => FDialog(
          animation: animation,
          direction: Axis.horizontal,
          title: const Text('Restart stream?'),
          body: const Text(
            'This starts a fresh copy of the same event settings from round one.',
          ),
          actions: [
            FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.close_rounded),
              onPress: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FButton(
              style: playPrimaryActionButtonStyle(),
              prefix: const Icon(Icons.restart_alt_rounded),
              onPress: () => Navigator.of(ctx).pop(true),
              child: const Text('Restart'),
            ),
          ],
        ),
  );
  if (ok == true) {
    await ref.read(tournamentServerProvider.notifier).restartTournamentStream();
  }
}

Future<void> _continueTournamentStream(
  BuildContext context,
  WidgetRef ref,
) async {
  await ref.read(tournamentServerProvider.notifier).continueTournamentStream();
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.emoji_events_outlined,
                color: kSecondaryTextColor,
                size: 56,
              ),
              const SizedBox(height: 16),
              const Text(
                'No tournament running',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Select New event. Include yourself to get playable pairings, '
                'or run a pure engine stream to watch.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveBrowser extends StatelessWidget {
  const _LiveBrowser({
    required this.snapshot,
    required this.focusedGameId,
    required this.tabId,
    required this.onFocusGame,
  });

  final TournamentSnapshot snapshot;
  final String? focusedGameId;
  final String tabId;
  final ValueChanged<String> onFocusGame;

  @override
  Widget build(BuildContext context) {
    final TournamentGame focused =
        (focusedGameId != null ? snapshot.gameById(focusedGameId!) : null) ??
        _defaultFocusedGame(snapshot, null) ??
        const TournamentGame(
          id: '',
          round: 0,
          whiteId: '',
          blackId: '',
          status: TournamentGameStatus.scheduled,
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _LiveGamesRail(
            snapshot: snapshot,
            focusedGameId: focused.id,
            onFocusGame: onFocusGame,
          ),
        ),
        const VerticalDivider(width: 1, color: kDividerColor),
        Expanded(
          child: _FocusedGameView(
            snapshot: snapshot,
            game: focused,
            tabId: tabId,
          ),
        ),
        const VerticalDivider(width: 1, color: kDividerColor),
        SizedBox(width: 260, child: _StandingsRail(snapshot: snapshot)),
      ],
    );
  }
}

class _LiveGamesRail extends StatelessWidget {
  const _LiveGamesRail({
    required this.snapshot,
    required this.focusedGameId,
    required this.onFocusGame,
  });

  final TournamentSnapshot snapshot;
  final String focusedGameId;
  final ValueChanged<String> onFocusGame;

  @override
  Widget build(BuildContext context) {
    final rounds = _roundGroupsForLiveRail(snapshot);
    return Container(
      color: kBlack2Color,
      child: ListView.separated(
        padding: const EdgeInsets.all(10),
        itemCount: rounds.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, idx) {
          final round = rounds[idx];
          return _LiveRoundCard(
            snapshot: snapshot,
            round: round,
            focusedGameId: focusedGameId,
            onFocusGame: onFocusGame,
          );
        },
      ),
    );
  }
}

class _LiveRoundGroup {
  const _LiveRoundGroup({required this.round, required this.games});

  final int round;
  final List<TournamentGame> games;

  int get finished =>
      games
          .where((game) => game.status == TournamentGameStatus.finished)
          .length;

  int get live =>
      games
          .where((game) => game.status == TournamentGameStatus.inProgress)
          .length;
}

List<_LiveRoundGroup> _roundGroupsForLiveRail(TournamentSnapshot snapshot) {
  final byRound = <int, List<TournamentGame>>{};
  for (final game in snapshot.games) {
    byRound.putIfAbsent(game.round, () => <TournamentGame>[]).add(game);
  }
  final rounds = byRound.keys.toList()..sort();
  return [
    for (final round in rounds)
      _LiveRoundGroup(
        round: round,
        games:
            (byRound[round]!..sort((a, b) {
              final human = _liveGameHumanRank(
                snapshot,
                a,
              ).compareTo(_liveGameHumanRank(snapshot, b));
              if (human != 0) return human;
              final status = _liveGameStatusRank(
                a.status,
              ).compareTo(_liveGameStatusRank(b.status));
              if (status != 0) return status;
              return a.id.compareTo(b.id);
            })),
      ),
  ];
}

int _liveGameStatusRank(TournamentGameStatus status) {
  return switch (status) {
    TournamentGameStatus.inProgress => 0,
    TournamentGameStatus.scheduled => 1,
    TournamentGameStatus.finished => 2,
  };
}

int _liveGameHumanRank(TournamentSnapshot snapshot, TournamentGame game) {
  return snapshot.isHumanGame(game) &&
          game.status != TournamentGameStatus.finished
      ? 0
      : 1;
}

class _LiveRoundCard extends StatelessWidget {
  const _LiveRoundCard({
    required this.snapshot,
    required this.round,
    required this.focusedGameId,
    required this.onFocusGame,
  });

  final TournamentSnapshot snapshot;
  final _LiveRoundGroup round;
  final String focusedGameId;
  final ValueChanged<String> onFocusGame;

  @override
  Widget build(BuildContext context) {
    final status = _roundRailStatus(snapshot, round);
    final color = status.color;
    final gameLabel =
        round.games.length == 1 ? '1 game' : '${round.games.length} games';
    return Container(
      decoration: BoxDecoration(
        color: kBackgroundColor,
        border: Border.all(
          color:
              round.round == snapshot.currentRound
                  ? color.withValues(alpha: 0.46)
                  : kDividerColor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  border: Border.all(color: color.withValues(alpha: 0.38)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  status.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Round ${round.round}',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$gameLabel • ${round.finished}/${round.games.length}',
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 10,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < round.games.length; i++) ...[
            _LiveGameCard(
              snapshot: snapshot,
              game: round.games[i],
              selected: round.games[i].id == focusedGameId,
              onTap: () => onFocusGame(round.games[i].id),
            ),
            if (i != round.games.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

({String label, Color color}) _roundRailStatus(
  TournamentSnapshot snapshot,
  _LiveRoundGroup round,
) {
  if (round.live > 0) return (label: 'LIVE', color: kGreenColor);
  if (round.finished == round.games.length) {
    return (label: 'DONE', color: kLightGreyColor);
  }
  if (round.round == snapshot.currentRound) {
    return (label: 'NOW', color: kPrimaryColor);
  }
  return (label: 'NEXT', color: kSecondaryTextColor);
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final TournamentGameStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TournamentGameStatus.inProgress => kGreenColor,
      TournamentGameStatus.scheduled => kSecondaryTextColor,
      TournamentGameStatus.finished => kWhiteColor70,
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _PairingLine extends StatelessWidget {
  const _PairingLine({required this.participant, required this.isWhite});
  final TournamentParticipant? participant;
  final bool isWhite;

  @override
  Widget build(BuildContext context) {
    final part = participant;
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 12,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child:
                part == null
                    ? Container(color: kBlack3Color)
                    : CountryFlag.fromCountryCode(part.identity.countryCode),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: isWhite ? kWhiteColor : kBlackColor,
            border: Border.all(color: kDividerColor),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Row(
            children: [
              if ((part?.identity.title ?? '').isNotEmpty) ...[
                _TitlePill(title: part!.identity.title!),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  part?.identity.fullName ?? 'TBD',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (part != null) ...[
          const SizedBox(width: 7),
          Text(
            '${part.identity.elo}',
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.16),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.38)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _FocusedGameView extends ConsumerStatefulWidget {
  const _FocusedGameView({
    required this.snapshot,
    required this.game,
    required this.tabId,
  });

  final TournamentSnapshot snapshot;
  final TournamentGame game;
  final String tabId;

  @override
  ConsumerState<_FocusedGameView> createState() => _FocusedGameViewState();
}

class _FocusedGameViewState extends ConsumerState<_FocusedGameView> {
  String? _lastSoundKey;

  @override
  void didUpdateWidget(covariant _FocusedGameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybePlayFocusedGameSound(oldWidget.game, widget.game);
  }

  void _maybePlayFocusedGameSound(TournamentGame oldGame, TournamentGame game) {
    if (game.id.isEmpty || game.movesUci.isEmpty) return;
    final key = '${game.id}:${game.movesUci.length}:${game.lastMoveUci}';
    if (key == _lastSoundKey) return;
    if (oldGame.id == game.id &&
        oldGame.movesUci.length == game.movesUci.length) {
      return;
    }
    final settings = ref.read(boardSettingsProviderNew).valueOrNull;
    if (settings?.soundEnabled == false) return;
    _lastSoundKey = key;
    final san = _lastMoveSan(game);
    if (san == null) {
      AudioPlayerService.instance.playSound(SfxType.move);
    } else {
      AudioPlayerService.instance.playSfxForSan(san);
    }
  }

  String? _lastMoveSan(TournamentGame game) {
    final last = game.movesUci.isEmpty ? null : game.movesUci.last;
    if (last == null) return null;
    try {
      Position position = Position.setupPosition(
        Rule.chess,
        Setup.parseFen(game.startingFen ?? Chess.initial.fen),
      );
      for (final uci in game.movesUci.take(game.movesUci.length - 1)) {
        final move = NormalMove.fromUci(uci);
        position = position.play(move);
      }
      final move = NormalMove.fromUci(last);
      return position.makeSan(move).$2;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final game = widget.game;
    if (game.id.isEmpty) {
      return const _EmptyFocus();
    }
    final activeTabId =
        ref.watch(desktopTabsProvider.select((state) => state.activeId)) ??
        'play-tournament-orphan';
    final activeSession = ref.watch(
      playSessionArgsByTabIdProvider.select(
        (sessions) => sessions[activeTabId],
      ),
    );
    final activeTournament = activeSession?.tournamentContext;
    if (activeTournament?.tournamentId == snapshot.config.id &&
        activeTournament?.gameId == game.id &&
        snapshot.isHumanGame(game) &&
        game.status != TournamentGameStatus.finished) {
      return PlayActiveGameView(tabId: activeTabId);
    }
    final w = snapshot.participantById(game.whiteId);
    final b = snapshot.participantById(game.blackId);
    final humanSide =
        w?.isHuman == true
            ? Side.white
            : b?.isHuman == true
            ? Side.black
            : null;
    final fen = game.fen ?? Chess.initial.fen;
    Position position;
    try {
      position = Position.setupPosition(Rule.chess, Setup.parseFen(fen));
    } catch (_) {
      position = Chess.initial;
    }
    return LayoutBuilder(
      builder: (context, c) {
        final boardSize = [
          (c.maxWidth - 48),
          (c.maxHeight - 200),
          640.0,
        ].reduce((a, b) => a < b ? a : b);
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: DesktopPlayFromHereButton(
                  onPress:
                      () => showPlayFromHereDialog(
                        context,
                        ref,
                        seed: PlayFromHereSeed(
                          fen: fen,
                          inheritedWhiteBaseSeconds: _clockSecondsForGame(
                            game,
                            Side.white,
                          ),
                          inheritedWhiteIncrementSeconds:
                              game.incrementSecondsOverride ??
                              snapshot.config.incrementSeconds,
                          inheritedBlackBaseSeconds: _clockSecondsForGame(
                            game,
                            Side.black,
                          ),
                          inheritedBlackIncrementSeconds:
                              game.incrementSecondsOverride ??
                              snapshot.config.incrementSeconds,
                        ),
                      ),
                ),
              ),
              const SizedBox(height: 10),
              _ParticipantRow(
                participant: b,
                clockMillis: game.blackMillis ?? 0,
                clockUpdatedAt: game.clockUpdatedAt,
                isActive:
                    game.status == TournamentGameStatus.inProgress &&
                    position.turn == Side.black,
                isWhite: false,
              ),
              const SizedBox(height: 10),
              Center(
                child: SizedBox.square(
                  dimension: boardSize,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapUp:
                        (_) => showPlayFromHereDialog(
                          context,
                          ref,
                          seed: PlayFromHereSeed(
                            fen: fen,
                            inheritedWhiteBaseSeconds: _clockSecondsForGame(
                              game,
                              Side.white,
                            ),
                            inheritedWhiteIncrementSeconds:
                                game.incrementSecondsOverride ??
                                snapshot.config.incrementSeconds,
                            inheritedBlackBaseSeconds: _clockSecondsForGame(
                              game,
                              Side.black,
                            ),
                            inheritedBlackIncrementSeconds:
                                game.incrementSecondsOverride ??
                                snapshot.config.incrementSeconds,
                          ),
                        ),
                    child: DesktopChessBoard(
                      key: ValueKey<String>('tournament-game-board:${game.id}'),
                      size: boardSize,
                      fen: fen,
                      orientation: humanSide ?? Side.white,
                      playerSide: cg.PlayerSide.none,
                      sideToMove: position.turn,
                      validMoves: const IMapConst<Square, ISet<Square>>({}),
                      lastMove: _parseLastMove(game.lastMoveUci),
                      isCheck: position.isCheck,
                      onMove: (_, {viaDragAndDrop}) {},
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _ParticipantRow(
                participant: w,
                clockMillis: game.whiteMillis ?? 0,
                clockUpdatedAt: game.clockUpdatedAt,
                isActive:
                    game.status == TournamentGameStatus.inProgress &&
                    position.turn == Side.white,
                isWhite: true,
              ),
              const SizedBox(height: 14),
              if (game.ecoLine != null)
                Text(
                  '${game.ecoLine}',
                  style: const TextStyle(
                    color: kPrimaryColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (game.endReason != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${game.result ?? ''} • ${game.endReason}',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
              if (snapshot.isHumanGame(game) &&
                  game.status != TournamentGameStatus.finished) ...[
                const SizedBox(height: 12),
                _HumanTournamentGameAction(
                  snapshot: snapshot,
                  game: game,
                  tabId: widget.tabId,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  NormalMove? _parseLastMove(String? uci) {
    if (uci == null || uci.isEmpty) return null;
    try {
      return NormalMove.fromUci(uci);
    } catch (_) {
      return null;
    }
  }
}

class _HumanTournamentGameAction extends ConsumerWidget {
  const _HumanTournamentGameAction({
    required this.snapshot,
    required this.game,
    required this.tabId,
  });

  final TournamentSnapshot snapshot;
  final TournamentGame game;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final humanIsWhite = snapshot.isHumanParticipant(game.whiteId);
    final opponent = snapshot.participantById(
      humanIsWhite ? game.blackId : game.whiteId,
    );
    if (opponent == null) return const SizedBox.shrink();
    final install = ref.watch(engineInstallProvider(opponent.engine));
    final ready = engineReady(install);
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        decoration: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: 0.10),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.36)),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.sports_esports_outlined, color: kPrimaryColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ready
                    ? 'This is your board against ${opponent.identity.displayName}.'
                    : '${opponent.engine.displayName} must finish installing before this board can start.',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FButton(
              style: playPrimaryActionButtonStyle(),
              prefix: const Icon(Icons.play_arrow_rounded),
              onPress:
                  ready
                      ? () => _startHumanTournamentGame(
                        ref,
                        snapshot: snapshot,
                        game: game,
                        opponent: opponent,
                        humanIsWhite: humanIsWhite,
                        tabId: tabId,
                      )
                      : null,
              child: Text(
                game.status == TournamentGameStatus.inProgress
                    ? 'Return to board'
                    : 'Start my game',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _startHumanTournamentGame(
  WidgetRef ref, {
  required TournamentSnapshot snapshot,
  required TournamentGame game,
  required TournamentParticipant opponent,
  required bool humanIsWhite,
  String? tabId,
}) {
  final binaryPath = engineBinaryPathFor(ref, opponent.engine);
  if (binaryPath == null) return false;
  final started =
      ref
          .read(tournamentServerProvider.notifier)
          .markHumanGameStarted(game.id) ??
      game;
  final activeTabId =
      tabId ??
      ref.read(desktopTabsProvider).activeId ??
      'play-tournament-orphan';
  final existingArgs = ref.read(playSessionArgsByTabIdProvider)[activeTabId];
  final existingContext = existingArgs?.tournamentContext;
  final replacesExistingSession =
      existingArgs != null &&
      (existingContext?.tournamentId != snapshot.config.id ||
          existingContext?.gameId != game.id);
  final baseSeconds =
      started.baseSecondsOverride ?? snapshot.config.baseSeconds;
  final incrementSeconds =
      started.incrementSecondsOverride ?? snapshot.config.incrementSeconds;
  final config = PlayConfig(
    engine: opponent.engine,
    elo: opponent.identity.elo,
    category: _categoryForSeconds(baseSeconds),
    baseSeconds: baseSeconds,
    incrementSeconds: incrementSeconds,
    color: humanIsWhite ? PlayColorChoice.white : PlayColorChoice.black,
    startClockImmediately: true,
    startingFen: _startingFenForGame(snapshot, started),
  );
  ref.read(playSessionArgsByTabIdProvider.notifier).update((sessions) {
    return <String, PlaySessionArgs>{
      ...sessions,
      activeTabId: PlaySessionArgs(
        config: config,
        engineBinaryPath: binaryPath,
        botIdentity: opponent.identity,
        tournamentContext: PlayTournamentContext(
          tournamentId: snapshot.config.id,
          tournamentTitle: snapshot.config.title,
          gameId: game.id,
          round: game.round,
        ),
      ),
    };
  });
  if (replacesExistingSession) {
    ref.invalidate(playSessionProviderFor(activeTabId));
  }
  return true;
}

String _startingFenForGame(TournamentSnapshot snapshot, TournamentGame game) {
  final existing = game.startingFen ?? game.fen;
  if (existing != null && existing.isNotEmpty) return existing;
  if (snapshot.config.ecoLines.isEmpty) return Chess.initial.fen;
  return snapshot
      .config
      .ecoLines[(game.round - 1) % snapshot.config.ecoLines.length]
      .fen;
}

TimeControlCategory _categoryForSeconds(int seconds) {
  if (seconds <= 120) return TimeControlCategory.bullet;
  if (seconds <= 300) return TimeControlCategory.blitz;
  if (seconds <= 1800) return TimeControlCategory.rapid;
  return TimeControlCategory.classical;
}

int? _clockSecondsForGame(TournamentGame game, Side side) {
  final millis = side == Side.white ? game.whiteMillis : game.blackMillis;
  if (millis == null || millis <= 0) return null;
  return (millis / 1000).ceil();
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.participant,
    required this.clockMillis,
    required this.clockUpdatedAt,
    required this.isActive,
    required this.isWhite,
  });

  final TournamentParticipant? participant;
  final int clockMillis;
  final DateTime? clockUpdatedAt;
  final bool isActive;
  final bool isWhite;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          height: 24,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child:
                participant == null
                    ? Container(color: kBlack3Color)
                    : CountryFlag.fromCountryCode(
                      participant!.identity.countryCode,
                    ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if ((participant?.identity.title ?? '').isNotEmpty) ...[
                    _TitlePill(title: participant!.identity.title!),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      participant?.identity.fullName ?? 'Unknown',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (participant != null)
                    Text(
                      '(${participant!.identity.elo})',
                      style: const TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              if ((participant?.identity.nickname ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '@${participant!.identity.nickname}',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        _LiveClockBadge(
          clockMillis: clockMillis,
          isActive: isActive,
          clockUpdatedAt: clockUpdatedAt,
          fontSize: 18,
          horizontalPadding: 12,
          verticalPadding: 6,
        ),
      ],
    );
  }
}

class _LiveClockBadge extends StatelessWidget {
  const _LiveClockBadge({
    required this.clockMillis,
    required this.isActive,
    required this.clockUpdatedAt,
    required this.fontSize,
    required this.horizontalPadding,
    required this.verticalPadding,
  });

  final int clockMillis;
  final bool isActive;
  final DateTime? clockUpdatedAt;
  final double fontSize;
  final double horizontalPadding;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream:
          isActive
              ? Stream.periodic(const Duration(seconds: 1), (tick) => tick)
              : null,
      builder: (context, _) {
        final displayMillis = _displayClockMillis(
          clockMillis: clockMillis,
          isActive: isActive,
          clockUpdatedAt: clockUpdatedAt,
        );
        final color =
            isActive
                ? (displayMillis < 10000 ? kRedColor : kPrimaryColor)
                : kWhiteColor70;
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.12) : kBlack3Color,
            border: Border.all(color: isActive ? color : kDividerColor),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            formatClock(displayMillis),
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

int _displayClockMillis({
  required int clockMillis,
  required bool isActive,
  required DateTime? clockUpdatedAt,
}) {
  if (!isActive || clockUpdatedAt == null) return clockMillis;
  final elapsed = DateTime.now().difference(clockUpdatedAt).inMilliseconds;
  if (elapsed <= 0) return clockMillis;
  return max(0, clockMillis - elapsed);
}

class _EmptyFocus extends StatelessWidget {
  const _EmptyFocus();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Pick a game from the rail to watch',
        style: TextStyle(color: kSecondaryTextColor, fontSize: 13),
      ),
    );
  }
}

class _StandingsRail extends StatefulWidget {
  const _StandingsRail({required this.snapshot});
  final TournamentSnapshot snapshot;

  static const double rowHeight = 44.0;

  @override
  State<_StandingsRail> createState() => _StandingsRailState();
}

class _StandingsRailState extends State<_StandingsRail> {
  final Map<String, int> _previousRanks = <String, int>{};

  @override
  void initState() {
    super.initState();
    _syncRanks(widget.snapshot);
  }

  @override
  void didUpdateWidget(covariant _StandingsRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.snapshot, widget.snapshot)) {
      _syncRanks(widget.snapshot);
    }
  }

  void _syncRanks(TournamentSnapshot snapshot) {
    final seen = <String>{};
    for (var i = 0; i < snapshot.standings.length; i++) {
      final id = snapshot.standings[i].participantId;
      seen.add(id);
      _previousRanks.putIfAbsent(id, () => i);
    }
    _previousRanks.removeWhere((id, _) => !seen.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final standings = widget.snapshot.standings;
    return Container(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.snapshot.config.title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.snapshot.config.format.displayName} • '
                  'Round ${widget.snapshot.currentRound}/${widget.snapshot.totalRounds}',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                height: standings.length * _StandingsRail.rowHeight,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    for (int idx = 0; idx < standings.length; idx++)
                      _AnimatedStandingRow(
                        key: ValueKey<String>(standings[idx].participantId),
                        rank: idx + 1,
                        previousRank:
                            (_previousRanks[standings[idx].participantId] ??
                                idx) +
                            1,
                        top: idx * _StandingsRail.rowHeight,
                        standing: standings[idx],
                        participant: widget.snapshot.participantById(
                          standings[idx].participantId,
                        ),
                        onSettled: () {
                          _previousRanks[standings[idx].participantId] = idx;
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedStandingRow extends StatelessWidget {
  const _AnimatedStandingRow({
    super.key,
    required this.rank,
    required this.previousRank,
    required this.top,
    required this.standing,
    required this.participant,
    required this.onSettled,
  });

  final int rank;
  final int previousRank;
  final double top;
  final TournamentStanding standing;
  final TournamentParticipant? participant;
  final VoidCallback onSettled;

  @override
  Widget build(BuildContext context) {
    final delta = previousRank - rank;
    final highlight =
        delta > 0
            ? const Color(0xFF34C759).withValues(alpha: 0.18)
            : delta < 0
            ? const Color(0xFFFF3B30).withValues(alpha: 0.15)
            : Colors.transparent;
    return SingleMotionBuilder(
      motion: const CupertinoMotion.snappy(
        duration: Duration(milliseconds: 520),
      ),
      value: top,
      onAnimationStatusChanged: (status) {
        if (status == AnimationStatus.completed) onSettled();
      },
      builder: (context, value, child) {
        return Positioned(
          left: 0,
          right: 0,
          top: value,
          height: _StandingsRail.rowHeight,
          child: child!,
        );
      },
      child: _StandingRowContent(
        rank: rank,
        delta: delta,
        highlight: highlight,
        standing: standing,
        participant: participant,
      ),
    );
  }
}

class _StandingRowContent extends StatelessWidget {
  const _StandingRowContent({
    required this.rank,
    required this.delta,
    required this.highlight,
    required this.standing,
    required this.participant,
  });

  final int rank;
  final int delta;
  final Color highlight;
  final TournamentStanding standing;
  final TournamentParticipant? participant;

  @override
  Widget build(BuildContext context) {
    final points = standing.points.toStringAsFixed(
      standing.points == standing.points.truncate() ? 0 : 1,
    );
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: highlight, end: Colors.transparent),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOut,
      builder: (context, color, child) {
        return Container(color: color, child: child);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Row(
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          transitionBuilder: (child, anim) {
                            final offset = Tween<Offset>(
                              begin: Offset(0, delta >= 0 ? 0.6 : -0.6),
                              end: Offset.zero,
                            ).animate(anim);
                            return ClipRect(
                              child: SlideTransition(
                                position: offset,
                                child: FadeTransition(
                                  opacity: anim,
                                  child: child,
                                ),
                              ),
                            );
                          },
                          child: Text(
                            '#$rank',
                            key: ValueKey<int>(rank),
                            style: const TextStyle(
                              color: kSecondaryTextColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Text(
                      participant?.identity.displayName ?? 'Unknown',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (delta != 0) ...[
                    Icon(
                      delta > 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      size: 16,
                      color:
                          delta > 0
                              ? const Color(0xFF34C759)
                              : const Color(0xFFFF3B30),
                    ),
                    const SizedBox(width: 2),
                  ],
                  Text(
                    points,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${standing.played})',
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: kDividerColor),
        ],
      ),
    );
  }
}

class _StandingsBoard extends StatelessWidget {
  const _StandingsBoard({required this.snapshot});

  final TournamentSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          border: Border.all(color: kDividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _StandingsRail(snapshot: snapshot),
      ),
    );
  }
}

class _BracketBoard extends StatelessWidget {
  const _BracketBoard({required this.snapshot, required this.onFocusGame});

  final TournamentSnapshot snapshot;
  final ValueChanged<String> onFocusGame;

  @override
  Widget build(BuildContext context) {
    final byRound = <int, List<TournamentGame>>{};
    for (final game in snapshot.games) {
      byRound.putIfAbsent(game.round, () => <TournamentGame>[]).add(game);
    }
    final rounds = byRound.keys.toList()..sort();
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      scrollDirection: Axis.horizontal,
      itemCount: rounds.length,
      separatorBuilder: (_, __) => const SizedBox(width: 14),
      itemBuilder: (context, index) {
        final round = rounds[index];
        final games = byRound[round]!..sort((a, b) => a.id.compareTo(b.id));
        return SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Round $round',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: games.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder:
                      (context, i) => _LiveGameCard(
                        snapshot: snapshot,
                        game: games[i],
                        onTap: () => onFocusGame(games[i].id),
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StreamBoard extends StatelessWidget {
  const _StreamBoard({required this.snapshot});

  final TournamentSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final moves =
        [
          for (final game in snapshot.games)
            if (game.lastMoveUci != null)
              '${game.tiebreakLabel ?? 'Round ${game.round}'}: '
                  '${snapshot.participantById(game.whiteId)?.identity.displayName ?? 'White'} vs '
                  '${snapshot.participantById(game.blackId)?.identity.displayName ?? 'Black'} '
                  'played ${game.lastMoveUci}',
        ].reversed.toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: _InfoPanel(
              title: 'Live action',
              children: [
                const Text(
                  'ChessEver keeps moves, clocks, standings, and watched games live while the tournament runs.',
                  style: TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                for (final move in moves.take(18))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      move,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 340,
            child: _InfoPanel(
              title: 'Event performance',
              children: [
                _ResourceSummary(assessment: snapshot.resourceAssessment),
                const SizedBox(height: 14),
                Text(
                  '${snapshot.config.participants.length} players • '
                  '${snapshot.resourceAssessment.recommendedConcurrency} games at once • '
                  'this computer',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.all(color: kDividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _LiveGameCard extends StatelessWidget {
  const _LiveGameCard({
    required this.snapshot,
    required this.game,
    required this.onTap,
    this.selected = false,
  });

  final TournamentSnapshot snapshot;
  final TournamentGame game;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final white = snapshot.participantById(game.whiteId);
    final black = snapshot.participantById(game.blackId);
    final turn = _turnForGame(game);
    final border = switch (game.status) {
      TournamentGameStatus.inProgress => kPrimaryColor.withValues(alpha: 0.52),
      TournamentGameStatus.finished => kWhiteColor70.withValues(alpha: 0.20),
      TournamentGameStatus.scheduled => kDividerColor,
    };
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton.raw(
        onPress: onTap,
        style: _liveGameCardButtonStyle(selected: selected, border: border),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _StatusDot(status: game.status),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      game.tiebreakLabel ?? 'Round ${game.round}',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    game.result ?? '*',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _PairingLine(participant: white, isWhite: true),
              const SizedBox(height: 5),
              _PairingLine(participant: black, isWhite: false),
              if (game.whiteMillis != null || game.blackMillis != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    _MiniClockPill(
                      label: 'W',
                      millis: game.whiteMillis ?? 0,
                      active:
                          game.status == TournamentGameStatus.inProgress &&
                          turn == Side.white,
                      clockUpdatedAt: game.clockUpdatedAt,
                    ),
                    const SizedBox(width: 6),
                    _MiniClockPill(
                      label: 'B',
                      millis: game.blackMillis ?? 0,
                      active:
                          game.status == TournamentGameStatus.inProgress &&
                          turn == Side.black,
                      clockUpdatedAt: game.clockUpdatedAt,
                    ),
                  ],
                ),
              ],
              if (game.lastMoveUci != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last move ${game.lastMoveUci}',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                  ),
                ),
              ],
              if (game.ecoLine != null) ...[
                const SizedBox(height: 8),
                Text(
                  game.ecoLine!,
                  style: const TextStyle(
                    color: kPrimaryColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniClockPill extends StatelessWidget {
  const _MiniClockPill({
    required this.label,
    required this.millis,
    required this.active,
    required this.clockUpdatedAt,
  });

  final String label;
  final int millis;
  final bool active;
  final DateTime? clockUpdatedAt;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: active ? kPrimaryColor : kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _LiveClockBadge(
              clockMillis: millis,
              isActive: active,
              clockUpdatedAt: clockUpdatedAt,
              fontSize: 11,
              horizontalPadding: 7,
              verticalPadding: 4,
            ),
          ),
        ],
      ),
    );
  }
}

Side _turnForGame(TournamentGame game) {
  final fen = game.fen ?? game.startingFen ?? Chess.initial.fen;
  try {
    return Position.setupPosition(Rule.chess, Setup.parseFen(fen)).turn;
  } catch (_) {
    return Side.white;
  }
}

FBaseButtonStyle Function(FButtonStyle style) _liveGameCardButtonStyle({
  required bool selected,
  required Color border,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.14) : kBlack2Color,
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.84)
                    : kWhiteColor.withValues(alpha: 0.16),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.10) : kBlack3Color,
          border: Border.all(
            color: selected ? kPrimaryColor.withValues(alpha: 0.72) : border,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(padding: const EdgeInsets.all(12)),
    ),
  );
}

class _ResourceBadge extends StatelessWidget {
  const _ResourceBadge({required this.assessment});

  final TournamentResourceAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final color = switch (assessment.level) {
      TournamentResourceWarningLevel.ok => kGreenColor,
      TournamentResourceWarningLevel.caution => kPrimaryColor,
      TournamentResourceWarningLevel.unsuitable => kRedColor,
    };
    return DesktopTooltip(
      message: assessment.message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.38)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          assessment.level == TournamentResourceWarningLevel.unsuitable
              ? 'Computer warning'
              : 'Performance notice',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _ResourceSummary extends StatelessWidget {
  const _ResourceSummary({required this.assessment});

  final TournamentResourceAssessment assessment;

  @override
  Widget build(BuildContext context) {
    return Text(
      assessment.message,
      style: TextStyle(
        color:
            assessment.level == TournamentResourceWarningLevel.unsuitable
                ? kRedColor
                : kWhiteColor70,
        fontSize: 12,
        height: 1.45,
      ),
    );
  }
}

enum _TournamentEngineMode { single, mixed }

extension _TournamentEngineModeLabel on _TournamentEngineMode {
  String get label => switch (this) {
    _TournamentEngineMode.single => 'One bot type',
    _TournamentEngineMode.mixed => 'Mixed bot types',
  };
}

class _CreateTournamentDialog extends ConsumerStatefulWidget {
  const _CreateTournamentDialog({required this.animation});

  final Animation<double> animation;

  @override
  ConsumerState<_CreateTournamentDialog> createState() =>
      _CreateTournamentDialogState();
}

class _CreateTournamentDialogState
    extends ConsumerState<_CreateTournamentDialog> {
  TournamentFormat _format = TournamentFormat.roundRobin;
  int _participantCount = 8;
  TimeControlCategory _timeCategory = TimeControlCategory.blitz;
  int _baseSeconds = 180;
  int _incrementSeconds = 2;
  bool _includeUser = true;
  _TournamentEngineMode _engineMode = _TournamentEngineMode.mixed;
  BotEngineKind _engine = BotEngineKind.stockfish;
  final Set<BotEngineKind> _enginePool = {
    BotEngineKind.stockfish,
    BotEngineKind.maia,
  };
  int _eloCenter = 1800;
  int _eloJitter = 200;
  KnockoutTiebreakMode _tiebreakMode =
      KnockoutTiebreakMode.rematchThenArmageddon;
  KnockoutReseeding _reseeding = KnockoutReseeding.reseedEachRound;
  final Set<String> _selectedEcos = <String>{};
  final TextEditingController _title = TextEditingController(
    text: 'ChessEver Cup',
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resource = assessTournamentResources(
      participantCount: _participantCount,
      engines:
          _engineMode == _TournamentEngineMode.single ? [_engine] : _enginePool,
    );
    final schedule = tournamentScheduleSummary(
      format: _format,
      participantCount: _participantCount,
    );
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _CreateTournamentHeader(),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _DialogSection(
                        icon: FIcons.trophy,
                        title: 'Event',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FTextField(
                              controller: _title,
                              label: const Text('Title'),
                              hint: 'ChessEver Cup',
                              clearable: (value) => value.text.isNotEmpty,
                            ),
                            const SizedBox(height: 12),
                            _fieldRow(
                              _selectField<TournamentFormat>(
                                label: 'Format',
                                value: _format,
                                values: TournamentFormat.values,
                                format: (value) => value.displayName,
                                onChanged: (value) => _format = value,
                              ),
                              _ParticipantsField(
                                count: _participantCount,
                                onChanged:
                                    (value) => setState(
                                      () => _participantCount = value,
                                    ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _IncludeUserSwitch(
                              selected: _includeUser,
                              onChanged:
                                  (value) =>
                                      setState(() => _includeUser = value),
                            ),
                            const SizedBox(height: 12),
                            _ScheduleMathPreview(summary: schedule),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _DialogSection(
                        icon: FIcons.timer,
                        title: 'Clock',
                        child: _TimeControlPicker(
                          category: _timeCategory,
                          baseSeconds: _baseSeconds,
                          incrementSeconds: _incrementSeconds,
                          onCategoryChanged: (cat) {
                            setState(() {
                              _timeCategory = cat;
                              if (cat != TimeControlCategory.custom) {
                                final preset = kTimeControlPresets[cat]!.first;
                                _baseSeconds = preset.baseSeconds;
                                _incrementSeconds = preset.incrementSeconds;
                              }
                            });
                          },
                          onPresetSelected: (preset) {
                            setState(() {
                              _timeCategory = preset.category;
                              _baseSeconds = preset.baseSeconds;
                              _incrementSeconds = preset.incrementSeconds;
                            });
                          },
                          onBaseChanged: (v) {
                            setState(() {
                              _baseSeconds = v.clamp(10, 3600 * 4);
                              _timeCategory = TimeControlCategory.custom;
                            });
                          },
                          onIncrementChanged: (v) {
                            setState(() {
                              _incrementSeconds = v.clamp(0, 180);
                              _timeCategory = TimeControlCategory.custom;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      _DialogSection(
                        icon: FIcons.target,
                        title: 'Rating',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SliderField(
                              label: 'Target ELO',
                              value: _eloCenter,
                              min: 800,
                              max: 3200,
                              onChanged:
                                  (v) => setState(
                                    () => _eloCenter = v.clamp(800, 3200),
                                  ),
                            ),
                            const SizedBox(height: 14),
                            _SliderField(
                              label: 'ELO spread',
                              value: _eloJitter,
                              min: 0,
                              max: 600,
                              onChanged:
                                  (v) => setState(
                                    () => _eloJitter = v.clamp(0, 600),
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _DialogSection(
                        icon: FIcons.bot,
                        title: 'Bots',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _engineControls(),
                            const SizedBox(height: 12),
                            _resourcePreview(resource),
                          ],
                        ),
                      ),
                      if (_format == TournamentFormat.knockout) ...[
                        const SizedBox(height: 14),
                        _DialogSection(
                          icon: FIcons.brackets,
                          title: 'Knockout rules',
                          child: _fieldRow(
                            _selectField<KnockoutTiebreakMode>(
                              label: 'Tiebreak',
                              value: _tiebreakMode,
                              values: KnockoutTiebreakMode.values,
                              format: (value) => value.displayName,
                              onChanged: (value) => _tiebreakMode = value,
                            ),
                            _selectField<KnockoutReseeding>(
                              label: 'Seeding',
                              value: _reseeding,
                              values: KnockoutReseeding.values,
                              format: (value) => value.displayName,
                              onChanged: (value) => _reseeding = value,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _DialogSection(
                        icon: FIcons.route,
                        title: 'Openings',
                        trailing: _CountPill('${_selectedEcos.length}'),
                        child: _ecoChips(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FButton(
                      style: playSecondaryActionButtonStyle(),
                      prefix: const Icon(FIcons.x),
                      onPress: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      style: playPrimaryActionButtonStyle(),
                      prefix: const Icon(FIcons.play),
                      onPress: () => Navigator.of(context).pop(_buildConfig()),
                      child: const Text('Create and start'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  TournamentConfig _buildConfig() {
    final gen = BotIdentityGenerator(
      seed: DateTime.now().millisecondsSinceEpoch,
    );
    final botCount =
        (_includeUser ? _participantCount - 1 : _participantCount)
            .clamp(1, 16)
            .toInt();
    final identities = gen.batch(
      count: botCount,
      elo: _eloCenter,
      eloJitter: _eloJitter,
    );
    final engines = _selectedEngines();
    final rng = Random(DateTime.now().microsecondsSinceEpoch);
    final participants = <TournamentParticipant>[
      if (_includeUser) _humanParticipant(),
      for (var i = 0; i < identities.length; i++)
        TournamentParticipant(
          id: 'p$i',
          identity: identities[i],
          engine: engines[(i + rng.nextInt(engines.length)) % engines.length],
        ),
    ];
    final ecoLines = [
      for (final e in kBuiltInEcoLibrary)
        if (_selectedEcos.contains(e.eco)) e,
    ];
    return TournamentConfig(
      id: newTournamentEventId(),
      title: _title.text.trim().isEmpty ? 'ChessEver Cup' : _title.text.trim(),
      format: _format,
      baseSeconds: _baseSeconds,
      incrementSeconds: _incrementSeconds,
      participants: participants,
      ecoLines: ecoLines,
      knockoutTiebreakMode: _tiebreakMode,
      knockoutReseeding: _reseeding,
    );
  }

  TournamentParticipant _humanParticipant() {
    final profile = ref.read(playUserProfileProvider).valueOrNull;
    final displayName = profile?.displayName.trim();
    final name =
        displayName == null || displayName.isEmpty
            ? ref.read(playProfileRepositoryProvider).currentDisplayName
            : displayName;
    final parts = name.split(RegExp(r'\s+'));
    final first = parts.isEmpty || parts.first.isEmpty ? 'You' : parts.first;
    final last =
        parts.length > 1 ? parts.skip(1).join(' ') : 'ChessEver Player';
    return TournamentParticipant(
      id: 'human',
      identity: BotIdentity(
        firstName: first,
        lastName: last,
        countryCode: 'US',
        elo: profile?.headlineRating ?? 1200,
        nickname: 'you',
      ),
      engine: _selectedEngines().first,
      isHuman: true,
    );
  }

  List<BotEngineKind> _selectedEngines() {
    if (_engineMode == _TournamentEngineMode.single) return [_engine];
    if (_enginePool.isEmpty) return [_engine];
    return _enginePool.toList(growable: false);
  }

  Widget _fieldRow(Widget left, Widget right) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left, const SizedBox(height: 12), right],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ],
        );
      },
    );
  }

  Widget _selectField<T>({
    required String label,
    required T value,
    required List<T> values,
    required String Function(T value) format,
    required ValueChanged<T> onChanged,
  }) {
    return FSelect<T>.rich(
      key: ValueKey<Object?>(value),
      label: Text(label),
      initialValue: value,
      format: format,
      onChange: (next) {
        if (next == null) return;
        setState(() => onChanged(next));
      },
      children: [
        for (final option in values)
          FSelectItem<T>(title: Text(format(option)), value: option),
      ],
    );
  }

  Widget _engineControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _selectField<_TournamentEngineMode>(
          label: 'Engine lineup',
          value: _engineMode,
          values: _TournamentEngineMode.values,
          format: (value) => value.label,
          onChanged: (value) => _engineMode = value,
        ),
        const SizedBox(height: 12),
        if (_engineMode == _TournamentEngineMode.single)
          _selectField<BotEngineKind>(
            label: 'Bot type',
            value: _engine,
            values: BotEngineKind.values,
            format: (value) => value.displayName,
            onChanged: (value) => _engine = value,
          )
        else
          Column(
            children: [
              for (final engine in BotEngineKind.values) ...[
                _EngineSwitchRow(
                  engine: engine,
                  selected: _enginePool.contains(engine),
                  enabled:
                      _enginePool.contains(engine)
                          ? _enginePool.length > 1
                          : true,
                  onChanged:
                      (enabled) => setState(() {
                        if (enabled) {
                          _enginePool.add(engine);
                        } else if (_enginePool.length > 1) {
                          _enginePool.remove(engine);
                        }
                      }),
                ),
                if (engine != BotEngineKind.values.last)
                  const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }

  Widget _resourcePreview(TournamentResourceAssessment resource) {
    final color = switch (resource.level) {
      TournamentResourceWarningLevel.ok => kGreenColor,
      TournamentResourceWarningLevel.caution => kPrimaryColor,
      TournamentResourceWarningLevel.unsuitable => kRedColor,
    };
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(FIcons.cpu, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${resource.message}\nRecommended: ${resource.recommendedMaxParticipants} players, ${resource.recommendedConcurrency} concurrent games.',
              style: TextStyle(color: color, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ecoChips() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final eco in kBuiltInEcoLibrary)
          _Chip(
            label: eco.eco,
            selected: _selectedEcos.contains(eco.eco),
            onTap: () {
              setState(() {
                if (!_selectedEcos.add(eco.eco)) _selectedEcos.remove(eco.eco);
              });
            },
            tooltip: eco.label,
          ),
      ],
    );
  }
}

class _CreateTournamentHeader extends StatelessWidget {
  const _CreateTournamentHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: 0.14),
            border: Border.all(color: kPrimaryColor.withValues(alpha: 0.42)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(FIcons.trophy, color: kLightYellowColor, size: 20),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Create tournament',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Local engine arena',
                style: TextStyle(color: kSecondaryTextColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DialogSection extends StatelessWidget {
  const _DialogSection({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.10)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: kPrimaryColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.12),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.38)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ParticipantsField extends StatelessWidget {
  const _ParticipantsField({required this.count, required this.onChanged});

  final int count;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Participants',
                style: TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _CountPill('$count'),
          ],
        ),
        const SizedBox(height: 11),
        DesktopValueSlider(
          min: 2,
          max: 16,
          divisions: 14,
          value: count.toDouble(),
          onChanged: (value) => onChanged(value.round()),
          tooltipFormatter: (value) => value.round().toString(),
        ),
      ],
    );
  }
}

class _IncludeUserSwitch extends StatelessWidget {
  const _IncludeUserSwitch({required this.selected, required this.onChanged});

  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBlack3Color,
        border: Border.all(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.46)
                  : kWhiteColor.withValues(alpha: 0.10),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.person_pin_circle_outlined,
            size: 16,
            color: selected ? kPrimaryColor : kSecondaryTextColor,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Include me',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Your pairings open a playable board in this Play tab.',
                  style: TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FSwitch(value: selected, onChange: onChanged),
        ],
      ),
    );
  }
}

class _ScheduleMathPreview extends StatelessWidget {
  const _ScheduleMathPreview({required this.summary});

  final TournamentScheduleSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBlack3Color,
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.10)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.functions_rounded, size: 16, color: kPrimaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary.label,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'max ${summary.maxGamesPerRound} boards',
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineSwitchRow extends StatelessWidget {
  const _EngineSwitchRow({
    required this.engine,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final BotEngineKind engine;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBlack3Color,
        border: Border.all(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.46)
                  : kWhiteColor.withValues(alpha: 0.10),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            switch (engine) {
              BotEngineKind.stockfish => FIcons.cpu,
              BotEngineKind.leela => FIcons.brainCircuit,
              BotEngineKind.maia => FIcons.userRound,
            },
            size: 16,
            color: selected ? kPrimaryColor : kSecondaryTextColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  engine.displayName,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  engine.tagline,
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FSwitch(value: selected, enabled: enabled, onChange: onChanged),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: _tournamentChipButtonStyle(selected: selected),
        onPress: onTap,
        mainAxisSize: MainAxisSize.min,
        child: Text(label),
      ),
    );
    if (tooltip == null) return w;
    return DesktopTooltip(message: tooltip!, child: w);
  }
}

FBaseButtonStyle Function(FButtonStyle style) _tournamentChipButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.18) : kBlack2Color,
          border: Border.all(
            color:
                selected ? kPrimaryColor : kWhiteColor.withValues(alpha: 0.16),
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.14) : kBlack3Color,
          border: Border.all(
            color: selected ? kPrimaryColor : kDividerColor,
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            textStyle: FWidgetStateMap({
              WidgetState.hovered | WidgetState.pressed: TextStyle(
                color: selected ? kPrimaryColor : kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
              WidgetState.any: TextStyle(
                color: selected ? kPrimaryColor : kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            }),
          ),
    ),
  );
}

class _NumField extends StatefulWidget {
  const _NumField({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value.toString(),
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!_focus.hasFocus) {
      final desired = widget.value.toString();
      if (_c.text != desired) {
        _c.value = TextEditingValue(
          text: desired,
          selection: TextSelection.collapsed(offset: desired.length),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant _NumField old) {
    super.didUpdateWidget(old);
    if (_focus.hasFocus) return;
    if (int.tryParse(_c.text) != widget.value) {
      _c.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_handleFocusChange);
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTextField(
      controller: _c,
      focusNode: _focus,
      label: Text(widget.label),
      keyboardType: TextInputType.number,
      textAlign: TextAlign.right,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChange: (raw) {
        if (raw.isEmpty) return;
        final n = int.tryParse(raw);
        if (n == null) return;
        widget.onChanged(n);
      },
      onSubmit: (raw) {
        final n = int.tryParse(raw);
        if (n != null) widget.onChanged(n);
        _focus.unfocus();
      },
    );
  }
}

class _TimeControlPicker extends StatelessWidget {
  const _TimeControlPicker({
    required this.category,
    required this.baseSeconds,
    required this.incrementSeconds,
    required this.onCategoryChanged,
    required this.onPresetSelected,
    required this.onBaseChanged,
    required this.onIncrementChanged,
  });

  final TimeControlCategory category;
  final int baseSeconds;
  final int incrementSeconds;
  final ValueChanged<TimeControlCategory> onCategoryChanged;
  final ValueChanged<TimeControlPreset> onPresetSelected;
  final ValueChanged<int> onBaseChanged;
  final ValueChanged<int> onIncrementChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSegmentedTabs<TimeControlCategory>(
          tabs: const [
            DesktopSegmentedTab(
              value: TimeControlCategory.bullet,
              label: 'Bullet',
              icon: Icons.bolt_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.blitz,
              label: 'Blitz',
              icon: Icons.flash_on_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.rapid,
              label: 'Rapid',
              icon: Icons.timer_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.classical,
              label: 'Classical',
              icon: Icons.hourglass_bottom_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.custom,
              label: 'Custom',
              icon: Icons.tune_outlined,
            ),
          ],
          selected: category,
          onChanged: onCategoryChanged,
          expand: true,
          wrap: true,
        ),
        const SizedBox(height: 14),
        if (category == TimeControlCategory.custom)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _NumField(
                  label: 'Base (seconds)',
                  value: baseSeconds,
                  onChanged: onBaseChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumField(
                  label: 'Increment (seconds)',
                  value: incrementSeconds,
                  onChanged: onIncrementChanged,
                ),
              ),
            ],
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final preset in kTimeControlPresets[category]!)
                _TimePresetChip(
                  preset: preset,
                  selected:
                      preset.baseSeconds == baseSeconds &&
                      preset.incrementSeconds == incrementSeconds,
                  onTap: () => onPresetSelected(preset),
                ),
            ],
          ),
      ],
    );
  }
}

class _TimePresetChip extends StatelessWidget {
  const _TimePresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final TimeControlPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: _tournamentChipButtonStyle(selected: selected),
        mainAxisSize: MainAxisSize.min,
        onPress: onTap,
        child: Text(preset.shorthand),
      ),
    );
  }
}

class _SliderField extends StatelessWidget {
  const _SliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: kSecondaryTextColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            Text(
              '$value',
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DesktopValueSlider(
          min: min.toDouble(),
          max: max.toDouble(),
          value: value.clamp(min, max).toDouble(),
          onChanged: (v) => onChanged(v.round()),
          tooltipFormatter: (v) => v.round().toString(),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '$min',
              style: const TextStyle(
                color: kTertiaryTextColor,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Text(
              '$max',
              style: const TextStyle(
                color: kTertiaryTextColor,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
