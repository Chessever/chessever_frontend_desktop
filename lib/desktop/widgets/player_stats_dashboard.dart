import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart'
    show PlayRatingPoint;
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/play_rating_chart.dart';
import 'package:chessever/theme/app_theme.dart';

// Result palette — chess-database convention: win green, draw slate, loss red.
const Color _kWin = kGreenColor;
const Color _kDraw = Color(0xFF8B93A7);
const Color _kLoss = kRedColor;

/// One selectable data source feeding the dashboard — a connected account's
/// local PGN database or the deduped combined set. Selecting one re-scopes the
/// entire dashboard to that resqlite database (all queries are already indexed
/// on `database_id`).
@immutable
class PlayerStatsSource {
  const PlayerStatsSource({
    required this.label,
    required this.accent,
    required this.path,
    required this.gameCount,
  });

  final String label;
  final Color accent;
  final String path;
  final int gameCount;
}

/// A relative date window applied to the whole dashboard, resolved against the
/// player's most recent game so it stays meaningful for historical players.
enum PlayerStatsWindow { all, year, sixMonths, ninetyDays, thirtyDays }

extension on PlayerStatsWindow {
  String get label => switch (this) {
    PlayerStatsWindow.all => 'All time',
    PlayerStatsWindow.year => '1Y',
    PlayerStatsWindow.sixMonths => '6M',
    PlayerStatsWindow.ninetyDays => '90D',
    PlayerStatsWindow.thirtyDays => '30D',
  };

  int? get days => switch (this) {
    PlayerStatsWindow.all => null,
    PlayerStatsWindow.year => 365,
    PlayerStatsWindow.sixMonths => 180,
    PlayerStatsWindow.ninetyDays => 90,
    PlayerStatsWindow.thirtyDays => 30,
  };
}

/// Locally-computed statistics dashboard for one workspace player, rendered in
/// the same visual language as the Play profile (panels, tinted-square icons,
/// tabular numbers, the reused animated rating chart).
///
/// A filter toolbar lets the user pick which source database and date window
/// feed every metric — the "prep" surface for scouting one opponent across
/// merged sources.
class PlayerStatsDashboard extends ConsumerStatefulWidget {
  const PlayerStatsDashboard({
    super.key,
    required this.sources,
    required this.aliases,
    this.revision = 0,
    this.onDownloadGames,
  });

  final List<PlayerStatsSource> sources;
  final List<String> aliases;
  final int revision;
  final VoidCallback? onDownloadGames;

  @override
  ConsumerState<PlayerStatsDashboard> createState() =>
      _PlayerStatsDashboardState();
}

class _PlayerStatsDashboardState extends ConsumerState<PlayerStatsDashboard> {
  int _sourceIndex = 0;
  PlayerStatsWindow _window = PlayerStatsWindow.all;

  @override
  Widget build(BuildContext context) {
    final sources = widget.sources;
    if (sources.isEmpty) {
      return _StatsMessage(
        icon: Icons.query_stats_outlined,
        title: 'No games to analyze yet',
        subtitle:
            'Download this player\'s games from a connected source, then the '
            'full statistics dashboard appears here — computed locally.',
        actionLabel: widget.onDownloadGames == null ? null : 'Go to Accounts',
        onAction: widget.onDownloadGames,
      );
    }
    final index = _sourceIndex.clamp(0, sources.length - 1);
    final source = sources[index];
    final request = PlayerStatsRequest(
      databasePath: source.path,
      aliases: widget.aliases,
      revision: widget.revision,
      windowDays: _window.days,
    );
    final async = ref.watch(playerStatsProvider(request));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PrepToolbar(
          sources: sources,
          selectedIndex: index,
          window: _window,
          loading: async.isLoading,
          onSource: (i) => setState(() => _sourceIndex = i),
          onWindow: (w) => setState(() => _window = w),
        ),
        Expanded(
          child: async.when(
            loading: () => const _StatsMessage(spinner: true),
            error: (error, _) => _StatsMessage(
              icon: Icons.error_outline_rounded,
              title: 'Could not compute statistics',
              subtitle: '$error',
            ),
            data: (snapshot) {
              if (snapshot.isEmpty) {
                return _StatsMessage(
                  icon: Icons.filter_alt_off_outlined,
                  title: 'No games in this view',
                  subtitle:
                      'No games match “${source.label}” in the ${_window.label} '
                      'window. Try a wider range or another source.',
                );
              }
              return _StatsBody(snapshot: snapshot);
            },
          ),
        ),
      ],
    );
  }
}

/// Source + date-window selector strip that sits above the metrics. Answers
/// "what is this chart sourcing from" by making the active database explicit
/// and switchable, and scopes the whole dashboard by date.
class _PrepToolbar extends StatelessWidget {
  const _PrepToolbar({
    required this.sources,
    required this.selectedIndex,
    required this.window,
    required this.loading,
    required this.onSource,
    required this.onWindow,
  });

  final List<PlayerStatsSource> sources;
  final int selectedIndex;
  final PlayerStatsWindow window;
  final bool loading;
  final ValueChanged<int> onSource;
  final ValueChanged<PlayerStatsWindow> onWindow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 2),
      child: _Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _Eyebrow('Source'),
                const SizedBox(width: 8),
                if (loading)
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: kPrimaryColor,
                    ),
                  ),
                const Spacer(),
                Text(
                  '${_formatInt(sources[selectedIndex].gameCount)} games',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < sources.length; i++)
                  PlayerSourceChip(
                    source: sources[i],
                    selected: i == selectedIndex,
                    onTap: () => onSource(i),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const _Eyebrow('Date range'),
            const SizedBox(height: 9),
            Row(
              children: [
                for (final w in PlayerStatsWindow.values) ...[
                  _Pill(
                    label: w.label,
                    selected: w == window,
                    onTap: () => onWindow(w),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Source chip — like [_Pill] but carries the source's brand accent so merged
/// databases are distinguishable at a glance. Shared by the Overview toolbar
/// and the Games tab source bar.
class PlayerSourceChip extends StatelessWidget {
  const PlayerSourceChip({
    super.key,
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final PlayerStatsSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = source.accent;
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : kBlack3Color,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.6)
                  : kDividerColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                source.label,
                style: TextStyle(
                  color: selected ? kWhiteColor : kWhiteColor70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.snapshot});

  final PlayerStatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _HeroStripe(snapshot: snapshot),
        const SizedBox(height: 14),
        _ScorePanel(snapshot: snapshot),
        if (snapshot.ratingSeries.length >= 2) ...[
          const SizedBox(height: 14),
          _RatingSection(spots: snapshot.ratingSeries),
        ],
        const SizedBox(height: 14),
        _ColorSplitRow(snapshot: snapshot),
        if (snapshot.openings.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OpeningsPanel(openings: snapshot.openings),
        ],
        if (snapshot.opponents.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OpponentsPanel(opponents: snapshot.opponents),
        ],
        if (snapshot.years.length >= 2) ...[
          const SizedBox(height: 14),
          _YearsPanel(years: snapshot.years),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_hasLengths(snapshot.lengthBuckets)) ...[
              Expanded(child: _lengthPanelWrapper(snapshot.lengthBuckets)),
              const SizedBox(width: 14),
            ],
            if (snapshot.timeControls.isNotEmpty)
              Expanded(child: _timeControlWrapper(snapshot.timeControls))
            else
              const Spacer(),
          ],
        ),
      ],
    );
  }

  static bool _hasLengths(List<PlayerLengthBucket> buckets) =>
      buckets.any((b) => b.count > 0);

  Widget _lengthPanelWrapper(List<PlayerLengthBucket> buckets) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: _LengthPanel(buckets: buckets),
  );

  Widget _timeControlWrapper(List<PlayerTimeControlStat> tcs) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: _TimeControlPanel(timeControls: tcs),
  );
}

// ---------------------------------------------------------------------------
// Hero stat stripe
// ---------------------------------------------------------------------------

class _HeroStripe extends StatelessWidget {
  const _HeroStripe({required this.snapshot});

  final PlayerStatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final winRate = snapshot.overall.scorePercent;
    final cards = <Widget>[
      _StatCard(
        icon: Icons.sports_score_outlined,
        accent: kPrimaryColor,
        value: _formatInt(snapshot.games),
        label: 'Games analyzed',
        sub: '${_formatInt(snapshot.decisiveGames)} decisive',
      ),
      _StatCard(
        icon: Icons.emoji_events_outlined,
        accent: _scoreColor(winRate),
        value: winRate == null ? '—' : '${winRate.round()}%',
        label: 'Score',
        subWidget: _ResultBreakdownChips(
          tally: snapshot.overall,
          includeScore: false,
        ),
      ),
      _StatCard(
        icon: Icons.trending_up_rounded,
        accent: const Color(0xFFE9A23B),
        value: snapshot.peakRating?.toString() ?? '—',
        label: 'Peak rating',
        sub: snapshot.latestRating == null
            ? 'No rated games'
            : 'Now ${snapshot.latestRating}',
      ),
      _StatCard(
        icon: Icons.military_tech_outlined,
        accent: const Color(0xFF5AA9E6),
        value: snapshot.performanceRating?.toString() ?? '—',
        label: 'Performance',
        sub: snapshot.averageOpponentRating == null
            ? 'Opponents unrated'
            : 'vs avg ${snapshot.averageOpponentRating}',
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.accent,
    required this.value,
    required this.label,
    this.sub,
    this.subWidget,
  });

  final IconData icon;
  final Color accent;
  final String value;
  final String label;
  final String? sub;
  final Widget? subWidget;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconSquare(icon: icon, accent: accent),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          if (subWidget != null) ...[
            const SizedBox(height: 6),
            subWidget!,
          ] else if (sub != null) ...[
            const SizedBox(height: 6),
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overall score panel — big W/D/L bar
// ---------------------------------------------------------------------------

class _ScorePanel extends StatelessWidget {
  const _ScorePanel({required this.snapshot});

  final PlayerStatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final tally = snapshot.overall;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _Eyebrow('Overall record'),
              const Spacer(),
              _Legend(tally: tally),
            ],
          ),
          const SizedBox(height: 12),
          _ScoreBar(tally: tally, height: 12),
          const SizedBox(height: 10),
          Row(
            children: [
              _RecordChunk(count: tally.wins, label: 'Wins', color: _kWin),
              _RecordChunk(count: tally.draws, label: 'Draws', color: _kDraw),
              _RecordChunk(count: tally.losses, label: 'Losses', color: _kLoss),
              const Spacer(),
              if (snapshot.decisiveRate != null)
                Text(
                  '${snapshot.decisiveRate!.round()}% decisive',
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordChunk extends StatelessWidget {
  const _RecordChunk({
    required this.count,
    required this.label,
    required this.color,
  });

  final int count;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            _formatInt(count),
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rounded stacked W/D/L bar.
class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.tally, this.height = 10});

  final PlayerResultTally tally;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (tally.games == 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(height: height, color: kDividerColor),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            if (tally.wins > 0)
              Expanded(flex: tally.wins, child: ColoredBox(color: _kWin)),
            if (tally.draws > 0)
              Expanded(flex: tally.draws, child: ColoredBox(color: _kDraw)),
            if (tally.losses > 0)
              Expanded(flex: tally.losses, child: ColoredBox(color: _kLoss)),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.tally});

  final PlayerResultTally tally;

  @override
  Widget build(BuildContext context) {
    return _ResultBreakdownChips(tally: tally, includeScore: false);
  }
}

// ---------------------------------------------------------------------------
// Rating progression (reuses the Play profile chart)
// ---------------------------------------------------------------------------

class _RatingSection extends StatelessWidget {
  const _RatingSection({required this.spots});

  final List<PlayerRatingSpot> spots;

  @override
  Widget build(BuildContext context) {
    final points = _toPoints(spots);
    final latest = spots.last.rating;
    final peak = spots.map((s) => s.rating).reduce((a, b) => a > b ? a : b);
    return _Panel(
      accent: kPrimaryColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _Eyebrow('Rating progression'),
              const Spacer(),
              Text(
                '$latest',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'peak $peak',
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // The date-range window is driven globally by the prep toolbar, so the
          // chart plots the full (already-scoped) series.
          PlayRatingChart(
            points: points,
            accent: kPrimaryColor,
            range: PlayRatingChartRange.allTime,
          ),
        ],
      ),
    );
  }

  List<PlayRatingPoint> _toPoints(List<PlayerRatingSpot> spots) {
    final points = <PlayRatingPoint>[];
    int? prev;
    for (final spot in spots) {
      points.add(
        PlayRatingPoint(
          playedAt: spot.date,
          rating: spot.rating,
          delta: prev == null ? 0 : spot.rating - prev,
          opponentElo: null,
          score: 0,
          kFactor: 0,
        ),
      );
      prev = spot.rating;
    }
    return points;
  }
}

// ---------------------------------------------------------------------------
// Color split
// ---------------------------------------------------------------------------

class _ColorSplitRow extends StatelessWidget {
  const _ColorSplitRow({required this.snapshot});

  final PlayerStatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    // Wrapped in IntrinsicHeight because this Row is a direct child of a
    // ListView (unbounded height); CrossAxisAlignment.stretch would otherwise
    // force an infinite height onto the cards. IntrinsicHeight gives the Row a
    // finite height (the taller card), so stretch equalizes both cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _ColorCard(
              label: 'As White',
              icon: Icons.circle_outlined,
              tally: snapshot.asWhite,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _ColorCard(
              label: 'As Black',
              icon: Icons.circle,
              tally: snapshot.asBlack,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorCard extends StatelessWidget {
  const _ColorCard({
    required this.label,
    required this.icon,
    required this.tally,
  });

  final String label;
  final IconData icon;
  final PlayerResultTally tally;

  @override
  Widget build(BuildContext context) {
    final score = tally.scorePercent;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: kWhiteColor70),
              const SizedBox(width: 8),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                score == null ? '—' : '${score.round()}%',
                style: TextStyle(
                  color: _scoreColor(score),
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _ScoreBar(tally: tally, height: 9),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${_formatInt(tally.games)} games',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              _ResultBreakdownChips(tally: tally, includeScore: false),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Openings
// ---------------------------------------------------------------------------

class _OpeningsPanel extends StatelessWidget {
  const _OpeningsPanel({required this.openings});

  final List<PlayerOpeningStat> openings;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Eyebrow('Top openings'),
          const SizedBox(height: 12),
          for (var i = 0; i < openings.length; i++) ...[
            if (i > 0) const Divider(height: 14, color: kDividerColor),
            _OpeningRow(opening: openings[i]),
          ],
        ],
      ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  const _OpeningRow({required this.opening});

  final PlayerOpeningStat opening;

  @override
  Widget build(BuildContext context) {
    final score = opening.tally.scorePercent;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _openingTitle(opening),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              _ResultBreakdownChips(tally: opening.tally, score: score),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 96, child: _ScoreBar(tally: opening.tally, height: 7)),
      ],
    );
  }
}

String _openingTitle(PlayerOpeningStat opening) {
  final name = opening.name?.trim();
  final eco = opening.eco.trim();
  if (name != null && name.isNotEmpty) return '$name ($eco)';
  return 'Unknown opening ($eco)';
}

// ---------------------------------------------------------------------------
// Opponents
// ---------------------------------------------------------------------------

class _OpponentsPanel extends StatelessWidget {
  const _OpponentsPanel({required this.opponents});

  final List<PlayerOpponentStat> opponents;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Eyebrow('Most-played opponents'),
          const SizedBox(height: 12),
          for (var i = 0; i < opponents.length; i++) ...[
            if (i > 0) const Divider(height: 14, color: kDividerColor),
            _OpponentRow(opponent: opponents[i]),
          ],
        ],
      ),
    );
  }
}

class _OpponentRow extends StatelessWidget {
  const _OpponentRow({required this.opponent});

  final PlayerOpponentStat opponent;

  @override
  Widget build(BuildContext context) {
    final score = opponent.tally.scorePercent;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _shortName(opponent.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ResultBreakdownChips(tally: opponent.tally, score: score),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                opponent.averageRating == null
                    ? '${_formatInt(opponent.tally.games)} games'
                    : '${_formatInt(opponent.tally.games)} games · avg ${opponent.averageRating}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 96, child: _ScoreBar(tally: opponent.tally, height: 7)),
      ],
    );
  }
}

class _ResultBreakdownChips extends StatelessWidget {
  const _ResultBreakdownChips({
    required this.tally,
    this.score,
    this.includeScore = true,
  });

  final PlayerResultTally tally;
  final double? score;
  final bool includeScore;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ResultStatChip(label: 'W', value: tally.wins, color: _kWin),
        const SizedBox(width: 4),
        _ResultStatChip(label: 'D', value: tally.draws, color: _kDraw),
        const SizedBox(width: 4),
        _ResultStatChip(label: 'L', value: tally.losses, color: _kLoss),
        if (includeScore) ...[
          const SizedBox(width: 6),
          _ResultScoreChip(score: score),
        ],
      ],
    );
  }
}

class _ResultStatChip extends StatelessWidget {
  const _ResultStatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 19,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Text(
        '$label ${_formatInt(value)}',
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _ResultScoreChip extends StatelessWidget {
  const _ResultScoreChip({required this.score});

  final double? score;

  @override
  Widget build(BuildContext context) {
    final color = _scoreColor(score);
    return Container(
      height: 19,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: score == null ? 0.06 : 0.11),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: color.withValues(alpha: score == null ? 0.16 : 0.28),
        ),
      ),
      child: Text(
        score == null ? '—' : '${score!.round()}%',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// By-year stacked bars
// ---------------------------------------------------------------------------

class _YearsPanel extends StatelessWidget {
  const _YearsPanel({required this.years});

  final List<PlayerYearStat> years;

  @override
  Widget build(BuildContext context) {
    final maxGames = years
        .map((y) => y.tally.games)
        .fold<int>(1, (a, b) => a > b ? a : b);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Eyebrow('Games by year'),
          const SizedBox(height: 14),
          SizedBox(
            height: 132,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final year in years)
                  Expanded(
                    child: _YearColumn(year: year, maxGames: maxGames),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _YearColumn extends StatelessWidget {
  const _YearColumn({required this.year, required this.maxGames});

  final PlayerYearStat year;
  final int maxGames;

  @override
  Widget build(BuildContext context) {
    final tally = year.tally;
    final heightFactor = (tally.games / maxGames).clamp(0.04, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            _formatInt(tally.games),
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: heightFactor,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Column(
                    children: [
                      if (tally.wins > 0)
                        Expanded(
                          flex: tally.wins,
                          child: const ColoredBox(color: _kWin),
                        ),
                      if (tally.draws > 0)
                        Expanded(
                          flex: tally.draws,
                          child: const ColoredBox(color: _kDraw),
                        ),
                      if (tally.losses > 0)
                        Expanded(
                          flex: tally.losses,
                          child: const ColoredBox(color: _kLoss),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "'${year.year % 100}".padLeft(3, '0'),
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Game-length histogram
// ---------------------------------------------------------------------------

class _LengthPanel extends StatelessWidget {
  const _LengthPanel({required this.buckets});

  final List<PlayerLengthBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final maxCount = buckets
        .map((b) => b.count)
        .fold<int>(1, (a, b) => a > b ? a : b);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Eyebrow('Game length (moves)'),
          const SizedBox(height: 14),
          SizedBox(
            height: 116,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final bucket in buckets)
                  Expanded(
                    child: _HistogramBar(bucket: bucket, maxCount: maxCount),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistogramBar extends StatelessWidget {
  const _HistogramBar({required this.bucket, required this.maxCount});

  final PlayerLengthBucket bucket;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final factor = bucket.count == 0
        ? 0.0
        : (bucket.count / maxCount).clamp(0.05, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Column(
        children: [
          Text(
            _formatInt(bucket.count),
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: factor == 0 ? 0.01 : factor,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        kPrimaryColor.withValues(alpha: 0.9),
                        kPrimaryColor.withValues(alpha: 0.45),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            bucket.label,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Time controls
// ---------------------------------------------------------------------------

class _TimeControlPanel extends StatelessWidget {
  const _TimeControlPanel({required this.timeControls});

  final List<PlayerTimeControlStat> timeControls;

  @override
  Widget build(BuildContext context) {
    final total = timeControls.fold<int>(0, (sum, tc) => sum + tc.count);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Eyebrow('Time controls'),
          const SizedBox(height: 12),
          for (var i = 0; i < timeControls.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _TimeControlRow(stat: timeControls[i], total: total),
          ],
        ],
      ),
    );
  }
}

class _TimeControlRow extends StatelessWidget {
  const _TimeControlRow({required this.stat, required this.total});

  final PlayerTimeControlStat stat;
  final int total;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : stat.count / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _titleCase(stat.category),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${_formatInt(stat.count)} · ${(share * 100).round()}%',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                Expanded(
                  flex: (share * 1000).round().clamp(1, 1000),
                  child: const ColoredBox(color: kPrimaryColor),
                ),
                Expanded(
                  flex: (1000 - (share * 1000).round()).clamp(0, 1000),
                  child: const ColoredBox(color: kDividerColor),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared primitives
// ---------------------------------------------------------------------------

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.accent, this.padding});

  final Widget child;
  final Color? accent;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: accent == null
              ? kDividerColor
              : accent!.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(padding: padding ?? const EdgeInsets.all(16), child: child),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: kSecondaryTextColor,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _IconSquare extends StatelessWidget {
  const _IconSquare({required this.icon, required this.accent});

  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Icon(icon, size: 16, color: accent),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? kPrimaryColor.withValues(alpha: 0.15)
                : kBlack3Color,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? kPrimaryColor.withValues(alpha: 0.55)
                  : kDividerColor,
            ),
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

class _StatsMessage extends StatelessWidget {
  const _StatsMessage({
    this.spinner = false,
    this.icon,
    this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final bool spinner;
  final IconData? icon;
  final String? title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    if (spinner) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: kPrimaryColor),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: kPrimaryColor.withValues(alpha: 0.30),
                  ),
                ),
                child: Icon(icon, color: kPrimaryColor, size: 24),
              ),
              const SizedBox(height: 14),
              Text(
                title ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                ClickCursor(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onAction,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: kPrimaryColor.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Text(
                        actionLabel!,
                        style: const TextStyle(
                          color: kPrimaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

Color _scoreColor(double? percent) {
  if (percent == null) return kWhiteColor;
  if (percent >= 55) return kGreenColor;
  if (percent < 45) return kRedColor;
  return kWhiteColor;
}

String _shortName(String name) {
  final trimmed = name.trim();
  final comma = trimmed.indexOf(',');
  if (comma > 0) {
    final last = trimmed.substring(0, comma).trim();
    final rest = trimmed.substring(comma + 1).trim();
    if (rest.isNotEmpty) return '${rest[0]}. $last';
    return last;
  }
  return trimmed;
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _formatInt(int value) {
  final text = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < text.length; i++) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return buffer.toString();
}
