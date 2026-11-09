import 'dart:convert';

import 'package:chessever/desktop/auth/web_sign_in_public_data.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// These are isolated decoder fixtures, never bundled or served as public data.
const _fen = '4k3/8/8/8/8/8/8/4K3 w - - 0 1';
Map<String, dynamic> _game(String id) => {
  'id': id,
  'round_id': 'test-round',
  'round_slug': 'round-1',
  'tour_id': 'test-event',
  'tour_slug': 'decoder-fixture',
  'fen': _fen,
  'status': 'draw',
  'players': [
    {'name': 'Fixture White', 'rating': 2501, 'title': 'GM'},
    {'name': 'Fixture Black', 'rating': 2499, 'title': 'IM'},
  ],
};
Map<String, dynamic> _response(CommunityLikesQuery query) => {
  'schemaVersion': 1,
  'dataset': 'community-likes',
  'period': query.period.name,
  'from': query.start.toUtc().toIso8601String(),
  'to': query.end.toUtc().toIso8601String(),
  'generatedAt': '2026-11-08T18:00:00Z',
  'rows': [
    {'source_game_id': 'fixture-z', 'like_count': 3},
    {'source_game_id': 'fixture-a', 'like_count': 7},
  ],
  'games': [_game('fixture-z'), _game('fixture-a')],
};

void main() {
  final query = CommunityLikesQuery(
    CommunityLikesPeriod.week,
    DateTime(2026, 11, 8),
  );

  test(
    'public Likes adapter preserves canonical identities, counts and ranks',
    () {
      final data = PublicLikesPreview.fromJson(_response(query), query);
      expect(data.result.entries.map((e) => e.game.gameId), [
        'fixture-a',
        'fixture-z',
      ]);
      expect(data.result.entries.map((e) => e.likes), [7, 3]);
      expect(data.result.entries.map((e) => e.rank), [1, 2]);
      expect(data.result.entries.every((e) => e.game.fen == _fen), isTrue);
      expect(data.result.nextCursor, isNull);
    },
  );

  test('unknown counts are unavailable, never zero or an empty success', () {
    final raw = _response(query);
    (raw['rows'] as List).first['like_count'] = null;
    expect(
      () => PublicLikesPreview.fromJson(raw, query),
      throwsFormatException,
    );
  });

  test(
    'a different date window cannot masquerade as the requested ranking',
    () {
      final raw = _response(query)..['from'] = '2026-01-01T00:00:00Z';
      expect(
        () => PublicLikesPreview.fromJson(raw, query),
        throwsFormatException,
      );
    },
  );

  test(
    'unresolved game data is not replaced by another game or start position',
    () {
      final raw = _response(query)..['games'] = [_game('fixture-a')];
      expect(
        () => PublicLikesPreview.fromJson(raw, query),
        throwsFormatException,
      );
    },
  );

  test('a malformed position is unavailable rather than a synthetic board', () {
    final raw = _response(query);
    (raw['games'] as List).first['fen'] = '';
    expect(
      () => PublicLikesPreview.fromJson(raw, query),
      throwsFormatException,
    );
  });

  test('sample/foreign dataset envelopes cannot populate a real ranking', () {
    final raw = _response(query)..['dataset'] = 'representative-public-sample';
    expect(
      () => PublicLikesPreview.fromJson(raw, query),
      throwsFormatException,
    );
  });

  test(
    'signed-out requests use the bounded same-origin API without auth',
    () async {
      final client = WebSignInPublicDataClient(
        origin: Uri.parse('https://app.chessever.com/app/likes'),
        timeZone: () => 'America/Chicago',
        client: MockClient((request) async {
          expect(request.url.path, '/api/signin-preview/likes');
          expect(request.url.queryParameters['period'], 'week');
          expect(request.url.queryParameters['timeZone'], 'America/Chicago');
          expect(
            request.url.queryParameters['from'],
            query.start.toUtc().toIso8601String(),
          );
          expect(
            request.headers.keys.map((s) => s.toLowerCase()),
            isNot(contains('authorization')),
          );
          return http.Response(jsonEncode(_response(query)), 200);
        }),
      );
      final data = await client.likes(query);
      expect(data.result.entries.first.likes, 7);
      client.close();
    },
  );

  test(
    'a denied backend cannot become fabricated empty ranking data',
    () async {
      final client = WebSignInPublicDataClient(
        origin: Uri.parse('https://app.chessever.com'),
        timeZone: () => 'UTC',
        client: MockClient((_) async => http.Response('unavailable', 503)),
      );
      await expectLater(client.likes(query), throwsStateError);
      client.close();
    },
  );
}
