import 'dart:async';
import 'dart:convert';

import 'package:chessever/desktop/services/event_artwork_loader.dart';
import 'package:chessever/desktop/state/event_artwork_provider.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _tour(
  String id,
  String? group, {
  String? image = 'https://example.com/poster.webp',
  String? location = 'Beijing, China.',
}) => {
  'id': id,
  'group_broadcast_id': group,
  'image': image,
  'location': location,
};

http.Response _response(List<Map<String, dynamic>> rows) => http.Response(
  jsonEncode(rows),
  200,
  headers: {'content-type': 'application/json'},
);

EventArtworkLoader _loader(
  Future<http.Response> Function(http.Request) respond, {
  Duration timeout = const Duration(seconds: 8),
}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((request) async {
      final response = await respond(request);
      return http.Response.bytes(
        response.bodyBytes,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }),
  );
  addTearDown(client.dispose);
  return EventArtworkLoader(
    source: EventArtworkSource(client: () => client),
    timeout: timeout,
  );
}

class _Source extends EventArtworkSource {
  _Source(this.rows)
    : super(client: () => throw StateError('No HTTP expected'));

  final Future<List<Map<String, dynamic>>> Function() rows;

  @override
  Future<List<Map<String, dynamic>>> byGroups(List<String> ids) => rows();
}

void main() {
  test(
    'visible covers share one lean query and one in-flight lookup',
    () async {
      final requests = <http.Request>[];
      final loader = _loader((request) async {
        requests.add(request);
        return _response([
          _tour('a1', 'a', image: '  '),
          _tour('a2', 'a', image: ' https://example.com/sibling.webp '),
          _tour('b1', 'b'),
        ]);
      });

      final a = loader.load('a');
      expect(identical(a, loader.load('a')), isTrue);
      final results = await Future.wait([a, loader.load('b')]);

      expect(requests, hasLength(1));
      final query = requests.single.url.queryParameters;
      expect(
        query['select'],
        'id,group_broadcast_id,image,location:info->>location',
      );
      expect(query['group_broadcast_id'], contains('a'));
      expect(query['group_broadcast_id'], contains('b'));
      expect(query['order'], 'avg_elo.desc.nullslast');
      expect(results.first.imageUrl, 'https://example.com/sibling.webp');
      expect(results.first.location, 'Beijing, China');
    },
  );

  test('raw tour IDs still find artwork on a sibling tour', () async {
    var requests = 0;
    final loader = _loader((request) async {
      requests++;
      final query = request.url.queryParameters;
      if (query.containsKey('id')) {
        return _response([_tour('raw', 'group', image: null)]);
      }
      if (query['group_broadcast_id']!.contains('group')) {
        return _response([
          _tour('raw', 'group', image: null),
          _tour('sibling', 'group'),
        ]);
      }
      return _response([]);
    });

    expect(
      (await loader.load('raw')).imageUrl,
      'https://example.com/poster.webp',
    );
    expect(requests, 3);
  });

  test('a raw ID lookup cannot delay resolved group covers', () async {
    final fallback = Completer<http.Response>();
    final loader = _loader((request) async {
      if (request.url.queryParameters.containsKey('id')) return fallback.future;
      return _response([_tour('tour', 'group')]);
    });
    final group = loader.load('group');
    final missing = loader.load('missing');
    expect((await group).imageUrl, isNotNull);
    expect(fallback.isCompleted, isFalse);
    fallback.complete(_response([]));
    expect((await missing).imageUrl, isNull);
  });

  test('large grids split into bounded batches', () async {
    final requests = <http.Request>[];
    final rows = [
      for (var i = 0; i < EventArtworkLoader.batchSize + 1; i++)
        _tour('tour$i', 'group$i'),
    ];
    final loader = _loader((request) async {
      requests.add(request);
      return _response(rows);
    });
    await Future.wait([
      for (final row in rows) loader.load(row['group_broadcast_id']),
    ]);
    expect(requests, hasLength(2));
    for (final request in requests) {
      final filter = request.url.queryParameters['group_broadcast_id']!;
      expect(
        filter.split(',').length,
        lessThanOrEqualTo(EventArtworkLoader.batchSize),
      );
    }
  });

  test('timed-out lookups release in-flight state and can retry', () async {
    final stalled = Completer<http.Response>();
    var requests = 0;
    final loader = _loader((_) async {
      requests++;
      if (requests == 1) return stalled.future;
      return _response([_tour('tour', 'group')]);
    }, timeout: const Duration(milliseconds: 20));

    await expectLater(loader.load('group'), throwsA(isA<TimeoutException>()));
    expect((await loader.load('group')).imageUrl, isNotNull);
    stalled.complete(_response([]));
    expect(requests, 2);
  });

  testWidgets('scrolling and tab switches retain covers until cache expires', (
    tester,
  ) async {
    var requests = 0;
    final loader = EventArtworkLoader(
      source: _Source(() async {
        requests++;
        return [_tour('tour', 'group')];
      }),
    );
    final container = ProviderContainer(
      overrides: [eventArtworkLoaderProvider.overrideWithValue(loader)],
    );
    final provider = eventArtworkProvider('group');
    var subscription = container.listen(provider, (_, _) {});
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(provider).requireValue.imageUrl, isNotNull);
    subscription.close();
    await tester.pump(const Duration(seconds: 1));

    subscription = container.listen(provider, (_, _) {});
    expect(container.read(provider).requireValue.imageUrl, isNotNull);
    expect(requests, 1);
    subscription.close();
    await tester.pump(const Duration(minutes: 11));
    await tester.pump(const Duration(milliseconds: 1));

    subscription = container.listen(provider, (_, _) {});
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests, 2);
    subscription.close();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('transient failures retry without caching an empty cover', (
    tester,
  ) async {
    var requests = 0;
    final loader = EventArtworkLoader(
      source: _Source(() async {
        requests++;
        if (requests == 1) throw StateError('temporarily unavailable');
        return [_tour('tour', 'group')];
      }),
    );
    final container = ProviderContainer(
      overrides: [eventArtworkLoaderProvider.overrideWithValue(loader)],
    );
    final provider = eventArtworkProvider('group');
    final subscription = container.listen(provider, (_, _) {});
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests, 2);
    expect(container.read(provider).requireValue.imageUrl, isNotNull);
    subscription.close();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('events without artwork keep the federation fallback', (
    tester,
  ) async {
    final loader = EventArtworkLoader(
      source: _Source(
        () async => [_tour('tour', 'group', image: null, location: null)],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        eventArtworkLoaderProvider.overrideWithValue(loader),
        eventImageProvider('group').overrideWith(
          (ref) async => const EventImageData(fallbackCountryCode: 'CN'),
        ),
      ],
    );
    final provider = eventArtworkProvider('group');
    final subscription = container.listen(provider, (_, _) {});
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(provider).requireValue.fallbackCountryCode, 'CN');
    subscription.close();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });
}
