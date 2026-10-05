import 'dart:convert';
import 'dart:typed_data';

import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _testAuthUrl = 'https://odmekzlfunfocvedqusl.supabase.co';

LibraryFolder _folder({
  bool subscribed = false,
  bool liked = false,
  String? parentId,
}) => LibraryFolder(
  id: 'folder-id',
  userId: 'owner',
  name: 'Sicilian studies',
  color: '#000000',
  icon: 'folder',
  orderIndex: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  isSubscribed: subscribed,
  isLikedGames: liked,
  parentId: parentId,
);

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int responseStatus = 200;
  String status = 'draft';
  String? errorCode;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'status': 'success',
        if (errorCode != null) 'error': {'code': errorCode},
        'data': {
          'folderId': 'folder-id',
          'status': status,
          'book': {
            'id': 'book-id',
            'title': 'Sicilian studies',
            'gameCount': 12,
          },
        },
      }),
      responseStatus,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'the author description is read as authorBio and sent as authorAbout',
    () {
      // An older server never sent it: the key stays out of the save.
      const older = LibraryBookMetadata(title: 'T');
      expect(older.toJson().containsKey('authorAbout'), isFalse);
      final known = LibraryBookMetadata.fromJson(const {
        'title': 'T',
        'author': 'Ann',
        'authorBio': 'Coach from Baku.',
      });
      expect(known.authorAbout, 'Coach from Baku.');
      expect(known.toJson()['authorAbout'], 'Coach from Baku.');
      expect(known.copyWith(author: 'Anne').authorAbout, 'Coach from Baku.');
      // An emptied field is null, which clears it.
      expect(
        const LibraryBookMetadata(title: 'T', authorAbout: ' ').toJson(),
        containsPair('authorAbout', null),
      );
      expect(
        LibraryBookMetadata.fromJson(const {
          'title': 'T',
          'authorBio': null,
        }).authorAbout,
        '',
      );
    },
  );

  test(
    'unsafe endpoint or account environment never receives a token',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      for (final (base, auth) in [
        ('https://service.chessever.com', _testAuthUrl),
        ('https://chessever.com/proxy', _testAuthUrl),
        ('https://service.chessever.com./proxy', _testAuthUrl),
        ('https://oelbsuggrzyqwzmvidju.supabase.co/functions/v1', _testAuthUrl),
        ('https://unknown.supabase.co/functions/v1', _testAuthUrl),
        ('https://user:password@example.test', _testAuthUrl),
        ('https://example.test?token=secret', _testAuthUrl),
        ('https://example.test#fragment', _testAuthUrl),
        ('http://example.test', _testAuthUrl),
        // (A production account is not in this list: it publishes through
        // its own project's proxy and never uses a test base. See below.)
        ('http://localhost:3000', 'https://unknown.supabase.co'),
        ('https://example.test', '$_testAuthUrl?project=another'),
        ('https://example.test', null),
      ]) {
        var tokenRead = false;
        final publisher = GamebaseLibraryBookPublisher(
          dio: dio,
          baseUrl: base,
          supabaseUrl: auth,
          accessToken: () {
            tokenRead = true;
            return 'session';
          },
        );
        var deleted = false;
        await expectLater(
          deleteLibraryFolderWithPublications(
            supabaseUrl: _testAuthUrl,
            folder: _folder(),
            publisher: publisher,
            deleteFolder: (_) async => deleted = true,
          ),
          throwsA(isA<LibraryBookPublicationException>()),
          reason: '$base / $auth',
        );
        expect(tokenRead, isFalse);
        expect(deleted, isFalse);
      }
      expect(adapter.requests, isEmpty);
      dio.close();
    },
  );

  test(
    'explicit test proxy and local development use test auth only',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      for (final base in [
        '$_testAuthUrl/functions/v1/gamebase-proxy',
        'https://example.test/proxy',
        'http://localhost:3000',
        'http://127.0.0.1:3000',
        'http://[::1]:3000',
      ]) {
        final publisher = GamebaseLibraryBookPublisher(
          dio: dio,
          baseUrl: base,
          supabaseUrl: _testAuthUrl,
          accessToken: () => 'test-session',
        );
        await publisher.load(_folder());
        expect(adapter.requests.last.followRedirects, isFalse);
      }
      expect(adapter.requests, hasLength(5));
      dio.close();
    },
  );

  test('pending deletion directs the author to retry deleting', () async {
    final adapter =
        _Adapter()
          ..responseStatus = 409
          ..errorCode = 'publication_deleting';
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      baseUrl: 'https://example.test',
      supabaseUrl: _testAuthUrl,
      accessToken: () => 'session',
    );
    await expectLater(
      publisher.save(_folder(), const LibraryBookMetadata(title: 'Study')),
      throwsA(
        isA<LibraryBookPublicationException>().having(
          (error) => error.message,
          'message',
          contains('Retry deleting'),
        ),
      ),
    );
    dio.close();
  });

  test(
    'publication includes nested folders but excludes subscriptions and Likes',
    () {
      expect(libraryFolderCanPublish(_folder(parentId: 'parent')), isTrue);
      expect(libraryFolderCanPublish(_folder(subscribed: true)), isFalse);
      expect(libraryFolderCanPublish(_folder(liked: true)), isFalse);
    },
  );

  test('unpublished state falls back to private folder title', () {
    final publication = LibraryBookPublication.fromJson({
      'status': 'unpublished',
      'book': null,
    }, fallbackTitle: 'Private study');
    expect(publication.isPublished, isFalse);
    expect(publication.metadata.title, 'Private study');
    expect(
      () => LibraryBookPublication.fromJson({
        'status': 'unexpected',
      }, fallbackTitle: ''),
      throwsFormatException,
    );
  });

  test(
    'draft edits do not publish and empty optional metadata clears fields',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test/proxy/',
        accessToken: () => 'user-session',
      );
      await publisher.save(
        _folder(),
        const LibraryBookMetadata(title: '  Sicilian studies  '),
      );
      final request = adapter.requests.single;
      expect(
        request.uri.toString(),
        'https://example.test/proxy/api/library/folders/folder-id/book',
      );
      expect(request.method, 'PUT');
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(request.headers['Authorization'], 'Bearer user-session');
      expect(request.headers.containsKey('X-API-Key'), isFalse);
      expect(request.data['title'], 'Sicilian studies');
      expect(request.data['author'], isNull);
      expect(request.data.containsKey('publish'), isFalse);
      expect(request.data.containsKey('refreshGames'), isFalse);
      dio.close();
    },
  );

  test(
    'publish, refresh and withdraw are separate explicit operations',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test',
        accessToken: () => 'session',
      );
      await publisher.save(
        _folder(),
        const LibraryBookMetadata(title: 'Study'),
        publish: true,
        refreshGames: true,
      );
      expect(adapter.requests.last.data['publish'], isTrue);
      expect(adapter.requests.last.data['refreshGames'], isTrue);
      await publisher.unpublish(_folder());
      expect(adapter.requests.last.method, 'DELETE');
      dio.close();
    },
  );

  test('folder deletion withdraws the entire subtree first', () async {
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      supabaseUrl: _testAuthUrl,
      baseUrl: 'https://example.test',
      accessToken: () => 'session',
    );
    var deleted = false;
    await deleteLibraryFolderWithPublications(
      supabaseUrl: _testAuthUrl,
      folder: _folder(),
      publisher: publisher,
      deleteFolder: (_) async {
        expect(adapter.requests.single.method, 'DELETE');
        expect(
          adapter.requests.single.queryParameters['includeDescendants'],
          true,
        );
        deleted = true;
      },
    );
    expect(deleted, isTrue);
    dio.close();
  });

  test(
    'test account cannot delete without a configured publishing endpoint',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: null,
        accessToken: () => 'session',
      );
      var deleted = false;
      expect(publisher.isConfigured, isFalse);
      await expectLater(
        deleteLibraryFolderWithPublications(
          folder: _folder(),
          publisher: publisher,
          supabaseUrl: _testAuthUrl,
          deleteFolder: (_) async => deleted = true,
        ),
        throwsA(
          isA<LibraryBookPublicationException>().having(
            (error) => error.message,
            'message',
            contains('not configured'),
          ),
        ),
      );
      expect(deleted, isFalse);
      expect(adapter.requests, isEmpty);
      dio.close();
    },
  );

  test(
    'withdrawal errors block deletion; only other environments keep legacy deletion',
    () async {
      final adapter = _Adapter()..responseStatus = 503;
      final dio = Dio()..httpClientAdapter = adapter;
      var deletions = 0;
      await expectLater(
        deleteLibraryFolderWithPublications(
          supabaseUrl: _testAuthUrl,
          folder: _folder(),
          publisher: GamebaseLibraryBookPublisher(
            dio: dio,
            supabaseUrl: _testAuthUrl,
            baseUrl: 'https://example.test',
            accessToken: () => 'session',
          ),
          deleteFolder: (_) async {
            deletions++;
          },
        ),
        throwsA(isA<LibraryBookPublicationException>()),
      );
      expect(deletions, 0);
      await deleteLibraryFolderWithPublications(
        supabaseUrl: null,
        folder: _folder(),
        publisher: GamebaseLibraryBookPublisher(
          dio: dio,
          supabaseUrl: _testAuthUrl,
          baseUrl: null,
          accessToken: () => null,
        ),
        deleteFolder: (_) async {
          deletions++;
        },
      );
      expect(deletions, 1);
      expect(adapter.requests, hasLength(1));
      dio.close();
    },
  );

  test(
    'missing configuration or sign-in fails without a network request',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      for (final publisher in [
        GamebaseLibraryBookPublisher(
          dio: dio,
          supabaseUrl: _testAuthUrl,
          baseUrl: null,
          accessToken: () => 'session',
        ),
        GamebaseLibraryBookPublisher(
          dio: dio,
          supabaseUrl: _testAuthUrl,
          baseUrl: 'https://example.test',
          accessToken: () => null,
        ),
      ]) {
        await expectLater(
          publisher.load(_folder()),
          throwsA(isA<LibraryBookPublicationException>()),
        );
      }
      expect(adapter.requests, isEmpty);
      dio.close();
    },
  );

  test(
    'busy publication is a recoverable error and never claims success',
    () async {
      final adapter = _Adapter()..responseStatus = 409;
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test',
        accessToken: () => 'session',
      );
      await expectLater(
        publisher.save(
          _folder(),
          const LibraryBookMetadata(title: 'Study'),
          publish: true,
        ),
        throwsA(
          isA<LibraryBookPublicationException>().having(
            (error) => error.message,
            'message',
            contains('already being processed'),
          ),
        ),
      );
      dio.close();
    },
  );

  // --- Author credit send rule ---------------------------------------------

  test(
    'authorCredit is omitted for a new "Me" book but sent for "other"',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test',
        accessToken: () => 'session',
      );
      // Default (null) credit: the key must be absent, so an old server that
      // 400s on unknown keys is never sent one.
      await publisher.save(_folder(), const LibraryBookMetadata(title: 'A'));
      expect(adapter.requests.last.data.containsKey('authorCredit'), isFalse);
      // Explicit "self" (a book that already carried the key, switched to Me):
      // sent verbatim so the server drops any credited photo.
      await publisher.save(
        _folder(),
        const LibraryBookMetadata(title: 'A', authorCredit: AuthorCredit.self),
      );
      expect(adapter.requests.last.data['authorCredit'], 'self');
      // "other": always sent.
      await publisher.save(
        _folder(),
        const LibraryBookMetadata(title: 'A', authorCredit: AuthorCredit.other),
      );
      expect(adapter.requests.last.data['authorCredit'], 'other');
      // authorPhotoUrl is never written through the save body.
      expect(adapter.requests.last.data.containsKey('authorPhotoUrl'), isFalse);
      dio.close();
    },
  );

  test('a loaded book that carried authorCredit is remembered', () {
    final withKey = LibraryBookPublication.fromJson({
      'status': 'published',
      'book': {'id': 'b', 'title': 'T', 'authorCredit': 'other'},
    }, fallbackTitle: 'T');
    expect(withKey.hadAuthorCreditKey, isTrue);
    expect(withKey.metadata.authorCredit, AuthorCredit.other);
    final withoutKey = LibraryBookPublication.fromJson({
      'status': 'published',
      'book': {'id': 'b', 'title': 'T'},
    }, fallbackTitle: 'T');
    expect(withoutKey.hadAuthorCreditKey, isFalse);
    expect(withoutKey.metadata.authorCredit, isNull);
  });

  // --- Author photo upload path and error mapping ---------------------------

  test('author photo upload and removal hit the author-photo path', () async {
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      supabaseUrl: _testAuthUrl,
      baseUrl: 'https://example.test',
      accessToken: () => 'session',
    );
    await publisher.uploadAuthorPhoto(_folder(), Uint8List.fromList([1, 2, 3]));
    expect(
      adapter.requests.last.uri.toString(),
      'https://example.test/api/library/folders/folder-id/book/author-photo',
    );
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data['image'], base64Encode([1, 2, 3]));
    await publisher.removeAuthorPhoto(_folder());
    expect(adapter.requests.last.method, 'DELETE');
    expect(
      adapter.requests.last.uri.toString(),
      'https://example.test/api/library/folders/folder-id/book/author-photo',
    );
    dio.close();
  });

  test('author photo error codes map to the spec copy', () async {
    for (final (code, status, expected) in [
      ('author_photo_type', 400, 'Use a JPEG, PNG or WebP image.'),
      ('author_photo_animated', 400, 'Use a still image, not an animation.'),
      ('author_photo_aspect', 400, 'Crop the photo to a square.'),
      (
        'author_photo_too_small',
        400,
        'Use an image at least 256 by 256 pixels.',
      ),
      (
        'author_photo_unavailable',
        400,
        'Author photo uploads are not available here yet.',
      ),
      ('bad_base64', 400, 'This image could not be read. Choose another one.'),
      ('too_large', 413, 'This image is too large. Choose one under 8 MB.'),
      (
        'publication_unavailable',
        409,
        'Save the collection details, then add the author photo.',
      ),
      // No code, bare HTTP status: 404/405 both read as "not available yet".
      (null, 404, 'Author photo uploads are not available here yet.'),
      (null, 405, 'Author photo uploads are not available here yet.'),
    ]) {
      final adapter =
          _Adapter()
            ..responseStatus = status
            ..errorCode = code;
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test',
        accessToken: () => 'session',
      );
      await expectLater(
        publisher.uploadAuthorPhoto(_folder(), Uint8List.fromList([0])),
        throwsA(
          isA<LibraryBookPublicationException>().having(
            (error) => error.message,
            'message',
            expected,
          ),
        ),
        reason: '$code / $status',
      );
      dio.close();
    }
  });

  // --- Author suggestions ---------------------------------------------------

  test('suggestions parse https avatars and ignore malformed rows', () async {
    final adapter = _SuggestAdapter(
      items: [
        {
          'id': 'credit:a',
          'name': 'Magnus Carlsen',
          'bookCount': 3,
          'avatarUrl': 'https://media.example/mc.webp',
        },
        {
          'id': 'credit:b',
          'name': 'Hikaru',
          'bookCount': 1,
          'avatarUrl': 'http://insecure/h.png',
        },
        {'id': '', 'name': 'No id'},
        {'id': 'credit:c', 'name': ''},
      ],
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      supabaseUrl: _testAuthUrl,
      baseUrl: 'https://example.test',
      accessToken: () => 'session',
    );
    final results = await publisher.suggestAuthors('mag');
    expect(results, hasLength(2));
    expect(results.first.name, 'Magnus Carlsen');
    expect(results.first.avatarUrl, 'https://media.example/mc.webp');
    // Non-https avatar is dropped to null; the row still comes through.
    expect(results[1].name, 'Hikaru');
    expect(results[1].avatarUrl, isNull);
    expect(
      adapter.requests.last.uri.toString(),
      'https://example.test/api/library/authors?name=mag&limit=6',
    );
    dio.close();
  });

  test('suggestions never throw: a failure yields an empty list', () async {
    final adapter = _Adapter()..responseStatus = 404;
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      supabaseUrl: _testAuthUrl,
      baseUrl: 'https://example.test',
      accessToken: () => 'session',
    );
    expect(await publisher.suggestAuthors('anything'), isEmpty);
    dio.close();
  });

  test('suggestions skip the network for empty or over-long queries', () async {
    final adapter = _SuggestAdapter(items: const []);
    final dio = Dio()..httpClientAdapter = adapter;
    final publisher = GamebaseLibraryBookPublisher(
      dio: dio,
      supabaseUrl: _testAuthUrl,
      baseUrl: 'https://example.test',
      accessToken: () => 'session',
    );
    expect(await publisher.suggestAuthors('   '), isEmpty);
    expect(await publisher.suggestAuthors('x' * 61), isEmpty);
    expect(adapter.requests, isEmpty);
    dio.close();
  });

  // --- Review round ---------------------------------------------------------

  LibraryBookPublication parse(String status, Object? review) =>
      LibraryBookPublication.fromJson({
        'status': status,
        'book': {'id': 'book-id', 'title': 'T', 'review': review},
      }, fallbackTitle: 'T');

  test('a draft says where its review stands', () {
    final pending = parse('draft', {
      'state': 'pending',
      'submittedAt': '2026-10-02T14:20:00Z',
      'note': 'a stale note',
    });
    expect(pending.stage, LibraryBookStage.inReview);
    expect(pending.review.submittedAt, isNotNull);
    expect(pending.review.note, isEmpty);

    final sentBack = parse('draft', {
      'state': 'changes_requested',
      'note': ' Replace the cover. ',
      'decidedAt': '2026-10-03T09:05:00Z',
    });
    expect(sentBack.stage, LibraryBookStage.changesRequested);
    expect(sentBack.review.note, 'Replace the cover.');
    expect(sentBack.review.decidedAt, isNotNull);
  });

  test('anything else is a plain draft, live, or taken down', () {
    // A server that predates reviews sends none; an unknown state, a note-less
    // send-back and a malformed value all read as no review.
    for (final review in <Object?>[
      null,
      'pending',
      {'state': 'approved'},
      {'state': 'changes_requested', 'note': '  '},
      {'state': 'none'},
    ]) {
      expect(parse('draft', review).stage, LibraryBookStage.draft);
    }
    expect(parse('unpublished', null).stage, LibraryBookStage.draft);
    // Only a draft can be in review, whatever a stale answer carries.
    final stale = {'state': 'pending', 'submittedAt': '2026-10-02T14:20:00Z'};
    expect(parse('published', stale).stage, LibraryBookStage.live);
    expect(parse('published', stale).review.state, LibraryBookReviewState.none);
    expect(parse('archived', stale).stage, LibraryBookStage.takenDown);
  });

  // --- Production transport -------------------------------------------------

  const productionAuthUrl = 'https://oelbsuggrzyqwzmvidju.supabase.co';
  const productionProxy = '$productionAuthUrl/functions/v1/gamebase-proxy';

  test(
    'a production account publishes through the gamebase proxy, as itself',
    () async {
      final adapter = _Adapter();
      final publisher = GamebaseLibraryBookPublisher(
        dio: Dio()..httpClientAdapter = adapter,
        // A test proxy left configured is never used by a production account.
        baseUrl: 'https://example.test',
        productionBaseUrl: '$productionProxy/',
        supabaseUrl: productionAuthUrl,
        accessToken: () => 'member-session',
        anonKey: 'anon',
      );
      expect(publisher.isConfigured, isTrue);
      await publisher.save(
        _folder(),
        const LibraryBookMetadata(title: 'Sicilian studies'),
        publish: true,
      );
      await publisher.suggestAuthors('Carlsen');
      expect(adapter.requests.map((r) => r.uri.toString()), [
        '$productionProxy/api/library/folders/folder-id/book',
        '$productionProxy/api/library/authors?name=Carlsen&limit=6',
      ]);
      for (final request in adapter.requests) {
        expect(request.headers['Authorization'], 'Bearer member-session');
        expect(request.headers['apikey'], 'anon');
      }
    },
  );

  test(
    'a production token only ever goes to the project or chessever.com',
    () async {
      // A configured proxy on any other host is passed over for the project's
      // own function: the token never reaches it, and publishing (and with it
      // folder deletion) still works.
      for (final base in [
        'https://example.test/functions/v1/gamebase-proxy',
        'https://odmekzlfunfocvedqusl.supabase.co/functions/v1/gamebase-proxy',
        'http://oelbsuggrzyqwzmvidju.supabase.co/functions/v1/gamebase-proxy',
        'https://user:pw@oelbsuggrzyqwzmvidju.supabase.co/functions/v1/x',
        '$productionProxy?token=secret',
        'https://chessever.com.evil.test/proxy',
        null,
        '',
      ]) {
        final adapter = _Adapter();
        final publisher = GamebaseLibraryBookPublisher(
          dio: Dio()..httpClientAdapter = adapter,
          baseUrl: null,
          productionBaseUrl: base,
          supabaseUrl: productionAuthUrl,
          accessToken: () => 'member-session',
        );
        expect(publisher.isConfigured, isTrue, reason: '$base');
        await publisher.load(_folder());
        await publisher.suggestAuthors('Carlsen');
        expect(adapter.requests, hasLength(2), reason: '$base');
        for (final request in adapter.requests) {
          expect(
            request.uri.toString(),
            startsWith('$productionProxy/api/library/'),
            reason: '$base',
          );
        }
      }

      // A chessever.com host is the one other place it may go.
      final adapter = _Adapter();
      final allowed = GamebaseLibraryBookPublisher(
        dio: Dio()..httpClientAdapter = adapter,
        baseUrl: null,
        productionBaseUrl: 'https://service.chessever.com',
        supabaseUrl: productionAuthUrl,
        accessToken: () => 'member-session',
      );
      await allowed.load(_folder());
      expect(adapter.requests.single.uri.host, 'service.chessever.com');
    },
  );

  test('a test account never uses the production proxy', () async {
    final adapter = _Adapter();
    final publisher = GamebaseLibraryBookPublisher(
      dio: Dio()..httpClientAdapter = adapter,
      baseUrl: 'https://example.test',
      productionBaseUrl: productionProxy,
      supabaseUrl: _testAuthUrl,
      accessToken: () => 'test-session',
    );
    await publisher.load(_folder());
    expect(adapter.requests.single.uri.host, 'example.test');
  });

  test(
    'a proxy deployed before publishing existed does not block folder deletion',
    () async {
      for (final refusal in ['route_not_allowed', 'method_not_allowed']) {
        GamebaseLibraryBookPublisher publisher(String auth) =>
            GamebaseLibraryBookPublisher(
              dio:
                  Dio()
                    ..httpClientAdapter = _RawAdapter(
                      refusal == 'route_not_allowed' ? 403 : 405,
                      {'error': refusal},
                    ),
              baseUrl: 'https://example.test',
              productionBaseUrl: productionProxy,
              supabaseUrl: auth,
              accessToken: () => 'session',
            );

        // Production: nothing could have been published from here, so the
        // folder is deleted as it always was.
        var deleted = false;
        await deleteLibraryFolderWithPublications(
          supabaseUrl: productionAuthUrl,
          folder: _folder(),
          publisher: publisher(productionAuthUrl),
          deleteFolder: (_) async => deleted = true,
        );
        expect(deleted, isTrue, reason: refusal);

        // The editor says so in words rather than "no permission".
        await expectLater(
          publisher(productionAuthUrl).load(_folder()),
          throwsA(
            isA<LibraryBookPublishingUnavailable>().having(
              (e) => e.message,
              'message',
              'Book publishing is not available here yet.',
            ),
          ),
        );

        // A test proxy stays strict: an unreachable withdrawal keeps the folder.
        var deletedInTest = false;
        await expectLater(
          deleteLibraryFolderWithPublications(
            supabaseUrl: _testAuthUrl,
            folder: _folder(),
            publisher: publisher(_testAuthUrl),
            deleteFolder: (_) async => deletedInTest = true,
          ),
          throwsA(isA<LibraryBookPublishingUnavailable>()),
        );
        expect(deletedInTest, isFalse);
      }
    },
  );

  test('a folder that can never be a book is deleted without asking', () async {
    final adapter = _Adapter();
    final publisher = GamebaseLibraryBookPublisher(
      dio: Dio()..httpClientAdapter = adapter,
      baseUrl: 'https://example.test',
      supabaseUrl: _testAuthUrl,
      accessToken: () => 'session',
    );
    for (final folder in [_folder(subscribed: true), _folder(liked: true)]) {
      var deleted = false;
      await deleteLibraryFolderWithPublications(
        supabaseUrl: _testAuthUrl,
        folder: folder,
        publisher: publisher,
        deleteFolder: (_) async => deleted = true,
      );
      expect(deleted, isTrue);
    }
    expect(adapter.requests, isEmpty);
  });

  test(
    'the server\'s refusals read as something the author can act on',
    () async {
      Future<String> refusal(int status, Map<String, dynamic>? error) async {
        final publisher = GamebaseLibraryBookPublisher(
          dio:
              Dio()
                ..httpClientAdapter = _RawAdapter(status, {
                  'status': 'error',
                  if (error != null) 'error': error,
                }),
          baseUrl: 'https://example.test',
          supabaseUrl: _testAuthUrl,
          accessToken: () => 'session',
        );
        try {
          await publisher.save(
            _folder(),
            const LibraryBookMetadata(
              title: 'Sicilian studies',
              authorCredit: AuthorCredit.other,
            ),
            publish: true,
          );
          return 'no error';
        } on LibraryBookPublicationException catch (e) {
          return e.message;
        }
      }

      expect(
        await refusal(403, {'code': 'taken_down', 'message': 'x'}),
        'ChessEver took this collection down. Ask ChessEver to restore it.',
      );
      expect(
        await refusal(409, {'code': 'empty_collection'}),
        'Add at least one game to this folder before submitting.',
      );
      expect(
        await refusal(422, {'code': 'forbidden_field'}),
        'Add an author credit and a description before submitting.',
      );
      // Why this account may not publish is said as the server says it.
      expect(
        await refusal(403, {
          'code': 'forbidden',
          'message': 'Verify your email before creating a book.',
        }),
        'Verify your email before creating a book.',
      );
      // An over-long or missing reason falls back to the status copy.
      expect(
        await refusal(403, {'code': 'forbidden', 'message': 'x' * 200}),
        'You do not have permission to publish this folder.',
      );
      // An older server refuses the unknown credit key with a bare 400.
      expect(
        await refusal(400, {
          'message': 'Check the book details and try again.',
        }),
        'Crediting someone else is not available here yet. Choose Me for now; your details are still here.',
      );
    },
  );

  // --- Refused games: say which, never "add a game" -------------------------

  GamebaseLibraryBookPublisher rawPublisher(
    int status,
    Map<String, dynamic> body,
  ) => GamebaseLibraryBookPublisher(
    dio: Dio()..httpClientAdapter = _RawAdapter(status, body),
    supabaseUrl: _testAuthUrl,
    baseUrl: 'https://example.test',
    accessToken: () => 'session',
  );

  Future<Object> publishError(
    int status,
    Map<String, dynamic> error, {
    LibraryBookMetadata metadata = const LibraryBookMetadata(title: 'Ulvi'),
  }) async {
    try {
      await rawPublisher(status, {
        'status': 'error',
        'error': error,
      }).save(_folder(), metadata, publish: true);
      return 'no error';
    } catch (error) {
      return error;
    }
  }

  test(
    'a refused game is named with its reason, not called an empty folder',
    () async {
      final error = await publishError(422, {
        'code': 'invalid_collection_games',
        'message': 'One or more games could not be prepared for publishing.',
        'invalidGameCount': 1,
        'games': [
          {
            'label': 'Steinitz - Von Bardeleben, Hastings 1895',
            'reason': 'Illegal move 25... Rxh7+',
          },
        ],
      });
      expect(error, isA<LibraryBookInvalidGames>());
      final refused = error as LibraryBookInvalidGames;
      expect(refused.count, 1);
      expect(
        refused.games.single.label,
        'Steinitz - Von Bardeleben, Hastings 1895',
      );
      expect(
        refused.message,
        '1 game in this folder could not be prepared for publishing.\n'
        '\u2022 Steinitz - Von Bardeleben, Hastings 1895: Illegal move 25... Rxh7+\n'
        'Fix it in the folder, then submit again. The collection is unchanged.',
      );
      expect(refused.message, isNot(contains('at least one game')));
    },
  );

  test('more refused games than the server named are counted', () async {
    final error =
        await publishError(422, {
              'code': 'invalid_collection_games',
              'invalidGameCount': 7,
              'games': [
                {'label': 'Game 3', 'reason': 'Illegal move 12. Nf6'},
                {'label': 'Game 9', 'reason': ''},
              ],
            })
            as LibraryBookInvalidGames;
    expect(error.count, 7);
    expect(
      error.message,
      '7 games in this folder could not be prepared for publishing.\n'
      '\u2022 Game 3: Illegal move 12. Nf6\n'
      '\u2022 Game 9\n'
      '\u2022 and 5 more\n'
      'Fix them in the folder, then submit again. The collection is unchanged.',
    );
  });

  test('a refusal that names no games never invents a count', () async {
    final error =
        await publishError(422, {
              'code': 'invalid_collection_games',
              'message': 'One or more games could not be prepared.',
            })
            as LibraryBookInvalidGames;
    expect(error.count, 0);
    expect(
      error.message,
      'Some games in this folder could not be prepared for publishing.\n'
      'Fix them in the folder, then submit again. The collection is unchanged.',
    );
  });

  test('an uncoded 422 says what the server said', () async {
    // What the server answers before it names the games.
    const said =
        'The folder contains invalid or empty games. Fix them before submitting; the previous book is unchanged.';
    final error = await publishError(422, {'message': said});
    expect((error as LibraryBookPublicationException).message, said);
    // No words from the server: still never "add at least one game".
    final silent = await publishError(422, {});
    expect(
      (silent as LibraryBookPublicationException).message,
      'Could not prepare this collection for publishing. Check the details or retry. Your existing collection is unchanged.',
    );
  });

  // --- Several authors -----------------------------------------------------

  test('one author never sends the author list', () {
    const metadata = LibraryBookMetadata(title: 'Book', author: 'Vasif');
    expect(metadata.toJson().containsKey('authors'), isFalse);
    expect(metadata.authors, [const BookAuthor(name: 'Vasif')]);
  });

  test('several authors send every name in order, without photos', () {
    const metadata = LibraryBookMetadata(
      title: 'Book',
      author: ' Aleksandar Colovic ',
      authorPhotoUrl: 'https://media.example.invalid/a.webp',
      coAuthors: [
        BookAuthor(name: 'Vasif Durarbayli', photoUrl: 'https://x.invalid/b'),
        BookAuthor(name: '  '),
      ],
      sendAuthorList: true,
    );
    expect(metadata.toJson()['authors'], [
      {'name': 'Aleksandar Colovic'},
      {'name': 'Vasif Durarbayli'},
    ]);
    expect(metadata.toJson()['author'], 'Aleksandar Colovic');
  });

  test('nobody left to credit clears the credit without an empty list', () {
    // The saved book had two authors; every name was removed.
    const metadata = LibraryBookMetadata(title: 'Book', sendAuthorList: true);
    final body = metadata.toJson();
    expect(body.containsKey('authors'), isFalse);
    expect(body['author'], isNull);
  });

  test('a refused author list is said in words', () async {
    final error = await publishError(400, {
      'code': 'invalid_authors',
      'message':
          'List 1 to 6 authors, each named once in at most 80 characters.',
    });
    expect(
      (error as LibraryBookPublicationException).message,
      'Check the authors: up to 6, each named once.',
    );
  });

  test('a book with an author list reads its first author from the list', () {
    final metadata = LibraryBookMetadata.fromJson({
      'title': 'Book',
      // The legacy field is every name joined, for old clients.
      'author': 'Aleksandar Colovic and Vasif Durarbayli',
      'authorPhotoUrl': 'https://media.example.invalid/first.webp',
      'authors': [
        {
          'name': 'Aleksandar Colovic',
          'photoUrl': 'https://media.example.invalid/first.webp',
        },
        {'name': 'Vasif Durarbayli', 'photoUrl': null},
      ],
    });
    expect(metadata.author, 'Aleksandar Colovic');
    expect(metadata.authorPhotoUrl, 'https://media.example.invalid/first.webp');
    expect(metadata.coAuthors, [const BookAuthor(name: 'Vasif Durarbayli')]);
    expect(metadata.sendAuthorList, isTrue);
    // A server that predates the list: the single author field stands.
    final legacy = LibraryBookMetadata.fromJson({
      'title': 'Book',
      'author': 'GM Colovic',
    });
    expect(legacy.author, 'GM Colovic');
    expect(legacy.coAuthors, isEmpty);
    expect(legacy.sendAuthorList, isFalse);
  });

  test('authors read as one credit line', () {
    expect(bookAuthorCredit(const []), '');
    expect(bookAuthorCredit(const ['A', ' ']), 'A');
    expect(bookAuthorCredit(const ['A', 'B']), 'A and B');
    expect(bookAuthorCredit(const ['A', 'B', 'C']), 'A, B and C');
  });

  test(
    'a co-author photo names its place; the first author sends none',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final publisher = GamebaseLibraryBookPublisher(
        dio: dio,
        supabaseUrl: _testAuthUrl,
        baseUrl: 'https://example.test',
        accessToken: () => 'session',
      );
      await publisher.uploadAuthorPhoto(_folder(), Uint8List.fromList([1]));
      expect(adapter.requests.last.uri.hasQuery, isFalse);
      await publisher.uploadAuthorPhoto(
        _folder(),
        Uint8List.fromList([1]),
        index: 2,
      );
      expect(adapter.requests.last.uri.queryParameters, {'index': '2'});
      expect(adapter.requests.last.method, 'POST');
      await publisher.removeAuthorPhoto(_folder(), index: 1);
      expect(adapter.requests.last.uri.queryParameters, {'index': '1'});
      expect(adapter.requests.last.method, 'DELETE');
      dio.close();
    },
  );

  test('an older server refusing the author list says so', () async {
    final error = await publishError(
      400,
      {'message': 'Unrecognized key(s) in object'},
      metadata: const LibraryBookMetadata(
        title: 'Book',
        author: 'A',
        coAuthors: [BookAuthor(name: 'B')],
        sendAuthorList: true,
      ),
    );
    expect(
      (error as LibraryBookPublicationException).message,
      'Crediting several authors is not available here yet. Keep one author for now; your details are still here.',
    );
  });

  test(
    'someone else plus several authors blames the list, not the credit',
    () async {
      final error = await publishError(
        400,
        {'message': 'Unrecognized key(s) in object'},
        metadata: const LibraryBookMetadata(
          title: 'Book',
          author: 'A',
          authorCredit: AuthorCredit.other,
          coAuthors: [BookAuthor(name: 'B')],
          sendAuthorList: true,
        ),
      );
      expect(
        (error as LibraryBookPublicationException).message,
        'Crediting several authors is not available here yet. Keep one author for now; your details are still here.',
      );
    },
  );
}

/// Returns a configurable authors payload for suggestion tests.
class _SuggestAdapter implements HttpClientAdapter {
  _SuggestAdapter({required this.items});
  final List<Map<String, dynamic>> items;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'status': 'success',
        'data': {'items': items},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every request with one status and body, as an upstream or the
/// proxy in front of it would.
class _RawAdapter implements HttpClientAdapter {
  _RawAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
