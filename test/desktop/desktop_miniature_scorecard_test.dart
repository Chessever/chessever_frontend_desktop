import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/miniatures/desktop_miniature_players_view.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

PlayerCard _player(String name, {String? id}) => PlayerCard(
  name: name,
  federation: '',
  title: '',
  rating: 0,
  countryCode: '',
  team: null,
  gamebasePlayerId: id,
);

GamesTourModel _game(
  GameStatus status, {
  String white = 'So, Wesley',
  String black = 'Carlsen, Magnus',
  String? whiteId = 'p-so',
  String? blackId = 'p-carlsen',
}) => GamesTourModel(
  gameId: 'g-1',
  whitePlayer: _player(white, id: whiteId),
  blackPlayer: _player(black, id: blackId),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: status,
  roundId: 'gamebase-miniatures',
  tourId: '',
);

void main() {
  group('miniature scorecard outcome is the scorecard player\'s', () {
    test('a win as Black is a win, a loss as White is a loss', () {
      expect(
        miniatureScorecardPlayerWon(
          _game(GameStatus.blackWins),
          playerId: 'p-carlsen',
          playerName: 'Carlsen, Magnus',
        ),
        isTrue,
      );
      expect(
        miniatureScorecardPlayerWon(
          _game(GameStatus.blackWins),
          playerId: 'p-so',
          playerName: 'So, Wesley',
        ),
        isFalse,
      );
    });

    test('the side falls back to the name when ids are missing', () {
      final game = _game(GameStatus.whiteWins, whiteId: null, blackId: null);
      expect(
        miniatureScorecardPlayerWon(
          game,
          playerId: 'p-carlsen',
          playerName: 'carlsen, magnus',
        ),
        isFalse,
      );
    });

    test('an unknown side or a draw has no outcome', () {
      expect(
        miniatureScorecardPlayerWon(
          _game(GameStatus.whiteWins, whiteId: null, blackId: null),
          playerId: 'p-nobody',
          playerName: 'Nobody, Else',
        ),
        isNull,
      );
      expect(
        miniatureScorecardPlayerWon(
          _game(GameStatus.draw),
          playerId: 'p-carlsen',
          playerName: 'Carlsen, Magnus',
        ),
        isNull,
      );
    });
  });
}
