import 'dart:convert';
import 'package:chessever/repositories/official_round_results_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'official_round_results_test.dart' show tourFixture, roundFixture;

void main() {
  test(
    'whole optional read times out without continuing late pagination',
    () async {
      var calls = 0;
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/tours')) {
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return http.Response(
            jsonEncode([roundFixture()]),
            200,
            request: request,
            headers: {'content-range': '0-0/2'},
          );
        }),
      );
      final repository = OfficialRoundResultsRepository(
        client,
        timeout: const Duration(milliseconds: 20),
      );
      expect(await repository.getByTourId('section-a'), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 2);
      await client.dispose();
    },
  );
  test(
    'optional read fails closed on incomplete changed or malformed pages and legacy metadata',
    () async {
      for (final mode in [
        'empty-page',
        'changing-count',
        'duplicate',
        'wrong-tour',
        'missing-count',
        'failure',
        'legacy',
        'missing-tour',
        'invalid-id',
      ]) {
        var calls = 0;
        final client = SupabaseClient(
          'https://synthetic.invalid',
          'synthetic-anon',
          httpClient: MockClient((request) async {
            calls++;
            if (calls > 5) throw StateError('unbounded paging');
            if (mode == 'invalid-id') {
              throw StateError('must not query invalid ID');
            }
            if (request.url.path.endsWith('/tours')) {
              final t = mode == 'legacy' ? {'id': 'section-a'} : tourFixture();
              return http.Response(
                jsonEncode(mode == 'missing-tour' ? [] : t),
                200,
                request: request,
              );
            }
            if (mode == 'failure') {
              return http.Response('{}', 403, request: request);
            }
            final round = roundFixture();
            if (mode == 'wrong-tour') round['tour_id'] = 'other-section';
            final body = mode == 'empty-page' && calls > 2 ? [] : [round];
            final count = mode == 'changing-count' && calls > 2 ? 3 : 2;
            return http.Response(
              jsonEncode(body),
              200,
              request: request,
              headers:
                  mode == 'missing-count'
                      ? {}
                      : {'content-range': '0-0/$count'},
            );
          }),
        );
        expect(
          await OfficialRoundResultsRepository(
            client,
          ).getByTourId(mode == 'invalid-id' ? 'bad/id' : 'section-a'),
          isEmpty,
          reason: mode,
        );
        expect(calls, lessThanOrEqualTo(3), reason: mode);
        if (mode == 'invalid-id') expect(calls, 0);
        if (mode == 'legacy' || mode == 'missing-tour') expect(calls, 1);
        await client.dispose();
      }
    },
  );
  test(
    'too many rounds fail closed before another page is requested',
    () async {
      var roundCalls = 0;
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/tours')) {
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          roundCalls++;
          return http.Response(
            jsonEncode([roundFixture()]),
            200,
            request: request,
            headers: {'content-range': '0-0/201'},
          );
        }),
      );
      expect(
        await OfficialRoundResultsRepository(client).getByTourId('section-a'),
        isEmpty,
      );
      expect(roundCalls, 1);
      await client.dispose();
    },
  );
  test(
    'public read scopes to tour and completely pages rounds with server count',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/tours')) {
            expect(request.url.queryParameters['id'], 'eq.section-a');
            expect(request.url.queryParameters['select'], 'id,info,players');
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          expect(request.url.queryParameters['tour_id'], 'eq.section-a');
          expect(request.url.queryParameters['order'], 'id.asc.nullslast');
          expect(
            request.url.queryParameters['select'],
            'id,name,slug,tour_id,pairings',
          );
          expect(request.headers['prefer'], contains('count=exact'));
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          // Simulate a server cap smaller than the requested page size.
          final r =
              roundFixture()
                ..['id'] = 'r${offset + 1}'
                ..['slug'] = 'round-${offset + 1}';
          (r['pairings'] as Map)['round_number'] = offset + 1;
          return http.Response(
            jsonEncode([r]),
            200,
            request: request,
            headers: {'content-range': '$offset-$offset/3'},
          );
        }),
      );
      final result = await OfficialRoundResultsRepository(
        client,
        pageSize: 2,
      ).getByTourId('section-a');
      expect(result.map((r) => r.roundId), ['r1', 'r2', 'r3']);
      expect(
        requests.where((r) => r.url.path.endsWith('/tours')),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.url.path.endsWith('/rounds')),
        hasLength(3),
      );
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await client.dispose();
    },
  );
}
