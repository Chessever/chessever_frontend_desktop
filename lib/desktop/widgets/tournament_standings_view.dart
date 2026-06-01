import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailStandingsSearchByTabIdProvider;
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardPlayerProfileDataSourceProvider;
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/location_service_provider.dart';
import 'package:chessever/widgets/federation_flag.dart';

/// Standings sub-view of the Tournament Detail.
///
/// Uses [playerTourScreenProvider] to surface the ranked desktop standings with
/// player, rating, and event score columns.
class TournamentStandingsView extends HookConsumerWidget {
  const TournamentStandingsView({
    super.key,
    required this.tabId,
    required this.tournamentId,
  });

  final String tabId;
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(playerTourScreenProvider);
    // Source of truth lives in the provider so the search text restores
    // after the tab.kind flip to Board and back. The controller is local
    // because TextEditingController itself can't survive widget disposal,
    // but its initial text is seeded from the persisted query.
    final query = ref.watch(
      tournamentDetailStandingsSearchByTabIdProvider(tabId),
    );
    final searchController = useTextEditingController(text: query);
    // If the provider is mutated by another path (e.g. tests, clear-all),
    // reflect it in the controller without clobbering the user's caret on
    // ordinary keystrokes.
    if (searchController.text != query) {
      searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: DesktopSearchField(
            controller: searchController,
            hintText: 'Filter standings (player, title, federation)',
            onChanged: (v) =>
                ref
                    .read(
                      tournamentDetailStandingsSearchByTabIdProvider(
                        tabId,
                      ).notifier,
                    )
                    .state = v,
            onClear: () =>
                ref
                    .read(
                      tournamentDetailStandingsSearchByTabIdProvider(
                        tabId,
                      ).notifier,
                    )
                    .state = '',
          ),
        ),
        Expanded(
          child: standings.when(
            skipLoadingOnRefresh: true,
            skipLoadingOnReload: true,
            data: (players) {
              final q = query.trim().toLowerCase();
              final filtered =
                  q.isEmpty
                      ? players
                      : players
                          .where((p) {
                            if (p.name.toLowerCase().contains(q)) return true;
                            if ((p.title ?? '').toLowerCase().contains(q)) {
                              return true;
                            }
                            if (p.countryCode.toLowerCase().contains(q)) {
                              return true;
                            }
                            return false;
                          })
                          .toList(growable: false);
              if (players.isEmpty) {
                return const _Empty();
              }
              if (filtered.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No standings match "$q"',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }
              return ListView.separated(
                key: PageStorageKey<String>(
                  'tournament-detail-standings:$tabId',
                ),
                physics: const DesktopScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                itemCount: filtered.length + 1,
                separatorBuilder:
                    (_, i) => Divider(
                      color: i == 0 ? Colors.transparent : kDividerColor,
                      height: 1,
                    ),
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return const _StandingsHeaderRow();
                  }

                  final p = filtered[i - 1];
                  return _StandingsPlayerRow(
                    player: p,
                    rank: p.overallRank ?? players.indexOf(p) + 1,
                    flagFederation: _flagFederation(ref, p.countryCode),
                    onOpenScoreCard: () => _openScoreCard(ref, p),
                  );
                },
              );
            },
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
            error:
                (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Could not load standings: $e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: kRedColor, fontSize: 12),
                    ),
                  ),
                ),
          ),
        ),
      ],
    );
  }

  String _flagFederation(WidgetRef ref, String countryCode) {
    // Some broadcasts ship the federation under non-ISO codes (e.g. FIDE
    // 3-letter); fall back to the LocationService mapping so the flag still
    // renders. Empty country = blank slot, not a broken image.
    final rawFed = countryCode.trim();
    final mappedFed = ref
        .read(locationServiceProvider)
        .getValidCountryCode(rawFed);
    return rawFed.isNotEmpty ? rawFed : mappedFed;
  }

  void _openScoreCard(WidgetRef ref, PlayerStandingModel player) {
    ref.read(scoreCardGamesContextProvider.notifier).state = null;
    ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
        PlayerProfileDataSource.supabase;
    openPlayerScoreCard(ref, player, fromTournamentContext: true);
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No standings published yet.',
          style: TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      ),
    );
  }
}

class _StandingsHeaderRow extends StatelessWidget {
  const _StandingsHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: kLightGreyColor,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Row(
        children: [
          const SizedBox(width: 24, child: Text('#', style: style)),
          const SizedBox(width: 32),
          const Expanded(child: Text('Player', style: style)),
          _HeaderCell(label: 'Rating', width: _StandingsPlayerRow.ratingWidth),
          const SizedBox(width: 16),
          _HeaderCell(label: 'Score', width: _StandingsPlayerRow.scoreWidth),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.width});

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        textAlign: TextAlign.right,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _StandingsPlayerRow extends StatelessWidget {
  const _StandingsPlayerRow({
    required this.player,
    required this.rank,
    required this.flagFederation,
    required this.onOpenScoreCard,
  });

  static const ratingWidth = 54.0;
  static const scoreWidth = 72.0;

  final PlayerStandingModel player;
  final int rank;
  final String flagFederation;
  final VoidCallback onOpenScoreCard;

  @override
  Widget build(BuildContext context) {
    final score = player.matchScore?.trim();
    final rating = player.score > 0 ? player.score.toString() : '-';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: 22,
            height: 14,
            child:
                flagFederation.isEmpty
                    ? const SizedBox.shrink()
                    : FederationFlag(
                      federation: flagFederation,
                      width: 22,
                      height: 14,
                      borderRadius: BorderRadius.circular(2),
                    ),
          ),
          const SizedBox(width: 10),
          if ((player.title ?? '').isNotEmpty) ...[
            Text(
              player.title!,
              style: const TextStyle(
                color: kLightYellowColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: _PlayerNameLink(
              playerName: player.name,
              onTap: onOpenScoreCard,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: ratingWidth,
            child: Text(
              rating,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: scoreWidth,
            child: Text(
              (score == null || score.isEmpty) ? '-' : score,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerNameLink extends StatefulWidget {
  const _PlayerNameLink({required this.playerName, required this.onTap});

  final String playerName;
  final VoidCallback onTap;

  @override
  State<_PlayerNameLink> createState() => _PlayerNameLinkState();
}

class _PlayerNameLinkState extends State<_PlayerNameLink> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused || _pressed;
    final color =
        _pressed ? kPrimaryColor.withValues(alpha: 0.82) : kWhiteColor;

    return Semantics(
      button: true,
      label: 'Open ${widget.playerName} score card',
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit:
                (_) => setState(() {
                  _hovered = false;
                  _pressed = false;
                }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: Text(
                widget.playerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration:
                      active ? TextDecoration.underline : TextDecoration.none,
                  decorationColor: kPrimaryColor,
                  decorationThickness: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
