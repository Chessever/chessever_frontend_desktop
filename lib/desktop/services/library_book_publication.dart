import 'package:dio/dio.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

const _testSupabaseHost = 'odmekzlfunfocvedqusl.supabase.co';

/// Link sharing and catalog publication are independent. A share token alone
/// never makes a folder a public book.
bool libraryFolderCanPublish(LibraryFolder folder) =>
    !folder.isSubscribed &&
    !folder.isLikedGames &&
    !folder.isPermanentLibraryFolder &&
    folder.id != kTwicBookId;

class LibraryBookMetadata {
  const LibraryBookMetadata({
    required this.title,
    this.subtitle = '',
    this.author = '',
    this.about = '',
    this.foreword = '',
    this.publisher = '',
    this.publishedYear,
    this.coverUrl = '',
  });

  final String title;
  final String subtitle;
  final String author;
  final String about;
  final String foreword;
  final String publisher;
  final int? publishedYear;
  final String coverUrl;

  factory LibraryBookMetadata.fromJson(Map<String, dynamic> json) =>
      LibraryBookMetadata(
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String? ?? '',
        author: json['author'] as String? ?? '',
        about: json['about'] as String? ?? '',
        foreword: json['foreword'] as String? ?? '',
        publisher: json['publisher'] as String? ?? '',
        publishedYear: (json['publishedYear'] as num?)?.toInt(),
        coverUrl: json['coverUrl'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'title': title.trim(),
    'subtitle': _nullable(subtitle),
    'author': _nullable(author),
    'about': _nullable(about),
    'foreword': _nullable(foreword),
    'publisher': _nullable(publisher),
    'publishedYear': publishedYear,
    'coverUrl': _nullable(coverUrl),
  };

  static String? _nullable(String value) =>
      value.trim().isEmpty ? null : value.trim();
}

class LibraryBookPublication {
  const LibraryBookPublication({
    required this.status,
    required this.metadata,
    this.bookId,
    this.gameCount = 0,
  });

  final String status;
  final LibraryBookMetadata metadata;
  final String? bookId;
  final int gameCount;
  bool get isPublished => status == 'published';

  factory LibraryBookPublication.fromJson(
    Map<String, dynamic> json, {
    required String fallbackTitle,
  }) {
    final status = json['status'];
    if (!const {
      'unpublished',
      'draft',
      'published',
      'archived',
    }.contains(status)) {
      throw const FormatException('Unknown book publication state');
    }
    final rawBook = json['book'];
    final book = rawBook is Map ? Map<String, dynamic>.from(rawBook) : null;
    return LibraryBookPublication(
      status: status as String,
      metadata:
          book == null
              ? LibraryBookMetadata(title: fallbackTitle)
              : LibraryBookMetadata.fromJson(book),
      bookId: book?['id'] as String?,
      gameCount: (book?['gameCount'] as num?)?.toInt() ?? 0,
    );
  }
}

abstract class LibraryBookPublisher {
  bool get isConfigured;
  Future<LibraryBookPublication> load(LibraryFolder folder);
  Future<LibraryBookPublication> save(
    LibraryFolder folder,
    LibraryBookMetadata metadata, {
    bool publish = false,
    bool refreshGames = false,
  });
  Future<LibraryBookPublication> unpublish(LibraryFolder folder);
  Future<void> unpublishTree(LibraryFolder folder);

  /// The collection's own cover (shown in collection cards), never the
  /// profile photo. [image] is a prepared 2:3 image; the book's details must
  /// have been saved once.
  Future<LibraryBookPublication> uploadCover(
    LibraryFolder folder,
    Uint8List image,
  );
  Future<LibraryBookPublication> removeCover(LibraryFolder folder);
}

class LibraryBookPublicationException implements Exception {
  const LibraryBookPublicationException(this.message);
  final String message;
}

/// Uses the configured authenticated proxy. Upstream API keys stay on the
/// server; there is no fallback endpoint or anonymous publication request.
class GamebaseLibraryBookPublisher implements LibraryBookPublisher {
  GamebaseLibraryBookPublisher({
    required Dio dio,
    required String? baseUrl,
    required String? supabaseUrl,
    required String? Function() accessToken,
    String? anonKey,
  }) : _dio = dio,
       _baseUrl = baseUrl?.trim().replaceFirst(RegExp(r'/+$'), ''),
       _supabaseUrl = supabaseUrl,
       _accessToken = accessToken,
       _anonKey = anonKey;

  final Dio _dio;
  final String? _baseUrl;
  final String? _supabaseUrl;
  final String? Function() _accessToken;
  final String? _anonKey;

  @override
  // Keep invalid-but-present configuration enabled for deletion checks: an
  // unsafe endpoint must block withdrawal, never silently skip it.
  bool get isConfigured => _baseUrl != null && _baseUrl.isNotEmpty;

  bool get _hasSafeTestConfiguration {
    final auth = Uri.tryParse(_supabaseUrl?.trim() ?? '');
    if (auth == null ||
        auth.scheme != 'https' ||
        auth.host != _testSupabaseHost ||
        auth.port != 443 ||
        (auth.path.isNotEmpty && auth.path != '/') ||
        auth.userInfo.isNotEmpty ||
        auth.hasQuery ||
        auth.hasFragment) {
      return false;
    }
    final endpoint = Uri.tryParse(_baseUrl ?? '');
    if (endpoint == null ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      return false;
    }
    final host = endpoint.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    final loopback = const {'localhost', '127.0.0.1', '::1'}.contains(host);
    if (endpoint.scheme != 'https' &&
        !(endpoint.scheme == 'http' && loopback)) {
      return false;
    }
    return host != 'chessever.com' &&
        !host.endsWith('.chessever.com') &&
        !host.contains('oelbsuggrzyqwzmvidju') &&
        (!(host == 'supabase.co' || host.endsWith('.supabase.co')) ||
            host == _testSupabaseHost);
  }

  @override
  Future<LibraryBookPublication> load(LibraryFolder folder) =>
      _request(folder, 'GET');

  @override
  Future<LibraryBookPublication> save(
    LibraryFolder folder,
    LibraryBookMetadata metadata, {
    bool publish = false,
    bool refreshGames = false,
  }) => _request(
    folder,
    'PUT',
    body: {
      ...metadata.toJson(),
      if (publish) 'publish': true,
      if (refreshGames) 'refreshGames': true,
    },
  );

  @override
  Future<LibraryBookPublication> unpublish(LibraryFolder folder) =>
      _request(folder, 'DELETE');

  @override
  Future<void> unpublishTree(LibraryFolder folder) async {
    await _request(folder, 'DELETE', query: {'includeDescendants': true});
  }

  @override
  Future<LibraryBookPublication> uploadCover(
    LibraryFolder folder,
    Uint8List image,
  ) => _request(
    folder,
    'POST',
    resource: 'book/cover',
    body: {'image': base64Encode(image)},
  );

  @override
  Future<LibraryBookPublication> removeCover(LibraryFolder folder) =>
      _request(folder, 'DELETE', resource: 'book/cover');

  Future<LibraryBookPublication> _request(
    LibraryFolder folder,
    String method, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    String resource = 'book',
  }) async {
    if (!libraryFolderCanPublish(folder)) {
      throw const LibraryBookPublicationException(
        'Only your own folders and databases can become books.',
      );
    }
    final base = _baseUrl;
    if (base == null || base.isEmpty) {
      throw const LibraryBookPublicationException(
        'Book publishing is not configured for this app.',
      );
    }
    if (!_hasSafeTestConfiguration) {
      throw const LibraryBookPublicationException(
        'Book publishing requires the test account environment and a safe test proxy URL.',
      );
    }
    final token = _accessToken();
    if (token == null || token.isEmpty) {
      throw const LibraryBookPublicationException('Sign in to publish a book.');
    }
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        '$base/api/library/folders/${Uri.encodeComponent(folder.id)}/$resource',
        data: body,
        queryParameters: query,
        options: Options(
          method: method,
          followRedirects: false,
          maxRedirects: 0,
          headers: {
            'Authorization': 'Bearer $token',
            if (_anonKey != null && _anonKey.isNotEmpty) 'apikey': _anonKey,
            'Accept': 'application/json',
          },
        ),
      );
      final data = response.data?['data'];
      if (data is! Map) throw const FormatException('Missing publication');
      return LibraryBookPublication.fromJson(
        Map<String, dynamic>.from(data),
        fallbackTitle: folder.name,
      );
    } on DioException catch (error) {
      final payload = error.response?.data;
      final details = payload is Map ? payload['error'] : null;
      if (resource == 'book/cover') {
        throw LibraryBookPublicationException(switch (details is Map
            ? details['code']
            : null) {
          'cover_type' => 'Use a JPEG, PNG or WebP image.',
          'cover_animated' => 'Use a still image, not an animation.',
          'cover_aspect' => 'The cover must be a 2:3 portrait.',
          'cover_too_small' => 'Use an image at least 600 × 900 pixels.',
          'bad_base64' => 'This image could not be read. Choose another one.',
          'cover_unavailable' =>
            'Cover uploads are unavailable right now. Try again shortly.',
          'taken_down' =>
            'ChessEver took this collection down. Ask ChessEver to restore it.',
          _ => switch (error.response?.statusCode) {
            401 => 'Your session expired. Sign in again to continue.',
            403 => 'You do not have permission to change this cover.',
            409 => 'Save the collection details, then add the cover.',
            413 => 'This image is too large. Choose one under 8 MB.',
            404 || 503 => 'Cover uploads are not available here yet.',
            _ => 'Could not save the cover. Retry when connected.',
          },
        });
      }
      if (details is Map && details['code'] == 'publication_deleting') {
        throw const LibraryBookPublicationException(
          'This folder has a pending deletion. Retry deleting it to finish.',
        );
      }
      final message = switch (error.response?.statusCode) {
        401 => 'Your session expired. Sign in again to continue.',
        403 => 'You do not have permission to publish this folder.',
        404 ||
        503 => 'Book publishing is not available in this environment yet.',
        409 =>
          query?['includeDescendants'] == true
              ? 'A book in this folder is being saved. Wait, then retry deleting the folder.'
              : 'This book is already being processed. Wait a moment and retry.',
        413 =>
          'Publish at most 1,000 games and 10 MB at a time. Move a smaller set into a folder.',
        400 || 422 =>
          'Check the book details and add at least one game before publishing.',
        _ =>
          'Could not update the book. Your entered details are still here. Retry when connected.',
      };
      throw LibraryBookPublicationException(message);
    }
  }
}

/// Withdraw every public book in the source subtree before removing its owner
/// mapping. A failed withdrawal leaves the private folder recoverable.
Future<void> deleteLibraryFolderWithPublications({
  required LibraryFolder folder,
  required LibraryBookPublisher publisher,
  required String? supabaseUrl,
  required Future<void> Function(String folderId) deleteFolder,
}) async {
  // Another client may already have published this source. Test accounts must
  // withdraw even when this installation has no publishing endpoint configured.
  final testAccount =
      Uri.tryParse(supabaseUrl?.trim() ?? '')?.host == _testSupabaseHost;
  if (publisher.isConfigured || testAccount) {
    await publisher.unpublishTree(folder);
  }
  await deleteFolder(folder.id);
}

final libraryBookPublisherProvider = Provider<LibraryBookPublisher>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );
  ref.onDispose(() => dio.close());
  return GamebaseLibraryBookPublisher(
    dio: dio,
    baseUrl: DesktopEnv.maybeGet('LIBRARY_BOOK_PUBLISHING_BASE'),
    supabaseUrl: DesktopEnv.maybeGet('SUPABASE_URL'),
    accessToken:
        () => Supabase.instance.client.auth.currentSession?.accessToken,
    anonKey: DesktopEnv.maybeGet('SUPABASE_ANON_KEY'),
  );
});
