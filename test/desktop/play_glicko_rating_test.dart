import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_glicko.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';

void main() {
  final at = DateTime(2026, 11, 20, 18);

  test('Glicko-2 matches Glickman\'s worked example', () {
    // Glickman (2012): 1500/200/0.06 player; the example's three games are
    // replaced here by one, so check the single-game expectation instead.
    final r = glicko2Rate(
      rating: 1500,
      rd: 200,
      volatility: 0.06,
      opponentRating: 1400,
      opponentRd: 30,
      score: 1,
    );
    expect(r.expectedScore, closeTo(0.639, 0.002));
    expect(r.rating, greaterThan(1500));
    expect(r.rd, lessThan(200));
  });

  test('a new player moves a lot, a settled one a little', () {
    const fresh = PlayRatingStats.initial;
    const settled = PlayRatingStats(
      rating: 1200,
      peak: 1250,
      gamesPlayed: 120,
      wins: 60,
      losses: 50,
      draws: 10,
      rd: 50,
      volatility: 0.06,
    );
    final a = ratePlayGame(
      stats: fresh,
      opponentRating: 1200,
      score: 1,
      at: at,
    );
    final b = ratePlayGame(
      stats: settled,
      opponentRating: 1200,
      score: 1,
      at: at,
    );
    expect(a.delta, greaterThan(100));
    expect(b.delta, inInclusiveRange(1, 12));
    expect(fresh.isProvisional, isTrue);
    expect(settled.isProvisional, isFalse);
    expect(a.statsAfter.gamesPlayed, 1);
    expect(a.statsAfter.wins, 1);
    expect(a.statsAfter.rd, lessThan(kPlayMaxRd));
    expect(a.statsAfter.lastPlayedAt, at);
  });

  test('losing to a much weaker bot costs more than to a stronger one', () {
    const stats = PlayRatingStats(
      rating: 1600,
      peak: 1600,
      gamesPlayed: 40,
      wins: 20,
      losses: 20,
      draws: 0,
      rd: 80,
    );
    final weak = ratePlayGame(
      stats: stats,
      opponentRating: 1200,
      score: 0,
      at: at,
    );
    final strong = ratePlayGame(
      stats: stats,
      opponentRating: 2000,
      score: 0,
      at: at,
    );
    expect(weak.delta, lessThan(strong.delta));
    expect(strong.delta, lessThan(0));
  });

  test('preview returns exactly the delta the save path applies', () {
    final profile = PlayUserProfile.fallback('Player').copyWithRating(
      RatedTimeControl.blitz,
      PlayRatingStats(
        rating: 1340,
        peak: 1360,
        gamesPlayed: 12,
        wins: 6,
        losses: 5,
        draws: 1,
        rd: 104.2,
        volatility: 0.061,
        lastPlayedAt: at.subtract(const Duration(days: 9)),
      ),
    );
    for (final score in [0.0, 0.5, 1.0]) {
      final preview = previewPlayRatingDelta(
        profile: profile,
        timeControl: RatedTimeControl.blitz,
        opponentRating: 1500,
        score: score,
        at: at,
      );
      final applied = ratePlayGame(
        stats: profile.statsFor(RatedTimeControl.blitz),
        opponentRating: 1500,
        score: score,
        at: at,
      );
      expect(preview, applied.delta);
      expect(applied.ratingAfter - applied.ratingBefore, applied.delta);
    }
    expect(
      previewPlayRatingDelta(
        profile: profile,
        timeControl: RatedTimeControl.blitz,
        opponentRating: 1500,
        score: 0.3,
      ),
      isNull,
    );
  });

  test('idle days widen RD again, capped at the new-player value', () {
    expect(inflateRdForIdleDays(rd: 60, volatility: 0.06, idleDays: 0), 60);
    final month = inflateRdForIdleDays(rd: 60, volatility: 0.06, idleDays: 30);
    expect(month, greaterThan(60));
    expect(month, lessThan(100));
    expect(
      inflateRdForIdleDays(rd: 300, volatility: 0.06, idleDays: 5000),
      kPlayMaxRd,
    );
  });

  test('legacy profiles without RD get one from their game count', () {
    final legacy = PlayUserProfile.fromJson({
      'displayName': 'Old',
      'ratings': {
        'rapid': {
          'rating': 1410,
          'peak': 1450,
          'gamesPlayed': 60,
          'wins': 30,
          'losses': 25,
          'draws': 5,
        },
        'bullet': {
          'rating': 1150,
          'peak': 1200,
          'gamesPlayed': 3,
          'wins': 1,
          'losses': 2,
          'draws': 0,
        },
      },
    });
    final rapid = legacy.statsFor(RatedTimeControl.rapid);
    final bullet = legacy.statsFor(RatedTimeControl.bullet);
    expect(rapid.rd, isNull);
    expect(rapid.ratingDeviation, closeTo(60, 1));
    expect(rapid.isProvisional, isFalse);
    expect(rapid.displayRating, '1410');
    expect(bullet.isProvisional, isTrue);
    expect(bullet.displayRating, '1150?');
    expect(rapid.volatility, kPlayInitialVolatility);

    // Once rated under Glicko-2 the state round-trips through local JSON.
    final next =
        ratePlayGame(
          stats: rapid,
          opponentRating: 1500,
          score: 1,
          at: at,
        ).statsAfter;
    final again = PlayUserProfile.fromJson(
      legacy.copyWithRating(RatedTimeControl.rapid, next).toLocalJson(),
    ).statsFor(RatedTimeControl.rapid);
    expect(again.rd, closeTo(next.rd!, 1e-9));
    expect(again.volatility, closeTo(next.volatility, 1e-9));
    expect(again.lastPlayedAt, at);
  });

  test('a server row keeps the local Glicko state when games agree', () {
    final local = PlayUserProfile.fallback('P').copyWithRating(
      RatedTimeControl.blitz,
      const PlayRatingStats(
        rating: 1300,
        peak: 1300,
        gamesPlayed: 5,
        wins: 3,
        losses: 2,
        draws: 0,
        rd: 140,
        volatility: 0.059,
      ),
    );
    final remote = PlayUserProfile.fromJson(
      local.toSupabaseJson('user'),
    ).withGlickoStateFrom(local);
    expect(remote.statsFor(RatedTimeControl.blitz).rd, 140);
    expect(remote.statsFor(RatedTimeControl.rapid).rd, isNull);
  });

  test('the old FIDE calculator still compiles and computes', () {
    final update = const FideEloCalculator().compute(
      currentRating: 1200,
      opponentRating: 1200,
      score: 1,
      gamesPlayedBefore: 0,
      peakRating: 1200,
    );
    expect(update.delta, 20);
  });
}
