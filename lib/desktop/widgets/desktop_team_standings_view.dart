import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_team.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart'
    show selectedBroadcastModelProvider;
import 'package:chessever/screens/tour_detail/team_tour/team_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';

const _tabular = [FontFeature.tabularFigures()];

enum DesktopTeamStandingsMode { teams, players }

/// Teams / Players choice per tournament-detail tab. Survives segment
/// switches so returning to Standings keeps the user's view.
final teamStandingsModeByTabIdProvider =
    StateProvider.family<DesktopTeamStandingsMode, String>(
      (ref, tabId) => DesktopTeamStandingsMode.teams,
    );

/// Standings segment for team events: ranked team table (match points,
/// then board points, then name) with the individual standings one switch
/// away. Selecting a team opens its score card tab.
class DesktopTeamStandingsSection extends ConsumerWidget {
  const DesktopTeamStandingsSection({
    super.key,
    required this.tabId,
    required this.playersView,
  });

  final String tabId;
  final Widget playersView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(teamStandingsModeByTabIdProvider(tabId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DesktopSegmentedTabs<DesktopTeamStandingsMode>(
              tabs: const [
                DesktopSegmentedTab(
                  value: DesktopTeamStandingsMode.teams,
                  label: 'Teams',
                ),
                DesktopSegmentedTab(
                  value: DesktopTeamStandingsMode.players,
                  label: 'Players',
                ),
              ],
              selected: mode,
              onChanged:
                  (next) =>
                      ref
                          .read(
                            teamStandingsModeByTabIdProvider(tabId).notifier,
                          )
                          .state = next,
            ),
          ),
        ),
        Expanded(
          child:
              mode == DesktopTeamStandingsMode.players
                  ? playersView
                  : const DesktopTeamStandingsTable(),
        ),
      ],
    );
  }
}

class DesktopTeamStandingsTable extends ConsumerWidget {
  const DesktopTeamStandingsTable({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(teamStandingsProvider);
    return standings.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (teams) {
        if (teams.isEmpty) {
          return const Center(
            child: Text(
              'No team results yet.',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
          );
        }
        return ListView.separated(
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          itemCount: teams.length + 1,
          separatorBuilder:
              (_, index) => Divider(
                color: index == 0 ? Colors.transparent : kDividerColor,
                height: 1,
              ),
          itemBuilder: (context, index) {
            if (index == 0) return const _TeamHeaderRow();
            final team = teams[index - 1];
            return _TeamRow(
              team: team,
              onOpen:
                  () => openTeamScoreCard(
                    ref,
                    TeamScoreCardTabArgs(
                      teamName: team.teamName,
                      selectedBroadcast: ref.read(
                        selectedBroadcastModelProvider,
                      ),
                    ),
                  ),
            );
          },
        );
      },
      loading:
          () => const Center(
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
          ),
      error:
          (_, _) => const Center(
            child: Text(
              'Could not load team standings.',
              style: TextStyle(color: kRedColor, fontSize: 12),
            ),
          ),
    );
  }
}

class _TeamHeaderRow extends StatelessWidget {
  const _TeamHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: kLightGreyColor,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );
    return const Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          SizedBox(width: 44, child: Text('#', style: style)),
          Expanded(child: Text('Team', style: style)),
          _Cell('MP', style: style),
          _Cell('Board pts', style: style, width: 88),
          _Cell('W · D · L', style: style, width: 96),
          _Cell('Players', style: style),
        ],
      ),
    );
  }
}

class _TeamRow extends StatefulWidget {
  const _TeamRow({required this.team, required this.onOpen});

  final TeamStandingModel team;
  final VoidCallback onOpen;

  @override
  State<_TeamRow> createState() => _TeamRowState();
}

class _TeamRowState extends State<_TeamRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    const numberStyle = TextStyle(
      color: kWhiteColor70,
      fontSize: 13,
      fontFeatures: _tabular,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: ColoredBox(
          color: _hovered ? kBlack3Color : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    '${team.rank}',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 13,
                      fontFeatures: _tabular,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    team.teamName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _hovered ? kPrimaryColor : kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _Cell(
                  '${team.matchPoints}',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: _tabular,
                  ),
                ),
                _Cell(team.gamePointsLabel, style: numberStyle, width: 88),
                _Cell(team.recordLabel, style: numberStyle, width: 96),
                _Cell('${team.players.length}', style: numberStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {required this.style, this.width = 64});

  final String text;
  final TextStyle style;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(text, textAlign: TextAlign.center, style: style),
    );
  }
}

/// In-game event-rail Standings for a team event: one compact row per team
/// (match points, then board points), matching the web rail. Body tap opens
/// the team score card.
class DesktopCompactTeamStandingsView extends ConsumerWidget {
  const DesktopCompactTeamStandingsView({
    super.key,
    required this.tabId,
    required this.tournamentId,
    this.tournamentTitle = '',
  });

  final String tabId;
  final String tournamentId;
  final String tournamentTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tourId = tournamentId.trim();
    if (tourId.isEmpty) {
      return const _CompactTeamEmpty();
    }
    final standings = ref.watch(teamStandingsForTourProvider(tourId));
    return standings.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (teams) {
        if (teams.isEmpty) return const _CompactTeamEmpty();
        return ListView.separated(
          key: const PageStorageKey<String>('event-rail-team-standings'),
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
          itemCount: teams.length,
          separatorBuilder:
              (_, _) => const Divider(color: kDividerColor, height: 1),
          itemBuilder: (context, index) {
            final team = teams[index];
            return _CompactTeamStandingRow(
              team: team,
              onOpen: () => _openTeamCard(ref, team),
            );
          },
        );
      },
      loading:
          () => const Center(
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
          ),
      error:
          (_, _) => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Could not load team standings.',
                style: TextStyle(color: kRedColor, fontSize: 12),
              ),
            ),
          ),
    );
  }

  void _openTeamCard(WidgetRef ref, TeamStandingModel team) {
    openTeamScoreCard(
      ref,
      TeamScoreCardTabArgs(
        teamName: team.teamName,
        selectedBroadcast: _broadcastForTeamCard(ref),
      ),
    );
  }

  GroupBroadcast? _broadcastForTeamCard(WidgetRef ref) {
    final selected = ref.read(selectedBroadcastModelProvider);
    if (selected != null) return selected;
    final tournament = ref.read(tournamentByTabIdProvider)[tabId];
    if (tournament == null) return null;
    return GroupBroadcast(
      id: tournament.id,
      createdAt: DateTime.now(),
      name:
          tournament.title.trim().isNotEmpty
              ? tournament.title.trim()
              : tournamentTitle,
      search: const <String>[],
    );
  }
}

class _CompactTeamEmpty extends StatelessWidget {
  const _CompactTeamEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Team standings appear here once pairings are published.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      ),
    );
  }
}

class _CompactTeamStandingRow extends StatefulWidget {
  const _CompactTeamStandingRow({required this.team, required this.onOpen});

  final TeamStandingModel team;
  final VoidCallback onOpen;

  @override
  State<_CompactTeamStandingRow> createState() =>
      _CompactTeamStandingRowState();
}

class _CompactTeamStandingRowState extends State<_CompactTeamStandingRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    final hasRecord =
        team.matchesWon > 0 || team.matchesDrawn > 0 || team.matchesLost > 0;
    final active = _hovered || _focused;
    final spoken = [
      '#${team.rank} ${team.teamName}',
      '${team.matchPoints} match points',
      '${team.gamePointsLabel} board points',
      if (hasRecord)
        'record ${team.matchesWon} won, ${team.matchesDrawn} drawn, ${team.matchesLost} lost',
    ].join(', ');

    return Semantics(
      button: true,
      label: 'Open ${team.teamName} team card',
      value: spoken,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            widget.onOpen();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpen,
              child: AnimatedContainer(
                key: Key('event-rail-team-standing-${team.teamName}'),
                duration: const Duration(milliseconds: 100),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                decoration: BoxDecoration(
                  color: active ? kBlack3Color : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${team.rank}',
                        style: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 11.5,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            team.teamName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasRecord
                                ? '${team.gamePointsLabel} pts · ${team.recordLabel}'
                                : '${team.gamePointsLabel} pts',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor70,
                              fontSize: 10.5,
                              fontFeatures: _tabular,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${team.matchPoints}',
                        key: Key(
                          'event-rail-team-standing-mp-${team.teamName}',
                        ),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          fontFeatures: _tabular,
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
