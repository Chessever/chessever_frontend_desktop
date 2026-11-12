import 'dart:convert';
import 'package:chessever/desktop/services/broadcast_video_origin_resolver.dart';
import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const scope = BroadcastVideoScope(tourId: 'combined', roundId: 'combined-r2');
Map<String, dynamic> row({
  bool mirror = false,
  String group = 'event',
  String start = '2026-11-11T12:30:00Z',
  String white = 'White Player',
  String black = 'Black Player',
  String tour = 'group-c',
  String round = 'c-r2',
}) => {
  'id': mirror ? 'mirror-game' : 'original-game',
  'tour_id': tour,
  'round_id': round,
  'player_white': white,
  'player_black': black,
  'tour': {'is_mirror': mirror, 'group_broadcast_id': group},
  'round': {'starts_at': start},
};

void main() {
  Future<(BroadcastVideoScope?, List<Uri>)> resolve({
    Map<String, dynamic>? source,
    List<Map<String, dynamic>>? candidates,
  }) async {
    final urls = <Uri>[];
    final client = SupabaseClient(
      'https://catalog.example.test',
      'test-key',
      httpClient: MockClient((request) async {
        urls.add(request.url);
        return http.Response(
          jsonEncode(
            urls.length == 1
                ? [
                  source ??
                      row(mirror: true, tour: 'combined', round: 'combined-r2'),
                ]
                : request.url.path.endsWith('/rounds')
                ? [
                  for (final game in candidates ?? [row()])
                    {
                      'id': game['round_id'],
                      'tour_id': game['tour_id'],
                      'tour': game['tour'],
                    },
                ]
                : candidates ?? [row()],
          ),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    try {
      return (
        await BroadcastVideoOriginResolver(
          client,
        ).resolve(scope, 'mirror-game'),
        urls,
      );
    } finally {
      await client.dispose();
    }
  }

  test(
    'bounds the game lookup to matching original round IDs before player filtering',
    () async {
      final (result, urls) = await resolve();
      expect(result, isNotNull);
      expect(urls.map((url) => url.path), [
        '/rest/v1/games',
        '/rest/v1/rounds',
        '/rest/v1/games',
      ]);
      expect(urls[1].queryParameters['tour.group_broadcast_id'], 'eq.event');
      expect(urls[1].queryParameters['tour.is_mirror'], 'eq.false');
      expect(urls[1].queryParameters['starts_at'], 'eq.2026-11-11T12:30:00Z');
      expect(urls.last.queryParameters['round_id'], 'in.("c-r2")');
    },
  );

  test(
    'matches only the original game in the same scheduled round and event',
    () async {
      final (result, urls) = await resolve();
      expect(
        result,
        const BroadcastVideoScope(tourId: 'group-c', roundId: 'c-r2'),
      );
      final query = urls.last.queryParameters;
      expect(query['tour.group_broadcast_id'], 'eq.event');
      expect(query['tour.is_mirror'], 'eq.false');
      expect(query['round.starts_at'], 'eq.2026-11-11T12:30:00Z');
      expect(query['player_white'], 'eq.White Player');
      expect(query['player_black'], 'eq.Black Player');
      expect(query['limit'], '2');
      expect(query['select'], contains('games_round_id_fkey!inner'));
      expect(query['select'], contains('games_tour_id_fkey!inner'));
    },
  );
  test('ordinary non-mirror games trigger no sibling query', () async {
    final (result, urls) = await resolve(
      source: row(tour: 'combined', round: 'combined-r2'),
    );
    expect(result, isNull);
    expect(urls.length, 1);
  });
  test(
    'missing mirror flag is legacy-safe and never guesses from the name',
    () async {
      final source = row(mirror: true, tour: 'combined', round: 'combined-r2');
      (source['tour'] as Map).remove('is_mirror');
      final (result, urls) = await resolve(source: source);
      expect(result, isNull);
      expect(urls.length, 1);
    },
  );
  test('no original match stays video-free', () async {
    expect((await resolve(candidates: [])).$1, isNull);
  });
  test('ambiguous originals never choose the first sibling', () async {
    expect(
      (await resolve(
        candidates: [row(), row(tour: 'group-d', round: 'd-r2')],
      )).$1,
      isNull,
    );
  });
  test('different event cannot supply commentary', () async {
    expect((await resolve(candidates: [row(group: 'other')])).$1, isNull);
  });
  test('another scheduled round cannot supply commentary', () async {
    expect(
      (await resolve(candidates: [row(start: '2026-11-12T12:30:00Z')])).$1,
      isNull,
    );
  });
  test('reversed player colors cannot supply commentary', () async {
    expect(
      (await resolve(
        candidates: [row(white: 'Black Player', black: 'White Player')],
      )).$1,
      isNull,
    );
  });
  test('stale board context cannot supply commentary', () async {
    final (result, urls) = await resolve(
      source: row(mirror: true, tour: 'combined', round: 'combined-r1'),
    );
    expect(result, isNull);
    expect(urls.length, 1);
  });
}
