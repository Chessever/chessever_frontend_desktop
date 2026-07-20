import 'dart:convert';

import 'package:chessever/desktop/services/fide_rating_history_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FIDE history parser sorts months and ignores invalid rows', () {
    final points = parseFideRatingHistoryResponse(
      '\uFEFF${jsonEncode({
        'history': [
          {'date': '2026-07', 'rating': 2666, 'games': 5},
          {'date': 'invalid', 'rating': 2700, 'games': 1},
          {'date': '2026-05', 'rating': 2632, 'games': '4'},
          {'date': '2026-06', 'rating': '2644', 'games': null},
          {'date': '2026-13', 'rating': 2700, 'games': 1},
        ],
      })}',
    );

    expect(points.map((point) => point.rating), [2632, 2644, 2666]);
    expect(points.first.month, DateTime.utc(2026, 5));
    expect(points.first.games, 4);
    expect(points[1].games, isNull);
  });

  test('rating card trend follows the website twelve-month window', () {
    final points = <FideRatingHistoryPoint>[];
    for (var index = 0; index < 13; index++) {
      final month = DateTime.utc(2025, 7 + index);
      points.add(
        FideRatingHistoryPoint(
          month: month,
          rating: 2500 + index,
          games: index + 1,
        ),
      );
    }
    final history = FideRatingHistory({
      FideRatingHistoryType.classical: points,
    });

    final trend = history.cardTrend(FideRatingHistoryType.classical);

    expect(trend.series, hasLength(13));
    expect(trend.current, 2512);
    expect(trend.change, 12);
    expect(trend.games, 90);
  });

  test('main rating chart keeps the requested number of month intervals', () {
    final points = <FideRatingHistoryPoint>[];
    for (var index = 0; index < 30; index++) {
      points.add(
        FideRatingHistoryPoint(
          month: DateTime.utc(2024, 1 + index),
          rating: 2400 + index,
          games: 1,
        ),
      );
    }
    final history = FideRatingHistory({
      FideRatingHistoryType.classical: points,
    });

    final oneYear = history.chartSeries(
      FideRatingHistoryType.classical,
      months: 12,
    );

    expect(oneYear, hasLength(13));
    expect(oneYear.first.month, DateTime.utc(2025, 6));
    expect(oneYear.last.month, DateTime.utc(2026, 6));
    expect(history.chartSeries(FideRatingHistoryType.classical), hasLength(30));
  });

  test('rating card omits game total when monthly counts are incomplete', () {
    final history = FideRatingHistory({
      FideRatingHistoryType.rapid: [
        FideRatingHistoryPoint(
          month: DateTime.utc(2026, 6),
          rating: 2500,
          games: 2,
        ),
        FideRatingHistoryPoint(
          month: DateTime.utc(2026, 7),
          rating: 2510,
          games: null,
        ),
      ],
    });

    final trend = history.cardTrend(FideRatingHistoryType.rapid);

    expect(trend.current, 2510);
    expect(trend.change, isNull);
    expect(trend.games, isNull);
  });
}
