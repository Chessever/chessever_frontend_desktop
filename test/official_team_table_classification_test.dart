import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/official_team_standings.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_tournament_state_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Russian Rapid Teams-shaped tour: Swiss format, no teamTable flag and no
/// team labels anywhere in the feed; only the organizer's team table says so.
TourInfo _infoWithOfficialTeams({String sourceTnr = '1494553'}) =>
    TourInfo.fromJson({
      'format': '9-round Swiss',
      'standings':
          'https://s1.chess-results.com/tnr1494553.aspx?lan=11&art=0&turdet=YES&SNode=S0',
      'officialTeamStandings': {
        'source': 'chess-results',
        'sourceUrl':
            'https://s1.chess-results.com/tnr$sourceTnr.aspx?lan=1&art=0&flag=NO&zeilen=99999',
        'round': 4,
        'fetchedAt': '2026-10-17T16:30:00+00:00',
        'matchScoring': {'win': 2, 'draw': 1, 'loss': 0},
        'teams': [
          for (final (i, name) in [
            'Свердловская область',
            'Саратов',
            'Северная корона',
          ].indexed)
            {
              'name': name,
              'rank': i == 2 ? 2 : i + 1,
              'matchPoints': 8 - 2 * i,
              'gamePoints': 10.5 - i,
              'matchesPlayed': 4,
              'wins': 4 - i,
              'draws': 0,
              'losses': i,
            },
        ],
      },
    });

bool _classify(TourInfo info, {bool? teamTable}) =>
    resolveTeamEventClassification(
      teamTable: teamTable,
      formatSaysTeam: false,
      formatSaysPlayer: false,
      allPlayersHaveTeam: false,
      hasOfficialTeamTable:
          buildOfficialTeamStandings(
            info: info,
            players: const <PlayerStandingModel>[],
          ) !=
          null,
    );

void main() {
  test('a valid organizer team table makes an unlabeled Swiss feed a team event', () {
    expect(_classify(_infoWithOfficialTeams()), isTrue);
    // Lichess' own leaderboard switch does not veto the organizer table.
    expect(_classify(_infoWithOfficialTeams(), teamTable: false), isTrue);
  });

  test('a snapshot of another event, or none, proves nothing', () {
    expect(_classify(_infoWithOfficialTeams(sourceTnr: '1494537')), isFalse);
    expect(_classify(TourInfo.fromJson({'format': '9-round Swiss'})), isFalse);
  });
}
