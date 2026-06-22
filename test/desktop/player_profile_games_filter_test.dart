import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TWIC player profile game-result chips filter loaded rows locally', () {
    const key = PlayerProfileKey(
      fideId: 1503014,
      playerName: 'Carlsen, Magnus',
      source: PlayerProfileDataSource.twic,
      gamebasePlayerId: 'player-1',
    );

    final state = PlayerProfileGamesState(
      playerKey: key,
      allGames: [
        _game('white-win', GameStatus.whiteWins),
        _game('draw', GameStatus.draw),
        _game('black-win', GameStatus.blackWins),
      ],
      filter: GameFilter(result: GameResultFilter.draw),
    );

    expect(state.filteredGames.map((g) => g.gameId), ['draw']);
  });

  test('game-result filter accepts all draw result formats', () {
    expect(GameStatus.fromString('1/2-1/2'), GameStatus.draw);
    expect(GameStatus.fromString('½-½'), GameStatus.draw);
    expect(GameStatus.fromString('0.5-0.5'), GameStatus.draw);
    expect(
      GameResultFilter.draw.matches(GameStatus.fromString('1/2-1/2')),
      true,
    );
  });
}

GamesTourModel _game(String id, GameStatus status) {
  return GamesTourModel(
    gameId: id,
    source: GameSource.twic,
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'event-1',
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
