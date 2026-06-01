import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/play_models.dart';

/// FIDE-style Elo math for the ChessEver Play ladders.
///
/// FIDE rules (Handbook B.02 8.3 + 11.2, simplified):
///   - K = 40 for new accounts during the first 30 rated games.
///   - K = 10 once the player has crossed 2400 at any point, even if the
///     current rating has since dropped below 2400.
///   - K = 20 otherwise.
///   - Expected score E = 1 / (1 + 10^((Ro - Rs)/400)).
///   - delta = round(K * (S - E)) where S in {0, 0.5, 1}.
///   - Working rating clamped to [100, 4000] to match the DB CHECKs.
@immutable
class FideEloCalculator {
  const FideEloCalculator({
    this.newPlayerGameThreshold = 30,
    this.peakKReductionRating = 2400,
    this.kNew = 40,
    this.kStandard = 20,
    this.kElite = 10,
    this.minRating = 100,
    this.maxRating = 4000,
  });

  final int newPlayerGameThreshold;
  final int peakKReductionRating;
  final int kNew;
  final int kStandard;
  final int kElite;
  final int minRating;
  final int maxRating;

  /// Returns the K factor to apply for the player's next rated game.
  ///
  /// [gamesPlayedBefore] is the number of rated games this player has
  /// completed in the same time control before the current game.
  /// [peakRating] is the lifetime peak rating in the same time control.
  int kFactorFor({
    required int gamesPlayedBefore,
    required int peakRating,
  }) {
    if (peakRating >= peakKReductionRating) return kElite;
    if (gamesPlayedBefore < newPlayerGameThreshold) return kNew;
    return kStandard;
  }

  /// Probability that the player rated [playerRating] scores against an
  /// opponent rated [opponentRating]. 0.0 to 1.0.
  double expectedScore({
    required int playerRating,
    required int opponentRating,
  }) {
    return 1 / (1 + math.pow(10, (opponentRating - playerRating) / 400));
  }

  /// Computes the rating change and the next rating after one rated game.
  ///
  /// [score] must be 1 (win), 0.5 (draw), or 0 (loss).
  /// Returns the rating delta (already rounded) and the resulting rating
  /// clamped to [minRating, maxRating].
  EloUpdate compute({
    required int currentRating,
    required int opponentRating,
    required double score,
    required int gamesPlayedBefore,
    required int peakRating,
  }) {
    assert(score == 0 || score == 0.5 || score == 1,
        'score must be 0, 0.5 or 1, got $score');
    final k = kFactorFor(
      gamesPlayedBefore: gamesPlayedBefore,
      peakRating: peakRating,
    );
    final expected = expectedScore(
      playerRating: currentRating,
      opponentRating: opponentRating,
    );
    final delta = (k * (score - expected)).round();
    final next = (currentRating + delta).clamp(minRating, maxRating);
    return EloUpdate(
      ratingBefore: currentRating,
      ratingAfter: next,
      delta: next - currentRating,
      expectedScore: expected,
      kFactor: k,
      score: score,
    );
  }
}

@immutable
class EloUpdate {
  const EloUpdate({
    required this.ratingBefore,
    required this.ratingAfter,
    required this.delta,
    required this.expectedScore,
    required this.kFactor,
    required this.score,
  });

  final int ratingBefore;
  final int ratingAfter;
  final int delta;
  final double expectedScore;
  final int kFactor;
  final double score;
}

/// Maps the engine-side [TimeControlCategory] (which also has a `custom`
/// fallback) onto the four rated ladders persisted server-side.
///
/// Returns null for `custom` games so callers can skip rating updates
/// when the user picked a wholly bespoke clock.
RatedTimeControl? toRatedTimeControl(TimeControlCategory category) {
  switch (category) {
    case TimeControlCategory.bullet:
      return RatedTimeControl.bullet;
    case TimeControlCategory.blitz:
      return RatedTimeControl.blitz;
    case TimeControlCategory.rapid:
      return RatedTimeControl.rapid;
    case TimeControlCategory.classical:
      return RatedTimeControl.classical;
    case TimeControlCategory.custom:
      return null;
  }
}

/// Same classification the engine uses, but takes raw base seconds. Useful
/// when a saved game only has `base_seconds` and no category string.
RatedTimeControl ratedTimeControlForSeconds(int baseSeconds) {
  if (baseSeconds <= 120) return RatedTimeControl.bullet;
  if (baseSeconds <= 300) return RatedTimeControl.blitz;
  if (baseSeconds <= 1800) return RatedTimeControl.rapid;
  return RatedTimeControl.classical;
}

/// Parse a category string -- the one stored on `PlayGameRecord.timeCategory`
/// or `user_play_games.time_category` โ€” back into a rated ladder.
/// Returns null for unknown values (e.g. legacy `custom`).
RatedTimeControl? ratedTimeControlFromString(String? raw) {
  if (raw == null) return null;
  switch (raw.toLowerCase().trim()) {
    case 'bullet':
      return RatedTimeControl.bullet;
    case 'blitz':
      return RatedTimeControl.blitz;
    case 'rapid':
      return RatedTimeControl.rapid;
    case 'classical':
    case 'standard':
      return RatedTimeControl.classical;
  }
  return null;
}

/// The four rated ladders persisted in `user_play_profiles` and
/// `user_play_rating_history`.
enum RatedTimeControl { bullet, blitz, rapid, classical }

extension RatedTimeControlExt on RatedTimeControl {
  /// Wire value stored in `user_play_rating_history.time_control`.
  String get wire {
    switch (this) {
      case RatedTimeControl.bullet:
        return 'bullet';
      case RatedTimeControl.blitz:
        return 'blitz';
      case RatedTimeControl.rapid:
        return 'rapid';
      case RatedTimeControl.classical:
        return 'classical';
    }
  }

  String get displayName {
    switch (this) {
      case RatedTimeControl.bullet:
        return 'Bullet';
      case RatedTimeControl.blitz:
        return 'Blitz';
      case RatedTimeControl.rapid:
        return 'Rapid';
      case RatedTimeControl.classical:
        return 'Classical';
    }
  }
}
