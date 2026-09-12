import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_team.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
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
