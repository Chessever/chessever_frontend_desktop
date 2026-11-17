import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/tournament_standings_view.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/services/official_round_results.dart';

void main() {
  test('verified result fills a missing standings round without a game', () {
    const player = PlayerStandingModel(
      countryCode: 'MGL',
      name: 'Player',
      score: 1646,
      scoreChange: 0,
      matchScore: '1 / 1',
      fideId: 1,
    );
    const opponent = PlayerStandingModel(
      countryCode: 'MAS',
      title: 'FM',
      name: 'Opponent',
      score: 1700,
      scoreChange: 0,
      matchScore: '0 / 1',
      fideId: 2,
      overallRank: 15,
    );
    final table = buildTournamentStandingsRoundTable(
      standings: [player, opponent],
      games: [],
      officialResults: [
        OfficialRoundResults(
          roundId: 'actual-round',
          roundName: 'Round 1',
          roundNumber: 1,
          tourId: 'event',
          results: [
            const OfficialRoundResult(
              playerName: 'Player',
              playerFideId: '1',
              roundId: 'actual-round',
              roundName: 'Round 1',
              roundNumber: 1,
              tourId: 'event',
              color: 'white',
              points: 1,
              opponentName: 'Opponent',
              opponentFideId: '2',
              opponentRating: 1700,
            ),
          ],
        ),
      ],
    );
    final cell = table.cellsFor(player).single;
    expect(cell.recordedGame, isNull);
    expect(cell.resultText, '1');
    expect(cell.opponentRank, 15);
    expect(cell.opponentTitle, 'FM');
    expect(cell.opponentFed, 'MAS');
  });
}
