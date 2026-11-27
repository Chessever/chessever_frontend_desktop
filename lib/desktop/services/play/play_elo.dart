import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/play_glicko.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';

/// Result of one rated game under the Glicko-2 ladders.
@immutable
class PlayRatingOutcome {
  const PlayRatingOutcome({
    required this.ratingBefore,
    required this.ratingAfter,
    required this.delta,
    required this.expectedScore,
    required this.score,
    required this.rdBefore,
    required this.rdAfter,
    required this.volatilityAfter,
    required this.statsAfter,
  });

  final int ratingBefore;
  final int ratingAfter;

  /// `ratingAfter - ratingBefore`, the number the UI shows as +N / -N.
  final int delta;
  final double expectedScore;
  final double score;

  /// RD going into the game, after growth for idle days.
  final double rdBefore;
  final double rdAfter;
  final double volatilityAfter;
  final PlayRatingStats statsAfter;

  bool get provisionalAfter => rdAfter > kPlayProvisionalRd;

  /// What a FIDE-style K factor would have been to give the same change.
  /// Stored in the history row's `k_factor` column for continuity. Never
  /// below 1: the column has `CHECK (k_factor > 0)`, and a game whose
  /// rating did not move would otherwise give 0 and be rejected.
  int get effectiveK {
    final surprise = score - expectedScore;
    if (surprise.abs() < 0.01) return 1;
    final k = (delta / surprise).abs().round();
    return k < 1 ? 1 : k;
  }
}

/// Rates one game on one ladder. The single source of truth: both the
/// in-game preview and [PlayProfileRepository.saveCompletedGame] go
/// through here, so the number shown before saving is the one applied.
///
/// [at] is when the game ended; it decides how many idle days grow RD.
///
/// [gainFactor] is the share of a rating gain the game keeps for the help
/// it used (`playHelpGainFactor`): 1 with no help. Only a gain shrinks; a
/// loss is never softened, and RD and volatility move as for any game.
PlayRatingOutcome ratePlayGame({
  required PlayRatingStats stats,
  required int opponentRating,
  required double score,
  required DateTime at,
  double gainFactor = 1,
}) {
  final rdBefore = inflateRdForIdleDays(
    rd: stats.ratingDeviation,
    volatility: stats.volatility,
    idleDays: idleDaysBetween(stats.lastPlayedAt, at),
  );
  final result = glicko2Rate(
    rating: stats.rating.toDouble(),
    rd: rdBefore,
    volatility: stats.volatility,
    opponentRating: opponentRating.toDouble(),
    score: score,
  );
  var next = result.rating.round().clamp(kPlayMinRating, kPlayMaxRating);
  final factor = gainFactor.clamp(0.0, 1.0);
  if (next > stats.rating && factor < 1) {
    next = stats.rating + ((next - stats.rating) * factor).round();
  }
  final after = stats.applyGlicko(
    newRating: next,
    rd: result.rd,
    volatility: result.volatility,
    score: score,
    at: at,
  );
  return PlayRatingOutcome(
    ratingBefore: stats.rating,
    ratingAfter: next,
    delta: next - stats.rating,
    expectedScore: result.expectedScore,
    score: score,
    rdBefore: rdBefore,
    rdAfter: result.rd,
    volatilityAfter: result.volatility,
    statsAfter: after,
  );
}

/// The rating change [PlayProfileRepository.saveCompletedGame] will apply
/// for this game, for the in-game result badge.
///
/// [score] is the human's score: 1, 0.5 or 0. [opponentRating] is the
/// bot's rating (`PlaySessionState.config.elo`). Returns null when the
/// score is not a chess result. Unrated (custom) clocks never reach here:
/// map them with [toRatedTimeControl] first, which returns null.
int? previewPlayRatingDelta({
  required PlayUserProfile profile,
  required RatedTimeControl timeControl,
  required int opponentRating,
  required double score,
  DateTime? at,
  double gainFactor = 1,
}) {
  if (score != 0 && score != 0.5 && score != 1) return null;
  return ratePlayGame(
    stats: profile.statsFor(timeControl),
    opponentRating: opponentRating,
    score: score,
    at: at ?? DateTime.now(),
    gainFactor: gainFactor,
  ).delta;
}

/// FIDE-style Elo math, kept for callers that still compile against it.
/// The Play ladders are rated with Glicko-2 through [ratePlayGame]; use
/// [previewPlayRatingDelta] to show the change a game will make.
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
  int kFactorFor({required int gamesPlayedBefore, required int peakRating}) {
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
    assert(
      score == 0 || score == 0.5 || score == 1,
      'score must be 0, 0.5 or 1, got $score',
    );
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
