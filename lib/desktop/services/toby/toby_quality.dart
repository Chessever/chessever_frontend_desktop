/// How much each of Toby's candidates gives away, by its own outcome
/// against the best candidate's: the colour of its arrow on the board and of
/// its chance and fill in the Toby Predicts rows.
///
/// Two copies, one rule: web `src/broadcast/lib/toby-quality.ts` (chessever
/// web frontend) and desktop `lib/desktop/services/toby/toby_quality.dart`
/// (this file). Change one, change both, each with its tests.
library;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/painting.dart' show Color;

import 'package:chessever/desktop/services/toby/toby_prediction.dart';

/// What a candidate costs the side to move against the best candidate.
enum TobyMoveQuality {
  /// Within five points of the best expected score.
  good,

  /// Five to ten points below it.
  dubious,

  /// Ten points or more below it: a mistake.
  bad,

  /// No outcome to judge by (Toby's quick network stage, or a row without
  /// one).
  neutral,
}

/// A loss at or above this is [TobyMoveQuality.dubious].
const double kTobyDubiousLoss = 0.05;

/// A loss at or above this is [TobyMoveQuality.bad].
const double kTobyBadLoss = 0.10;

/// Float noise allowance on the thresholds, so 0.35 - 0.30 counts as the
/// five points it is.
const double _kLossTolerance = 1e-9;

/// The mover's expected score after a move: its win share plus half the
/// draw. [TobyWdl] is already normalised to fractions that add up to one
/// (any scale Gamebase sends is divided by its total in `TobyWdl.fromJson`).
double tobyExpectedScore(TobyWdl wdl, Side mover) {
  final total = wdl.white + wdl.draw + wdl.black;
  if (total <= 0) return 0;
  final win = mover == Side.white ? wdl.white : wdl.black;
  return (win + wdl.draw / 2) / total;
}

/// The quality of a move whose outcome is [wdl], against the [best]
/// expected score of the reading. Null [wdl] or [best] is neutral.
TobyMoveQuality tobyMoveQuality({
  required TobyWdl? wdl,
  required double? best,
  required Side mover,
}) {
  if (wdl == null || best == null) return TobyMoveQuality.neutral;
  final loss = best - tobyExpectedScore(wdl, mover);
  if (loss >= kTobyBadLoss - _kLossTolerance) return TobyMoveQuality.bad;
  if (loss >= kTobyDubiousLoss - _kLossTolerance) {
    return TobyMoveQuality.dubious;
  }
  return TobyMoveQuality.good;
}

/// Every candidate's quality in [reading], by UCI. The best is the highest
/// expected score among ALL the moves the payload sent with an outcome
/// ([TobyReading.bestOutcomeScore], taken before the parser keeps only the
/// 24 most likely), matching the web, which keeps every move; a reading
/// where none carries one (the network stage) is all neutral.
Map<String, TobyMoveQuality> tobyMoveQualities(TobyReading reading) {
  final mover = reading.sideToMove;
  double? best = reading.bestOutcomeScore;
  for (final candidate in reading.candidates) {
    final wdl = candidate.wdl;
    if (wdl == null) continue;
    final score = tobyExpectedScore(wdl, mover);
    if (best == null || score > best) best = score;
  }
  return {
    for (final candidate in reading.candidates)
      candidate.uci: tobyMoveQuality(
        wdl: candidate.wdl,
        best: best,
        mover: mover,
      ),
  };
}

/// The arrow's hue on the board for each quality: deep, tonal values that
/// read on light and dark squares alike (the board keeps its colours in
/// every theme). Neutral is Toby's teal. The same hex values on the web.
const Color kTobyArrowGood = Color(0xFF2E7D4F);
const Color kTobyArrowDubious = Color(0xFFB7791F);
const Color kTobyArrowBad = Color(0xFFB23A3A);
const Color kTobyArrowNeutral = Color(0xFF1E7F79);

Color tobyArrowHue(TobyMoveQuality quality) => switch (quality) {
  TobyMoveQuality.good => kTobyArrowGood,
  TobyMoveQuality.dubious => kTobyArrowDubious,
  TobyMoveQuality.bad => kTobyArrowBad,
  TobyMoveQuality.neutral => kTobyArrowNeutral,
};

/// What a row's accessible label adds for [quality]: nothing for a good or
/// neutral move.
String tobyQualitySpoken(TobyMoveQuality quality) => switch (quality) {
  TobyMoveQuality.dubious => 'dubious',
  TobyMoveQuality.bad => 'a mistake',
  TobyMoveQuality.good || TobyMoveQuality.neutral => '',
};
