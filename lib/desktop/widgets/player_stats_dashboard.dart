import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart'
    show PlayRatingPoint;
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/play_rating_chart.dart';
import 'package:chessever/desktop/widgets/tempo_icon.dart';
import 'package:chessever/theme/app_theme.dart';

// Result palette — wins use brand primary (not green), draw slate, loss red.
const Color _kWin = kPrimaryColor;
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
    required this.kind,
    this.preferredTimeControl = 'classical',
    this.unclassifiedTimeControlCategory,
  });

  final String label;
  final Color accent;
  final String path;
  final int gameCount;

  /// Platform this chip represents — drives the brand mark (same assets as
  /// the player list on the left).
  final PlayerWorkspaceSource kind;

  /// Default overview time-control chip for this source:
  /// `classical` for Combined/ChessEver, `blitz` for Lichess/Chess.com.
  final String preferredTimeControl;

  /// Source-level fallback for PGNs that omit `TimeControl`. ChessEver's
  /// FIDE/OTB export is classical unless an explicit tag/event says otherwise.
  final String? unclassifiedTimeControlCategory;
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

  /// null = All; otherwise canonical category. Unset until user or source pick.
  String? _timeControlOverride;
  bool _userPickedTimeControl = false;
  PlayerStatsOutcomeFilter _outcome = PlayerStatsOutcomeFilter.all;
  String? _playerColor; // 'w' | 'b' | null

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
    // Source-aware default (classical for Combined/ChessEver, blitz for online)
    // until the user picks a chip or we switch sources (which resets).
    final timeControl =
        _userPickedTimeControl
            ? _timeControlOverride
            : source.preferredTimeControl;
    final request = PlayerStatsRequest(
      databasePath: source.path,
      aliases: widget.aliases,
      playerFideId: widget.playerFideId,
      revision: widget.revision,
      windowDays: _window.days,
      timeControlCategory: timeControl,
      preferredRatingTimeControl: source.preferredTimeControl,
      unclassifiedTimeControlCategory: source.unclassifiedTimeControlCategory,
      playerOutcome: _outcome,
      playerColor: _playerColor,
    );
    final async = ref.watch(playerStatsProvider(request));

    // Toolbar scrolls with the dashboard body (not a sticky/pinned header).
    final toolbar = _PrepToolbar(
      sources: sources,
      selectedIndex: index,
      window: _window,
      timeControl: timeControl,
      timeControls: async.asData?.value.timeControls ?? const [],
      loading: async.isLoading,
      onSource: (i) {
        setState(() {
          _sourceIndex = i;
          // Switching source resets to that source's default ladder.
          _userPickedTimeControl = false;
          _timeControlOverride = null;
          _outcome = PlayerStatsOutcomeFilter.all;
          _playerColor = null;
        });
      },
      onWindow: (w) => setState(() => _window = w),
      onTimeControl:
          (tc) => setState(() {
            _userPickedTimeControl = true;
            _timeControlOverride = tc;
          }),
    );

    return async.when(
      loading:
          () => _scrollableWithToolbar(
            toolbar: toolbar,
            body: const _StatsMessage(spinner: true),
          ),
      error:
          (error, _) => _scrollableWithToolbar(
            toolbar: toolbar,
            body: _StatsMessage(
              icon: Icons.error_outline_rounded,
              title: 'Could not compute statistics',
              subtitle: '$error',
            ),
          ),
      data: (snapshot) {
        if (snapshot.isEmpty) {
          final hasScopedChips =
              _outcome != PlayerStatsOutcomeFilter.all || _playerColor != null;
          return _scrollableWithToolbar(
            toolbar: toolbar,
            body: _StatsMessage(
              icon: Icons.filter_alt_off_outlined,
              title: 'No games in this view',
              subtitle:
                  'No games match “${source.label}”'
                  '${timeControl == null ? '' : ' · ${_titleCase(timeControl)}'}'
                  '${_outcome == PlayerStatsOutcomeFilter.all ? '' : ' · ${_outcomeLabel(_outcome)}'}'
                  '${_playerColor == null ? '' : (_playerColor == 'w' ? ' · As White' : ' · As Black')}'
                  ' in the ${_window.label} window.',
              actionLabel:
                  hasScopedChips ? 'Clear result & colour filters' : null,
              onAction:
                  hasScopedChips
                      ? () => setState(() {
                        _outcome = PlayerStatsOutcomeFilter.all;
                        _playerColor = null;
                      })
                      : null,
              secondaryActionLabel:
                  timeControl != null || _window != PlayerStatsWindow.all
                      ? 'Reset time control & range'
                      : null,
              onSecondaryAction:
                  timeControl != null || _window != PlayerStatsWindow.all
                      ? () => setState(() {
                        _userPickedTimeControl = true;
                        _timeControlOverride = null; // All TCs
                        _window = PlayerStatsWindow.all;
                        _outcome = PlayerStatsOutcomeFilter.all;
                        _playerColor = null;
                      })
                      : null,
            ),
          );
        }
        return _StatsBody(
          toolbar: toolbar,
          snapshot: snapshot,
          sourcePath: source.path,
          outcome: _outcome,
          playerColor: _playerColor,
          onOutcome: (next) => setState(() => _outcome = next),
          onPlayerColor: (next) => setState(() => _playerColor = next),
          onOverviewFilter: widget.onOverviewFilter,
        );
      },
    );
  }
}

/// Toolbar + short body (loading / error / empty) in one scroll view so the
/// filter strip is not pinned above the viewport.
Widget _scrollableWithToolbar({required Widget toolbar, required Widget body}) {
  return CustomScrollView(
    slivers: [
      SliverToBoxAdapter(child: toolbar),
      // Fills leftover height when content is short; still scrolls away with
      // the toolbar when the viewport is tight.
      SliverFillRemaining(hasScrollBody: false, child: body),
    ],
  );
}

String _outcomeLabel(PlayerStatsOutcomeFilter o) => switch (o) {
  PlayerStatsOutcomeFilter.all => 'All',
  PlayerStatsOutcomeFilter.win => 'Wins',
  PlayerStatsOutcomeFilter.draw => 'Draws',
  PlayerStatsOutcomeFilter.loss => 'Losses',
};

/// Source + date-window + time-control selector strip above the metrics.
/// Time-control chips re-scope every overview metric (not just the rating chart).
class _PrepToolbar extends StatelessWidget {
  const _PrepToolbar({
    required this.sources,
    required this.selectedIndex,
    required this.window,
    required this.timeControl,
    required this.timeControls,
    required this.loading,
    required this.onSource,
    required this.onWindow,
    required this.onTimeControl,
  });

  final List<PlayerStatsSource> sources;
  final int selectedIndex;
  final PlayerStatsWindow window;

  /// null = All.
  final String? timeControl;
  final List<PlayerTimeControlStat> timeControls;
  final bool loading;
  final ValueChanged<int> onSource;
  final ValueChanged<PlayerStatsWindow> onWindow;
  final ValueChanged<String?> onTimeControl;

  @override
  Widget build(BuildContext context) {
    final tcChips = _overviewTimeControlChips(timeControls);
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
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in PlayerStatsWindow.values)
                  _Pill(
                    label: w.label,
                    selected: w == window,
                    onTap: () => onWindow(w),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const _Eyebrow('Time control'),
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Pill(
                  label: 'All',
                  selected: timeControl == null,
                  onTap: () => onTimeControl(null),
                ),
                for (final chip in tcChips)
                  _TempoPill(
                    label: chip.label,
                    category: chip.key,
                    selected: timeControl == chip.key,
                    onTap: () => onTimeControl(chip.key),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Standard overview TC chips always present; extras from the database follow.
List<({String key, String label})> _overviewTimeControlChips(
  List<PlayerTimeControlStat> counts,
) {
  const primary = <String>['classical', 'rapid', 'blitz', 'bullet'];
  final seen = <String>{...primary};
  final extras = <String>[];
  for (final tc in counts) {
    final key = _canonicalTimeControlKey(tc.category);
    if (key == null || seen.contains(key)) continue;
    seen.add(key);
    extras.add(key);
  }
  extras.sort();
  return [
    for (final key in primary) (key: key, label: _tempoChipLabel(key)),
    for (final key in extras) (key: key, label: _tempoChipLabel(key)),
  ];
}

String _tempoChipLabel(String key) {
  switch (key) {
    case 'ultrabullet':
      return 'UltraBullet';
    case 'bullet':
      return 'Bullet';
    default:
      return _titleCase(key);
  }
}

String? _canonicalTimeControlKey(String raw) {
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'unknown':
    case 'all':
      return null;
    case 'classical':
    case 'standard':
      return 'classical';
    case 'rapid':
      return 'rapid';
    case 'blitz':
      return 'blitz';
    case 'bullet':
      return 'bullet';
    case 'ultrabullet':
    case 'ultra_bullet':
    case 'ultra-bullet':
    case 'ultra bullet':
      return 'ultrabullet';
    default:
      return raw.trim().toLowerCase();
  }
}

/// Source chip — like [_Pill] but carries the platform brand mark (same logos
/// as the player-list source icons on the left). Shared by the Overview
/// toolbar and the Games tab source bar.
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
          padding: const EdgeInsets.fromLTRB(8, 6, 11, 6),
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
              _PlayerSourceBrandMark(kind: source.kind, size: 14),
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

/// Mini platform logo / icon — same assets as the left player-list source tiles.
class _PlayerSourceBrandMark extends StatelessWidget {
  const _PlayerSourceBrandMark({required this.kind, this.size = 14});

  final PlayerWorkspaceSource kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: switch (kind) {
        PlayerWorkspaceSource.lichess => SvgPicture.asset(
          'assets/svgs/lichess_logo.svg',
          width: size,
          height: size,
          colorFilter: const ColorFilter.mode(kWhiteColor, BlendMode.srcIn),
        ),
        PlayerWorkspaceSource.chesscom => Image.asset(
          'assets/pngs/chesscom_pawn.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        PlayerWorkspaceSource.chessever => ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.28),
          child: Image.asset(
            'assets/pngs/new_app_logo.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
        PlayerWorkspaceSource.manual => Icon(
          Icons.note_add_outlined,
          size: size,
          color: kPrimaryColor,
        ),
        PlayerWorkspaceSource.combined => Icon(
          Icons.hub_outlined,
          size: size,
          color: kPrimaryColor,
        ),
      },
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({
    required this.toolbar,
    required this.snapshot,
    required this.sourcePath,
    required this.outcome,
    required this.playerColor,
    required this.onOutcome,
    required this.onPlayerColor,
    this.onOverviewFilter,
  });

  /// Source / date / time-control strip — first child of the same scroll view
  /// as the metrics so it scrolls away instead of sticking.
  final Widget toolbar;
  final PlayerStatsSnapshot snapshot;
  final String sourcePath;
  final PlayerStatsOutcomeFilter outcome;
  final String? playerColor;
  final ValueChanged<PlayerStatsOutcomeFilter> onOutcome;
  final ValueChanged<String?> onPlayerColor;
  final ValueChanged<PlayerOverviewFilterRequest>? onOverviewFilter;

  void _emitGames(
    PlayerOverviewFilterFacet facet, {
    String? eco,
    int? year,
    String? tc,
    String? opponent,
  }) {
    final cb = onOverviewFilter;
    if (cb == null) return;
    cb(
      PlayerOverviewFilterRequest(
        facet: facet,
        ecoCode: eco,
        year: year,
        timeControlCategory: tc,
        opponentName: opponent,
        sourcePath: sourcePath,
      ),
    );
  }

  void _toggleOutcome(PlayerStatsOutcomeFilter next) {
    onOutcome(outcome == next ? PlayerStatsOutcomeFilter.all : next);
  }

  void _toggleColor(String side) {
    onPlayerColor(playerColor == side ? null : side);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Toolbar carries its own outer padding; metrics keep the previous
      // 18px inset so layout under the strip matches the old fixed header.
      padding: EdgeInsets.zero,
      children: [
        toolbar,
        Padding(
          // Room under the last panel so the games-by-year hover detail can
          // open fully without sitting under the pane fold.
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 160),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeroStripe(snapshot: snapshot),
              const SizedBox(height: 14),
              _ScorePanel(
                snapshot: snapshot,
                outcome: outcome,
                onWins: () => _toggleOutcome(PlayerStatsOutcomeFilter.win),
                onDraws: () => _toggleOutcome(PlayerStatsOutcomeFilter.draw),
                onLosses: () => _toggleOutcome(PlayerStatsOutcomeFilter.loss),
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
                selectedColor: playerColor,
                onAsWhite: () => _toggleColor('w'),
                onAsBlack: () => _toggleColor('b'),
              ),
              if (snapshot.openings.isNotEmpty) ...[
                const SizedBox(height: 14),
                _OpeningsPanel(
                  openings: snapshot.openings,
                  onOpening:
                      (eco) =>
                          _emitGames(PlayerOverviewFilterFacet.eco, eco: eco),
                ),
              ],
              if (snapshot.opponents.isNotEmpty) ...[
                const SizedBox(height: 14),
                _OpponentsPanel(
                  opponents: snapshot.opponents,
                  onOpponent:
                      (name) => _emitGames(
                        PlayerOverviewFilterFacet.opponent,
                        opponent: name,
                      ),
                ),
              ],
              if (snapshot.years.length >= 2) ...[
                const SizedBox(height: 14),
                _YearsPanel(
                  years: snapshot.years,
                  timeControls: snapshot.timeControls,
                  onYear:
                      (y) =>
                          _emitGames(PlayerOverviewFilterFacet.year, year: y),
                  onTimeControl:
                      (cat) => _emitGames(
                        PlayerOverviewFilterFacet.timeControl,
                        tc: cat,
                      ),
                ),
              ],
              if (_hasLengths(snapshot.lengthBuckets)) ...[
                const SizedBox(height: 14),
                _LengthPanel(buckets: snapshot.lengthBuckets),
              ],
            ],
          ),
        ),
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
    required this.outcome,
    this.onWins,
    this.onDraws,
    this.onLosses,
  });

  final PlayerStatsSnapshot snapshot;
  final PlayerStatsOutcomeFilter outcome;
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
              if (outcome != PlayerStatsOutcomeFilter.all)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    'Filtered · ${_outcomeLabel(outcome)}',
                    style: TextStyle(
                      color: kPrimaryColor.withValues(alpha: 0.9),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              _Legend(tally: tally),
            ],
          ),
          const SizedBox(height: 12),
          _ScoreBar(tally: tally, height: 12),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _RecordChunk(
                count: tally.wins,
                label: 'Wins',
                color: _kWin,
                selected: outcome == PlayerStatsOutcomeFilter.win,
                onTap: onWins,
              ),
              _RecordChunk(
                count: tally.draws,
                label: 'Draws',
                color: _kDraw,
                selected: outcome == PlayerStatsOutcomeFilter.draw,
                onTap: onDraws,
              ),
              _RecordChunk(
                count: tally.losses,
                label: 'Losses',
                color: _kLoss,
                selected: outcome == PlayerStatsOutcomeFilter.loss,
                onTap: onLosses,
              ),
              if (snapshot.decisiveRate != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6),
                  child: Text(
                    '${snapshot.decisiveRate!.round()}% decisive',
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
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
    this.selected = false,
    this.onTap,
  });

  final int count;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: selected ? 0.75 : 0.32),
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            _formatInt(count),
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: selected ? kWhiteColor : kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return ClickCursor(
      child: DesktopTooltip(
        message:
            selected
                ? 'Clear $label filter (show all results)'
                : 'Scope overview to $label only',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: chip,
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
    this.selectedColor,
    this.onAsWhite,
    this.onAsBlack,
  });

  final PlayerStatsSnapshot snapshot;
  final String? selectedColor;
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
              selected: selectedColor == 'w',
              onTap: onAsWhite,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _ColorCard(
              label: 'As Black',
              icon: Icons.circle,
              tally: snapshot.asBlack,
              selected: selectedColor == 'b',
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
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final PlayerResultTally tally;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final score = tally.scorePercent;
    final panel = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.65) : kDividerColor,
          width: selected ? 1.4 : 1,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? kPrimaryColor : kWhiteColor70,
              ),
              const SizedBox(width: 8),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: selected ? kPrimaryColor : kSecondaryTextColor,
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
        message:
            selected
                ? 'Clear colour filter'
                : 'Scope overview to games played $label',
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
                  onOpening == null ? null : () => onOpening!(openings[i].eco),
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
        const SizedBox(width: 8),
        SizedBox(width: 96, child: _ScoreBar(tally: opening.tally, height: 7)),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: kWhiteColor.withValues(alpha: 0.35),
          ),
        ],
      ],
    );
    if (onTap == null) return row;
    return ClickCursor(
      child: DesktopTooltip(
        message: 'Show games with ${opening.eco}',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            hoverColor: kWhiteColor.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: row,
            ),
          ),
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
  const _OpponentsPanel({required this.opponents, this.onOpponent});

  final List<PlayerOpponentStat> opponents;
  final ValueChanged<String>? onOpponent;

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
            _OpponentRow(
              opponent: opponents[i],
              onTap:
                  onOpponent == null
                      ? null
                      : () => onOpponent!(opponents[i].name),
            ),
          ],
        ],
      ),
    );
  }
}

class _OpponentRow extends StatelessWidget {
  const _OpponentRow({required this.opponent, this.onTap});

  final PlayerOpponentStat opponent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final score = opponent.tally.scorePercent;
    final row = Row(
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
        if (onTap != null) ...[
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: kWhiteColor.withValues(alpha: 0.35),
          ),
        ],
        const SizedBox(width: 4),
        SizedBox(width: 96, child: _ScoreBar(tally: opponent.tally, height: 7)),
      ],
    );
    if (onTap == null) return row;
    return ClickCursor(
      child: DesktopTooltip(
        message: 'Show games vs ${_shortName(opponent.name)}',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            hoverColor: kWhiteColor.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: row,
            ),
          ),
        ),
      ),
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

/// Games-per-year chart: single CustomPainter (grid + stacked W/D/L bars +
/// labels) so axis scale and bar heights share one ceiling. Horizontally
/// scrollable when there are many years.
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
  static const double _kChartHeight = 200;
  static const double _kAxisWidth = 40;
  static const double _kLabelBand = 22;
  static const double _kMinSlot = 36;

  int? _hoveredYear;

  @override
  Widget build(BuildContext context) {
    final series = playerYearChartSeries(widget.years);
    final peak = playerYearChartMaxGames(series);
    final axisMax = playerYearChartAxisMax(peak);
    final ticks = playerYearChartAxisTicks(axisMax);
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
            height: _kChartHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _kAxisWidth,
                  child: _YearAxisLabels(
                    ticks: ticks,
                    axisMax: axisMax,
                    labelBand: _kLabelBand,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final n = series.isEmpty ? 1 : series.length;
                      final width = math.max(
                        constraints.maxWidth,
                        n * _kMinSlot,
                      );
                      return ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: true),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: width,
                            height: constraints.maxHeight,
                            child: MouseRegion(
                              onHover: (event) {
                                final year = _yearAt(
                                  series,
                                  width,
                                  event.localPosition.dx,
                                );
                                if (year != _hoveredYear) {
                                  setState(() => _hoveredYear = year);
                                }
                              },
                              onExit: (_) {
                                if (_hoveredYear != null) {
                                  setState(() => _hoveredYear = null);
                                }
                              },
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) {
                                  final year = _yearAt(
                                    series,
                                    width,
                                    details.localPosition.dx,
                                  );
                                  if (year != null) widget.onYear?.call(year);
                                },
                                child: CustomPaint(
                                  painter: _GamesByYearChartPainter(
                                    series: series,
                                    axisMax: axisMax,
                                    ticks: ticks,
                                    hoveredYear: _hoveredYear,
                                    labelBand: _kLabelBand,
                                    winColor: _kWin,
                                    drawColor: _kDraw,
                                    lossColor: _kLoss,
                                    unclassifiedColor: _kUnclassified,
                                    gridColor: kDividerColor,
                                    labelColor: kSecondaryTextColor,
                                    hoverLabelColor: kWhiteColor,
                                  ),
                                  size: Size(width, constraints.maxHeight),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          if (hovered != null) ...[
            const SizedBox(height: 10),
            _YearHoverCard(point: hovered),
          ],
        ],
      ),
    );
  }

  int? _yearAt(List<PlayerYearChartPoint> series, double width, double localX) {
    if (series.isEmpty || width <= 0) return null;
    final slot = width / series.length;
    final index = (localX / slot).floor().clamp(0, series.length - 1);
    return series[index].year;
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
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
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
      return const Color(0xFF38BDF8);
    case 'ultrabullet':
    case 'ultra_bullet':
    case 'ultra-bullet':
    case 'ultra bullet':
      return const Color(0xFFF472B6);
    case 'correspondence':
    case 'daily':
      return const Color(0xFFA78BFA);
    default:
      return kPrimaryColor;
  }
}

class _YearAxisLabels extends StatelessWidget {
  const _YearAxisLabels({
    required this.ticks,
    required this.axisMax,
    required this.labelBand,
  });

  final List<int> ticks;
  final int axisMax;
  final double labelBand;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: labelBand),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          if (height <= 0 || axisMax <= 0) return const SizedBox.shrink();
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final tick in ticks)
                Positioned(
                  left: 0,
                  right: 0,
                  // Align label center with grid line.
                  top: height - (tick / axisMax).clamp(0.0, 1.0) * height - 6,
                  child: Text(
                    _formatInt(tick),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: kWhiteColor.withValues(alpha: 0.42),
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

/// Paints grid, stacked W/D/L bars, and year labels in one pass so geometry
/// cannot drift between separate layout widgets.
class _GamesByYearChartPainter extends CustomPainter {
  _GamesByYearChartPainter({
    required this.series,
    required this.axisMax,
    required this.ticks,
    required this.hoveredYear,
    required this.labelBand,
    required this.winColor,
    required this.drawColor,
    required this.lossColor,
    required this.unclassifiedColor,
    required this.gridColor,
    required this.labelColor,
    required this.hoverLabelColor,
  });

  final List<PlayerYearChartPoint> series;
  final int axisMax;
  final List<int> ticks;
  final int? hoveredYear;
  final double labelBand;
  final Color winColor;
  final Color drawColor;
  final Color lossColor;
  final Color unclassifiedColor;
  final Color gridColor;
  final Color labelColor;
  final Color hoverLabelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - labelBand;
    if (plotHeight <= 0 || axisMax <= 0) return;

    final gridPaint =
        Paint()
          ..color = gridColor.withValues(alpha: 0.55)
          ..strokeWidth = 1;
    final baselinePaint =
        Paint()
          ..color = gridColor.withValues(alpha: 0.95)
          ..strokeWidth = 1.25;

    for (final tick in ticks) {
      final y = plotHeight - (tick / axisMax).clamp(0.0, 1.0) * plotHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawLine(
      Offset(0, plotHeight),
      Offset(size.width, plotHeight),
      baselinePaint,
    );

    if (series.isEmpty) return;

    final slot = size.width / series.length;
    final barWidth = (slot * 0.52).clamp(6.0, 32.0);
    final dense = slot < 44;

    for (var i = 0; i < series.length; i++) {
      final point = series[i];
      final cx = (i + 0.5) * slot;
      final left = cx - barWidth / 2;
      final hovered = point.year == hoveredYear;
      final games = point.games;

      // Stack from baseline upward: unclassified → L → D → W (W on top).
      final segments = <({int count, Color color})>[
        if (point.unclassified > 0)
          (count: point.unclassified, color: unclassifiedColor),
        if (point.losses > 0) (count: point.losses, color: lossColor),
        if (point.draws > 0) (count: point.draws, color: drawColor),
        if (point.wins > 0) (count: point.wins, color: winColor),
      ];
      // Fall back when tally is empty but total games is set.
      if (segments.isEmpty && games > 0) {
        segments.add((count: games, color: unclassifiedColor));
      }

      final totalSeg = segments.fold<int>(0, (s, e) => s + e.count);
      final scaleCount = totalSeg > 0 ? totalSeg : games;
      // Height from axis scale (games / axisMax), not inflated min height that
      // broke short bars against the grid.
      final fullBarH =
          games <= 0 ? 0.0 : (games / axisMax).clamp(0.0, 1.0) * plotHeight;
      final paintBarH = games <= 0 ? 0.0 : math.max(fullBarH, 2.0);

      if (paintBarH > 0 && scaleCount > 0) {
        // Distribute painted height proportionally to segment counts so the
        // bar tip matches the game count on the axis.
        final rrectRadius = Radius.circular(barWidth > 14 ? 3.5 : 2);
        // Draw bottom-up without clipping each segment separately so corners
        // only round the outer silhouette.
        final barRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, plotHeight - paintBarH, barWidth, paintBarH),
          rrectRadius,
        );
        canvas.save();
        canvas.clipRRect(barRect);
        var drawn = 0.0;
        for (final seg in segments) {
          final h = paintBarH * (seg.count / scaleCount);
          final top = plotHeight - drawn - h;
          final paint =
              Paint()
                ..color = seg.color.withValues(alpha: hovered ? 1 : 0.9)
                ..style = PaintingStyle.fill;
          canvas.drawRect(Rect.fromLTWH(left, top, barWidth, h + 0.5), paint);
          drawn += h;
        }
        canvas.restore();
        if (hovered) {
          canvas.drawRRect(
            barRect,
            Paint()
              ..color = kWhiteColor.withValues(alpha: 0.22)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
      }

      // Year label under the plot.
      final label =
          dense
              ? "'${(point.year % 100).toString().padLeft(2, '0')}"
              : '${point.year}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color:
                hovered ? hoverLabelColor : labelColor.withValues(alpha: 0.92),
            fontSize: dense ? 9 : 10,
            fontWeight: hovered ? FontWeight.w800 : FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: slot);
      tp.paint(
        canvas,
        Offset(cx - tp.width / 2, plotHeight + (labelBand - tp.height) / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GamesByYearChartPainter oldDelegate) {
    return oldDelegate.axisMax != axisMax ||
        oldDelegate.hoveredYear != hoveredYear ||
        oldDelegate.labelBand != labelBand ||
        !listEquals(oldDelegate.ticks, ticks) ||
        !listEquals(oldDelegate.series, series);
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
                  _HoverSourceChip(label: src.label, value: src.count),
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

/// Year-hover source chip with platform brand mark (not a colored dot).
class _HoverSourceChip extends StatelessWidget {
  const _HoverSourceChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final kind = _workspaceSourceFromLabel(label);
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 4, 9, 4),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kind != null) ...[
            _PlayerSourceBrandMark(kind: kind, size: 12),
            const SizedBox(width: 6),
          ],
          Text(
            '$label · ${_formatInt(value)}',
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

PlayerWorkspaceSource? _workspaceSourceFromLabel(String label) {
  switch (label.trim().toLowerCase()) {
    case 'lichess':
      return PlayerWorkspaceSource.lichess;
    case 'chess.com':
    case 'chesscom':
      return PlayerWorkspaceSource.chesscom;
    case 'chessever':
    case 'chess ever':
      return PlayerWorkspaceSource.chessever;
    case 'manual':
    case 'manual pgn':
      return PlayerWorkspaceSource.manual;
    case 'combined':
      return PlayerWorkspaceSource.combined;
    default:
      return null;
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

/// Time-control chip with distinct tempo glyph (blitz/bullet no longer share art).
class _TempoPill extends StatelessWidget {
  const _TempoPill({
    required this.label,
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = _timeControlAccent(category);
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : kBlack3Color,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.55) : kDividerColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TempoIcon(category: category, size: 13, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? accent : kWhiteColor70,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6,
                ),
              ),
            ],
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
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final bool spinner;
  final IconData? icon;
  final String? title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

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
              if (secondaryActionLabel != null &&
                  onSecondaryAction != null) ...[
                const SizedBox(height: 10),
                ClickCursor(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSecondaryAction,
                    child: Text(
                      secondaryActionLabel!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: kWhiteColor.withValues(alpha: 0.72),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline,
                        decorationColor: kWhiteColor.withValues(alpha: 0.35),
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
  if (percent >= 55) return kPrimaryColor;
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
