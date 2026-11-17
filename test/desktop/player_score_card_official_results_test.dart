import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/player_score_card_results.dart';
import 'package:chessever/services/official_round_results.dart';

void main() {
  test(
    'event scorecard includes an official outcome without inventing a game',
    () {
      final entries = buildPlayerScoreCardResults(
        playerName: 'Player',
        playerFideId: 1,
        games: [],
        officialResults: [
          OfficialRoundResults(
            roundId: 'real-round',
            roundName: 'Round 2',
            roundNumber: 2,
            tourId: 'event',
            results: [
              const OfficialRoundResult(
                playerName: 'Player',
                playerFideId: '1',
                roundId: 'real-round',
                roundName: 'Round 2',
                roundNumber: 2,
                tourId: 'event',
                color: 'black',
                points: .5,
                opponentName: 'Opponent',
                opponentRating: 1700,
              ),
            ],
          ),
        ],
      );
      expect(entries.single.game, isNull);
      expect(entries.single.points, .5);
      expect(entries.single.opponent.name, 'Opponent');
      expect(entries.single.roundLabel, 'R2');
    },
  );
  test(
    'real board and its result win while verified NP enriches rating eligibility',
    () {
      final game = _game('real', 'round-2');
      final rows = buildPlayerScoreCardResults(
        playerName: 'Player',
        playerFideId: 1,
        games: [game],
        officialResults: [_round(nonPlayed: true)],
      );
      expect(rows, hasLength(1));
      expect(rows.single.game, same(game));
      expect(rows.single.points, 1);
      expect(rows.single.nonPlayed, isTrue);
      expect(
        calculateScorecardMetrics(
          playerRating: 1800,
          kFactor: 40,
          games: rows.map((r) => r.metricGame),
        ).ratingChange,
        isNull,
      );
    },
  );
  test('ambiguous recorded boards block a synthetic result fallback', () {
    final rows = buildPlayerScoreCardResults(
      playerName: 'Player',
      playerFideId: 1,
      games: [_game('real-a', 'round-2'), _game('real-b', 'round-2')],
      officialResults: [_round()],
    );
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.game != null), isTrue);
  });
  test('duplicate official round entries fail closed', () {
    final rows = buildPlayerScoreCardResults(
      playerName: 'Player',
      playerFideId: 1,
      games: [],
      officialResults: [_round(), _round()],
    );
    expect(rows, isEmpty);
  });
  test(
    'history retains caller order instead of adopting event round order',
    () {
      final rows = buildPlayerScoreCardResults(
        playerName: 'Player',
        playerFideId: 1,
        games: [_game('newer', 'round-8'), _game('older', 'round-1')],
        sortByRound: false,
      );
      expect(rows.map((row) => row.game!.gameId), ['newer', 'older']);
    },
  );
}

OfficialRoundResults _round({bool nonPlayed = false}) => OfficialRoundResults(
  roundId: 'round-2',
  roundName: 'Round 2',
  roundNumber: 2,
  tourId: 'event',
  results: [
    OfficialRoundResult(
      playerName: 'Player',
      playerFideId: '1',
      roundId: 'round-2',
      roundName: 'Round 2',
      roundNumber: 2,
      tourId: 'event',
      points: 0,
      opponentName: 'Opponent',
      opponentFideId: '2',
      opponentRating: 1700,
      nonPlayed: nonPlayed,
    ),
  ],
);
GamesTourModel _game(String id, String round) {
  PlayerCard player(String name, int fide) => PlayerCard(
    name: name,
    fideId: fide,
    rating: 1800,
    countryCode: '',
    federation: '',
    title: '',
    team: null,
  );
  return GamesTourModel(
    gameId: id,
    whitePlayer: player('Player', 1),
    blackPlayer: player('Opponent', 2),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.whiteWins,
    roundId: round,
    roundSlug: round,
    tourId: 'event',
  );
}
