import 'dart:convert';
import 'dart:typed_data';

import 'package:chessever/repository/gamebase/collections/collection_search_query.dart';
import 'package:chessever/repository/gamebase/collections/collections_models.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers each request from a queue and records what was asked.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<(int, Object)> answers = [];

  void answer(int status, Object body) => answers.add((status, body));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = answers.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _ok(Object? data) => {'status': 'success', 'data': data};

Map<String, Object?> _book(String slug) => {
  'id': 'id-$slug',
  'slug': slug,
  'kind': 'book',
  'title': 'Title $slug',
  'gameCount': 3,
};

void main() {
  late _Adapter adapter;
  late GamebaseRepository api;

  setUp(() {
    adapter = _Adapter();
    api = GamebaseRepository(
      Dio()..httpClientAdapter = adapter,
      baseUrl: 'https://proxy.test/functions/v1/gamebase-proxy',
    );
  });

  test(
    'the catalog is read through the proxy with the search as sent',
    () async {
      adapter.answer(
        200,
        _ok({
          'items': [_book('a'), _book('b')],
          'total': 2,
          'limit': 40,
          'offset': 0,
        }),
      );

      final page = await api.searchCollectionBooks(
        search: const CollectionSearchQuery(
          text: ' najdorf ',
          eco: 'b90',
          minYear: 1960,
          maxYear: 1972,
          authorId: 'account:0123456789abcdef0123456789abcdef',
        ),
        offset: 40,
      );

      expect(page.items.map((c) => c.slug), ['a', 'b']);
      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(
        request.uri.path,
        '/functions/v1/gamebase-proxy/api/collections/catalog/books',
      );
      expect(request.uri.queryParameters, {
        'q': 'najdorf',
        'eco': 'B90',
        'minYear': '1960',
        'maxYear': '1972',
        'authorId': 'account:0123456789abcdef0123456789abcdef',
        'limit': '40',
        'offset': '40',
      });
    },
  );

  test('authors come back with their photo and counts', () async {
    adapter.answer(
      200,
      _ok({
        'items': [
          {
            'id': 'account:0123456789abcdef0123456789abcdef',
            'name': 'Elif Demir',
            'avatarUrl': 'https://img.test/a.png',
            'bookCount': 2,
            'gameCount': 96,
          },
        ],
        'total': 1,
      }),
    );

    final authors = await api.searchCollectionAuthors(limit: 100);

    expect(authors.total, 1);
    expect(authors.items.single.name, 'Elif Demir');
    expect(authors.items.single.bookCount, 2);
    expect(authors.items.single.hasCatalogIdentity, isTrue);
    expect(adapter.requests.single.uri.queryParameters['limit'], '100');
  });

  test('a collection is read by slug, and a fresh read says so', () async {
    adapter
      ..answer(200, _ok({..._book('my book'), 'contentLocked': true}))
      ..answer(200, _ok({..._book('my book'), 'contentLocked': false}));

    final locked = await api.getCollection('my book');
    final open = await api.getCollection('my book', fresh: true);

    expect(locked.contentLocked, isTrue);
    expect(open.contentLocked, isFalse);
    expect(
      adapter.requests.first.uri.path,
      '/functions/v1/gamebase-proxy/api/collections/my%20book',
    );
    expect(adapter.requests.first.headers['Cache-Control'], isNull);
    expect(adapter.requests.last.headers['Cache-Control'], 'no-cache');
  });

  test('games ask for their PGN and carry the search and the player', () async {
    adapter.answer(
      200,
      _ok({
        'items': [
          {
            'id': 'g1',
            'white': {'name': 'A'},
            'black': {'name': 'B'},
            'pgn': '1. e4 e5 *',
          },
        ],
        'total': 1,
        'limit': 200,
        'offset': 0,
      }),
    );

    final page = await api.getCollectionGames(
      'endgames',
      includePgn: true,
      limit: 200,
      playerKey: 'fide:1503014',
      search: const CollectionSearchQuery(result: '1-0'),
    );

    expect(page.items.single.pgn, '1. e4 e5 *');
    expect(adapter.requests.single.uri.queryParameters, {
      'result': '1-0',
      'player': 'fide:1503014',
      'include': 'pgn',
      'limit': '200',
      'offset': '0',
    });
  });

  test('the Premium gate arrives as a gate, with the server\'s code', () async {
    adapter.answer(402, {
      'status': 'error',
      'error': {'message': 'Premium required', 'code': 'premium_required'},
    });

    await expectLater(
      api.getCollectionGames('zurich-1953', includePgn: true),
      throwsA(
        isA<CollectionsRequestException>()
            .having((e) => e.isPremiumGate, 'isPremiumGate', isTrue)
            .having((e) => e.statusCode, 'statusCode', 402),
      ),
    );
  });

  test('a proxy that predates collections reads as not available', () async {
    adapter
      ..answer(403, {'error': 'route_not_allowed'})
      ..answer(405, {'error': 'method_not_allowed'});

    await expectLater(
      api.searchCollectionBooks(),
      throwsA(
        isA<CollectionsRequestException>().having(
          (e) => e.isNotAvailable,
          'isNotAvailable',
          isTrue,
        ),
      ),
    );
    await expectLater(
      api.recordCollectionEngagement('endgames', {'starred': true}, star: true),
      throwsA(
        isA<CollectionsRequestException>().having(
          (e) => e.isNotAvailable,
          'isNotAvailable',
          isTrue,
        ),
      ),
    );
  });

  test('a bad search keeps its status, so the list can explain it', () async {
    adapter.answer(400, {
      'status': 'error',
      'error': {'message': 'Invalid eco'},
    });

    await expectLater(
      api.searchCollectionBooks(search: const CollectionSearchQuery(eco: 'ZZ')),
      throwsA(
        isA<CollectionsRequestException>().having(
          (e) => e.statusCode,
          'statusCode',
          400,
        ),
      ),
    );
  });

  test('a network failure is a plain load failure', () async {
    adapter.answer(502, {'error': 'gamebase_upstream_unavailable'});

    await expectLater(
      api.getCollectionPlayers('endgames'),
      throwsA(
        isA<CollectionsRequestException>()
            .having((e) => e.isNotAvailable, 'isNotAvailable', isFalse)
            .having((e) => e.isPremiumGate, 'isPremiumGate', isFalse),
      ),
    );
  });

  test(
    'a view is a POST with the reader id, a star a PUT with the flag',
    () async {
      adapter
        ..answer(200, _ok({'viewCount': 12, 'starCount': 3}))
        ..answer(200, _ok({'viewCount': 12, 'starCount': 4}));

      final viewed = await api.recordCollectionEngagement('endgames', {
        'viewerId': '11111111-2222-4333-8444-555555555555',
      });
      final starred = await api.recordCollectionEngagement('endgames', {
        'starred': true,
      }, star: true);

      expect(viewed['viewCount'], 12);
      expect(starred['starCount'], 4);
      expect(adapter.requests.first.method, 'POST');
      expect(
        adapter.requests.first.uri.path,
        '/functions/v1/gamebase-proxy/api/collections/endgames/view',
      );
      expect(adapter.requests.first.data, {
        'viewerId': '11111111-2222-4333-8444-555555555555',
      });
      expect(adapter.requests.last.method, 'PUT');
      expect(
        adapter.requests.last.uri.path,
        '/functions/v1/gamebase-proxy/api/collections/endgames/star',
      );
      expect(adapter.requests.last.data, {'starred': true});
    },
  );

  test('event bindings repeat their keys and skip an empty question', () async {
    expect(await api.getCollectionsForEvent(CollectionEventAnchors()), isEmpty);
    expect(adapter.requests, isEmpty);

    adapter.answer(
      200,
      _ok({
        'books': [_book('bound')],
      }),
    );
    final books = await api.getCollectionsForEvent(
      CollectionEventAnchors(groups: ['gb_1'], tours: ['t1', 't2']),
    );

    expect(books.single.slug, 'bound');
    final uri = adapter.requests.single.uri;
    expect(uri.path, '/functions/v1/gamebase-proxy/api/collections/for-event');
    expect(uri.queryParametersAll['tour'], ['t1', 't2']);
    expect(uri.queryParametersAll['group'], ['gb_1']);
  });
}
