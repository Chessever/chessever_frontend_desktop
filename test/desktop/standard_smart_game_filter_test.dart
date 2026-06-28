import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shared finish filter keeps games ending inside the selected move cap',
    () {
      final short = _game(
        'short',
        pgn: '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 15. Qxf7# 1-0',
      );
      final long = _game(
        'long',
        pgn: '[Result "1-0"]\n\n1. d4 Nf6 20. Rc1 c6 26. Qb3 1-0',
      );

      final filtered = GameFilterHelper.applyFilter([
        short,
        long,
      ], GameFilter(finish: GameFinishFilter.byMove20));

      expect(filtered.map((game) => game.gameId), ['short']);
    },
  );

  test('premium games filter tracks standard smart-game fields', () {
    const filter = PremiumGamesFilter(
      timeControl: GameTimeControlFilter.classical,
      eco: GameEcoFilter(code: 'B'),
      finish: GameFinishFilter.byMove25,
      minElo: 2500,
    );

    expect(filter.hasActiveFilters, isTrue);

    final copied = filter.copyWith(
      timeControl: GameTimeControlFilter.rapid,
      finish: GameFinishFilter.byMove15,
      clearElo: true,
    );

    expect(copied.timeControl, GameTimeControlFilter.rapid);
    expect(copied.eco, const GameEcoFilter(code: 'B'));
    expect(copied.finish, GameFinishFilter.byMove15);
    expect(copied.minElo, isNull);
  });
}

GamesTourModel _game(String id, {String? pgn}) {
  return GamesTourModel(
    gameId: id,
    source: GameSource.twic,
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.whiteWins,
    roundId: 'round-1',
    tourId: 'event-1',
    pgn: pgn,
    lastMoveTime: DateTime.utc(2026),
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 2700,
    countryCode: '',
    team: null,
  );
}
