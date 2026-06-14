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

      expect(groups.map((g) => g.label), [
        'Today',
        'Yesterday',
        'Jun 12, 2026',
      ]);
      expect(groups.first.games, isEmpty);
      expect(groups[1].games.map((g) => g.gameId), ['yesterday']);
      expect(groups[2].games.map((g) => g.gameId), ['older-high', 'older-low']);
    },
  );
}

GamesTourModel _game(
  String id,
  DateTime day,
  int whiteRating,
  int blackRating,
) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: _player('White $id', whiteRating),
    blackPlayer: _player('Black $id', blackRating),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.unknown,
    roundId: 'round-$id',
    tourId: 'tour-$id',
    gameDay: day,
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
