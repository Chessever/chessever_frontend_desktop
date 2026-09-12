import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// What a miniature is, and what Free covers.
///
/// Deliberately static. `getMiniatureStats` exists, but every figure a stats
/// dashboard could show (totals, colour split, openings, speeds, busiest day)
/// is a shortcut into a filter the Games view already exposes, so it would
/// restate the same database twice. This view answers the question the other
/// two cannot, reads no provider, sends no request, and has no loading or
/// error state.
class DesktopMiniaturesAboutView extends StatelessWidget {
  const DesktopMiniaturesAboutView({super.key});

  static const List<(String, String)> _rules = [
    ('Length', '3 to 25 moves. White never plays a 26th.'),
    ('Result', 'One side wins. A draw is never a miniature.'),
    (
      'Finish',
      'Mate on the board, or an engine confirming the winner was clearly '
          'ahead when the game stopped.',
    ),
    (
      'Free',
      'Games dated today. Premium opens every other day, including undated '
          'games.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          // A readable measure for prose, not a panel size.
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'A miniature is a game won in 25 moves or fewer.',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Short decisive games: an opening trap, a missed tactic, an '
                'attack that lands before the position settles.',
                style: TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              const _MoveWindow(),
              const SizedBox(height: 30),
              Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                },
                children: [
                  for (var i = 0; i < _rules.length; i++)
                    TableRow(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            right: 20,
                            bottom: i == _rules.length - 1 ? 0 : 14,
                          ),
                          child: Text(
                            _rules[i].$1,
                            style: const TextStyle(
                              color: kWhiteColor70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.5,
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: i == _rules.length - 1 ? 0 : 14,
                          ),
                          child: Text(
                            _rules[i].$2,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The qualifying window drawn as one full-width band, labelled at both ends.
class _MoveWindow extends StatelessWidget {
  const _MoveWindow();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: kWhiteColor.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const SizedBox(height: 6),
        ),
        const SizedBox(height: 8),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [_Tick('Move 3'), _Tick('Move 25')],
        ),
      ],
    );
  }
}

class _Tick extends StatelessWidget {
  const _Tick(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 12,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}
