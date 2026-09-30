import 'package:chessever/desktop/services/desktop_local_day_clock.dart';
import 'package:chessever/desktop/state/desktop_miniature_players.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/miniatures/miniature_players.dart';
import 'package:chessever/repository/gamebase/miniatures/miniatures_order.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

GamebaseMiniature _mini(String id, {DateTime? date, int? white, int? black}) =>
    GamebaseMiniature(
      gameId: id,
      plyCount: 20,
      finalMoveNumber: 10,
      result: 'W',
      timeControl: 'BLITZ',
      isOnline: false,
      date: date,
      whiteElo: white,
      blackElo: black,
    );

GamesTourModel _tour(String id, DateTime? date, int white, int black) =>
    GamesTourModel(
      gameId: id,
      whitePlayer: PlayerCard(
        name: 'W',
        federation: '',
        title: '',
        rating: white,
        countryCode: '',
        team: null,
      ),
      blackPlayer: PlayerCard(
        name: 'B',
        federation: '',
        title: '',
        rating: black,
        countryCode: '',
        team: null,
      ),
      whiteTimeDisplay: '--:--',
      blackTimeDisplay: '--:--',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.whiteWins,
      roundId: 'gamebase-miniatures',
      tourId: '',
      lastMoveTime: date,
    );

void main() {
  group('canonical Miniatures order', () {
    test(
      'UTC day desc, then average rating desc with 1800 fallback, then id',
      () {
        final day1 = DateTime.utc(2026, 9, 11);
        final day2 = DateTime.utc(2026, 9, 12);
        final ordered = orderMiniaturesByDayAndAverageRating([
          _mini('old-strong', date: day1, white: 2800, black: 2800),
          _mini('fallback', date: day2, white: null, black: 2000), // 1900
          _mini('rated', date: day2, white: 1850, black: 1850), // 1850
          _mini('undated', white: 2900, black: 2900),
          _mini('zero', date: day2, white: 0, black: 0), // 1800
          _mini('b-tie', date: day2, white: 1900, black: 1900), // 1900
        ]);
        expect(ordered.map((m) => m.gameId), [
          'b-tie',
          'fallback',
          'rated',
          'zero',
          'old-strong',
          'undated',
        ]);
        expect(
          _mini('x', white: null, black: 2001).effectiveAverageRating,
          1901,
        );
        expect(miniatureMissingRatingFallback, 1800);
      },
    );

    test('the board-model comparator matches the gamebase order', () {
      final day1 = DateTime.utc(2026, 9, 11);
      final day2 = DateTime.utc(2026, 9, 12);
      final games = [
        _tour('a', day1, 2700, 2700),
        _tour('b', day2, 0, 2000),
        _tour('c', day2, 1850, 1850),
        _tour('d', null, 2900, 2900),
      ]..sort(compareMiniatureGamesByDayAndAverageRating);
      expect(games.map((g) => g.gameId), ['b', 'c', 'a', 'd']);
    });

    test('a UTC day key is not shifted by the local timezone', () {
      expect(miniatureUtcDayKey(DateTime.utc(2026, 9, 12)), 20260912);
      expect(
        miniatureUtcDateKey(DateTime.utc(2026, 9, 11, 23, 59)),
        '2026-09-11',
      );
      expect(miniatureUtcDateKey(null), kMiniatureUnknownDateKey);
    });
  });

  group('Miniatures queries', () {
    test('a scorecard scope is sent but never counted as a filter', () {
      final filter = MiniatureGamesFilter.defaultFilter.copyWith(
        playerId: 'p-1',
      );
      expect(filter.queryParameters(limit: 50, offset: 0)['playerId'], 'p-1');
      expect(filter.hasActiveFilters, isFalse);
      expect(
        filter
            .copyWith(clearPlayerId: true)
            .queryParameters(limit: 1, offset: 0)
            .containsKey('playerId'),
        isFalse,
      );
    });

    test('the players query has no sort: ranking is always by rating', () {
      const query = DesktopMiniaturePlayersQuery(
        titles: {MiniaturePlayerTitle.gm},
        search: 'carl',
      );
      expect(
        query,
        const DesktopMiniaturePlayersQuery(
          titles: {MiniaturePlayerTitle.gm},
          search: 'carl',
        ),
      );
      expect(query.copyWith(search: '').search, '');
    });

    test('leaderboard rows match by FIDE id, then exact name', () {
      final rows = [
        const MiniaturePlayer(
          playerId: 'n',
          name: 'Carlsen, Magnus',
          games: 3,
          wins: 3,
          losses: 0,
        ),
        const MiniaturePlayer(
          playerId: 'f',
          name: 'M. Carlsen',
          games: 9,
          wins: 7,
          losses: 2,
          fideId: 1503014,
        ),
      ];
      expect(
        matchMiniaturePlayerRecord(
          candidates: rows,
          fideId: 1503014,
          name: 'Carlsen, Magnus',
        )?.playerId,
        'f',
      );
      expect(
        matchMiniaturePlayerRecord(
          candidates: rows.take(1).toList(),
          fideId: 1,
          name: 'carlsen, magnus',
        )?.winLossLabel,
        '3W-0L',
      );
    });
  });

  group('local day clock', () {
    test('next local midnight uses calendar arithmetic', () {
      expect(
        desktopNextLocalMidnight(DateTime(2026, 12, 31, 23, 59)),
        DateTime(2027, 1, 1),
      );
      expect(
        desktopNextLocalMidnight(DateTime(2026, 3, 8, 0, 30)),
        DateTime(2026, 3, 9),
      );
      expect(desktopLocalDay(DateTime(2026, 9, 12, 18)), DateTime(2026, 9, 12));
    });

    test('republishes only when the local day changes', () {
      var clock = DateTime(2026, 9, 12, 23, 59);
      final day = DesktopLocalDayClock(
        clock: () => clock,
        listenToLifecycle: false,
      );
      addTearDown(day.dispose);
      final seen = <DateTime>[];
      final remove = day.addListener(seen.add, fireImmediately: false);
      addTearDown(remove);

      day.refresh();
      expect(seen, isEmpty);
      clock = DateTime(2026, 9, 13, 0, 0, 1);
      day.refresh();
      expect(seen, [DateTime(2026, 9, 13)]);
    });
  });
}
