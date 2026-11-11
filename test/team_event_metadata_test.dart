import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_tournament_state_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TourInfo round-trips the authoritative Lichess team marker', () {
    final info = TourInfo.fromJson(const {
      'format': '7-round Swiss',
      'teamTable': true,
    });

    expect(info.teamTable, isTrue);
    expect(info.toJson()['teamTable'], isTrue);
  });

  test('authoritative team marker identifies a Swiss team event', () {
    expect(
      resolveTeamEventClassification(
        teamTable: true,
        formatSaysTeam: false,
        formatSaysPlayer: false,
        allPlayersHaveTeam: false,
      ),
      isTrue,
    );
  });

  test('authoritative false overrides heuristic team evidence', () {
    expect(
      resolveTeamEventClassification(
        teamTable: false,
        formatSaysTeam: true,
        formatSaysPlayer: false,
        allPlayersHaveTeam: true,
      ),
      isFalse,
    );
  });

  test('legacy rows still use bounded format and player heuristics', () {
    expect(
      resolveTeamEventClassification(
        teamTable: null,
        formatSaysTeam: false,
        formatSaysPlayer: false,
        allPlayersHaveTeam: true,
      ),
      isTrue,
    );
  });

  GamesTourModel board(String id, String? whiteTeam, String? blackTeam) {
    PlayerCard player(String name, String? team) => PlayerCard(
      name: name,
      federation: '',
      title: '',
      rating: 2700,
      countryCode: '',
      team: team,
    );
    return GamesTourModel(
      gameId: id,
      whitePlayer: player('$id-w', whiteTeam),
      blackPlayer: player('$id-b', blackTeam),
      whiteTimeDisplay: '',
      blackTimeDisplay: '',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.ongoing,
      roundId: 'r1',
      tourId: 't1',
    );
  }

  group('gamesOnlyPairTeammates', () {
    test('a Combined section pairs only group mates', () {
      expect(
        gamesOnlyPairTeammates([
          board('g1', 'Group A', 'Group A'),
          board('g2', 'Group B', 'Group B'),
        ]),
        isTrue,
      );
    });

    test('one board between two teams clears it', () {
      expect(
        gamesOnlyPairTeammates([
          board('g1', 'Group A', 'Group A'),
          board('g2', 'Team X', 'Team Y'),
        ]),
        isFalse,
      );
    });

    test('untagged games and a single board are not evidence', () {
      expect(gamesOnlyPairTeammates([board('g1', 'A', 'A')]), isFalse);
      expect(
        gamesOnlyPairTeammates([board('g1', null, null), board('g2', '', '')]),
        isFalse,
      );
    });
  });

  test('games pairing only teammates override teamTable and format', () {
    expect(
      resolveTeamEventClassification(
        teamTable: true,
        formatSaysTeam: true,
        formatSaysPlayer: false,
        allPlayersHaveTeam: true,
        gamesOnlyPairTeammates: true,
      ),
      isFalse,
    );
  });

  test(
    'an official team table yields to the same evidence (mobile parity)',
    () {
      expect(
        resolveTeamEventClassification(
          teamTable: null,
          formatSaysTeam: false,
          formatSaysPlayer: false,
          allPlayersHaveTeam: false,
          hasOfficialTeamTable: true,
          gamesOnlyPairTeammates: true,
        ),
        isFalse,
      );
    },
  );

  test('Tour reads is_mirror and defaults it to false', () {
    Map<String, dynamic> row({Object? isMirror, Map<String, dynamic>? info}) =>
        {
          'id': 'wLrwkC0C',
          'name': 'Group Stage | Combined',
          'slug': 'group-stage--combined',
          'info': info ?? <String, dynamic>{},
          'created_at': '2026-11-01T00:00:00Z',
          'url': 'https://lichess.org/broadcast/x/wLrwkC0C',
          'tier': 0,
          'dates': <String>[],
          'players': <dynamic>[],
          if (isMirror != null) 'is_mirror': isMirror,
        };

    expect(Tour.fromJson(row()).isMirror, isFalse);
    expect(Tour.fromJson(row(isMirror: true)).isMirror, isTrue);
    expect(Tour.fromJson(row(info: {'mirror': true})).isMirror, isTrue);
    expect(Tour.fromJson(row(isMirror: true)).toJson()['is_mirror'], isTrue);
  });
}
