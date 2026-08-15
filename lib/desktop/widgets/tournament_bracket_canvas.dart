import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/screens/tour_detail/bracket/models/knockout_bracket.dart';
import 'package:chessever/screens/tour_detail/bracket/widgets/bracket_graph_layout.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

/// Desktop rendering of a normalized knockout bracket.
///
/// Placement and connector evidence come from the shared phone-parity graph
/// model; only the visual treatment and interaction vocabulary are Desktop
/// specific.
class DesktopKnockoutBracketCanvas extends StatelessWidget {
  const DesktopKnockoutBracketCanvas({
    super.key,
    required this.bracket,
    required this.onMatchActivate,
    this.focusedMatchKey,
  });

  final KnockoutBracket bracket;
  final String? focusedMatchKey;
  final ValueChanged<KnockoutMatch> onMatchActivate;

  @override
  Widget build(BuildContext context) {
    final layout = buildBracketGraphLayout(bracket);
    final stages = List<KnockoutStage>.of(bracket.stages)
      ..sort((a, b) => a.order.compareTo(b.order));

    return RepaintBoundary(
      child: SizedBox.fromSize(
        key: const ValueKey('desktop-knockout-bracket-canvas'),
        size: layout.size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _DesktopBracketConnectorPainter(
                  edges: bracket.edges,
                  matchRects: layout.matchRects,
                  focusedMatchKey: focusedMatchKey,
                ),
              ),
            ),
            for (final stage in stages)
              if (layout.stageHeaderRects[stage.key] case final rect?)
                Positioned.fromRect(
                  rect: rect,
                  child: _DesktopBracketStageHeader(
                    stage: stage,
                    isCurrent: bracket.currentStageKey == stage.key,
                  ),
                ),
            for (final stage in stages)
              for (final match in stage.matches)
                if (layout.matchRects[match.key] case final rect?)
                  Positioned.fromRect(
                    rect: rect,
                    child: _DesktopBracketMatchCard(
                      key: ValueKey('desktop-bracket-match-${match.key}'),
                      match: match,
                      focused: focusedMatchKey == match.key,
                      onActivate: () => onMatchActivate(match),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _DesktopBracketStageHeader extends StatelessWidget {
  const _DesktopBracketStageHeader({
    required this.stage,
    required this.isCurrent,
  });

  final KnockoutStage stage;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final matchLabel = stage.matches.length == 1 ? 'match' : 'matches';
    return Semantics(
      header: true,
      label: '${stage.label}, ${stage.matches.length} $matchLabel',
      child: Row(
        children: [
          Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: isCurrent ? kPrimaryColor : kDividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              stage.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                height: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (stage.isLive) ...[
            const SizedBox(width: 7),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: kPrimaryColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: kPrimaryColor.withValues(alpha: 0.4),
                    blurRadius: 5,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Text(
              'LIVE',
              style: TextStyle(
                color: kPrimaryColor,
                fontSize: 9.5,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DesktopBracketMatchCard extends StatelessWidget {
  const _DesktopBracketMatchCard({
    super.key,
    required this.match,
    required this.focused,
    required this.onActivate,
  });

  final KnockoutMatch match;
  final bool focused;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final winnerId = match.winner?.id;
    final semantics =
        StringBuffer()
          ..write(match.isLive ? 'Live match. ' : 'Match. ')
          ..write(
            '${match.participant1.displayName} '
            '${_formatBracketScore(match.participant1Score)}, '
            '${match.participant2.displayName} '
            '${_formatBracketScore(match.participant2Score)}',
          );
    if (match.winner != null) {
      semantics.write('. ${match.winner!.displayName} advances');
    }

    return DesktopTappable(
      onPress: onActivate,
      semanticsLabel: semantics.toString(),
      borderRadius: BorderRadius.circular(10),
      hoverColor: kPrimaryColor.withValues(alpha: 0.055),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: focused ? kBlack3Color : kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                focused ? kPrimaryColor.withValues(alpha: 0.78) : kDividerColor,
            width: focused ? 1.4 : 1,
          ),
          boxShadow:
              focused
                  ? [
                    BoxShadow(
                      color: kPrimaryColor.withValues(alpha: 0.13),
                      blurRadius: 12,
                    ),
                  ]
                  : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: _DesktopBracketParticipantRow(
                      participant: match.participant1,
                      score: match.participant1Score,
                      winner: winnerId == match.participant1.id,
                      eliminated:
                          winnerId != null && winnerId != match.participant1.id,
                      leader: match.leader?.id == match.participant1.id,
                    ),
                  ),
                  const Divider(height: 1, thickness: 1, color: kDividerColor),
                  Expanded(
                    child: _DesktopBracketParticipantRow(
                      participant: match.participant2,
                      score: match.participant2Score,
                      winner: winnerId == match.participant2.id,
                      eliminated:
                          winnerId != null && winnerId != match.participant2.id,
                      leader: match.leader?.id == match.participant2.id,
                    ),
                  ),
                ],
              ),
              if (match.isLive)
                Positioned(
                  left: 0,
                  top: 10,
                  bottom: 10,
                  child: Container(
                    width: 3,
                    decoration: const BoxDecoration(
                      color: kPrimaryColor,
                      borderRadius: BorderRadius.horizontal(
                        right: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopBracketParticipantRow extends StatelessWidget {
  const _DesktopBracketParticipantRow({
    required this.participant,
    required this.score,
    required this.winner,
    required this.eliminated,
    required this.leader,
  });

  final BracketParticipant participant;
  final double score;
  final bool winner;
  final bool eliminated;
  final bool leader;

  @override
  Widget build(BuildContext context) {
    final foreground = eliminated ? kLightGreyColor : kWhiteColor;
    final metadata = <String>[
      if ((participant.title ?? '').trim().isNotEmpty)
        participant.title!.trim(),
      if (participant.rating != null && participant.rating! > 0)
        participant.rating.toString(),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
      child: Row(
        children: [
          BackfilledFederationFlag(
            federation: participant.federation,
            fideId: participant.fideId,
            playerName: participant.name,
            width: 17,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        participant.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 12.5,
                          height: 1.1,
                          fontWeight:
                              winner ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (winner) ...[
                      const SizedBox(width: 3),
                      const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: kPrimaryColor,
                      ),
                    ],
                  ],
                ),
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          eliminated
                              ? kLightGreyColor.withValues(alpha: 0.72)
                              : kWhiteColor70,
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatBracketScore(score),
            textAlign: TextAlign.right,
            style: TextStyle(
              color:
                  winner || leader
                      ? kPrimaryColor
                      : eliminated
                      ? kLightGreyColor
                      : kWhiteColor,
              fontSize: 15,
              height: 1,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBracketScore(double score) =>
    score == score.roundToDouble()
        ? score.toInt().toString()
        : score.toStringAsFixed(1);

class _DesktopBracketConnectorPainter extends CustomPainter {
  const _DesktopBracketConnectorPainter({
    required this.edges,
    required this.matchRects,
    required this.focusedMatchKey,
  });

  final List<KnockoutEdge> edges;
  final Map<String, Rect> matchRects;
  final String? focusedMatchKey;

  @override
  void paint(Canvas canvas, Size size) {
    final basePaint =
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.24)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    final focusPaint =
        Paint()
          ..color = kPrimaryColor.withValues(alpha: 0.82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.1
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;

    for (final edge in edges) {
      if (_isFocused(edge)) continue;
      _paintEdge(canvas, edge, basePaint);
    }
    for (final edge in edges) {
      if (!_isFocused(edge)) continue;
      _paintEdge(canvas, edge, focusPaint);
    }
  }

  bool _isFocused(KnockoutEdge edge) =>
      focusedMatchKey != null &&
      (edge.sourceMatchKey == focusedMatchKey ||
          edge.destinationMatchKey == focusedMatchKey);

  void _paintEdge(Canvas canvas, KnockoutEdge edge, Paint paint) {
    final source = matchRects[edge.sourceMatchKey];
    final destination = matchRects[edge.destinationMatchKey];
    if (source == null || destination == null) return;

    final start = source.centerRight;
    final end = destination.centerLeft;
    final middleX = (start.dx + end.dx) / 2;
    final path =
        Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(middleX, start.dy, middleX, end.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DesktopBracketConnectorPainter oldDelegate) =>
      oldDelegate.edges != edges ||
      oldDelegate.matchRects != matchRects ||
      oldDelegate.focusedMatchKey != focusedMatchKey;
}
