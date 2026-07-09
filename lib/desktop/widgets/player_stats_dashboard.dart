import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart'
    show PlayRatingPoint;
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/play_rating_chart.dart';
import 'package:chessever/theme/app_theme.dart';

// Result palette — chess-database convention: win green, draw slate, loss red.
const Color _kWin = kGreenColor;
const Color _kDraw = Color(0xFF8B93A7);
const Color _kLoss = kRedColor;
const Color _kUnclassified = Color(0xFF465160);

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
    this.playerFideId,
    this.revision = 0,
    this.onDownloadGames,
    this.onOverviewFilter,
  });

  final List<PlayerStatsSource> sources;
  final List<String> aliases;
  final String? playerFideId;
  final int revision;
  final VoidCallback? onDownloadGames;

  /// When a stats surface is tapped, seed Games-tab filters and navigate.
  final ValueChanged<PlayerOverviewFilterRequest>? onOverviewFilter;

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
      playerFideId: widget.playerFideId,
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
            error:
                (error, _) => _StatsMessage(
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
              return _StatsBody(
                snapshot: snapshot,
                sourcePath: source.path,
                onOverviewFilter: widget.onOverviewFilter,
              );
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
              color: selected ? accent.withValues(alpha: 0.6) : kDividerColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
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
  const _StatsBody({
    required this.snapshot,
    required this.sourcePath,
    this.onOverviewFilter,
  });

  final PlayerStatsSnapshot snapshot;
  final String sourcePath;
  final ValueChanged<PlayerOverviewFilterRequest>? onOverviewFilter;

  void _emit(PlayerOverviewFilterFacet facet, {String? eco, int? year, String? tc}) {
    final cb = onOverviewFilter;
    if (cb == null) return;
    cb(
      PlayerOverviewFilterRequest(
        facet: facet,
        ecoCode: eco,
        year: year,
        timeControlCategory: tc,
        sourcePath: sourcePath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _HeroStripe(snapshot: snapshot),
        const SizedBox(height: 14),
        _ScorePanel(
          snapshot: snapshot,
          onWins: () => _emit(PlayerOverviewFilterFacet.wins),
          onDraws: () => _emit(PlayerOverviewFilterFacet.draws),
          onLosses: () => _emit(PlayerOverviewFilterFacet.losses),
        ),
        if (snapshot.ratingSeries.length >= 2) ...[
          const SizedBox(height: 14),
          _RatingSection(
            spots: snapshot.ratingSeries,
            timeControlCategory: snapshot.ratingTimeControlCategory,
          ),
        ],
        const SizedBox(height: 14),
        _ColorSplitRow(
          snapshot: snapshot,
          onAsWhite: () => _emit(PlayerOverviewFilterFacet.asWhite),
          onAsBlack: () => _emit(PlayerOverviewFilterFacet.asBlack),
        ),
        if (snapshot.openings.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OpeningsPanel(
            openings: snapshot.openings,
            onOpening:
                (eco) => _emit(PlayerOverviewFilterFacet.eco, eco: eco),
          ),
        ],
        if (snapshot.opponents.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OpponentsPanel(opponents: snapshot.opponents),
        ],
        if (snapshot.years.length >= 2) ...[
          const SizedBox(height: 14),
          _YearsPanel(
            years: snapshot.years,
            timeControls: snapshot.timeControls,
            onYear: (y) => _emit(PlayerOverviewFilterFacet.year, year: y),
            onTimeControl:
                (cat) =>
                    _emit(PlayerOverviewFilterFacet.timeControl, tc: cat),
          ),
        ],
        if (_hasLengths(snapshot.lengthBuckets)) ...[
          const SizedBox(height: 14),
          _LengthPanel(buckets: snapshot.lengthBuckets),
        ],
      ],
    );
  }

  static bool _hasLengths(List<PlayerLengthBucket> buckets) =>
      buckets.any((b) => b.count > 0);
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
    final ratingCategory = snapshot.ratingTimeControlCategory;
    final ratingNowLabel =
        ratingCategory == null ? 'Now' : '${_titleCase(ratingCategory)} now';
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
        sub:
            snapshot.latestRating == null
                ? 'No classified rated games'
                : '$ratingNowLabel ${snapshot.latestRating}',
      ),
      _StatCard(
        icon: Icons.military_tech_outlined,
        accent: const Color(0xFF5AA9E6),
        value: snapshot.performanceRating?.toString() ?? '—',
        label: 'Performance',
        sub:
            snapshot.averageOpponentRating == null
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
  const _ScorePanel({
    required this.snapshot,
    this.onWins,
    this.onDraws,
    this.onLosses,
  });

  final PlayerStatsSnapshot snapshot;
  final VoidCallback? onWins;
  final VoidCallback? onDraws;
  final VoidCallback? onLosses;

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
              _RecordChunk(
                count: tally.wins,
                label: 'Wins',
                color: _kWin,
                onTap: onWins,
              ),
              _RecordChunk(
                count: tally.draws,
                label: 'Draws',
                color: _kDraw,
                onTap: onDraws,
              ),
              _RecordChunk(
                count: tally.losses,
                label: 'Losses',
                color: _kLoss,
                onTap: onLosses,
              ),
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
    this.onTap,
  });

  final int count;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
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
    if (onTap == null) return content;
    return ClickCursor(
      child: DesktopTooltip(
        message: 'Show $label games',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
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
  const _RatingSection({required this.spots, this.timeControlCategory});

  final List<PlayerRatingSpot> spots;
  final String? timeControlCategory;

  @override
  Widget build(BuildContext context) {
    final points = _toPoints(spots);
    final latest = spots.last.rating;
    final peak = spots.map((s) => s.rating).reduce((a, b) => a > b ? a : b);
    final title =
        timeControlCategory == null
            ? 'Rating progression'
            : '${_titleCase(timeControlCategory!)} rating progression';
    return _Panel(
      accent: kPrimaryColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Eyebrow(title),
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
  const _ColorSplitRow({
    required this.snapshot,
    this.onAsWhite,
    this.onAsBlack,
  });

  final PlayerStatsSnapshot snapshot;
  final VoidCallback? onAsWhite;
  final VoidCallback? onAsBlack;

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
              onTap: onAsWhite,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _ColorCard(
              label: 'As Black',
              icon: Icons.circle,
              tally: snapshot.asBlack,
              onTap: onAsBlack,
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
    this.onTap,
  });

  final String label;
  final IconData icon;
  final PlayerResultTally tally;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final score = tally.scorePercent;
    final panel = _Panel(
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
    if (onTap == null) return panel;
    return ClickCursor(
      child: DesktopTooltip(
        message: 'Show games played $label',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: panel,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Openings
// ---------------------------------------------------------------------------

class _OpeningsPanel extends StatelessWidget {
  const _OpeningsPanel({required this.openings, this.onOpening});

  final List<PlayerOpeningStat> openings;
  final ValueChanged<String>? onOpening;

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
            _OpeningRow(
              opening: openings[i],
              onTap:
                  onOpening == null
                      ? null
                      : () => onOpening!(openings[i].eco),
            ),
          ],
        ],
      ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  const _OpeningRow({required this.opening, this.onTap});

  final PlayerOpeningStat opening;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final score = opening.tally.scorePercent;
    final row = Row(
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
    if (onTap == null) return row;
    return ClickCursor(
      child: DesktopTooltip(
        message: 'Show games with ${opening.eco}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: row,
        ),
      ),
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
// Games-by-year chart + time-control chips
// ---------------------------------------------------------------------------

/// Games-per-year bar chart stacked by W/D/L. Static bars (no draw-in or
/// hover motion); hover shows an instant detail popup for that year.
class _YearsPanel extends StatefulWidget {
  const _YearsPanel({
    required this.years,
    required this.timeControls,
    this.onYear,
    this.onTimeControl,
  });

  final List<PlayerYearStat> years;
  final List<PlayerTimeControlStat> timeControls;
  final ValueChanged<int>? onYear;
  final ValueChanged<String>? onTimeControl;

  @override
  State<_YearsPanel> createState() => _YearsPanelState();
}

class _YearsPanelState extends State<_YearsPanel> {
  int? _hoveredYear;

  @override
  Widget build(BuildContext context) {
    final series = playerYearChartSeries(widget.years);
    final maxGames = playerYearChartMaxGames(series);
    final yTicks = _yearAxisTicks(maxGames);
    final totalGames = series.fold<int>(0, (sum, p) => sum + p.games);
    PlayerYearChartPoint? hovered;
    final hoveredYear = _hoveredYear;
    if (hoveredYear != null) {
      for (final point in series) {
        if (point.year == hoveredYear) {
          hovered = point;
          break;
        }
      }
    }

    return _Panel(
      accent: kPrimaryColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _Eyebrow('Games by year'),
              const Spacer(),
              Text(
                '${_formatInt(totalGames)} total',
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 12),
              const _ResultLegend(),
            ],
          ),
          if (widget.timeControls.isNotEmpty) ...[
            const SizedBox(height: 12),
            _TimeControlChips(
              timeControls: widget.timeControls,
              onTap: widget.onTimeControl,
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 188,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 34,
                  child: _YearAxisLabels(ticks: yTicks, maxGames: maxGames),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _YearChartGridPainter(
                            ticks: yTicks,
                            maxGames: maxGames,
                          ),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final point in series)
                            Expanded(
                              child: _YearChartBar(
                                point: point,
                                maxGames: maxGames,
                                hovered: _hoveredYear == point.year,
                                onHover:
                                    (active) => setState(() {
                                      _hoveredYear =
                                          active ? point.year : null;
                                    }),
                                onTap:
                                    widget.onYear == null
                                        ? null
                                        : () => widget.onYear!(point.year),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (hovered != null) ...[
            const SizedBox(height: 12),
            _YearHoverCard(point: hovered),
          ],
        ],
      ),
    );
  }
}

class _ResultLegend extends StatelessWidget {
  const _ResultLegend();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LegendDot(color: _kWin, label: 'W'),
        SizedBox(width: 8),
        _LegendDot(color: _kDraw, label: 'D'),
        SizedBox(width: 8),
        _LegendDot(color: _kLoss, label: 'L'),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

List<int> _yearAxisTicks(int maxGames) {
  if (maxGames <= 1) return const <int>[0, 1];
  final step = _niceStep(maxGames / 3);
  final top = ((maxGames / step).ceil() * step).clamp(step, maxGames * 2);
  final ticks = <int>{0, step, step * 2, top}.toList()..sort();
  return ticks;
}

int _niceStep(double rough) {
  if (rough <= 1) return 1;
  final exp = (math.log(rough) / math.ln10).floor();
  final base = math.pow(10, exp).toDouble();
  final fraction = rough / base;
  final nice =
      fraction <= 1
          ? 1.0
          : fraction <= 2
          ? 2.0
          : fraction <= 5
          ? 5.0
          : 10.0;
  return (nice * base).round().clamp(1, 1000000);
}

class _TimeControlChips extends StatelessWidget {
  const _TimeControlChips({required this.timeControls, this.onTap});

  final List<PlayerTimeControlStat> timeControls;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final total = timeControls.fold<int>(0, (sum, tc) => sum + tc.count);
    if (total <= 0) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tc in timeControls)
          _TimeControlChip(
            category: tc.category,
            count: tc.count,
            share: tc.count / total,
            onTap: onTap == null ? null : () => onTap!(tc.category),
          ),
      ],
    );
  }
}

class _TimeControlChip extends StatelessWidget {
  const _TimeControlChip({
    required this.category,
    required this.count,
    required this.share,
    this.onTap,
  });

  final String category;
  final int count;
  final double share;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = _timeControlAccent(category);
    final pct = (share * 100).round();
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(9, 5, 9, 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _titleCase(category),
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$pct%',
            style: TextStyle(
              color: kWhiteColor.withValues(alpha: 0.72),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return DesktopTooltip(
      message:
          onTap == null
              ? '${_titleCase(category)} · ${_formatInt(count)} games · $pct% of activity'
              : 'Show ${_titleCase(category)} games · ${_formatInt(count)} · $pct%',
      child:
          onTap == null
              ? chip
              : ClickCursor(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: chip,
                ),
              ),
    );
  }
}

Color _timeControlAccent(String category) {
  switch (category.trim().toLowerCase()) {
    case 'classical':
    case 'standard':
      return const Color(0xFF60A5FA);
    case 'rapid':
      return const Color(0xFF34D399);
    case 'blitz':
      return const Color(0xFFFBBF24);
    case 'bullet':
      return const Color(0xFFF87171);
    case 'correspondence':
    case 'daily':
      return const Color(0xFFA78BFA);
    default:
      return kPrimaryColor;
  }
}

class _YearAxisLabels extends StatelessWidget {
  const _YearAxisLabels({required this.ticks, required this.maxGames});

  final List<int> ticks;
  final int maxGames;

  @override
  Widget build(BuildContext context) {
    // Leave room under the plot for year labels (~18px).
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Stack(
            children: [
              for (final tick in ticks)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom:
                      maxGames <= 0
                          ? 0
                          : (tick / maxGames).clamp(0.0, 1.0) * height - 6,
                  child: Text(
                    _formatInt(tick),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: kWhiteColor.withValues(alpha: 0.38),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _YearChartGridPainter extends CustomPainter {
  const _YearChartGridPainter({required this.ticks, required this.maxGames});

  final List<int> ticks;
  final int maxGames;

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - 18;
    if (plotHeight <= 0 || maxGames <= 0) return;
    final line =
        Paint()
          ..color = kDividerColor.withValues(alpha: 0.55)
          ..strokeWidth = 1;
    final baseline =
        Paint()
          ..color = kDividerColor.withValues(alpha: 0.9)
          ..strokeWidth = 1.2;
    for (final tick in ticks) {
      final y = plotHeight - (tick / maxGames).clamp(0.0, 1.0) * plotHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    canvas.drawLine(
      Offset(0, plotHeight),
      Offset(size.width, plotHeight),
      baseline,
    );
  }

  @override
  bool shouldRepaint(covariant _YearChartGridPainter oldDelegate) {
    return oldDelegate.maxGames != maxGames ||
        !listEquals(oldDelegate.ticks, ticks);
  }
}

/// Stacked W/D/L bar for one year. Static — no AnimatedContainer / shadows.
class _YearChartBar extends StatelessWidget {
  const _YearChartBar({
    required this.point,
    required this.maxGames,
    required this.hovered,
    required this.onHover,
    this.onTap,
  });

  final PlayerYearChartPoint point;
  final int maxGames;
  final bool hovered;
  final ValueChanged<bool> onHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final games = point.games;
    final heightFactor =
        games <= 0 ? 0.0 : (games / maxGames).clamp(0.035, 1.0).toDouble();

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final plotHeight = constraints.maxHeight;
                    final availableWidth = constraints.maxWidth;
                    final barWidth =
                        (availableWidth * 0.55).clamp(8.0, 28.0).toDouble();
                    final width =
                        barWidth > availableWidth ? availableWidth : barWidth;
                    final barHeight =
                        games <= 0
                            ? 0.0
                            : (plotHeight * heightFactor)
                                .clamp(3.0, plotHeight)
                                .toDouble();
                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: Opacity(
                        opacity: hovered ? 1 : 0.9,
                        child: Container(
                          key: ValueKey<String>(
                            'player-stats-year-bar-${point.year}',
                          ),
                          width: width,
                          height: barHeight,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            children: [
                              if (point.wins > 0)
                                Expanded(
                                  flex: point.wins,
                                  child: const ColoredBox(color: _kWin),
                                ),
                              if (point.draws > 0)
                                Expanded(
                                  flex: point.draws,
                                  child: const ColoredBox(color: _kDraw),
                                ),
                              if (point.losses > 0)
                                Expanded(
                                  flex: point.losses,
                                  child: const ColoredBox(color: _kLoss),
                                ),
                              if (point.unclassified > 0)
                                Expanded(
                                  flex: point.unclassified,
                                  child: const ColoredBox(
                                    color: _kUnclassified,
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
              const SizedBox(height: 6),
              Text(
                point.year.toString(),
                style: TextStyle(
                  color:
                      hovered
                          ? kWhiteColor
                          : kSecondaryTextColor.withValues(alpha: 0.9),
                  fontSize: 10,
                  fontWeight: hovered ? FontWeight.w800 : FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Instant hover detail: W/D/L counts, per-year sources, time controls.
class _YearHoverCard extends StatelessWidget {
  const _YearHoverCard({required this.point});

  final PlayerYearChartPoint point;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${point.year}',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${_formatInt(point.games)} games',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              _HoverResultChip(label: 'W', value: point.wins, color: _kWin),
              const SizedBox(width: 6),
              _HoverResultChip(label: 'D', value: point.draws, color: _kDraw),
              const SizedBox(width: 6),
              _HoverResultChip(label: 'L', value: point.losses, color: _kLoss),
            ],
          ),
          if (point.sources.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Sources',
              style: TextStyle(
                color: kSecondaryTextColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final src in point.sources)
                  _HoverMetaChip(
                    label: src.label,
                    value: src.count,
                    color: _sourceAccent(src.label),
                  ),
              ],
            ),
          ],
          if (point.timeControls.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Time controls',
              style: TextStyle(
                color: kSecondaryTextColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tc in point.timeControls)
                  _HoverMetaChip(
                    label: _titleCase(tc.category),
                    value: tc.count,
                    color: _timeControlAccent(tc.category),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HoverResultChip extends StatelessWidget {
  const _HoverResultChip({
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label ${_formatInt(value)}',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _HoverMetaChip extends StatelessWidget {
  const _HoverMetaChip({
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        '$label · ${_formatInt(value)}',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

Color _sourceAccent(String label) {
  switch (label.trim().toLowerCase()) {
    case 'lichess':
      return const Color(0xFF81B64C);
    case 'chess.com':
      return const Color(0xFF00A86B);
    case 'chess24':
      return const Color(0xFF60A5FA);
    case 'chessbase':
      return const Color(0xFFFBBF24);
    case 'unknown':
      return kSecondaryTextColor;
    default:
      return kPrimaryColor;
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
    final factor =
        bucket.count == 0 ? 0.0 : (bucket.count / maxCount).clamp(0.05, 1.0);
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
          color:
              accent == null ? kDividerColor : accent!.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
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
            color:
                selected ? kPrimaryColor.withValues(alpha: 0.15) : kBlack3Color,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color:
                  selected
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
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kPrimaryColor,
          ),
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
