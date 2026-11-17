import 'package:chessever/services/official_round_results.dart';
import 'package:flutter_test/flutter_test.dart';

// Deliberately synthetic fixtures; these are not saved production data.
Map<String, dynamic> tourFixture() => {
  'id': 'section-a',
  'info': {'standings': 'https://chess-results.com/tnr123.aspx?lan=1'},
  'players': [
    {'name': 'Alice, Example', 'fideId': 1001, 'startNumber': 1},
    {
      'name': 'Béla Example',
      'fideId': 1002,
      'startNumber': 2,
      'title': 'IM',
      'fed': 'HUN',
      'rank': 7,
    },
  ],
};
Map<String, dynamic> roundFixture({String result = '1-0'}) => {
  'id': 'r1',
  'tour_id': 'section-a',
  'name': 'First round',
  'slug': 'section-a-round-1',
  'pairings': {
    'format': 'individual',
    'sourceUrl': 'https://s1.chess-results.com/tnr123.aspx',
    'round_number': 1,
    'pairings': [
      <String, dynamic>{
        'white': {
          'name': 'Alice Example',
          'no': 1,
          'fideId': 1001,
          'rating': 2100,
        },
        'black': {
          'name': 'Béla Example',
          'no': 2,
          'fideId': 1002,
          'rating': 2200,
        },
        'result': result,
      },
    ],
  },
};
void main() {
  test(
    'round boundaries and optional numeric identity metadata fail closed',
    () {
      final wrongTour = roundFixture()..['tour_id'] = 'section-b';
      expect(
        normalizeOfficialRoundResults(tourFixture(), [wrongTour]),
        isEmpty,
      );
      final zero = roundFixture()..['slug'] = 'round-0';
      (zero['pairings'] as Map)['round_number'] = 0;
      expect(normalizeOfficialRoundResults(tourFixture(), [zero]), isEmpty);
      final emptyId = roundFixture()..['id'] = '';
      expect(normalizeOfficialRoundResults(tourFixture(), [emptyId]), isEmpty);
      final invalidRoster = tourFixture();
      ((invalidRoster['players'] as List).first as Map)['startNumber'] =
          'invalid';
      final invalid = roundFixture();
      (((invalid['pairings'] as Map)['pairings'] as List).first['white']
              as Map)['no'] =
          'bad';
      expect(normalizeOfficialRoundResults(invalidRoster, [invalid]), isEmpty);
    },
  );
  test('combining marks do not silently merge distinct Unicode names', () {
    final t = tourFixture();
    ((t['players'] as List).first as Map)['name'] = 'Jose\u0301';
    final r = roundFixture();
    final p = ((r['pairings'] as Map)['pairings'] as List).first as Map;
    p['white'] = {'name': 'Jose', 'fideId': 1001};
    expect(normalizeOfficialRoundResults(t, [r]), isEmpty);
    p['white'] = {'name': 'Jose\u0301', 'fideId': 1001};
    expect(normalizeOfficialRoundResults(t, [r]), hasLength(1));
  });
  test(
    'malformed optional opponent metadata is ignored without losing verified scores',
    () {
      final t = tourFixture();
      final b = (t['players'] as List).last as Map;
      b['rank'] = 'invalid';
      b['title'] = 42;
      b['fed'] = [];
      final r = roundFixture();
      final pair = ((r['pairings'] as Map)['pairings'] as List).first as Map;
      (pair['black'] as Map)['rating'] = 'unknown';
      final result = normalizeOfficialRoundResults(t, [r]).single.results.first;
      expect(result.opponentRating, isNull);
      expect(result.opponentRank, isNull);
      expect(result.opponentTitle, isNull);
      expect(result.opponentFed, isNull);
      expect(result.points, 1);
    },
  );
  test(
    'player lookup uses positive FIDE first and otherwise exact Unicode names',
    () {
      final rounds = normalizeOfficialRoundResults(tourFixture(), [
        roundFixture(),
      ]);
      expect(
        findOfficialRoundResult(
          rounds,
          playerName: 'renamed',
          playerFideId: 1001,
          roundId: 'r1',
        )?.points,
        1,
      );
      expect(
        findOfficialRoundResult(
          rounds,
          playerName: 'Alice Example',
          playerFideId: 9999,
        ),
        isNull,
      );
      expect(
        findOfficialRoundResult(
          rounds,
          playerName: 'Alice Example',
          playerFideId: 0,
        )?.points,
        1,
      );
      expect(
        findOfficialRoundResult(rounds, playerName: 'Bela Example'),
        isNull,
      );
      expect(
        findOfficialRoundResult(rounds, playerName: 'BÉLA EXAMPLE')?.points,
        0,
      );
      expect(
        findOfficialRoundResult([
          ...rounds,
          ...rounds,
        ], playerName: 'Alice Example'),
        isNull,
      );
      expect(
        findOfficialRoundResult(
          rounds,
          playerName: 'Alice Example',
          roundId: 'r2',
        ),
        isNull,
      );
      final unicode = tourFixture();
      ((unicode['players'] as List).first as Map)['name'] = '李四';
      final round = roundFixture();
      (((round['pairings'] as Map)['pairings'] as List).first
          as Map)['white'] = {'name': '李四', 'fideId': 1001};
      final parsed = normalizeOfficialRoundResults(unicode, [round]);
      expect(findOfficialRoundResult(parsed, playerName: '李四')?.points, 1);
      expect(findOfficialRoundResult(parsed, playerName: '王五'), isNull);
    },
  );
  test(
    'duplicate participants invalidate the whole round including unfinished duplicates',
    () {
      for (final duplicateResult in ['1-0', '*']) {
        final r = roundFixture();
        final pairs = (r['pairings'] as Map)['pairings'] as List;
        pairs.add(
          (((roundFixture(result: duplicateResult)['pairings'])
                      as Map)['pairings']
                  as List)
              .first,
        );
        expect(normalizeOfficialRoundResults(tourFixture(), [r]), isEmpty);
      }
      expect(
        normalizeOfficialRoundResults(tourFixture(), [
          roundFixture(),
          roundFixture(),
        ]),
        isEmpty,
      );
    },
  );
  test(
    'official completed scores and non-played marks map without scoring unfinished pairings',
    () {
      final marks = <String, List<double>>{
        '1-0': [1, 0],
        '0-1': [0, 1],
        '½-½': [.5, .5],
        '1/2-1/2': [.5, .5],
        '+--': [1, 0],
        '--+': [0, 1],
        '0-0': [0, 0],
        '---': [0, 0],
      };
      for (final entry in marks.entries) {
        final results =
            normalizeOfficialRoundResults(tourFixture(), [
              roundFixture(result: entry.key),
            ]).single.results;
        expect(results.map((r) => r.points), entry.value, reason: entry.key);
        expect(
          results.every((r) => r.nonPlayed),
          ['+--', '--+', '0-0', '---'].contains(entry.key),
        );
      }
      for (final unfinished in ['', '*', 'pending', '1', 'NaN']) {
        expect(
          normalizeOfficialRoundResults(tourFixture(), [
            roundFixture(result: unfinished),
          ]),
          isEmpty,
        );
      }
      for (final byeName in ['bye', 'not paired', 'Not paired bye']) {
        for (final score in ['1', '½', '0.5', '0']) {
          final round = roundFixture(result: score);
          final p =
              ((round['pairings'] as Map)['pairings'] as List).first as Map;
          p['black'] = {'name': byeName};
          final result =
              normalizeOfficialRoundResults(tourFixture(), [
                round,
              ]).single.results.single;
          expect(
            result.points,
            score == '1'
                ? 1
                : score == '0'
                ? 0
                : .5,
          );
          expect(result.nonPlayed, isTrue);
          expect(result.color, isNull);
          expect(result.opponentName, byeName);
        }
      }
    },
  );
  test(
    'roster identity must be unambiguous with exact optional FIDE and start number',
    () {
      for (final badSide in [
        {'name': 'Alice Example', 'no': 99},
        {'name': 'Alice Example', 'fideId': 9999},
        {'name': 'Alice Examp'},
        {'name': ''},
        null,
      ]) {
        final r = roundFixture();
        (((r['pairings'] as Map)['pairings'] as List).first as Map)['white'] =
            badSide;
        expect(normalizeOfficialRoundResults(tourFixture(), [r]), isEmpty);
      }
      final ambiguous = tourFixture();
      (ambiguous['players'] as List).add({
        'name': 'Alice Example',
        'fideId': 1001,
        'startNumber': 1,
      });
      expect(
        normalizeOfficialRoundResults(ambiguous, [roundFixture()]),
        isEmpty,
      );
      final same = roundFixture();
      final p = ((same['pairings'] as Map)['pairings'] as List).first as Map;
      p['black'] = p['white'];
      expect(normalizeOfficialRoundResults(tourFixture(), [same]), isEmpty);
    },
  );
  test(
    'only exact HTTPS Chess Results section and round provenance is trusted',
    () {
      for (final source in [
        'https://chess-results.com/tnr999.aspx',
        'http://chess-results.com/tnr123.aspx',
        'https://evil.chess-results.com/tnr123.aspx',
        'https://chess-results.com.evil.test/tnr123.aspx',
        'https://user@chess-results.com/tnr123.aspx',
        'https://chess-results.com:443/tnr123.aspx',
        'https://chess-results.com:444/tnr123.aspx',
        'https://chess-results.com/tnr123.aspx/extra',
      ]) {
        final r = roundFixture();
        (r['pairings'] as Map)['sourceUrl'] = source;
        expect(
          normalizeOfficialRoundResults(tourFixture(), [r]),
          isEmpty,
          reason: source,
        );
      }
      final mismatch = roundFixture()..['slug'] = 'round-2';
      expect(normalizeOfficialRoundResults(tourFixture(), [mismatch]), isEmpty);
      final team = roundFixture();
      (team['pairings'] as Map)['format'] = 'team';
      expect(normalizeOfficialRoundResults(tourFixture(), [team]), isEmpty);
      expect(normalizeOfficialRoundResults({}, [roundFixture()]), isEmpty);
      expect(
        normalizeOfficialRoundResults(tourFixture(), [null, {}, []]),
        isEmpty,
      );
    },
  );
  test('verified individual result retains roster and round metadata', () {
    final rounds = normalizeOfficialRoundResults(tourFixture(), [
      roundFixture(),
    ]);
    expect(rounds, hasLength(1));
    final round = rounds.single;
    expect(round.roundId, 'r1');
    expect(round.roundName, 'First round');
    expect(round.roundNumber, 1);
    expect(round.tourId, 'section-a');
    expect(round.results, hasLength(2));
    final alice = round.results.first;
    expect(alice.playerName, 'Alice, Example');
    expect(alice.playerFideId, '1001');
    expect(alice.color, 'white');
    expect(alice.points, 1);
    expect(alice.opponentName, 'Béla Example');
    expect(alice.opponentFideId, '1002');
    expect(alice.opponentRating, 2200);
    expect(alice.opponentTitle, 'IM');
    expect(alice.opponentFed, 'HUN');
    expect(alice.opponentRank, 7);
    expect(alice.nonPlayed, false);
    expect(alice.roundId, round.roundId);
    expect(round.results.last.points, 0);
    expect(round.results.last.color, 'black');
  });
}
