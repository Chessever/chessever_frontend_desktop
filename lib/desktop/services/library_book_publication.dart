import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

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
  Future<LibraryBookPublication> load(LibraryFolder folder);
  Future<LibraryBookPublication> save(
    LibraryFolder folder,
    LibraryBookMetadata metadata, {
    bool publish = false,
    bool refreshGames = false,
  });
  Future<LibraryBookPublication> unpublish(LibraryFolder folder);
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
    required String? Function() accessToken,
    String? anonKey,
  }) : _dio = dio,
       _baseUrl = baseUrl?.replaceFirst(RegExp(r'/+$'), ''),
       _accessToken = accessToken,
       _anonKey = anonKey;

  final Dio _dio;
  final String? _baseUrl;
  final String? Function() _accessToken;
  final String? _anonKey;

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

  Future<LibraryBookPublication> _request(
    LibraryFolder folder,
    String method, {
    Map<String, dynamic>? body,
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
    final token = _accessToken();
    if (token == null || token.isEmpty) {
      throw const LibraryBookPublicationException('Sign in to publish a book.');
    }
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        '$base/api/library/folders/${Uri.encodeComponent(folder.id)}/book',
        data: body,
        options: Options(
          method: method,
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
      final message = switch (error.response?.statusCode) {
        401 => 'Your session expired. Sign in again to continue.',
        403 => 'You do not have permission to publish this folder.',
        404 ||
        503 => 'Book publishing is not available in this environment yet.',
        409 => 'This book is already being processed. Wait a moment and retry.',
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
    accessToken:
        () => Supabase.instance.client.auth.currentSession?.accessToken,
    anonKey: DesktopEnv.maybeGet('SUPABASE_ANON_KEY'),
  );
});
