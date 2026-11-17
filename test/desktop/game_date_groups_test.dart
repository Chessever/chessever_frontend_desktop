import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'smart date groups start with Today, exclude future, and sort by average rating',
    () {
      final now = DateTime(2026, 6, 14, 15);
      final yesterday = DateTime(2026, 6, 13, 12);
      final older = DateTime(2026, 6, 12, 12);
      final tomorrow = DateTime(2026, 6, 15, 12);

      final groups = buildDesktopGameDateGroups(
        [
          _game('older-low', older, 2500, 2500),
          _game('tomorrow', tomorrow, 2800, 2800),
          _game('older-high', older, 2700, 2700),
          _game('yesterday', yesterday, 2600, 2600),
        ],
        now: now,
        includeToday: true,
        excludeFuture: true,
      );

      expect(groups.map((g) => g.label), ['Today', 'Yesterday', '12 Jun 2026']);
      expect(groups.first.games, isEmpty);
      expect(groups[1].games.map((g) => g.gameId), ['yesterday']);
      expect(groups[2].games.map((g) => g.gameId), ['older-high', 'older-low']);
    },
  );

  test('can preserve feed order inside date groups', () {
    final day = DateTime(2026, 6, 12, 12);

    final groups = buildDesktopGameDateGroups([
      _game('low-first', day, 2500, 2500),
      _game('high-second', day, 2700, 2700),
    ], preserveGameOrder: true);

    expect(groups.single.games.map((g) => g.gameId), [
      'low-first',
      'high-second',
    ]);
  });

  test('Live first lifts games in play to the top of today only', () {
    final now = DateTime(2026, 6, 14, 15);
    final today = DateTime(2026, 6, 14, 12);
    final yesterday = DateTime(2026, 6, 13, 12);
    final games = [
      _game('today-finished-high', today, 2800, 2800, GameStatus.whiteWins),
      _game(
        'today-live-low',
        today,
        2400,
        2400,
        GameStatus.ongoing,
        now.subtract(const Duration(minutes: 3)),
      ),
      _game(
        'today-live-mid',
        today,
        2600,
        2600,
        GameStatus.ongoing,
        now.subtract(const Duration(minutes: 1)),
      ),
      _game('today-finished-low', today, 2500, 2500, GameStatus.draw),
      _game('yesterday-high', yesterday, 2750, 2750, GameStatus.blackWins),
      _game('yesterday-low', yesterday, 2450, 2450, GameStatus.whiteWins),
    ];

    List<List<String>> order({required bool liveFirst}) => [
      for (final group in buildDesktopGameDateGroups(
        games,
        now: now,
        liveFirst: liveFirst,
      ))
        [for (final game in group.games) game.gameId],
    ];

    expect(order(liveFirst: false), [
      [
        'today-finished-high',
        'today-live-mid',
        'today-finished-low',
        'today-live-low',
      ],
      ['yesterday-high', 'yesterday-low'],
    ]);
    // Live games lead, each side keeps the rating order, other days stay put.
    expect(order(liveFirst: true), [
      [
        'today-live-mid',
        'today-live-low',
        'today-finished-high',
        'today-finished-low',
      ],
      ['yesterday-high', 'yesterday-low'],
    ]);
  });
}

GamesTourModel _game(
  String id,
  DateTime day,
  int whiteRating,
  int blackRating, [
  GameStatus status = GameStatus.unknown,
  DateTime? lastMoveTime,
]) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: _player('White $id', whiteRating),
    blackPlayer: _player('Black $id', blackRating),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-$id',
    tourId: 'tour-$id',
    gameDay: day,
    lastMoveTime: lastMoveTime,
  );
}

PlayerCard _player(String name, int rating) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: rating,
    countryCode: 'USA',
    team: null,
  );
}
