import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  test('live-only countrymen filter hides finished games only', () {
    final state = CountrymenCombinedGamesState(
      liveOnly: true,
      games: [
        _game('finished', GameStatus.draw),
        _game('unknown', GameStatus.unknown),
        _game('live', GameStatus.ongoing),
      ],
    );

    expect(state.filteredGames.map((game) => game.gameId), ['unknown', 'live']);
  });
}

GamesTourModel _game(String id, GameStatus status) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: PlayerCard(
      name: 'White $id',
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: 'Black $id',
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
    ),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
  );
}
