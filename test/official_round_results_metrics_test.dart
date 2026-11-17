import 'package:chessever/services/official_round_results.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ratings clamp at 400 Elo while performance keeps actual opponents', () {
    final high = calculateScorecardMetrics(
      playerRating: 1000,
      kFactor: 20,
      games: const [ScorecardMetricGame(points: 1, opponentRating: 3000)],
    );
    expect(high.ratingChange, 18);
    expect(high.performanceRating, 3800);
    final low = calculateScorecardMetrics(
      playerRating: 3000,
      kFactor: 20,
      games: const [ScorecardMetricGame(points: 0, opponentRating: 1000)],
    );
    expect(low.ratingChange, -18);
    expect(low.performanceRating, 200);
  });
  test(
    'missing invalid player rating or K excludes Elo but retains performance',
    () {
      for (final rating in [null, 0.0, -1.0, double.nan, double.infinity]) {
        final m = calculateScorecardMetrics(
          playerRating: rating,
          kFactor: 20,
          games: const [ScorecardMetricGame(points: .5, opponentRating: 2000)],
        );
        expect(m.ratingChange, isNull);
        expect(m.gameRatingChanges, [null]);
        expect(m.performanceRating, 2000);
      }
      for (final k in [null, 0.0, -1.0, double.nan, double.infinity]) {
        final m = calculateScorecardMetrics(
          playerRating: 2000,
          kFactor: k,
          games: const [ScorecardMetricGame(points: 0, opponentRating: 2000)],
        );
        expect(m.ratingChange, isNull);
        expect(m.performanceRating, 1200);
      }
    },
  );
  test(
    'unfinished invalid scores and empty histories never become rated losses',
    () {
      final m = calculateScorecardMetrics(
        playerRating: 2000,
        kFactor: 20,
        games: const [
          ScorecardMetricGame(points: null, opponentRating: 2000),
          ScorecardMetricGame(points: .75, opponentRating: 2000),
        ],
      );
      expect(m.performanceRating, isNull);
      expect(m.ratingChange, isNull);
      expect(m.gameRatingChanges, [null, null]);
      final empty = calculateScorecardMetrics(
        playerRating: 2000,
        kFactor: 20,
        games: [],
      );
      expect(empty.performanceRating, isNull);
      expect(empty.ratingChange, isNull);
      expect(empty.gameRatingChanges, isEmpty);
    },
  );
  test(
    'source rounding ties go toward positive infinity including negative zero',
    () {
      final m = calculateScorecardMetrics(
        playerRating: 2000,
        kFactor: 1,
        games: const [ScorecardMetricGame(points: 0, opponentRating: 2000)],
      );
      expect(m.gameRatingChanges, [0]);
      expect(m.ratingChange, 0);
    },
  );
  test('official scorecard excludes byes forfeits and unrated opponents', () {
    OfficialRoundResult result(
      double points,
      double? rating, {
      bool np = false,
    }) => OfficialRoundResult(
      playerName: 'Synthetic Player',
      roundId: 'r',
      roundName: 'Round',
      roundNumber: 1,
      points: points,
      opponentName: 'Synthetic Opponent',
      opponentRating: rating,
      nonPlayed: np,
    );
    final metrics = calculateOfficialScorecardMetrics(
      playerRating: 2000,
      kFactor: 20,
      results: [
        result(1, 2000),
        result(1, 2300, np: true),
        result(1, null),
        result(0, 0),
        result(.5, double.nan),
        result(1, double.infinity),
      ],
    );
    expect(metrics.performanceRating, 2800);
    expect(metrics.ratingChange, 10);
    expect(metrics.gameRatingChanges, [10, null, null, null, null, null]);
  });
  test(
    'mixed scorecard computes source performance and sums raw Elo changes',
    () {
      final metrics = calculateScorecardMetrics(
        playerRating: 2000,
        kFactor: 20,
        games: const [
          ScorecardMetricGame(points: 1, opponentRating: 2100),
          ScorecardMetricGame(points: 0.5, opponentRating: 2100),
          ScorecardMetricGame(points: 0, opponentRating: 2100),
        ],
      );
      expect(metrics.performanceRating, 2100);
      expect(metrics.gameRatingChanges, [13, 3, -7]);
      // Sum of rounded rows is 9; rounding the raw sum is 8.
      expect(metrics.ratingChange, 8);
    },
  );
}
