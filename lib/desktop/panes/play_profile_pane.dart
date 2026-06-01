import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_pane.dart'
    show PlayPaneTab, playPaneTabByTabIdProvider, playPaneTabProvider;
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/play_achievement_badge.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_rating_chart.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart'
    show GameStatus;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

/// Right-pane sections selectable from the rail and the segmented strip.
enum _ProfileTab { overview, ratings, games, achievements }

extension on _ProfileTab {
  String get label {
    switch (this) {
      case _ProfileTab.overview:
        return 'Overview';
      case _ProfileTab.ratings:
        return 'Ratings';
      case _ProfileTab.games:
        return 'Games';
      case _ProfileTab.achievements:
        return 'Achievements';
    }
  }
}

// ---------------------------------------------------------------------------
// Per-TC palette + assets used by tiles, chips and charts so a player
// can scan ladders without re-reading labels.
// ---------------------------------------------------------------------------

const _kTimeControls = <RatedTimeControl>[
  RatedTimeControl.classical,
  RatedTimeControl.rapid,
  RatedTimeControl.blitz,
  RatedTimeControl.bullet,
];

Color _accentFor(RatedTimeControl tc) {
  switch (tc) {
    case RatedTimeControl.classical:
      return const Color(0xFFE9A23B);
    case RatedTimeControl.rapid:
      return kPrimaryColor;
    case RatedTimeControl.blitz:
      return const Color(0xFFFFD338);
    case RatedTimeControl.bullet:
      return const Color(0xFFF06B6B);
  }
}

String _assetFor(RatedTimeControl tc) {
  switch (tc) {
    case RatedTimeControl.classical:
      return PngAsset.classicalIcon;
    case RatedTimeControl.rapid:
      return PngAsset.rapidIcon;
    case RatedTimeControl.blitz:
      return PngAsset.blitzIcon;
    case RatedTimeControl.bullet:
      // No dedicated bullet asset shipped -- reuse the blitz icon.
      return PngAsset.blitzIcon;
  }
}

BoxDecoration _panel({Color? accent}) => BoxDecoration(
  color: kBlack2Color,
  border: Border.all(
    color: accent == null ? kDividerColor : accent.withValues(alpha: 0.45),
  ),
  borderRadius: BorderRadius.circular(10),
);

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

class PlayProfilePane extends ConsumerStatefulWidget {
  const PlayProfilePane({super.key, this.playTabId});

  final String? playTabId;

  @override
  ConsumerState<PlayProfilePane> createState() => _PlayProfilePaneState();
}

class _PlayProfilePaneState extends ConsumerState<PlayProfilePane> {
  _ProfileTab _tab = _ProfileTab.overview;
  RatedTimeControl? _ratingsTc;

  void _setTab(_ProfileTab t) => setState(() => _tab = t);
  void _openRatings(RatedTimeControl tc) => setState(() {
    _tab = _ProfileTab.ratings;
    _ratingsTc = tc;
  });

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(playUserProfileProvider);
    final achievements = ref.watch(playAchievementsProvider);
    final gamesAsync = ref.watch(playRecentGamesProvider);
    return FTheme(
      data: FThemes.zinc.dark,
      child: profileAsync.when(
        loading: () => const _Loading(),
        error:
            (e, _) => _ErrorState(
              message: 'Profile could not load: $e',
              onRetry: () => ref.invalidate(playUserProfileProvider),
            ),
        data: (profile) {
          final games = gamesAsync.valueOrNull ?? const <PlayGameRecord>[];
          return _Body(
            profile: profile,
            achievements: achievements,
            games: games,
            historyLoading: gamesAsync.isLoading,
            historyError: gamesAsync.hasError ? '${gamesAsync.error}' : null,
            playTabId: widget.playTabId,
            tab: _tab,
            ratingsTc: _ratingsTc ?? profile.headlineTimeControl,
            onTabChanged: _setTab,
            onShowRatings: _openRatings,
            onRatingsTcChanged: (tc) => setState(() => _ratingsTc = tc),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body -- left identity rail and right tabbed pane.
// ---------------------------------------------------------------------------

class _Body extends StatelessWidget {
  const _Body({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.historyLoading,
    required this.playTabId,
    required this.tab,
    required this.ratingsTc,
    required this.onTabChanged,
    required this.onShowRatings,
    required this.onRatingsTcChanged,
    this.historyError,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final bool historyLoading;
  final String? playTabId;
  final String? historyError;
  final _ProfileTab tab;
  final RatedTimeControl ratingsTc;
  final ValueChanged<_ProfileTab> onTabChanged;
  final ValueChanged<RatedTimeControl> onShowRatings;
  final ValueChanged<RatedTimeControl> onRatingsTcChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IdentityRail(
          profile: profile,
          achievements: achievements,
          playTabId: playTabId,
          onShowRatings: onShowRatings,
          onShowAchievements: () => onTabChanged(_ProfileTab.achievements),
          onShowGames: () => onTabChanged(_ProfileTab.games),
        ),
        Container(width: 1, color: kDividerColor),
        Expanded(
          child: _RightPane(
            profile: profile,
            achievements: achievements,
            games: games,
            historyLoading: historyLoading,
            historyError: historyError,
            tab: tab,
            ratingsTc: ratingsTc,
            onTabChanged: onTabChanged,
            onShowRatings: onShowRatings,
            onRatingsTcChanged: onRatingsTcChanged,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Identity rail (left column)
// ---------------------------------------------------------------------------

class _IdentityRail extends StatelessWidget {
  const _IdentityRail({
    required this.profile,
    required this.achievements,
    required this.playTabId,
    required this.onShowRatings,
    required this.onShowAchievements,
    required this.onShowGames,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final String? playTabId;
  final ValueChanged<RatedTimeControl> onShowRatings;
  final VoidCallback onShowAchievements;
  final VoidCallback onShowGames;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileCard(profile: profile, playTabId: playTabId),
            const SizedBox(height: 16),
            _HeadlineBanner(
              profile: profile,
              onTap: () => onShowRatings(profile.headlineTimeControl),
            ),
            const SizedBox(height: 16),
            _RatingTilesGrid(profile: profile, onTap: onShowRatings),
            const SizedBox(height: 16),
            _BioCard(
              profile: profile,
              achievements: achievements,
              onTapBadges: onShowAchievements,
              onTapLastGame: onShowGames,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends ConsumerStatefulWidget {
  const _ProfileCard({required this.profile, required this.playTabId});

  final PlayUserProfile profile;
  final String? playTabId;

  @override
  ConsumerState<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<_ProfileCard> {
  late final TextEditingController _name;
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.displayName);
  }

  @override
  void didUpdateWidget(covariant _ProfileCard old) {
    super.didUpdateWidget(old);
    if (!_editing &&
        old.profile.displayName != widget.profile.displayName &&
        _name.text != widget.profile.displayName) {
      _name.text = widget.profile.displayName;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DesktopUserAvatar(
                size: 76,
                displayName: p.displayName,
                borderRadius: 18,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editing)
                      FTextField(
                        controller: _name,
                        hint: 'Display name',
                        autofocus: true,
                        inputFormatters: [LengthLimitingTextInputFormatter(42)],
                      )
                    else
                      Text(
                        p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'ChessEver Player',
                      style: TextStyle(
                        color: _accentFor(p.headlineTimeControl),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_editing)
            Row(
              children: [
                Expanded(
                  child: FButton(
                    style: playSecondaryActionButtonStyle(),
                    onPress: _saving ? null : _cancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FButton(
                    style: playPrimaryActionButtonStyle(),
                    prefix: const Icon(Icons.save_outlined, size: 16),
                    onPress: _saving ? null : _save,
                    child: Text(_saving ? 'Saving...' : 'Save'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: FButton(
                    style: playSecondaryActionButtonStyle(),
                    prefix: const Icon(Icons.edit_outlined, size: 16),
                    onPress: () => setState(() => _editing = true),
                    child: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FButton(
                    style: playPrimaryActionButtonStyle(),
                    prefix: const Icon(Icons.play_arrow_rounded, size: 16),
                    onPress: () {
                      final playTabId = widget.playTabId;
                      if (playTabId == null) {
                        ref.read(playPaneTabProvider.notifier).state =
                            PlayPaneTab.single;
                      } else {
                        ref
                            .read(
                              playPaneTabByTabIdProvider(playTabId).notifier,
                            )
                            .state = PlayPaneTab.single;
                      }
                      ref.read(desktopTabsProvider.notifier).open(TabKind.play);
                    },
                    child: const Text('Play'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _cancel() {
    setState(() {
      _name.text = widget.profile.displayName;
      _editing = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final trimmed = _name.text.trim();
    final next = widget.profile.copyWith(
      displayName: trimmed.isEmpty ? 'ChessEver Player' : trimmed,
    );
    await ref.read(playProfileRepositoryProvider).saveProfile(next);
    ref.invalidate(playUserProfileProvider);
    if (mounted) {
      setState(() {
        _saving = false;
        _editing = false;
      });
    }
  }
}

class _HeadlineBanner extends StatelessWidget {
  const _HeadlineBanner({required this.profile, required this.onTap});
  final PlayUserProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = profile.headlineTimeControl;
    final accent = _accentFor(tc);
    final stats = profile.statsFor(tc);
    return _Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Image.asset(_assetFor(tc), width: 28, height: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tc.displayName.toUpperCase(),
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${stats.rating}',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      fontFeatures: [FontFeature.tabularFigures()],
                      height: 1.05,
                    ),
                  ),
                  Text(
                    'Peak ${stats.peak} · ${stats.gamesPlayed} games',
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: kWhiteColor70,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class _RatingTilesGrid extends StatelessWidget {
  const _RatingTilesGrid({required this.profile, required this.onTap});
  final PlayUserProfile profile;
  final ValueChanged<RatedTimeControl> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.55,
      children: [
        for (final tc in _kTimeControls)
          _RatingTile(
            tc: tc,
            stats: profile.statsFor(tc),
            onTap: () => onTap(tc),
          ),
      ],
    );
  }
}

class _RatingTile extends StatelessWidget {
  const _RatingTile({
    required this.tc,
    required this.stats,
    required this.onTap,
  });
  final RatedTimeControl tc;
  final PlayRatingStats stats;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(tc);
    return _Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: kBlack2Color,
          border: Border.all(color: kDividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Image.asset(_assetFor(tc), width: 14, height: 14),
                const SizedBox(width: 6),
                Text(
                  tc.displayName.toUpperCase(),
                  style: TextStyle(
                    color: accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
              ],
            ),
            Text(
              '${stats.rating}',
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1.1,
              ),
            ),
            Text(
              '${stats.gamesPlayed} games · ${stats.winRatePct}% win',
              style: const TextStyle(
                color: kSecondaryTextColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BioCard extends StatelessWidget {
  const _BioCard({
    required this.profile,
    required this.achievements,
    required this.onTapBadges,
    required this.onTapLastGame,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final VoidCallback onTapBadges;
  final VoidCallback onTapLastGame;

  @override
  Widget build(BuildContext context) {
    final joined = profile.createdAt;
    final last = profile.lastGameAt;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PROFILE',
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          _bioRow(
            'Total games',
            '${profile.gamesPlayedTotal}',
            onTap: onTapLastGame,
          ),
          _bioRow(
            'Record',
            '${profile.winsTotal}W · ${profile.lossesTotal}L · ${profile.drawsTotal}D',
          ),
          _bioRow(
            'Badges',
            '${achievements.unlocked.length} / ${kPlayAchievementDefinitions.length}',
            onTap: onTapBadges,
          ),
          if (joined != null) _bioRow('Joined', _formatDate(joined)),
          if (last != null)
            _bioRow('Last game', _formatDate(last), onTap: onTapLastGame),
        ],
      ),
    );
  }
}

Widget _bioRow(String label, String value, {VoidCallback? onTap}) {
  final row = Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: onTap != null ? kPrimaryColor : kWhiteColor,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(
            Icons.chevron_right_rounded,
            size: 14,
            color: kWhiteColor70,
          ),
        ],
      ],
    ),
  );
  if (onTap == null) return row;
  return _Tap(onTap: onTap, child: row);
}

String _formatDate(DateTime d) {
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
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

// ---------------------------------------------------------------------------
// Right pane -- forui tabs.
// ---------------------------------------------------------------------------

class _RightPane extends StatelessWidget {
  const _RightPane({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.historyLoading,
    required this.tab,
    required this.ratingsTc,
    required this.onTabChanged,
    required this.onShowRatings,
    required this.onRatingsTcChanged,
    this.historyError,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final bool historyLoading;
  final String? historyError;
  final _ProfileTab tab;
  final RatedTimeControl ratingsTc;
  final ValueChanged<_ProfileTab> onTabChanged;
  final ValueChanged<RatedTimeControl> onShowRatings;
  final ValueChanged<RatedTimeControl> onRatingsTcChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabStrip(selected: tab, onChanged: onTabChanged),
          const SizedBox(height: 14),
          Expanded(
            child: PersistentIndexedStack(
              index: tab.index,
              sizing: StackFit.expand,
              children: [
                _OverviewBody(
                  profile: profile,
                  games: games,
                  onShowRatings: onShowRatings,
                  onShowAllGames: () => onTabChanged(_ProfileTab.games),
                ),
                _RatingsBody(
                  profile: profile,
                  selectedTc: ratingsTc,
                  onTcChanged: onRatingsTcChanged,
                ),
                _GamesBody(
                  games: games,
                  loading: historyLoading,
                  error: historyError,
                ),
                _AchievementsBody(state: achievements),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.selected, required this.onChanged});
  final _ProfileTab selected;
  final ValueChanged<_ProfileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final t in _ProfileTab.values) ...[
          _TabPill(
            label: t.label,
            selected: t == selected,
            onTap: () => onChanged(t),
          ),
          if (t != _ProfileTab.values.last) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.16) : kBlack2Color,
          border: Border.all(
            color:
                selected ? kPrimaryColor.withValues(alpha: 0.6) : kDividerColor,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? kPrimaryColor : kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview tab
// ---------------------------------------------------------------------------

class _OverviewBody extends ConsumerWidget {
  const _OverviewBody({
    required this.profile,
    required this.games,
    required this.onShowRatings,
    required this.onShowAllGames,
  });

  final PlayUserProfile profile;
  final List<PlayGameRecord> games;
  final ValueChanged<RatedTimeControl> onShowRatings;
  final VoidCallback onShowAllGames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryStripe(profile: profile),
          const SizedBox(height: 18),
          const _SectionLabel('Rating progression'),
          const SizedBox(height: 10),
          _MiniChartsGrid(profile: profile, onTap: onShowRatings),
          const SizedBox(height: 22),
          Row(
            children: [
              const _SectionLabel('Latest games'),
              const Spacer(),
              if (games.isNotEmpty)
                _Tap(
                  onTap: onShowAllGames,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        'See all',
                        style: TextStyle(
                          color: kPrimaryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6,
                        ),
                      ),
                      SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: kPrimaryColor,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _GameList(games: games.take(6).toList(growable: false)),
        ],
      ),
    );
  }
}

class _SummaryStripe extends StatelessWidget {
  const _SummaryStripe({required this.profile});
  final PlayUserProfile profile;

  @override
  Widget build(BuildContext context) {
    final total = profile.gamesPlayedTotal;
    final winRate = total == 0 ? 0 : (100 * profile.winsTotal / total).round();
    int peak = 0;
    for (final tc in _kTimeControls) {
      final p = profile.statsFor(tc).peak;
      if (p > peak) peak = p;
    }
    return Row(
      children: [
        Expanded(child: _Stat('Games', '$total')),
        const SizedBox(width: 10),
        Expanded(child: _Stat('Win rate', '$winRate%')),
        const SizedBox(width: 10),
        Expanded(child: _Stat('Peak', '$peak')),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(
            'Record',
            '${profile.winsTotal}/${profile.drawsTotal}/${profile.lossesTotal}',
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: _panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChartsGrid extends StatelessWidget {
  const _MiniChartsGrid({required this.profile, required this.onTap});
  final PlayUserProfile profile;
  final ValueChanged<RatedTimeControl> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 2.1,
      children: [
        for (final tc in _kTimeControls)
          _MiniRatingCard(
            tc: tc,
            stats: profile.statsFor(tc),
            onTap: () => onTap(tc),
          ),
      ],
    );
  }
}

class _MiniRatingCard extends ConsumerWidget {
  const _MiniRatingCard({
    required this.tc,
    required this.stats,
    required this.onTap,
  });

  final RatedTimeControl tc;
  final PlayRatingStats stats;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = _accentFor(tc);
    final historyAsync = ref.watch(playRatingHistoryProvider(tc));
    return _Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: _panel(accent: accent),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Image.asset(_assetFor(tc), width: 16, height: 16),
                const SizedBox(width: 6),
                Text(
                  tc.displayName.toUpperCase(),
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                Text(
                  '${stats.rating}',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: historyAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
                data:
                    (points) => PlayRatingChart(
                      points: points,
                      accent: accent,
                      range: PlayRatingChartRange.last90Days,
                      showAxisLabels: false,
                      height: double.infinity,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ratings tab -- big animated chart + TC/range switchers + breakdown.
// ---------------------------------------------------------------------------

class _RatingsBody extends ConsumerStatefulWidget {
  const _RatingsBody({
    required this.profile,
    required this.selectedTc,
    required this.onTcChanged,
  });
  final PlayUserProfile profile;
  final RatedTimeControl selectedTc;
  final ValueChanged<RatedTimeControl> onTcChanged;

  @override
  ConsumerState<_RatingsBody> createState() => _RatingsBodyState();
}

class _RatingsBodyState extends ConsumerState<_RatingsBody> {
  PlayRatingChartRange _range = PlayRatingChartRange.last90Days;

  @override
  Widget build(BuildContext context) {
    final tc = widget.selectedTc;
    final accent = _accentFor(tc);
    final stats = widget.profile.statsFor(tc);
    final historyAsync = ref.watch(playRatingHistoryProvider(tc));
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final t in _kTimeControls) ...[
                Expanded(
                  child: _TcChip(
                    tc: t,
                    selected: t == tc,
                    onTap: () => widget.onTcChanged(t),
                  ),
                ),
                if (t != _kTimeControls.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            decoration: _panel(accent: accent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Image.asset(_assetFor(tc), width: 22, height: 22),
                    const SizedBox(width: 8),
                    Text(
                      '${tc.displayName} rating',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${stats.rating}',
                      style: TextStyle(
                        color: accent,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Peak ${stats.peak} · ${stats.gamesPlayed} games · '
                  '${stats.wins}W ${stats.losses}L ${stats.draws}D',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final range in PlayRatingChartRange.values) ...[
                      _RangeChip(
                        label: range.label,
                        selected: range == _range,
                        onTap: () => setState(() => _range = range),
                      ),
                      if (range != PlayRatingChartRange.values.last)
                        const SizedBox(width: 6),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 320,
                  child: historyAsync.when(
                    loading:
                        () => const Center(
                          child: CircularProgressIndicator(
                            color: kPrimaryColor,
                          ),
                        ),
                    error:
                        (e, _) => Center(
                          child: Text(
                            '$e',
                            style: const TextStyle(
                              color: kRedColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    data:
                        (points) => PlayRatingChart(
                          points: points,
                          accent: accent,
                          range: _range,
                          height: double.infinity,
                        ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _RatingDistributionCard(profile: widget.profile),
        ],
      ),
    );
  }
}

class _TcChip extends StatelessWidget {
  const _TcChip({
    required this.tc,
    required this.selected,
    required this.onTap,
  });

  final RatedTimeControl tc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(tc);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : kBlack2Color,
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.6) : kDividerColor,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(_assetFor(tc), width: 14, height: 14),
              const SizedBox(width: 8),
              Text(
                tc.displayName,
                style: TextStyle(
                  color: selected ? accent : kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color:
                selected ? kPrimaryColor.withValues(alpha: 0.15) : kBlack3Color,
            border: Border.all(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.55)
                      : kDividerColor,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kPrimaryColor : kWhiteColor70,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }
}

class _RatingDistributionCard extends StatelessWidget {
  const _RatingDistributionCard({required this.profile});
  final PlayUserProfile profile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: _panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'BREAKDOWN',
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          for (final tc in _kTimeControls) ...[
            _BreakdownRow(tc: tc, stats: profile.statsFor(tc)),
            if (tc != _kTimeControls.last)
              const Divider(height: 14, color: kDividerColor),
          ],
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({required this.tc, required this.stats});
  final RatedTimeControl tc;
  final PlayRatingStats stats;

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(tc);
    return Row(
      children: [
        Image.asset(_assetFor(tc), width: 16, height: 16),
        const SizedBox(width: 10),
        SizedBox(
          width: 80,
          child: Text(
            tc.displayName,
            style: TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Expanded(
          child: Text(
            '${stats.rating}',
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(
          'Peak ${stats.peak}',
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 14),
        Text(
          '${stats.gamesPlayed}g',
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${stats.winRatePct}%',
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Games tab -- filter + sort + list.
// ---------------------------------------------------------------------------

enum _GameResultFilter { all, wins, losses, draws }

extension on _GameResultFilter {
  String get label {
    switch (this) {
      case _GameResultFilter.all:
        return 'All';
      case _GameResultFilter.wins:
        return 'Wins';
      case _GameResultFilter.losses:
        return 'Losses';
      case _GameResultFilter.draws:
        return 'Draws';
    }
  }
}

enum _GameSort { newest, oldest, highRated, lowRated, longest, shortest }

extension on _GameSort {
  String get label {
    switch (this) {
      case _GameSort.newest:
        return 'Newest';
      case _GameSort.oldest:
        return 'Oldest';
      case _GameSort.highRated:
        return 'Highest';
      case _GameSort.lowRated:
        return 'Lowest';
      case _GameSort.longest:
        return 'Longest';
      case _GameSort.shortest:
        return 'Shortest';
    }
  }
}

enum _SourceFilter { all, single, fromHere, tournament }

extension on _SourceFilter {
  String get label {
    switch (this) {
      case _SourceFilter.all:
        return 'Any source';
      case _SourceFilter.single:
        return 'Single';
      case _SourceFilter.fromHere:
        return 'From position';
      case _SourceFilter.tournament:
        return 'Tournament';
    }
  }

  bool matches(PlayGameRecord g) {
    switch (this) {
      case _SourceFilter.all:
        return true;
      case _SourceFilter.single:
        return g.source == PlayGameSource.singlePlay;
      case _SourceFilter.fromHere:
        return g.source == PlayGameSource.playFromHere;
      case _SourceFilter.tournament:
        return g.source == PlayGameSource.tournament;
    }
  }
}

class _GamesBody extends StatefulWidget {
  const _GamesBody({required this.games, required this.loading, this.error});

  final List<PlayGameRecord> games;
  final bool loading;
  final String? error;

  @override
  State<_GamesBody> createState() => _GamesBodyState();
}

class _GamesBodyState extends State<_GamesBody> {
  RatedTimeControl? _tc;
  _GameResultFilter _result = _GameResultFilter.all;
  _GameSort _sort = _GameSort.newest;
  _SourceFilter _source = _SourceFilter.all;
  Side? _color;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  RatedTimeControl? _tcOf(PlayGameRecord g) {
    final fromCat = ratedTimeControlFromString(g.timeCategory);
    if (fromCat != null) return fromCat;
    if (g.baseSeconds != null && g.baseSeconds! > 0) {
      return ratedTimeControlForSeconds(g.baseSeconds!);
    }
    return null;
  }

  bool _matchesQuery(PlayGameRecord g, String q) {
    if (q.isEmpty) return true;
    final hay =
        '${g.whiteName} ${g.blackName} '
                '${g.openingName ?? ''} ${g.eco ?? ''} '
                '${g.endReason} ${g.source.value}'
            .toLowerCase();
    return hay.contains(q);
  }

  List<PlayGameRecord> _filter() {
    final q = _search.text.trim().toLowerCase();
    Iterable<PlayGameRecord> it = widget.games;
    if (_tc != null) it = it.where((g) => _tcOf(g) == _tc);
    it = it.where(_source.matches);
    if (_color != null) {
      final wantWhite = _color == Side.white;
      it = it.where((g) => (g.humanColor == 'white') == wantWhite);
    }
    it = it.where((g) {
      switch (_result) {
        case _GameResultFilter.all:
          return true;
        case _GameResultFilter.wins:
          return g.userScore == 1;
        case _GameResultFilter.losses:
          return g.userScore == 0;
        case _GameResultFilter.draws:
          return g.userScore == 0.5;
      }
    });
    it = it.where((g) => _matchesQuery(g, q));
    final list = it.toList();
    switch (_sort) {
      case _GameSort.newest:
        list.sort((a, b) => b.playedAt.compareTo(a.playedAt));
        break;
      case _GameSort.oldest:
        list.sort((a, b) => a.playedAt.compareTo(b.playedAt));
        break;
      case _GameSort.highRated:
        list.sort((a, b) => (b.ratingAfter ?? 0).compareTo(a.ratingAfter ?? 0));
        break;
      case _GameSort.lowRated:
        list.sort((a, b) => (a.ratingAfter ?? 0).compareTo(b.ratingAfter ?? 0));
        break;
      case _GameSort.longest:
        list.sort((a, b) => b.movesUci.length.compareTo(a.movesUci.length));
        break;
      case _GameSort.shortest:
        list.sort((a, b) => a.movesUci.length.compareTo(b.movesUci.length));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          controller: _search,
          hint: 'Search games — player, opening, ECO, source…',
          onChange: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _RangeChip(
              label: 'ALL TC',
              selected: _tc == null,
              onTap: () => setState(() => _tc = null),
            ),
            for (final tc in _kTimeControls)
              _RangeChip(
                label: tc.displayName.toUpperCase(),
                selected: _tc == tc,
                onTap: () => setState(() => _tc = tc),
              ),
            Container(width: 1, height: 16, color: kDividerColor),
            for (final r in _GameResultFilter.values)
              _RangeChip(
                label: r.label.toUpperCase(),
                selected: r == _result,
                onTap: () => setState(() => _result = r),
              ),
            Container(width: 1, height: 16, color: kDividerColor),
            _RangeChip(
              label: 'ANY COLOR',
              selected: _color == null,
              onTap: () => setState(() => _color = null),
            ),
            _RangeChip(
              label: 'WHITE',
              selected: _color == Side.white,
              onTap: () => setState(() => _color = Side.white),
            ),
            _RangeChip(
              label: 'BLACK',
              selected: _color == Side.black,
              onTap: () => setState(() => _color = Side.black),
            ),
            Container(width: 1, height: 16, color: kDividerColor),
            for (final s in _SourceFilter.values)
              _RangeChip(
                label: s.label.toUpperCase(),
                selected: s == _source,
                onTap: () => setState(() => _source = s),
              ),
            Container(width: 1, height: 16, color: kDividerColor),
            ..._GameSort.values.map(
              (s) => _RangeChip(
                label: s.label.toUpperCase(),
                selected: s == _sort,
                onTap: () => setState(() => _sort = s),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
          child: Text(
            widget.loading
                ? 'Loading games…'
                : '${filtered.length} of ${widget.games.length} games',
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (widget.loading) {
                return const Center(
                  child: CircularProgressIndicator(color: kPrimaryColor),
                );
              }
              if (widget.error != null) {
                return Center(
                  child: Text(
                    widget.error!,
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                );
              }
              if (filtered.isEmpty) {
                return Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 26,
                    ),
                    decoration: _panel(),
                    child: const Text(
                      'No games match these filters yet.',
                      style: TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }
              return _GameList(games: filtered, scrollable: true);
            },
          ),
        ),
      ],
    );
  }
}

class _GameList extends ConsumerWidget {
  const _GameList({required this.games, this.scrollable = false});
  final List<PlayGameRecord> games;
  final bool scrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (games.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: _panel(),
        child: const Center(
          child: Text(
            'No games yet — finish a game in Play to populate this list.',
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return DesktopGameCardsFlow(
      layout: DesktopCardLayout.list,
      embedded: !scrollable,
      itemCount: games.length,
      itemBuilder: (context, i) {
        final game = games[i];
        return DesktopGameCard(
          data: _gameCardData(game),
          layout: DesktopCardLayout.list,
          allowStockfishFallback: false,
          onTap:
              () => openDetachedPgnTab(
                ref,
                label: _gameTitle(game),
                pgn: _pgnWithChesseverSource(game),
              ),
        );
      },
    );
  }
}

GameCardData _gameCardData(PlayGameRecord game) {
  final tc =
      ratedTimeControlFromString(game.timeCategory) ??
      (game.baseSeconds != null
          ? ratedTimeControlForSeconds(game.baseSeconds!)
          : null);
  final score = game.userScore;
  final resultLabel =
      score == 1
          ? 'Win'
          : score == 0
          ? 'Loss'
          : score == 0.5
          ? 'Draw'
          : game.result;
  final subtitle = [
    resultLabel,
    if (tc != null) tc.displayName,
    _formatDate(game.playedAt),
    if (game.ratingAfter != null) '${game.ratingAfter} rating',
  ].join(' · ');
  return GameCardData(
    id: game.localGameKey,
    title: _gameTitle(game),
    whiteName: game.whiteName,
    blackName: game.blackName,
    whiteFederation: game.whiteCountry ?? '',
    blackFederation: game.blackCountry ?? '',
    whiteTitle: game.whiteTitle ?? '',
    blackTitle: game.blackTitle ?? '',
    whiteRating: game.whiteElo ?? 0,
    blackRating: game.blackElo ?? 0,
    fen: game.finalFen.trim().isEmpty ? game.startingFen : game.finalFen,
    lastMove: game.movesUci.isNotEmpty ? game.movesUci.last : null,
    status: _statusFromResult(game.result),
    hasStarted: game.movesUci.isNotEmpty,
    openingName:
        game.openingName?.trim().isNotEmpty == true
            ? game.openingName
            : game.eco,
    subtitle: subtitle,
  );
}

GameStatus _statusFromResult(String result) {
  switch (result.trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
    case '½-½':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

String _gameTitle(PlayGameRecord game) {
  return '${game.whiteName} vs ${game.blackName}';
}

String _pgnWithChesseverSource(PlayGameRecord game) {
  final sourceUrl = _playGameShareUrl(game.localGameKey);
  try {
    final chessGame = ChessGame.fromPgn(game.localGameKey, game.pgn);
    final headers = Map<String, dynamic>.from(chessGame.metadata);
    _applyChesseverSourceHeaders(headers, sourceUrl);
    return exportGameToPgn(chessGame.copyWith(metadata: headers));
  } catch (_) {
    return game.pgn;
  }
}

String _playGameShareUrl(String key) => 'https://chessever.com/games/$key';

void _applyChesseverSourceHeaders(
  Map<String, dynamic> headers,
  String sourceUrl,
) {
  headers['Site'] = sourceUrl;
  headers['Source'] = sourceUrl;
  headers['ChessEverSourceUrl'] = sourceUrl;
}

// ---------------------------------------------------------------------------
// Achievements tab -- reuses the badge gallery + a summary hero.
// ---------------------------------------------------------------------------

class _AchievementsBody extends ConsumerWidget {
  const _AchievementsBody({required this.state});
  final PlayAchievementsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AchievementHero(state: state),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 340,
              mainAxisExtent: 128,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: kPlayAchievementDefinitions.length,
            itemBuilder: (context, index) {
              final def = kPlayAchievementDefinitions[index];
              final unlocked = state.unlocked.contains(def.id);
              final claimable = state.claimable.contains(def.id);
              final earned = unlocked || claimable;
              final progress = state.stats.progressFor(def.id);
              final value = (progress / def.target).clamp(0.0, 1.0);
              final card = AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  color:
                      claimable
                          ? def.color.withValues(alpha: 0.08)
                          : kBlack2Color,
                  border: Border.all(
                    color:
                        earned
                            ? def.color.withValues(alpha: 0.55)
                            : kDividerColor,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow:
                      earned
                          ? [
                            BoxShadow(
                              color: def.color.withValues(alpha: 0.10),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ]
                          : null,
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    PlayAchievementBadgeArt(
                      definition: def,
                      unlocked: earned,
                      size: 64,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  def.title,
                                  style: TextStyle(
                                    color: earned ? kWhiteColor : kWhiteColor70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              Text(
                                unlocked
                                    ? 'CLAIMED'
                                    : claimable
                                    ? 'CLAIM'
                                    : '${(value * 100).round()}%',
                                style: TextStyle(
                                  color:
                                      earned ? def.color : kSecondaryTextColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            def.description,
                            style: const TextStyle(
                              color: kSecondaryTextColor,
                              fontSize: 11,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            def.group.label,
                            style: TextStyle(
                              color:
                                  earned
                                      ? def.color.withValues(alpha: 0.82)
                                      : kWhiteColor.withValues(alpha: 0.36),
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: value.toDouble(),
                              minHeight: 5,
                              color: def.color,
                              backgroundColor: kBlackColor.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              if (!claimable) return card;
              return _Tap(
                onTap: () async {
                  await ref
                      .read(playAchievementsProvider.notifier)
                      .claimAchievements([def.id]);
                  ref.invalidate(playUserProfileProvider);
                },
                child: card,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AchievementHero extends ConsumerWidget {
  const _AchievementHero({required this.state});
  final PlayAchievementsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = kPlayAchievementDefinitions.length;
    final unlocked = state.unlocked.length;
    final claimable = state.claimable.length;
    final value = total == 0 ? 0.0 : unlocked / total;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.all(color: kDividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Achievement cabinet',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                claimable == 0
                    ? '$unlocked / $total'
                    : '$unlocked / $total · $claimable ready',
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 7,
              color: kPrimaryColor,
              backgroundColor: kBlack3Color,
            ),
          ),
          if (claimable > 0) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.inventory_2_outlined),
                onPress: () async {
                  await ref
                      .read(playAchievementsProvider.notifier)
                      .claimAllPending();
                  ref.invalidate(playUserProfileProvider);
                },
                child: const Text('Claim ready badges'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: kSecondaryTextColor,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.4,
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(color: kPrimaryColor));
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _panel(),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
            ),
            FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.refresh_rounded),
              onPress: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
