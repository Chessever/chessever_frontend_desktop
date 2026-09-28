import 'dart:convert';
import 'dart:typed_data';

import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test(
    'missing configuration or sign-in fails without a network request',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      for (final publisher in [
        GamebaseLibraryBookPublisher(
          dio: dio,
          baseUrl: null,
          accessToken: () => 'session',
        ),
        GamebaseLibraryBookPublisher(
          dio: dio,
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
}
