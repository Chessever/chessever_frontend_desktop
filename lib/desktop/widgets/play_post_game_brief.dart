/// The brief beside the board once a game against a bot is over: the
/// result, the rating it moved, how accurately the player played, Toby's
/// estimate of the level they played at, and how many moves earned each of
/// the report's marks. Everything is computed in place, on the same board,
/// so the board keeps the size and layout the player chose.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/play/play_live_move_classifier.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';
import 'package:chessever/desktop/services/toby/toby_performance.dart';
import 'package:chessever/desktop/state/play_live_move_judgements.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/play_achievement_badge.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_reward_motion.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/theme/app_theme.dart';

/// The player's rating on the game's ladder, taken the moment the game
/// ended and before it was saved, so the brief keeps showing the change
/// after the profile has moved on.
@immutable
class PlayFinishedRating {
  const PlayFinishedRating({
    required this.ladder,
    required this.before,
    required this.after,
    this.provisional = false,
    this.gainFactor = 1,
  });

  /// "Blitz", "Rapid" ...
  final String ladder;
  final int before;
  final int after;

  /// Too few games for the rating to be settled yet.
  final bool provisional;

  /// Share of a gain the game kept for the help it used; 1 with no help.
  final double gainFactor;

  int get delta => after - before;
}

/// The finished game's rating change, per Play tab. Cleared with the game.
final playFinishedRatingProvider =
    StateProvider.family<PlayFinishedRating?, String>((ref, tabId) => null);

/// What the game earned (XP, level, badge tiers), per Play tab. Copied from
/// `playLastGameRewardsProvider` once the game is recorded, and only while
/// that same game is still on the tab; cleared with the game.
final playFinishedRewardsProvider =
    StateProvider.family<PlayGameRewards?, String>((ref, tabId) => null);

/// The marks the brief counts, in the order the report lists them.
const List<GameMoveClassification> _kBriefMarks = <GameMoveClassification>[
  GameMoveClassification.brilliant,
  GameMoveClassification.goodMove,
  GameMoveClassification.bestMove,
  GameMoveClassification.bookMove,
  GameMoveClassification.inaccuracy,
  GameMoveClassification.mistake,
  GameMoveClassification.blunder,
  GameMoveClassification.missedWin,
];

/// Short glyph for each mark, as it reads in the move list.
String _markGlyph(GameMoveClassification mark) => switch (mark) {
  GameMoveClassification.brilliant => '!!',
  GameMoveClassification.goodMove => '!',
  GameMoveClassification.bestMove => 'Best',
  GameMoveClassification.bookMove => 'Book',
  GameMoveClassification.inaccuracy => '?!',
  GameMoveClassification.mistake => '?',
  GameMoveClassification.blunder => '??',
  GameMoveClassification.missedWin => 'Missed',
};

/// Indices (in the game's main line) of the moves [humanSide] made, for a
/// game that started from [startingFen].
@visibleForTesting
bool playBriefIsHumanMove(int index, String startingFen, Side humanSide) {
  final parts = startingFen.split(' ');
  final firstMover =
      parts.length > 1 && parts[1] == 'b' ? Side.black : Side.white;
  final mover = index.isEven ? firstMover : firstMover.opposite;
  return mover == humanSide;
}

/// The marks [humanSide] earned, counted from the classifier's verdicts.
@visibleForTesting
Map<GameMoveClassification, int> playBriefMarkCounts(
  Map<int, GameMoveClassification> classes, {
  required String startingFen,
  required Side humanSide,
}) {
  final counts = <GameMoveClassification, int>{};
  for (final entry in classes.entries) {
    if (!playBriefIsHumanMove(entry.key, startingFen, humanSide)) continue;
    counts[entry.value] = (counts[entry.value] ?? 0) + 1;
  }
  return counts;
}

class PlayPostGameBrief extends ConsumerStatefulWidget {
  const PlayPostGameBrief({
    super.key,
    required this.state,
    required this.tabId,
    required this.humanRating,
    required this.onPlayAgain,
    required this.onRematch,
    required this.onOpenReport,
    this.fill = false,
    this.moves,
    this.movesLabel,
  });

  final PlaySessionState state;
  final String tabId;

  /// The player's rating on this game's ladder before it was played, for
  /// Toby's reading of the game.
  final int humanRating;
  final VoidCallback onPlayAgain;
  final VoidCallback onRematch;
  final VoidCallback onOpenReport;

  /// Takes the whole height it is given: the result set large at the top,
  /// [moves] under it, and the actions pinned to the bottom edge.
  final bool fill;

  /// What sits under the result when [fill]: the move list, or the whole
  /// analysis panel (moves, engine, explorer). Always kept on screen; the
  /// result gives up room first.
  final Widget? moves;

  /// A small heading over [moves], for a bare move list.
  final String? movesLabel;

  @override
  ConsumerState<PlayPostGameBrief> createState() => _PlayPostGameBriefState();
}

/// What a filling brief always leaves for [PlayPostGameBrief.moves].
const double _kBriefMovesMinHeight = 200;

/// Below this width a filling brief sets the rating under the title and
/// counts the marks in one compact run.
const double _kBriefNarrowWidth = 340;

class _PlayPostGameBriefState extends ConsumerState<PlayPostGameBrief> {
  GameAnalysisReport? _report;
  TobyPerformanceQuery? _tobyQuery;
  int _reportFor = -1;

  void _refreshReport(PlayLiveMoveJudgements judgements) {
    final total = widget.state.history.length;
    if (judgements.judgedMoves < total || _reportFor == total) return;
    final whiteIsHuman = widget.state.humanSide == Side.white;
    final bot = widget.state.botIdentity.elo;
    final report = ref
        .read(playLiveMoveJudgementsProvider(widget.tabId).notifier)
        .completeReport(
          whiteRating: whiteIsHuman ? widget.humanRating : bot,
          blackRating: whiteIsHuman ? bot : widget.humanRating,
        );
    if (report == null) return;
    _reportFor = total;
    _report = report;
    final config = widget.state.config;
    _tobyQuery = TobyPerformanceQuery(
      fingerprint: report.fingerprint,
      request: TobyPerformanceRequest.forReport(
        report,
        startFen: widget.state.startingFen,
        moves: List<String>.unmodifiable(widget.state.history),
        whiteRating: whiteIsHuman ? widget.humanRating : bot,
        blackRating: whiteIsHuman ? bot : widget.humanRating,
        timeControl: '${config.baseSeconds}+${config.incrementSeconds}',
        category: config.category.displayName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final fill = widget.fill;
    final judgements = ref.watch(playLiveMoveJudgementsProvider(widget.tabId));
    _refreshReport(judgements);
    final rating = ref.watch(playFinishedRatingProvider(widget.tabId));
    final rewards = ref.watch(playFinishedRewardsProvider(widget.tabId));
    final total = state.history.length;
    final reviewing =
        judgements.engineAvailable && judgements.judgedMoves < total;
    final counts = playBriefMarkCounts(
      judgements.classes,
      startingFen: state.startingFen,
      humanSide: state.humanSide,
    );

    final report = _report;
    double? accuracy;
    if (report != null) {
      final humanFirst = playBriefIsHumanMove(
        0,
        state.startingFen,
        state.humanSide,
      );
      // The report's "white" is the side that moved first.
      accuracy = humanFirst ? report.whiteAccuracy : report.blackAccuracy;
    }
    final tobyQuery = _tobyQuery;
    final toby =
        tobyQuery == null
            ? null
            : ref.watch(tobyPerformanceProvider(tobyQuery));
    final tobySide =
        state.humanSide == Side.white
            ? toby?.performance?.white
            : toby?.performance?.black;

    final humanWon = state.outcome?.winner == state.humanSide;
    final draw = state.outcome == Outcome.draw;
    final title = draw ? 'Draw' : (humanWon ? 'You won' : 'You lost');
    final humanMoves =
        <int>[
          for (var i = 0; i < total; i++)
            if (playBriefIsHumanMove(i, state.startingFen, state.humanSide)) i,
        ].length;

    Widget headerFor({required bool large, required bool stacked}) {
      final titleBlock = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kWhiteColor,
              fontSize: large ? 32 : 22,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          SizedBox(height: large ? 6 : 4),
          Text(
            '${state.endReason.banner} · '
            '${(total + 1) ~/ 2} moves',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: large ? 13 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            titleBlock,
            if (rating != null) ...[
              const SizedBox(height: 12),
              _RatingFigure(rating: rating, large: large, alignStart: true),
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: titleBlock),
          if (rating != null) _RatingFigure(rating: rating, large: large),
        ],
      );
    }

    final figures = Row(
      children: [
        Expanded(
          child: _Figure(
            label: 'Accuracy',
            value: accuracy?.toStringAsFixed(1),
            pending: reviewing,
            large: fill,
          ),
        ),
        Expanded(
          child: DesktopTooltip(
            message: kTobyPerformanceDescription,
            child: _Figure(
              label: kTobyPerformanceLabel,
              value: tobySide?.display,
              pending:
                  reviewing || toby?.status == TobyPerformanceStatus.loading,
              large: fill,
            ),
          ),
        ),
        Expanded(
          child: _Figure(
            label: rewards == null ? 'Your moves' : 'XP earned',
            value: rewards == null ? '$humanMoves' : '+${rewards.xpEarned}',
            pending: false,
            large: fill,
          ),
        ),
      ],
    );

    List<Widget> summaryFor({required bool large, required bool narrow}) {
      final gap = SizedBox(height: large ? 20 : 14);
      return [
        headerFor(large: large, stacked: narrow),
        gap,
        figures,
        gap,
        if (reviewing) ...[
          _ReviewProgress(done: judgements.judgedMoves, total: total),
          const SizedBox(height: 10),
        ],
        _MarkCounts(counts: counts, large: large && !narrow),
        if (rewards != null) ...[gap, _LevelProgress(rewards: rewards)],
      ];
    }

    // One clear primary action; the two quieter ways on sit under it as
    // text buttons, each a real focusable forui button.
    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FButton(
          style: playPrimaryActionButtonStyle(),
          prefix: const Icon(Icons.replay_rounded),
          onPress: widget.onRematch,
          child: const Text('Rematch'),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: DesktopTooltip(
                message: 'Back to the game setup',
                child: FButton(
                  style: FButtonStyle.ghost(),
                  prefix: const Icon(Icons.tune_rounded),
                  onPress: widget.onPlayAgain,
                  // Flexible, so a narrow column ellipsizes the label instead
                  // of pushing it past the button's edge.
                  child: const Flexible(
                    child: Text(
                      'New game',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: DesktopTooltip(
                message: 'Open the game on the Board with its full report',
                child: FButton(
                  style: FButtonStyle.ghost(),
                  prefix: const Icon(Icons.analytics_outlined),
                  onPress: widget.onOpenReport,
                  // Flexible, so a narrow column ellipsizes the label instead
                  // of pushing it past the button's edge.
                  child: const Flexible(
                    child: Text(
                      'Full report',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    final decoration = BoxDecoration(
      color: kBlack3Color,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kWhiteColor.withValues(alpha: 0.06)),
    );

    if (!fill) {
      return FTheme(
        data: FThemes.zinc.dark,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: decoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...summaryFor(large: false, narrow: false),
              const SizedBox(height: 14),
              actions,
            ],
          ),
        ),
      );
    }

    final moves = widget.moves;
    final movesLabel = widget.movesLabel;
    return FTheme(
      data: FThemes.zinc.dark,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < _kBriefNarrowWidth;
          final card = Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            decoration: decoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The result scrolls inside the card when the panel is short;
                // the actions under it never leave the screen.
                Flexible(
                  child: ScrollEdgeArrows(
                    shrinkWrap: true,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: summaryFor(large: true, narrow: narrow),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                actions,
              ],
            ),
          );
          if (moves == null) {
            return Align(alignment: Alignment.topCenter, child: card);
          }
          // The card takes what it needs up to three fifths of the panel,
          // always leaving the moves their floor.
          final height = constraints.maxHeight;
          // The floor is the moves' own; the gap and heading come on top.
          final under =
              _kBriefMovesMinHeight + 12 + (movesLabel != null ? 26 : 0);
          final cardCap = (height - under).clamp(0.0, height * 0.62);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: cardCap),
                child: card,
              ),
              const SizedBox(height: 12),
              if (movesLabel != null) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    movesLabel,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(child: moves),
            ],
          );
        },
      ),
    );
  }
}

class _RatingFigure extends StatelessWidget {
  const _RatingFigure({
    required this.rating,
    this.large = false,
    this.alignStart = false,
  });

  final PlayFinishedRating rating;
  final bool large;

  /// Set under the title (a narrow brief) rather than beside it.
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    final delta = rating.delta;
    final deltaColor =
        delta > 0
            ? Color.lerp(kGreenColor, kWhiteColor, 0.25)!
            : delta < 0
            ? Color.lerp(kRedColor, kWhiteColor, 0.25)!
            : kWhiteColor70;
    final sign = delta > 0 ? '+' : (delta < 0 ? '−' : '±');
    final provisional = rating.provisional ? '?' : '';
    return Column(
      crossAxisAlignment:
          alignStart ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${rating.after}$provisional',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: large ? 32 : 22,
                fontWeight: FontWeight.w900,
                height: 1.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$sign${delta.abs()}',
              style: TextStyle(
                color: deltaColor,
                fontSize: large ? 18 : 14,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${rating.ladder}, was ${rating.before}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        // A gain trimmed for the help the game used says so.
        if (rating.gainFactor < 1 && delta >= 0) ...[
          const SizedBox(height: 2),
          Text(
            'Help used: ${(rating.gainFactor * 100).round()}% of the gain',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.pending,
    this.large = false,
  });

  final String label;
  final String? value;
  final bool pending;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final shown = value ?? (pending ? '…' : '–');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          shown,
          style: TextStyle(
            color: value == null ? kSecondaryTextColor : kWhiteColor,
            fontSize: large ? 24 : 18,
            fontWeight: FontWeight.w800,
            height: 1.15,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: kSecondaryTextColor,
            fontSize: large ? 12 : 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ReviewProgress extends StatelessWidget {
  const _ReviewProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Reviewing your moves  $done / $total',
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        // A width fill with stable round caps: the track and the fill share
        // one radius, so nothing flips shape while it grows.
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: kBlack2Color),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: fraction),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder:
                      (context, value, _) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: value,
                        child: const ColoredBox(color: kWhiteColor70),
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MarkCounts extends StatelessWidget {
  const _MarkCounts({required this.counts, this.large = false});

  final Map<GameMoveClassification, int> counts;

  /// Two named columns instead of a run of glyphs.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final marks = [
      for (final mark in _kBriefMarks)
        if (mark != GameMoveClassification.missedWin || (counts[mark] ?? 0) > 0)
          mark,
    ];
    if (large) {
      Widget cell(GameMoveClassification mark) {
        final count = counts[mark] ?? 0;
        return Row(
          children: [
            SvgPicture.asset(
              classificationIconAsset(mark),
              width: 20,
              height: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                mark.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: count == 0 ? kSecondaryTextColor : kWhiteColor70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                color: count == 0 ? kSecondaryTextColor : kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      }

      final rows = <Widget>[];
      for (var i = 0; i < marks.length; i += 2) {
        if (i > 0) rows.add(const SizedBox(height: 10));
        rows.add(
          Row(
            children: [
              Expanded(child: cell(marks[i])),
              const SizedBox(width: 24),
              Expanded(
                child:
                    i + 1 < marks.length
                        ? cell(marks[i + 1])
                        : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      );
    }
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final mark in marks)
          DesktopTooltip(
            message: mark.label,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  classificationIconAsset(mark),
                  width: 16,
                  height: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  '${counts[mark] ?? 0}',
                  style: TextStyle(
                    color:
                        (counts[mark] ?? 0) == 0
                            ? kSecondaryTextColor
                            : kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  _markGlyph(mark),
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The level bar after the game: where the XP left the player, a level-up
/// called out, and every badge tier the game reached.
class _LevelProgress extends StatelessWidget {
  const _LevelProgress({required this.rewards});

  final PlayGameRewards rewards;

  @override
  Widget build(BuildContext context) {
    final before = rewards.levelBefore;
    final after = rewards.levelAfter;
    // Within one level the fill grows from where it was; a level-up refills
    // the new level from empty.
    final from = rewards.leveledUp ? 0.0 : before.fraction;
    final headline =
        rewards.leveledUp
            ? 'Level ${after.level} reached · ${after.title}'
            : 'Level ${after.level} · ${after.title}';
    final tiers = [
      for (final up in rewards.tierUps)
        if (up.track != null) '${up.track!.title} ${up.tierName}',
    ];
    // At most three badges beside the line; the text names them all.
    final shownUps =
        rewards.tierUps.where((up) => up.track != null).take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (rewards.leveledUp) ...[
              // Chevrons climb and one settles beside the new level.
              PlayRewardBurst(
                motion: PlayRewardMotion.levelUp,
                color: kPrimaryColor,
                size: 20,
                onceKey: 'level:${after.level}',
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                headline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: rewards.leveledUp ? kWhiteColor : kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              '${after.xpToNext} XP to level ${after.level + 1}',
              style: const TextStyle(
                color: kSecondaryTextColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: kBlack2Color),
                // Starts at the level's old fill (never at zero for a game
                // inside one level), so a stalled ticker still reads true.
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: from, end: after.fraction),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder:
                      (context, value, _) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: value,
                        child: const ColoredBox(color: kPrimaryColor),
                      ),
                ),
              ],
            ),
          ),
        ),
        if (tiers.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              // Each badge the game moved up is struck in its new metal.
              for (final up in shownUps) ...[
                PlayBadgeWithBurst(
                  badgeSize: 32,
                  color: playBadgeTierMetal(up.tier),
                  playKey: '${up.trackKey}:${up.tier}',
                  onceKey: '${up.trackKey}:${up.tier}',
                  child: PlayAchievementBadgeArt(
                    definition: up.track!.artDefinition,
                    unlocked: true,
                    size: 32,
                    tier: up.tier,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  tiers.length == 1
                      ? 'New badge tier: ${tiers.first}'
                      : 'New badge tiers: ${tiers.join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
