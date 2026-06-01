import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'game cards use countryCode fallback and keep FIDE IDs for TWIC rows',
    () {
      final game = GamesTourModel(
        gameId: 'twic-1',
        source: GameSource.twic,
        whitePlayer: PlayerCard(
          name: 'White Player',
          federation: '',
          title: 'GM',
          rating: 2500,
          countryCode: 'AZE',
          fideId: 13400000,
          team: null,
        ),
        blackPlayer: PlayerCard(
          name: 'Black Player',
          federation: '',
          title: 'IM',
          rating: 2400,
          countryCode: 'USA',
          fideId: 2010000,
          team: null,
        ),
        whiteTimeDisplay: '--:--',
        blackTimeDisplay: '--:--',
        whiteClockCentiseconds: 0,
        blackClockCentiseconds: 0,
        gameStatus: GameStatus.draw,
        roundId: 'round-1',
        tourId: 'twic-event',
      );

      final card = GameCardData.fromGamesTourModel(game);

      expect(card.whiteFederation, 'AZE');
      expect(card.blackFederation, 'USA');
      expect(card.whiteFideId, 13400000);
      expect(card.blackFideId, 2010000);
    },
  );

  test('board rail summaries preserve FIDE IDs and countryCode fallback', () {
    final game = GamesTourModel(
      gameId: 'twic-2',
      source: GameSource.twic,
      whitePlayer: PlayerCard(
        name: 'White Player',
        federation: '',
        title: '',
        rating: 2300,
        countryCode: 'IND',
        fideId: 5000000,
        team: null,
      ),
      blackPlayer: PlayerCard(
        name: 'Black Player',
        federation: '',
        title: '',
        rating: 2200,
        countryCode: 'ESP',
        fideId: 2200000,
        team: null,
      ),
      whiteTimeDisplay: '--:--',
      blackTimeDisplay: '--:--',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.whiteWins,
      roundId: 'round-1',
      tourId: 'twic-event',
    );

    final summary = TournamentGameSummary.fromGamesTourModel(game);

    expect(summary.whiteFederation, 'IND');
    expect(summary.blackFederation, 'ESP');
    expect(summary.whiteFideId, 5000000);
    expect(summary.blackFideId, 2200000);
  });

  test('Gamebase position rows carry FIDE IDs for backfilled rail flags', () {
    final summary = gamebasePositionGameSummaryFromRow({
      'id': 'gamebase-1',
      'white': 'White Player',
      'black': 'Black Player',
      'whiteFed': '',
      'blackFed': '',
      'whiteFideId': '13400000',
      'blackFideId': 2010000,
      'whiteElo': 2500,
      'blackElo': 2400,
      'result': '1/2-1/2',
    }, fallbackFen: 'start-fen');

    expect(summary.whiteFideId, 13400000);
    expect(summary.blackFideId, 2010000);
    expect(summary.whiteFederation, isEmpty);
    expect(summary.blackFederation, isEmpty);
  });
}
