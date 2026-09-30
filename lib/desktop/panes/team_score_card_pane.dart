import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/team_share_url.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_team.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show openTournamentGameTab;
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardPlayerProfileDataSourceProvider;
import 'package:chessever/screens/standings/team_avg_elo.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:chessever/screens/standings/team_standings_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart'
    show selectedBroadcastModelProvider;
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:chessever/screens/tour_detail/team_tour/team_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';

const _tabular = [FontFeature.tabularFigures()];

/// Desktop team score card: standing summary, roster and match history for
/// one team in a team event, plus link and image sharing.
///
/// Everything is computed client-side from the event's games and individual
/// standings (`teamStandingsProvider`, `teamMatchesFamilyProvider`); there is
/// no team table on the server.
class TeamScoreCardPane extends ConsumerWidget {
  const TeamScoreCardPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ref.watch(teamScoreCardByTabIdProvider)[tabId];
    if (args == null) {
      return const _Message(text: 'Open a team from an event standings table.');
    }
    _syncEventContext(context, ref, args);

    final teamName = args.teamName.trim();
    final standingsAsync = ref.watch(teamStandingsProvider);
    final stub = TeamStandingModel(
      teamName: teamName,
      rank: 0,
      matchPoints: 0,
      gamePoints: 0,
      matchesWon: 0,
      matchesDrawn: 0,
      matchesLost: 0,
      boardsPlayed: 0,
      players: const <PlayerStandingModel>[],
    );
    final team =
        resolveSelectedTeamStanding(
          selected: stub,
          standings: standingsAsync.valueOrNull,
        ) ??
        stub;
    final matches = ref.watch(teamMatchesFamilyProvider(teamName));
    final teamCount = standingsAsync.valueOrNull?.length ?? 0;
    final about =
        ref.watch(tourDetailScreenProvider).valueOrNull?.aboutTourModel;
    final eventName =
        about?.name.trim().isNotEmpty == true
            ? about!.name.trim()
            : args.selectedBroadcast?.name;
    final shareUrl = buildDesktopTeamEventShareUrl(
      teamName: teamName,
      canonicalEventId:
          about?.groupBroadcastId?.isNotEmpty == true
              ? about!.groupBroadcastId
              : about?.id,
      eventName: eventName,
      tourId: about?.id,
      tourSlug: about?.slug,
    );
    final avgElo =
        ref.watch(teamAvgEloProvider(teamName)).valueOrNull ??
        teamAverageEloFromStandings(team);

    return ColoredBox(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            team: team,
            teamCount: teamCount,
            eventName: eventName,
            avgElo: avgElo,
            loading: standingsAsync.isLoading && !standingsAsync.hasValue,
            onShare:
                (position) => _openShareMenu(
                  context,
                  position: position,
                  team: team,
                  matches: matches,
                  eventName: eventName,
                  avgElo: avgElo,
                  shareUrl: shareUrl,
                ),
          ),
          const Divider(color: kDividerColor, height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: _Roster(
                      players: team.players,
                      onOpenPlayer: (player) => _openPlayer(ref, player),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 3,
                    child: _MatchHistory(
                      matches: matches,
                      onOpenBoard:
                          (board) => _openBoard(
                            ref,
                            board.game,
                            matches,
                            eventName ?? teamName,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Keeps the shared tournament providers scoped to this tab's event, the
  /// way the player score card tab does, so a team tab never shows another
  /// event's standings after the user switched tournaments elsewhere.
  void _syncEventContext(
    BuildContext context,
    WidgetRef ref,
    TeamScoreCardTabArgs args,
  ) {
    final broadcast = args.selectedBroadcast;
    final needsBroadcast =
        broadcast != null &&
        ref.read(selectedBroadcastModelProvider)?.id != broadcast.id;
    final selectedTeam = ref.read(selectedTeamProvider);
    final needsTeam =
        selectedTeam?.teamName.trim().toLowerCase() !=
        args.teamName.trim().toLowerCase();
    if (!needsBroadcast && !needsTeam) return;
    Future.microtask(() {
      if (!context.mounted) return;
      if (needsBroadcast) {
        ref.read(selectedBroadcastModelProvider.notifier).state = broadcast;
      }
      if (needsTeam) {
        ref.read(selectedTeamProvider.notifier).state = TeamStandingModel(
          teamName: args.teamName.trim(),
          rank: 0,
          matchPoints: 0,
          gamePoints: 0,
          matchesWon: 0,
          matchesDrawn: 0,
          matchesLost: 0,
          boardsPlayed: 0,
          players: const <PlayerStandingModel>[],
        );
      }
    });
  }

  void _openPlayer(WidgetRef ref, PlayerStandingModel player) {
    ref.read(scoreCardGamesContextProvider.notifier).state = null;
    ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
        PlayerProfileDataSource.supabase;
    openPlayerScoreCard(ref, player, fromTournamentContext: true);
  }

  void _openBoard(
    WidgetRef ref,
    GamesTourModel game,
    List<TeamMatch> matches,
    String title,
  ) {
    unawaited(
      openTournamentGameTab(
        ref,
        game,
        title,
        eventGames: [
          for (final match in matches)
            for (final board in match.boardGames) board.game,
        ],
      ),
    );
  }

  Future<void> _openShareMenu(
    BuildContext context, {
    required Offset position,
    required TeamStandingModel team,
    required List<TeamMatch> matches,
    required String? eventName,
    required int? avgElo,
    required String? shareUrl,
  }) async {
    final action = await showDesktopContextMenu<_ShareAction>(
      context: context,
      position: position,
      width: 230,
      entries: [
        DesktopContextMenuItem(
          value: _ShareAction.copyLink,
          icon: Icons.link_rounded,
          label: 'Copy link',
          enabled: shareUrl != null,
        ),
        const DesktopContextMenuItem(
          value: _ShareAction.copyImage,
          icon: Icons.image_outlined,
          label: 'Copy image',
        ),
        const DesktopContextMenuItem(
          value: _ShareAction.saveImage,
          icon: Icons.save_alt_rounded,
          label: 'Save image...',
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action == _ShareAction.copyLink) {
      if (shareUrl == null) return;
      await BoardShareService.copyToClipboard(shareUrl);
      if (context.mounted) showDesktopToast(context, 'Link copied');
      return;
    }
    try {
      final bytes = await _renderShareImage(
        team: team,
        matches: matches,
        eventName: eventName,
        avgElo: avgElo,
        shareUrl: shareUrl,
      );
      if (bytes == null) throw StateError('Team share image was empty');
      if (action == _ShareAction.copyImage) {
        await BoardShareService.copyPngBytesToClipboard(bytes);
        if (context.mounted) showDesktopToast(context, 'Image copied');
      } else {
        await BoardShareService.savePngBytesToDisk(
          bytes,
          defaultName: '${_fileSafe(team.teamName)}.png',
        );
      }
    } catch (error, stackTrace) {
      ErrorReporter.report(error, stackTrace: stackTrace, tag: 'team.share');
      if (context.mounted) {
        showDesktopToast(context, 'Could not create the image', error: true);
      }
    }
  }
}

enum _ShareAction { copyLink, copyImage, saveImage }

String _fileSafe(String value) {
  final cleaned = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
  final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.isEmpty ? 'team' : trimmed.toLowerCase();
}

Future<Uint8List?> _renderShareImage({
  required TeamStandingModel team,
  required List<TeamMatch> matches,
  required String? eventName,
  required int? avgElo,
  required String? shareUrl,
}) {
  final shown = matches.take(10).toList(growable: false);
  const width = 720.0;
  final height = 188.0 + shown.length * 38.0 + (shareUrl == null ? 0 : 30);
  return BoardShareService.captureWidget(
    TeamShareImageCard(
      team: team,
      matches: shown,
      eventName: eventName,
      avgElo: avgElo,
      footer: shareUrl,
    ),
    width: width,
    height: height,
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.team,
    required this.teamCount,
    required this.eventName,
    required this.avgElo,
    required this.loading,
    required this.onShare,
  });

  final TeamStandingModel team;
  final int teamCount;
  final String? eventName;
  final int? avgElo;
  final bool loading;
  final ValueChanged<Offset> onShare;

  @override
  Widget build(BuildContext context) {
    final rank =
        team.rank > 0
            ? (teamCount > 0 ? '#${team.rank} of $teamCount' : '#${team.rank}')
            : (loading ? 'Loading standings' : 'Not ranked yet');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  team.teamName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [rank, if (eventName != null) eventName!].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kWhiteColor70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          _Stat(label: 'Match pts', value: '${team.matchPoints}'),
          _Stat(label: 'Board pts', value: team.gamePointsLabel),
          _Stat(label: 'W · D · L', value: team.recordLabel),
          _Stat(label: 'Avg Elo', value: avgElo == null ? '-' : '$avgElo'),
          const SizedBox(width: 20),
          Builder(
            builder:
                (buttonContext) => DesktopHeaderActionButton(
                  label: 'Share',
                  icon: Icons.ios_share_rounded,
                  onPress: () {
                    final box = buttonContext.findRenderObject() as RenderBox?;
                    final origin =
                        box == null
                            ? Offset.zero
                            : box.localToGlobal(Offset(0, box.size.height + 4));
                    onShare(origin);
                  },
                ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: _tabular,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: kLightGreyColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 13,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Roster extends StatelessWidget {
  const _Roster({required this.players, required this.onOpenPlayer});

  final List<PlayerStandingModel> players;
  final ValueChanged<PlayerStandingModel> onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Roster', trailing: '${players.length}'),
        Expanded(
          child:
              players.isEmpty
                  ? const _Message(
                    text: 'No players are listed for this team yet.',
                    alignment: Alignment.topLeft,
                  )
                  : ListView.separated(
                    physics: const DesktopScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: players.length,
                    separatorBuilder:
                        (_, _) =>
                            const Divider(color: kDividerColor, height: 1),
                    itemBuilder: (context, index) {
                      final player = players[index];
                      return _HoverRow(
                        onTap: () => onOpenPlayer(player),
                        child: Row(
                          children: [
                            if ((player.title ?? '').isNotEmpty) ...[
                              Text(
                                player.title!,
                                style: const TextStyle(
                                  color: kPrimaryColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                player.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              player.score > 0 ? '${player.score}' : '',
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                                fontFeatures: _tabular,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              player.matchScore ?? '',
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFeatures: _tabular,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

class _MatchHistory extends StatelessWidget {
  const _MatchHistory({required this.matches, required this.onOpenBoard});

  final List<TeamMatch> matches;
  final ValueChanged<TeamBoardGame> onOpenBoard;

  @override
  Widget build(BuildContext context) {
    final heading =
        teamMatchesSectionHeading(matches) == null
            ? 'Matches by round'
            : 'Matches';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(heading, trailing: '${matches.length}'),
        Expanded(
          child:
              matches.isEmpty
                  ? const _Message(
                    text: 'No matches have been played yet.',
                    alignment: Alignment.topLeft,
                  )
                  : ListView.builder(
                    physics: const DesktopScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: matches.length,
                    itemBuilder:
                        (context, index) => _MatchBlock(
                          match: matches[index],
                          onOpenBoard: onOpenBoard,
                        ),
                  ),
        ),
      ],
    );
  }
}

class _MatchBlock extends StatelessWidget {
  const _MatchBlock({required this.match, required this.onOpenBoard});

  final TeamMatch match;
  final ValueChanged<TeamBoardGame> onOpenBoard;

  @override
  Widget build(BuildContext context) {
    final result = match.result;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      teamMatchHasRoundNumber(match) ? match.roundLabel : '',
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 13,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      teamMatchHasRoundNumber(match)
                          ? 'vs ${match.opponentTeam}'
                          : '${match.roundLabel}  ·  vs ${match.opponentTeam}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    match.scoreLabel,
                    style: TextStyle(
                      color:
                          result == TeamMatchResult.win
                              ? kWhiteColor
                              : kWhiteColor70,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFeatures: _tabular,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 76,
                    child: Text(
                      _resultLabel(match),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color:
                            result == TeamMatchResult.ongoing
                                ? kLightGreyColor
                                : kWhiteColor70,
                        fontSize: 12,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final board in match.boardGames)
                _HoverRow(
                  onTap: () => onOpenBoard(board),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          board.boardNr == null ? '' : '${board.boardNr}',
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            fontFeatures: _tabular,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _playerLabel(board.ourTitle, board.ourName),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          _boardResult(board.result),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFeatures: _tabular,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _playerLabel(board.opponentTitle, board.opponentName),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          board.opponentRating == null
                              ? ''
                              : '${board.opponentRating}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            fontFeatures: _tabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _playerLabel(String? title, String name) =>
    title == null || title.isEmpty ? name : '$title $name';

String _boardResult(TeamMatchResult result) => switch (result) {
  TeamMatchResult.win => '1',
  TeamMatchResult.loss => '0',
  TeamMatchResult.draw => '½',
  TeamMatchResult.ongoing => '*',
};

String _resultLabel(TeamMatch match) => switch (match.result) {
  TeamMatchResult.win => 'Won, +${match.matchPoints}',
  TeamMatchResult.draw => 'Drawn, +${match.matchPoints}',
  TeamMatchResult.loss => 'Lost',
  TeamMatchResult.ongoing => 'In progress',
};

class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ColoredBox(
          color: _hovered ? kBlack3Color : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.alignment = Alignment.center});

  final String text;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          text,
          style: const TextStyle(color: kWhiteColor70, fontSize: 13),
        ),
      ),
    );
  }
}

/// Off-screen card rendered for image sharing. It carries the link as a
/// footer only when the event has a real URL identity.
@visibleForTesting
class TeamShareImageCard extends StatelessWidget {
  const TeamShareImageCard({
    super.key,
    required this.team,
    required this.matches,
    required this.eventName,
    required this.avgElo,
    required this.footer,
  });

  final TeamStandingModel team;
  final List<TeamMatch> matches;
  final String? eventName;
  final int? avgElo;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              team.teamName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 26,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (team.rank > 0) 'Rank ${team.rank}',
                if (eventName != null) eventName!,
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kWhiteColor70, fontSize: 14),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _ShareStat('Match pts', '${team.matchPoints}'),
                _ShareStat('Board pts', team.gamePointsLabel),
                _ShareStat('W · D · L', team.recordLabel),
                _ShareStat('Avg Elo', avgElo == null ? '-' : '$avgElo'),
              ],
            ),
            const SizedBox(height: 18),
            for (final match in matches)
              SizedBox(
                height: 38,
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        teamMatchHasRoundNumber(match) ? match.roundLabel : '',
                        style: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 14,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'vs ${match.opponentTeam}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Text(
                      match.scoreLabel,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ],
                ),
              ),
            if (footer != null) ...[
              const Spacer(),
              Text(
                footer!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShareStat extends StatelessWidget {
  const _ShareStat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              fontFeatures: _tabular,
            ),
          ),
          Text(
            label,
            style: const TextStyle(color: kLightGreyColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
