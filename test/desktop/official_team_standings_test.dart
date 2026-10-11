import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/official_team_standings.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _link = 'https://s1.chess-results.com/tnr1508653.aspx?art=1';
const _source =
    'https://s1.chess-results.com/tnr1508653.aspx?lan=1&art=0&flag=NO&zeilen=99999';

Map<String, dynamic> _team(
  String name,
  int rank, {
  required int mp,
  required num gp,
  int played = 4,
  int wins = 0,
  int draws = 0,
  int losses = 0,
}) => {
  'name': name,
  'rank': rank,
  'matchPoints': mp,
  'gamePoints': gp,
  'matchesPlayed': played,
  'wins': wins,
  'draws': draws,
  'losses': losses,
};

TourInfo _info({
  List<Map<String, dynamic>>? teams,
  Map<String, dynamic>? scoring,
  String sourceUrl = _source,
  int round = 4,
}) => TourInfo.fromJson({
  'standings': _link,
  'officialTeamStandings': {
    'source': 'chess-results',
    'sourceUrl': sourceUrl,
    'round': round,
    'fetchedAt': '2026-10-12T00:00:00Z',
    if (scoring != null) 'matchScoring': scoring,
    'teams':
        teams ??
        [
          // The organizer ranks on game points: the leader has fewer match
          // points than the team below it.
          _team('Gerunda A', 1, mp: 7, gp: 12.5, wins: 3, draws: 1),
          _team('Tres Peons A', 2, mp: 8, gp: 12, wins: 4),
          _team('Gerunda B', 3, mp: 6, gp: 11.5, wins: 3, losses: 1),
        ],
  },
});

PlayerStandingModel _player(String name, String team) => PlayerStandingModel(
  countryCode: 'ESP',
  name: name,
  score: 0,
  scoreChange: 0,
  matchScore: '3 / 4',
  team: team,
);

void main() {
  test('official table keeps the organizer order and totals', () {
    final rows = buildOfficialTeamStandings(
      info: _info(),
      players: [_player('Cid Marcos, Laia', 'gerunda a')],
    );

    expect(rows!.map((t) => t.teamName), [
      'Gerunda A',
      'Tres Peons A',
      'Gerunda B',
    ]);
    expect(rows.map((t) => t.rank), [1, 2, 3]);
    expect(rows.map((t) => t.matchPoints), [7, 8, 6]);
    expect(rows.first.gamePoints, 12.5);
    expect(rows.first.recordLabel, '3 · 1 · 0');
    expect(rows.first.officialRound, 4);
    expect(rows.first.players.single.name, 'Cid Marcos, Laia');
    expect(rows[1].players, isEmpty);
  });

  test('tied ranks are kept as published', () {
    final rows = buildOfficialTeamStandings(
      info: _info(
        teams: [
          _team('A', 1, mp: 6, gp: 10, wins: 3, losses: 1),
          _team('B', 1, mp: 6, gp: 10, wins: 3, losses: 1),
          _team('C', 3, mp: 2, gp: 5, wins: 1, losses: 3),
        ],
      ),
      players: const [],
    );
    expect(rows!.map((t) => t.rank), [1, 1, 3]);
  });

  test('three-one-zero match points are accepted when published', () {
    final teams = [
      _team('Čast i slava', 1, mp: 21, gp: 25, played: 8, wins: 7, losses: 1),
      _team('Sirmium', 2, mp: 16, gp: 18.5, played: 8, wins: 5, draws: 1, losses: 2),
    ];
    expect(
      buildOfficialTeamStandings(
        info: _info(teams: teams, round: 8),
        players: const [],
      ),
      isNull,
      reason: '21 match points cannot come from eight 2-1-0 matches',
    );
    final rows = buildOfficialTeamStandings(
      info: _info(
        teams: teams,
        round: 8,
        scoring: {'win': 3, 'draw': 1, 'loss': 0},
      ),
      players: const [],
    );
    expect(rows!.first.matchPoints, 21);
  });

  test('snapshot for another event or a damaged table is ignored', () {
    expect(
      buildOfficialTeamStandings(
        info: _info(
          sourceUrl:
              'https://s1.chess-results.com/tnr999.aspx?lan=1&art=0&flag=NO',
        ),
        players: const [],
      ),
      isNull,
    );
    expect(
      buildOfficialTeamStandings(
        info: _info(
          teams: [
            _team('A', 1, mp: 6, gp: 10, wins: 3, losses: 1),
            _team('B', 3, mp: 2, gp: 5, wins: 1, losses: 3),
          ],
        ),
        players: const [],
      ),
      isNull,
      reason: 'rank 2 is missing',
    );
    expect(
      buildOfficialTeamStandings(
        info: _info(
          teams: [
            _team('A', 1, mp: 6, gp: 10, wins: 3, losses: 2),
            _team('B', 2, mp: 2, gp: 5, wins: 1, losses: 3),
          ],
        ),
        players: const [],
      ),
      isNull,
      reason: 'matches played must equal wins + draws + losses',
    );
    expect(
      buildOfficialTeamStandings(
        info: TourInfo.fromJson({'standings': _link}),
        players: const [],
      ),
      isNull,
    );
  });
}
