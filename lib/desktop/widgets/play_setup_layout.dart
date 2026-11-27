import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/theme/app_theme.dart';

/// Side gutter of every Play face. It matches the Play header above, so
/// switching between Single game, Tournaments, Events and Profile never
/// moves the content's edges.
const double kPlayPaneGutter = 24;

/// Gap between the Play header and the first line of a face.
const double kPlayPaneTopInset = 24;

/// Widest a Play face's content grows; wider panes centre it.
const double kPlayPaneMaxContentWidth = 1320;

/// Horizontal inset that keeps a Play face inside [kPlayPaneMaxContentWidth]
/// and centres it on wide panes. Scroll views take this as padding so they
/// span the whole pane and wheel anywhere in it.
double playPaneHorizontalInset(double paneWidth) {
  final spare = paneWidth - 2 * kPlayPaneGutter - kPlayPaneMaxContentWidth;
  return kPlayPaneGutter + math.max(0, spare / 2);
}

/// The setup page every Play mode starts from: a fixed title, two columns of
/// [PlaySetupCard]s and a [PlaySetupStartBar] docked at the foot of the right
/// column, directly under its last card. Each column scrolls on its own
/// without a scrollbar, an arrow marking any edge with more, so the start
/// action never leaves the screen.
/// Narrow panes stack the cards in one scroll and dock the bar at the
/// bottom. Single games and tournaments share it, so both are set up the
/// same way and switching between them moves nothing.
class PlaySetupPage extends StatelessWidget {
  const PlaySetupPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.left,
    required this.right,
    required this.startBar,
  });

  final String title;
  final String subtitle;
  final List<Widget> left;
  final List<Widget> right;
  final Widget startBar;

  static const double _cardGap = 18;
  static const double _columnGap = 28;
  static const double _bottomInset = 24;

  /// Below this content width the two columns stack.
  static const double stackedBreakpoint = 980;

  static Widget _cards(List<Widget> cards) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(height: _cardGap),
        cards[i],
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = playPaneHorizontalInset(constraints.maxWidth);
        final contentWidth = constraints.maxWidth - 2 * inset;
        final header = PlaySetupHeader(title: title, subtitle: subtitle);
        if (contentWidth < stackedBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ScrollEdgeArrows(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      kPlayPaneTopInset,
                      inset,
                      _cardGap,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: 20),
                        _cards(left),
                        const SizedBox(height: _cardGap),
                        _cards(right),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(inset, 0, inset, _bottomInset),
                child: startBar,
              ),
            ],
          );
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
            inset,
            kPlayPaneTopInset,
            inset,
            _bottomInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 20),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: PlaySetupColumnScroll(child: _cards(left))),
                    const SizedBox(width: _columnGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Loose: a short column keeps the bar right under
                          // its last card; a tall one scrolls above the bar.
                          Flexible(
                            child: PlaySetupColumnScroll(child: _cards(right)),
                          ),
                          const SizedBox(height: _cardGap),
                          startBar,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One setup column that scrolls without a scrollbar of its own. When it
/// holds more than it shows, the edge with more fades under an arrow button
/// ([ScrollEdgeArrows]), so the cut reads as more to scroll, never as a
/// sliced card. Under loose constraints it stays as short as its cards, so
/// a short right column keeps the start bar right under its last card.
/// Focus traversal still scrolls a focused control into view.
class PlaySetupColumnScroll extends StatelessWidget {
  const PlaySetupColumnScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Sized in the same layout pass as the cards: a growing card never
    // leaves the column a frame behind its content.
    return ScrollEdgeArrows(
      shrinkWrap: true,
      child: SingleChildScrollView(child: child),
    );
  }
}

class PlaySetupHeader extends StatelessWidget {
  const PlaySetupHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    // Fixed to one line each, so every Play setup header is the same
    // height and the columns below start at the same place.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// One titled group of setup controls.
class PlaySetupCard extends StatelessWidget {
  const PlaySetupCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;

  /// Sits at the end of the title row, such as a selection count.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: PlaySetupCardTitle(title)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// The title type of a [PlaySetupCard], shared by cards that build their
/// own title row.
class PlaySetupCardTitle extends StatelessWidget {
  const PlaySetupCardTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}

/// One line of the start bar's summary: the chosen value, and what it is.
class PlaySetupFact {
  const PlaySetupFact({required this.value, required this.label});

  final String value;
  final String label;
}

/// What will start, and the button that starts it. Docked under the right
/// column of [PlaySetupPage], so it is on screen however long the setup is.
class PlaySetupStartBar extends StatelessWidget {
  const PlaySetupStartBar({
    super.key,
    required this.facts,
    required this.primaryAction,
    this.heading,
    this.detail,
    this.secondaryAction,
    this.detailIsError = false,
  });

  /// The choices that matter most, read at a glance.
  final List<PlaySetupFact> facts;

  /// Optional line above the facts, such as the event's title.
  final String? heading;

  /// Optional note under the facts, shown only when it says something:
  /// what blocks the start, or a start from a chosen position.
  final String? detail;

  /// The start button, at the end of the facts.
  final Widget primaryAction;

  /// A way back, at the end of the heading row.
  final Widget? secondaryAction;

  /// Shows [detail] as a problem to fix, such as a failed start.
  final bool detailIsError;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (heading != null || secondaryAction != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      heading ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (secondaryAction != null) ...[
                    const SizedBox(width: 12),
                    secondaryAction!,
                  ],
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                for (var i = 0; i < facts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Expanded(child: _FactView(fact: facts[i])),
                ],
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 168),
                  child: primaryAction,
                ),
              ],
            ),
            if (detail != null) ...[
              const SizedBox(height: 10),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: detailIsError ? kRedColor : kSecondaryTextColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FactView extends StatelessWidget {
  const _FactView({required this.fact});

  final PlaySetupFact fact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fact.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            height: 1.2,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          fact.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
