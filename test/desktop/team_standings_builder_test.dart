import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/team_standings_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/team_tour/team_tour_screen_provider.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:flutter_test/flutter_test.dart';

var _gameSeq = 0;

PlayerCard _card(String name, String team) => PlayerCard(
  name: name,
  federation: 'NOR',
  title: 'GM',
  rating: 2600,
  countryCode: 'NOR',
  team: team,
);

GamesTourModel _game({
  required String round,
  required String white,
  required String whiteTeam,
  required String black,
  required String blackTeam,
  required GameStatus status,
  int? board,
}) {
  return GamesTourModel(
    gameId: 'g${_gameSeq++}',
    whitePlayer: _card(white, whiteTeam),
    blackPlayer: _card(black, blackTeam),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: round,
    roundSlug: round,
    tourId: 'tour-1',
    boardNr: board,
  );
}

/// Two-board match in [round] between [a] and [b].
List<GamesTourModel> _match(
  String round,
  String a,
  String b,
  GameStatus board1,
  GameStatus board2,
) => [
  _game(
    round: round,
    white: '$a 1',
    whiteTeam: a,
    black: '$b 1',
    blackTeam: b,
    status: board1,
    board: 1,
  ),
  _game(
    round: round,
    white: '$b 2',
    whiteTeam: b,
    black: '$a 2',
    blackTeam: a,
    status: board2,
    board: 2,
  ),
];

TeamStandingModel _row(List<TeamStandingModel> rows, String name) =>
    rows.singleWhere((row) => row.teamName == name);

void main() {
  test('match points only for completed matches', () {
    final rows = buildTeamStandings(
      games: [
        // Round 1 finished: Alpha wins board 1 and draws board 2.
        ..._match('round-1', 'Alpha', 'Bravo', GameStatus.whiteWins, GameStatus.draw),
        // Round 2 still running: Alpha leads on board 1, board 2 ongoing.
        ..._match('round-2', 'Alpha', 'Charlie', GameStatus.whiteWins, GameStatus.ongoing),
      ],
      playerStandings: const [],
    );

    final alpha = _row(rows, 'Alpha');
    expect(alpha.matchPoints, 2, reason: 'only round 1 is complete');
    expect(alpha.gamePoints, 1.5 + 1, reason: 'finished boards still count');
    expect(alpha.boardsPlayed, 3);
    expect((alpha.matchesWon, alpha.matchesDrawn, alpha.matchesLost), (1, 0, 0));

    final charlie = _row(rows, 'Charlie');
    expect(charlie.matchPoints, 0);
    expect((charlie.matchesWon, charlie.matchesDrawn, charlie.matchesLost), (0, 0, 0));

    final round2 = buildTeamMatches(
      games: _match('round-2', 'Alpha', 'Charlie', GameStatus.whiteWins, GameStatus.ongoing),
      teamName: 'Alpha',
    ).single;
    expect(round2.complete, isFalse);
    expect(round2.result, TeamMatchResult.ongoing);
    expect(round2.matchPoints, 0);
  });

  test('rank tiebreak is match points, then board points, then name', () {
    final rows = buildTeamStandings(
      games: [
        // Delta and Echo both win their match (2 MP each); Delta by more.
        ..._match('round-1', 'Delta', 'Foxtrot', GameStatus.whiteWins, GameStatus.blackWins),
        ..._match('round-1', 'Echo', 'Golf', GameStatus.whiteWins, GameStatus.draw),
        // Bravo and Alpha draw each other: equal MP and equal GP.
        ..._match('round-1', 'Bravo', 'Alpha', GameStatus.draw, GameStatus.draw),
      ],
      playerStandings: const [],
    );

    expect(rows.map((row) => row.teamName).toList(), [
      'Delta', // 2 MP, 2 GP
      'Echo', // 2 MP, 1.5 GP
      'Alpha', // 1 MP, 1 GP, name before Bravo
      'Bravo', // 1 MP, 1 GP
      'Golf', // 0 MP, 0.5 GP
      'Foxtrot', // 0 MP, 0 GP
    ]);
    expect(rows.map((row) => row.rank).toList(), [1, 2, 3, 4, 5, 6]);
  });

  test('byes are not credited', () {
    const rosterOnly = PlayerStandingModel(
      countryCode: 'NOR',
      name: 'Hotel 1',
      score: 2500,
      scoreChange: 0,
      matchScore: null,
      team: 'Hotel',
    );
    final rows = buildTeamStandings(
      games: [
        // Hotel sits out round 1; Alpha beats Bravo.
        ..._match('round-1', 'Alpha', 'Bravo', GameStatus.whiteWins, GameStatus.blackWins),
      ],
      playerStandings: const [rosterOnly],
    );

    final hotel = _row(rows, 'Hotel');
    expect(hotel.matchPoints, 0);
    expect(hotel.gamePoints, 0);
    expect(hotel.boardsPlayed, 0);
    expect(hotel.players.single.name, 'Hotel 1');
    expect(buildTeamMatches(games: const [], teamName: 'Hotel'), isEmpty);
  });

  test('a match is keyed by round and the unordered team pair', () {
    final games = [
      ..._match('round-1', 'Alpha', 'Bravo', GameStatus.whiteWins, GameStatus.whiteWins),
      ..._match('round-3', 'Bravo', 'Alpha', GameStatus.draw, GameStatus.draw),
    ];
    final matches = buildTeamMatches(games: games, teamName: 'Alpha');
    expect(matches.map((m) => m.roundId).toList(), ['round-3', 'round-1']);
    expect(matches.every((m) => m.opponentTeam == 'Bravo'), isTrue);
    expect(matches.last.boardGames.map((b) => b.boardNr).toList(), [1, 2]);

    final rows = buildTeamStandings(games: games, playerStandings: const []);
    final alpha = _row(rows, 'Alpha');
    expect(rows.map((row) => row.teamName).toSet(), {'Alpha', 'Bravo'});
    expect((alpha.matchesWon, alpha.matchesDrawn, alpha.matchesLost), (0, 2, 0),
        reason: 'round 1 is a 1-1 split and round 3 is a 1-1 draw: two '
            'separate matches, not one merged pairing');
    expect(alpha.matchPoints, 2);
  });

  test('a placeholder selection resolves to the computed standing', () {
    final rows = buildTeamStandings(
      games: _match('round-1', 'Alpha', 'Bravo', GameStatus.whiteWins, GameStatus.draw),
      playerStandings: const [],
    );
    const placeholder = TeamStandingModel(
      teamName: ' alpha ',
      rank: 0,
      matchPoints: 0,
      gamePoints: 0,
      matchesWon: 0,
      matchesDrawn: 0,
      matchesLost: 0,
      boardsPlayed: 0,
      players: [],
    );
    final resolved = resolveSelectedTeamStanding(
      selected: placeholder,
      standings: rows,
    );
    expect(resolved!.teamName, 'Alpha');
    expect(resolved.matchPoints, 2);
    expect(
      resolveSelectedTeamStanding(selected: placeholder, standings: null),
      same(placeholder),
    );
  });
}
