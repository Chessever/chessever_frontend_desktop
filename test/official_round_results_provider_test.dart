import 'dart:convert';
import 'package:chessever/repositories/official_round_results_repository.dart';
import 'package:chessever/screens/tour_detail/official_round_results_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'official_round_results_test.dart' show tourFixture, roundFixture;

void main() {
  test(
    'standings and scorecards share one cached per-tour read across reopen',
    () async {
      var tours = 0;
      var rounds = 0;
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/tours')) {
            tours++;
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          rounds++;
          return http.Response(
            jsonEncode([roundFixture()]),
            200,
            request: request,
            headers: {'content-range': '0-0/1'},
          );
        }),
      );
      final container = ProviderContainer(
        overrides: [
          officialRoundResultsRepositoryProvider.overrideWithValue(
            OfficialRoundResultsRepository(client),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final standings = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      final card = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      final results = await container.read(
        officialRoundResultsProvider('section-a').future,
      );
      expect(results.single.results, hasLength(2));
      expect(tours, 1);
      expect(rounds, 1);
      standings.close();
      card.close();
      await container.pump();
      final reopened = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      expect(
        await container.read(officialRoundResultsProvider('section-a').future),
        same(results),
      );
      expect(tours, 1);
      container.invalidate(officialRoundResultsProvider('section-a'));
      await container.read(officialRoundResultsProvider('section-a').future);
      expect(tours, 2);
      expect(rounds, 2);
      reopened.close();
    },
  );
  test(
    'watched sections refresh once per section and pause without readers',
    () async {
      var reads = 0;
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/tours')) {
            reads++;
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          return http.Response(
            jsonEncode([roundFixture()]),
            200,
            request: request,
            headers: {'content-range': '0-0/1'},
          );
        }),
      );
      final container = ProviderContainer(
        overrides: [
          officialRoundResultsRepositoryProvider.overrideWithValue(
            OfficialRoundResultsRepository(client),
          ),
          officialRoundResultsRefreshIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 20),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final first = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      final second = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      await container.read(officialRoundResultsProvider('section-a').future);
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(reads, greaterThanOrEqualTo(2));
      first.close();
      second.close();
      await container.pump();
      final stoppedAt = reads;
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(reads, stoppedAt);
    },
  );

  test(
    'a failed refresh retains the last verified results for that section',
    () async {
      var tourReads = 0;
      final client = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/tours')) {
            if (++tourReads > 1) {
              return http.Response('offline', 400, request: request);
            }
            return http.Response(
              jsonEncode(tourFixture()),
              200,
              request: request,
            );
          }
          return http.Response(
            jsonEncode([roundFixture()]),
            200,
            request: request,
            headers: {'content-range': '0-0/1'},
          );
        }),
      );
      final container = ProviderContainer(
        overrides: [
          officialRoundResultsRepositoryProvider.overrideWithValue(
            OfficialRoundResultsRepository(client),
          ),
          officialRoundResultsRefreshIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 20),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final subscription = container.listen(
        officialRoundResultsProvider('section-a'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final first = await container.read(
        officialRoundResultsProvider('section-a').future,
      );
      expect(first, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(tourReads, greaterThanOrEqualTo(2));
      expect(
        await container.read(officialRoundResultsProvider('section-a').future),
        same(first),
      );
    },
  );
}
