import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/official_team_standings.dart';
import 'package:flutter_test/flutter_test.dart';

Tour event(String source, String url) => Tour.fromJson({
  'id': 'fixture',
  'name': 'Fixture',
  'slug': 'fixture',
  'created_at': '2026-10-14T00:00:00Z',
  'url': '',
  'tier': 1,
  'dates': [],
  'players': [],
  'info': {
    'standings': url,
    'standingsSource': source,
    'standingsUpdatedAt': '2026-10-14T20:45:00Z',
  },
});

Tour pinned(Map<String, dynamic>? pin, {String? standings}) => Tour.fromJson({
  'id': 'fixture',
  'name': 'Fixture',
  'slug': 'fixture',
  'created_at': '2026-10-17T00:00:00Z',
  'url': '',
  'tier': 1,
  'dates': [],
  'players': [],
  'info': {
    'standings':
        standings ??
        'https://www.chessmanager.com/tournaments/5841081857736704',
    'standingsPin': pin,
  },
});

void main() {
  test('a pinned organizer table is published standings for its own link', () {
    const url = 'https://www.chessmanager.com/tournaments/5841081857736704';
    final pin = {
      'url': url,
      'source': 'chessmanager',
      'pinnedAt': '2026-10-17T05:31:13+00:00',
    };
    final tour = pinned(pin);
    expect(tour.info.hasPinnedStandings, isTrue);
    // Forfeits are not games played in the organizer table, so the pin
    // must not depend on the broadcast games agreeing with it.
    expect(tour.usesExternalStandings, isTrue);
    expect(tour.info.toJson()['standingsPin'], pin);

    expect(pinned(null).usesExternalStandings, isFalse);
    expect(
      pinned(
        pin,
        standings: 'https://www.chessmanager.com/tournaments/1',
      ).usesExternalStandings,
      isFalse,
    );
    expect(pinned({'url': url}).usesExternalStandings, isFalse);
    expect(
      pinned({'url': '', 'source': 'chessmanager'}).usesExternalStandings,
      isFalse,
    );
  });

  test(
    'Info64 individual standings are authoritative only for an exact supported source',
    () {
      expect(
        event(
          'info64',
          'https://info64.org/world-g17/standings',
        ).usesExternalStandings,
        isTrue,
      );
      expect(
        event(
          'info64',
          'https://other.test/world-g17/standings',
        ).usesExternalStandings,
        isFalse,
      );
      expect(
        event(
          'info64',
          'https://info64.org/team/world/standings',
        ).usesExternalStandings,
        isFalse,
      );
      expect(
        event(
          'info64',
          'https://info64.org/world/standings?round=1',
        ).usesExternalStandings,
        isFalse,
      );
      expect(
        event(
          'unknown',
          'https://info64.org/world/standings',
        ).usesExternalStandings,
        isFalse,
      );
      expect(
        event(
          'chess-results',
          'https://chess-results.com/tnr123.aspx',
        ).usesExternalStandings,
        isTrue,
      );
    },
  );
  test(
    'Info64 team ranking preserves official values and rejects another event',
    () {
      final snapshot = {
        'source': 'info64',
        'sourceUrl': 'https://info64.org/team/rapid/standings',
        'round': 2,
        'fetchedAt': '2026-10-14T20:45:00Z',
        'teams': [
          {
            'name': 'Alpha',
            'rank': 1,
            'matchPoints': 3,
            'gamePoints': 6.5,
            'matchesPlayed': 2,
            'wins': 1,
            'draws': 1,
            'losses': 0,
            'tiebreaks': [
              {'points': 7.5, 'description': 'BH:MP', 'extendedCode': 'BH:MP'},
            ],
          },
          {
            'name': 'Beta',
            'rank': 2,
            'matchPoints': 1,
            'gamePoints': 1.5,
            'matchesPlayed': 2,
            'wins': 0,
            'draws': 1,
            'losses': 1,
          },
        ],
      };
      final rows = buildOfficialTeamStandings(
        info: TourInfo(
          standings: 'https://info64.org/team/rapid',
          officialTeamStandings: snapshot,
        ),
        players: [],
      );
      expect(rows, isNotNull);
      expect(rows!.first.teamName, 'Alpha');
      expect(rows.first.gamePoints, 6.5);
      expect(rows.first.tiebreaks.single.points, 7.5);
      expect(
        buildOfficialTeamStandings(
          info: TourInfo(
            standings: 'https://info64.org/team/other',
            officialTeamStandings: snapshot,
          ),
          players: [],
        ),
        isNull,
      );
      expect(
        buildOfficialTeamStandings(
          info: TourInfo(
            standings: 'https://chess-results.com/tnr123.aspx',
            officialTeamStandings: snapshot,
          ),
          players: [],
        ),
        isNull,
      );
    },
  );
}
