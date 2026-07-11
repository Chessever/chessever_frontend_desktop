import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/models/player_stats.dart';

void main() {
  group('playerYearChartSeries', () {
    test('maps ordered years with games and W/D/L stack segments', () {
      const years = <PlayerYearStat>[
        PlayerYearStat(
          year: 2021,
          tally: PlayerResultTally(wins: 2, draws: 1, losses: 1),
          // total overrides tally sum (4) — bar height uses total; remainder unclassified.
          total: 10,
          timeControls: [
            PlayerTimeControlStat(category: 'blitz', count: 6),
            PlayerTimeControlStat(category: 'rapid', count: 4),
          ],
          sources: [
            PlayerSourceStat(label: 'Lichess', count: 7),
            PlayerSourceStat(label: 'Chess.com', count: 3),
          ],
        ),
        PlayerYearStat(
          year: 2022,
          tally: PlayerResultTally(wins: 5, draws: 0, losses: 3),
        ),
        PlayerYearStat(
          year: 2023,
          tally: PlayerResultTally(wins: 0, draws: 2, losses: 0),
          total: 2,
        ),
        PlayerYearStat(year: 2024, tally: PlayerResultTally.empty, total: 7),
      ];

      final series = playerYearChartSeries(years);

      expect(series.map((p) => p.year).toList(), [2021, 2022, 2023, 2024]);
      expect(series.map((p) => p.games).toList(), [10, 8, 2, 7]);
      expect(playerYearChartMaxGames(series), 10);

      final y2021 = series[0];
      expect(y2021.wins, 2);
      expect(y2021.draws, 1);
      expect(y2021.losses, 1);
      expect(y2021.unclassified, 6); // 10 - 4
      expect(y2021.timeControls.map((t) => t.category), ['blitz', 'rapid']);
      expect(y2021.timeControls.map((t) => t.count), [6, 4]);
      expect(y2021.sources.map((s) => s.label), ['Lichess', 'Chess.com']);
      expect(y2021.sources.map((s) => s.count), [7, 3]);

      final y2022 = series[1];
      expect(y2022.wins, 5);
      expect(y2022.draws, 0);
      expect(y2022.losses, 3);
      expect(y2022.unclassified, 0);
    });

    test('empty series max is 1 so axis scale stays valid', () {
      expect(playerYearChartSeries(const []), isEmpty);
      expect(playerYearChartMaxGames(const []), 1);
      expect(playerYearChartAxisMax(1), 1);
      expect(playerYearChartAxisTicks(1), [0, 1]);
    });

    test('single-year series preserves game count from tally alone', () {
      const years = <PlayerYearStat>[
        PlayerYearStat(
          year: 2019,
          tally: PlayerResultTally(wins: 1, draws: 1, losses: 1),
        ),
      ];
      final series = playerYearChartSeries(years);
      expect(series, hasLength(1));
      expect(series.single.year, 2019);
      expect(series.single.games, 3);
      expect(
        series.single.wins + series.single.draws + series.single.losses,
        3,
      );
      expect(playerYearChartMaxGames(series), 3);
    });

    test('axis max is a nice ceiling at or above peak games', () {
      expect(playerYearChartAxisMax(10), greaterThanOrEqualTo(10));
      expect(playerYearChartAxisMax(11), greaterThanOrEqualTo(11));
      final ticks = playerYearChartAxisTicks(playerYearChartAxisMax(11));
      expect(ticks.first, 0);
      expect(ticks.last, playerYearChartAxisMax(11));
      // Bar scale and grid share the same top — no tick above axisMax.
      expect(ticks.every((t) => t <= playerYearChartAxisMax(11)), isTrue);
    });
  });
}
