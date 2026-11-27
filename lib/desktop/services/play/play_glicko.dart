import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Glicko-2 for the ChessEver Play ladders, the system Lichess runs.
///
/// Every ladder carries a rating, a rating deviation (RD: how sure we are
/// of the rating) and a volatility (how erratic the player's results are).
/// A new or long-idle player has a high RD, so each game moves their
/// rating a lot; a settled player has a low RD and moves slowly. While RD
/// is above [kPlayProvisionalRd] the rating is provisional and shown with
/// a "?" the way Lichess does.
///
/// Each game is its own rating period. Before the game, RD grows with the
/// days since the player's previous game on that ladder, so coming back
/// after a break moves the rating faster again.
///
/// Reference: Mark Glickman, "Example of the Glicko-2 system" (2012).

/// Default rating for a ladder that has no games. Kept at the value the
/// earlier Elo model used so nobody's starting number changes.
const int kPlayInitialRating = 1200;

/// RD of a ladder with no games, and the ceiling RD can grow back to.
const double kPlayMaxRd = 350;

/// RD never shrinks below this, so a settled rating can still move.
const double kPlayMinRd = 45;

/// Above this RD the rating is provisional (Lichess uses the same line).
const double kPlayProvisionalRd = 110;

/// Starting volatility, Glickman's recommended default.
const double kPlayInitialVolatility = 0.06;

/// Bots play at a fixed, calibrated strength, so their rating is treated
/// as well known.
const double kPlayBotRd = 60;

/// System constant: how much volatility may change per period. Lichess
/// uses 0.75.
const double kPlayGlickoTau = 0.75;

const int kPlayMinRating = 100;
const int kPlayMaxRating = 4000;

const double _scale = 173.7178;
const double _epsilon = 0.000001;

/// RD for a ladder stored before Glicko-2 existed, from its game count.
/// 0 games: 350; 5: ~165; 10: ~124; 20: ~90; 50 and up: ~60.
double legacyRdForGames(int gamesPlayed) {
  if (gamesPlayed <= 0) return kPlayMaxRd;
  final rd = kPlayMaxRd / math.sqrt(1 + gamesPlayed * 0.7);
  return rd.clamp(60.0, kPlayMaxRd).toDouble();
}

/// RD after [idleDays] whole days without a game on the ladder.
double inflateRdForIdleDays({
  required double rd,
  required double volatility,
  required int idleDays,
}) {
  if (idleDays <= 0) return rd.clamp(kPlayMinRd, kPlayMaxRd).toDouble();
  final phi = rd / _scale;
  final grown = math.sqrt(phi * phi + volatility * volatility * idleDays);
  return (grown * _scale).clamp(kPlayMinRd, kPlayMaxRd).toDouble();
}

/// Whole days between two moments, never negative.
int idleDaysBetween(DateTime? previous, DateTime at) {
  if (previous == null) return 0;
  final days = at.difference(previous).inDays;
  return days < 0 ? 0 : days;
}

@immutable
class Glicko2Result {
  const Glicko2Result({
    required this.rating,
    required this.rd,
    required this.volatility,
    required this.expectedScore,
  });

  /// Unrounded rating after the game.
  final double rating;
  final double rd;
  final double volatility;

  /// The player's expected score before the game, 0 to 1.
  final double expectedScore;
}

/// One Glicko-2 rating period with a single game.
///
/// [score] is 1 for a win, 0.5 for a draw, 0 for a loss. [rd] must
/// already include any idle-time growth.
Glicko2Result glicko2Rate({
  required double rating,
  required double rd,
  required double volatility,
  required double opponentRating,
  double opponentRd = kPlayBotRd,
  required double score,
  double tau = kPlayGlickoTau,
}) {
  final mu = (rating - 1500) / _scale;
  final phi = rd / _scale;
  final muJ = (opponentRating - 1500) / _scale;
  final phiJ = opponentRd / _scale;

  final g = 1 / math.sqrt(1 + 3 * phiJ * phiJ / (math.pi * math.pi));
  final e = 1 / (1 + math.exp(-g * (mu - muJ)));
  final v = 1 / (g * g * e * (1 - e));
  final delta = v * g * (score - e);

  // Volatility: Illinois-method root of f(x) (Glickman step 5).
  final a = math.log(volatility * volatility);
  double f(double x) {
    final ex = math.exp(x);
    final num = ex * (delta * delta - phi * phi - v - ex);
    final den = 2 * math.pow(phi * phi + v + ex, 2);
    return num / den - (x - a) / (tau * tau);
  }

  var bigA = a;
  double bigB;
  if (delta * delta > phi * phi + v) {
    bigB = math.log(delta * delta - phi * phi - v);
  } else {
    var k = 1;
    while (f(a - k * tau) < 0) {
      k++;
      if (k > 100) break;
    }
    bigB = a - k * tau;
  }
  var fA = f(bigA);
  var fB = f(bigB);
  var guard = 0;
  while ((bigB - bigA).abs() > _epsilon && guard < 100) {
    guard++;
    final c = bigA + (bigA - bigB) * fA / (fB - fA);
    final fC = f(c);
    if (fC * fB <= 0) {
      bigA = bigB;
      fA = fB;
    } else {
      fA = fA / 2;
    }
    bigB = c;
    fB = fC;
  }
  final nextVolatility = math.exp(bigA / 2);

  final phiStar = math.sqrt(phi * phi + nextVolatility * nextVolatility);
  final nextPhi = 1 / math.sqrt(1 / (phiStar * phiStar) + 1 / v);
  final nextMu = mu + nextPhi * nextPhi * g * (score - e);

  return Glicko2Result(
    rating: nextMu * _scale + 1500,
    rd: (nextPhi * _scale).clamp(kPlayMinRd, kPlayMaxRd).toDouble(),
    volatility: nextVolatility.clamp(0.02, 0.15).toDouble(),
    expectedScore: e,
  );
}
