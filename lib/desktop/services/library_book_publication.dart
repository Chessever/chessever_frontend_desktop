import 'package:dio/dio.dart';
import 'package:chessever/desktop/services/library_book_failure_message.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

const _testSupabaseHost = 'odmekzlfunfocvedqusl.supabase.co';
const _productionSupabaseHost = 'oelbsuggrzyqwzmvidju.supabase.co';

/// Where a draft stands with ChessEver staff. A submission is not a status:
/// the book stays a draft, [pending] while it waits and [changesRequested]
/// once staff send it back with a note.
enum LibraryBookReviewState { none, pending, changesRequested }

/// The review round of a draft, as the server answers it. Servers that
/// predate reviews omit it; that reads as [none].
class LibraryBookReview {
  const LibraryBookReview({
    this.state = LibraryBookReviewState.none,
    this.submittedAt,
    this.note = '',
    this.decidedAt,
  });

  static const none = LibraryBookReview();

  final LibraryBookReviewState state;

  /// When it was last submitted; null unless it is pending.
  final DateTime? submittedAt;

  /// What staff asked to change; empty unless it was sent back.
  final String note;

  /// When staff sent it back; null unless it was sent back.
  final DateTime? decidedAt;

  factory LibraryBookReview.fromJson(Object? raw) {
    if (raw is! Map) return none;
    DateTime? when(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toLocal() : null;
    final note = raw['note'];
    return switch (raw['state']) {
      'pending' => LibraryBookReview(
        state: LibraryBookReviewState.pending,
        submittedAt: when(raw['submittedAt']),
      ),
      // Sent back without a note is not a state the author could act on.
      'changes_requested' when note is String && note.trim().isNotEmpty =>
        LibraryBookReview(
          state: LibraryBookReviewState.changesRequested,
          // The server caps a note at 1,000 characters; never trust that
          // with the dialog's layout.
          note:
              note.trim().length > 1000
                  ? '${note.trim().substring(0, 1000)}…'
                  : note.trim(),
          decidedAt: when(raw['decidedAt']),
        ),
      _ => none,
    };
  }
}

/// Where a collection is on its way to readers. Derived, never stored: the
/// publication status plus, for a draft, its review round.
enum LibraryBookStage {
  /// Private, and not waiting on anyone.
  draft,

  /// Private, waiting for a ChessEver decision.
  inReview,

  /// Private again: staff sent it back with a note.
  changesRequested,

  /// Public in Collections.
  live,

  /// Archived by ChessEver; the owner cannot change it.
  takenDown,
}

/// Who a collection is credited to. [self] is the publishing account (the
/// server shows that account's profile photo); [other] credits a named author
/// with their own, separate photo. Old servers omit the field entirely, which
/// means [self] — see [LibraryBookMetadata.authorCredit] for the send rule.
enum AuthorCredit {
  self,
  other;

  static AuthorCredit? maybeParse(Object? raw) => switch (raw) {
    'self' => AuthorCredit.self,
    'other' => AuthorCredit.other,
    _ => null,
  };

  String get wire => name;
}

/// One existing published-author match returned by the author directory. The
/// id groups a person's collections together across ChessEver.
class AuthorSuggestion {
  const AuthorSuggestion({
    required this.id,
    required this.name,
    this.bookCount = 0,
    this.avatarUrl,
  });

  final String id;
  final String name;
  final int bookCount;
  final String? avatarUrl;

  factory AuthorSuggestion.fromJson(Map<String, dynamic> json) =>
      AuthorSuggestion(
        id: json['id'] as String? ?? '',
        name: (json['name'] as String? ?? '').trim(),
        bookCount: (json['bookCount'] as num?)?.toInt() ?? 0,
        avatarUrl: _httpsOrNull(json['avatarUrl']),
      );

  static String? _httpsOrNull(Object? raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri.toString();
  }
}

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
    this.authorCredit,
    this.authorPhotoUrl = '',
  });

  final String title;
  final String subtitle;
  final String author;
  final String about;
  final String foreword;
  final String publisher;
  final int? publishedYear;
  final String coverUrl;

  /// null means the key is absent from the save body entirely — the only safe
  /// value for an old server that rejects unknown keys with 400, and for a new
  /// book that never left "Me". [AuthorCredit.self]/[AuthorCredit.other] are
  /// sent verbatim: "other" when the user credited someone else, "self" (which
  /// also tells the server to drop any credited photo) when a book that
  /// already carried the key is switched back to Me.
  final AuthorCredit? authorCredit;

  /// The credited author's own photo, distinct from the cover and from the
  /// publishing account's profile photo. Empty when none is set.
  final String authorPhotoUrl;

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
        // A present key (even an unrecognised value, which parses to self via
        // the caller) is what [LibraryBookPublication.hadAuthorCreditKey]
        // records; the typed value here is only the known states.
        authorCredit: AuthorCredit.maybeParse(json['authorCredit']),
        authorPhotoUrl: json['authorPhotoUrl'] as String? ?? '',
      );

  LibraryBookMetadata copyWith({
    String? author,
    AuthorCredit? authorCredit,
    bool clearAuthorCredit = false,
    String? authorPhotoUrl,
  }) => LibraryBookMetadata(
    title: title,
    subtitle: subtitle,
    author: author ?? this.author,
    about: about,
    foreword: foreword,
    publisher: publisher,
    publishedYear: publishedYear,
    coverUrl: coverUrl,
    authorCredit:
        clearAuthorCredit ? null : (authorCredit ?? this.authorCredit),
    authorPhotoUrl: authorPhotoUrl ?? this.authorPhotoUrl,
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
    // Omit the key unless it must travel: old servers 400 on unknown keys, so
    // a new "Me" book sends nothing. authorPhotoUrl is never written here — it
    // is only ever changed through the author-photo upload/remove endpoints.
    if (authorCredit != null) 'authorCredit': authorCredit!.wire,
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
    this.hadAuthorCreditKey = false,
    this.review = LibraryBookReview.none,
  });

  final String status;
  final LibraryBookMetadata metadata;
  final String? bookId;
  final int gameCount;

  /// Whether the loaded book JSON carried an `authorCredit` key at all (any
  /// value, even one this client does not recognise). Once a book has the key,
  /// a save must keep sending it, so the editor seeds its send rule from this.
  final bool hadAuthorCreditKey;

  /// The draft's review round. Only a draft can be in review.
  final LibraryBookReview review;
  bool get isPublished => status == 'published';

  LibraryBookStage get stage => switch (status) {
    'published' => LibraryBookStage.live,
    'archived' => LibraryBookStage.takenDown,
    _ => switch (review.state) {
      LibraryBookReviewState.pending => LibraryBookStage.inReview,
      LibraryBookReviewState.changesRequested =>
        LibraryBookStage.changesRequested,
      LibraryBookReviewState.none => LibraryBookStage.draft,
    },
  };

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
      hadAuthorCreditKey: book?.containsKey('authorCredit') ?? false,
      // A stale review on anything but a draft is ignored, as the server does.
      review:
          status == 'draft'
              ? LibraryBookReview.fromJson(book?['review'])
              : LibraryBookReview.none,
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

  /// The credited author's own square photo (shown with their name in
  /// Collections), distinct from the cover and the profile photo. [image] is a
  /// prepared square image; the book's details must have been saved once.
  /// Uploading sets the credit to "other" server-side.
  Future<LibraryBookPublication> uploadAuthorPhoto(
    LibraryFolder folder,
    Uint8List image,
  );
  Future<LibraryBookPublication> removeAuthorPhoto(LibraryFolder folder);

  /// Existing published ChessEver authors whose name matches [name], so one
  /// person's collections stay grouped. Any failure (old server, network)
  /// resolves to an empty list rather than throwing — suggestions are an
  /// optional aid, never a blocker.
  Future<List<AuthorSuggestion>> suggestAuthors(String name);
}

class LibraryBookPublicationException implements Exception {
  const LibraryBookPublicationException(this.message);
  final String message;
}

/// The proxy in front of gamebase does not carry book publishing yet: an edge
/// function deployed before these routes existed answers `route_not_allowed`
/// (or `method_not_allowed` for PUT and DELETE) instead of forwarding.
class LibraryBookPublishingUnavailable extends LibraryBookPublicationException {
  const LibraryBookPublishingUnavailable()
    : super('Book publishing is not available here yet.');
}

/// Uses an authenticated proxy. Upstream API keys stay on the server; there
/// is no fallback endpoint or anonymous publication request.
///
/// Which proxy depends on the account's project, and the two never mix:
/// - a production account goes through [productionBaseUrl], the gamebase
///   proxy edge function, which injects the upstream key and forwards the
///   member's own token so the server can tell whose folder it is;
/// - a test account goes through [baseUrl], an explicitly configured test
///   proxy that may never point at production.
class GamebaseLibraryBookPublisher implements LibraryBookPublisher {
  GamebaseLibraryBookPublisher({
    required Dio dio,
    required String? baseUrl,
    required String? supabaseUrl,
    required String? Function() accessToken,
    String? anonKey,
    String? productionBaseUrl,
  }) : _dio = dio,
       _baseUrl = baseUrl?.trim().replaceFirst(RegExp(r'/+$'), ''),
       _productionBaseUrl = productionBaseUrl?.trim().replaceFirst(
         RegExp(r'/+$'),
         '',
       ),
       _supabaseUrl = supabaseUrl,
       _accessToken = accessToken,
       _anonKey = anonKey;

  final Dio _dio;
  final String? _baseUrl;
  final String? _productionBaseUrl;
  final String? _supabaseUrl;
  final String? Function() _accessToken;
  final String? _anonKey;

  @override
  // Keep invalid-but-present configuration enabled for deletion checks: an
  // unsafe test endpoint must block withdrawal, never silently skip it. A
  // production account always has a proxy it may use (its own project's).
  bool get isConfigured =>
      _isProductionAccount || (_baseUrl != null && _baseUrl.isNotEmpty);

  /// Signed in to the production project, over a plain https origin.
  bool get _isProductionAccount => _isProjectOrigin(_productionSupabaseHost);

  bool _isProjectOrigin(String host) {
    final auth = Uri.tryParse(_supabaseUrl?.trim() ?? '');
    return auth != null &&
        auth.scheme == 'https' &&
        auth.host == host &&
        auth.port == 443 &&
        (auth.path.isEmpty || auth.path == '/') &&
        auth.userInfo.isEmpty &&
        !auth.hasQuery &&
        !auth.hasFragment;
  }

  /// A production proxy carries a member's production token, so it is only
  /// ever the project's own functions host or a chessever.com host, over
  /// https, with nothing smuggled into the URL.
  static bool _mayCarryProductionToken(String? base) {
    final endpoint = Uri.tryParse(base ?? '');
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      return false;
    }
    final host = endpoint.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    return host == _productionSupabaseHost ||
        host == 'chessever.com' ||
        host.endsWith('.chessever.com');
  }

  /// Where a production account publishes. A configured proxy on any other
  /// host is passed over for the project's own function, which is always
  /// allowed: refusing instead would make every folder delete fail on a build
  /// whose read proxy happens to live elsewhere.
  String get _productionBase {
    final configured = _productionBaseUrl;
    if (configured != null && _mayCarryProductionToken(configured)) {
      return configured;
    }
    return 'https://$_productionSupabaseHost/functions/v1/gamebase-proxy';
  }

  /// The endpoint requests go to, or null when this build must not publish.
  String? get _safeBase {
    if (_isProductionAccount) return _productionBase;
    return _hasSafeTestConfiguration ? _baseUrl : null;
  }

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
    try {
      // Deleting a folder waits on this, with nothing on screen but the
      // folder: a minute is long enough to withdraw and short enough to say
      // so when the server is not answering.
      await _request(
        folder,
        'DELETE',
        query: {'includeDescendants': true},
        receiveTimeout: const Duration(seconds: 60),
      );
    } on LibraryBookPublishingUnavailable {
      // A production proxy that cannot publish cannot have published from
      // this app either, and deleting a folder worked before publishing
      // existed here: do not start refusing it. A test proxy stays strict.
      if (!_isProductionAccount) rethrow;
    }
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

  @override
  Future<LibraryBookPublication> uploadAuthorPhoto(
    LibraryFolder folder,
    Uint8List image,
  ) => _request(
    folder,
    'POST',
    resource: 'book/author-photo',
    body: {'image': base64Encode(image)},
  );

  @override
  Future<LibraryBookPublication> removeAuthorPhoto(LibraryFolder folder) =>
      _request(folder, 'DELETE', resource: 'book/author-photo');

  @override
  Future<List<AuthorSuggestion>> suggestAuthors(String name) async {
    final query = name.trim();
    // The directory expects 1–60 chars; anything outside that, an unconfigured
    // or unsafe environment, or no session simply yields no suggestions.
    final base = _safeBase;
    // The session is only read once there is a safe place to send it.
    if (query.isEmpty || query.length > 60 || base == null || base.isEmpty) {
      return const [];
    }
    final token = _accessToken();
    if (token == null || token.isEmpty) return const [];
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/api/library/authors',
        queryParameters: {'name': query, 'limit': 6},
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          headers: {
            'Authorization': 'Bearer $token',
            if (_anonKey != null && _anonKey.isNotEmpty) 'apikey': _anonKey,
            'Accept': 'application/json',
          },
        ),
      );
      final items = response.data?['data']?['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map(
            (raw) => AuthorSuggestion.fromJson(Map<String, dynamic>.from(raw)),
          )
          .where((author) => author.id.isNotEmpty && author.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // 404 on old servers, network errors, malformed JSON: no suggestions,
      // silently. Author matching is an aid, never a gate.
      return const [];
    }
  }

  Future<LibraryBookPublication> _request(
    LibraryFolder folder,
    String method, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    String resource = 'book',
    Duration? receiveTimeout,
  }) async {
    if (!libraryFolderCanPublish(folder)) {
      throw const LibraryBookPublicationException(
        'Only your own folders and databases can become books.',
      );
    }
    if (!isConfigured) {
      throw const LibraryBookPublicationException(
        'Book publishing is not configured for this app.',
      );
    }
    final base = _safeBase;
    if (base == null) {
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
          receiveTimeout: receiveTimeout,
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
      if (details == 'route_not_allowed' || details == 'method_not_allowed') {
        throw const LibraryBookPublishingUnavailable();
      }
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
      if (resource == 'book/author-photo') {
        throw LibraryBookPublicationException(switch (details is Map
            ? details['code']
            : null) {
          'author_photo_type' => 'Use a JPEG, PNG or WebP image.',
          'author_photo_animated' => 'Use a still image, not an animation.',
          'author_photo_aspect' => 'Crop the photo to a square.',
          'author_photo_too_small' =>
            'Use an image at least 256 by 256 pixels.',
          'author_photo_unavailable' =>
            'Author photo uploads are not available here yet.',
          // too_large / bad_base64 reuse the cover equivalents.
          'bad_base64' => 'This image could not be read. Choose another one.',
          'too_large' => 'This image is too large. Choose one under 8 MB.',
          'publication_unavailable' =>
            'Save the collection details, then add the author photo.',
          'taken_down' =>
            'ChessEver took this collection down. Ask ChessEver to restore it.',
          _ => switch (error.response?.statusCode) {
            401 => 'Your session expired. Sign in again to continue.',
            403 => 'You do not have permission to change this author photo.',
            409 => 'Save the collection details, then add the author photo.',
            413 => 'This image is too large. Choose one under 8 MB.',
            404 ||
            405 ||
            503 => 'Author photo uploads are not available here yet.',
            _ => 'Could not save the author photo. Retry when connected.',
          },
        });
      }
      // An older server refuses the unknown credit key with a bare 400.
      if (resource == 'book' &&
          method == 'PUT' &&
          body?['authorCredit'] == 'other' &&
          error.response?.statusCode == 400 &&
          (details is! Map || details['code'] == null)) {
        throw const LibraryBookPublicationException(
          'Crediting someone else is not available here yet. Choose Me for now; your details are still here.',
        );
      }
      if (details is Map && details['code'] == 'publication_deleting') {
        throw const LibraryBookPublicationException(
          'This folder has a pending deletion. Retry deleting it to finish.',
        );
      }
      final code = details is Map ? details['code'] : null;
      // Why the server refused, when it said so in words an author can act on.
      final said = details is Map ? details['message'] : null;
      final refusal =
          code == 'forbidden' &&
                  said is String &&
                  said.trim().isNotEmpty &&
                  said.length <= 160
              ? said.trim()
              : null;
      final named = switch (code) {
        'taken_down' =>
          'ChessEver took this collection down. Ask ChessEver to restore it.',
        'empty_collection' =>
          'Add at least one game to this folder before submitting.',
        // The server's code for missing details on a submission.
        'forbidden_field' =>
          'Add an author credit and a description before submitting.',
        _ => refusal,
      };
      if (named != null) throw LibraryBookPublicationException(named);
      final snapshotFailure = libraryBookSnapshotFailureMessage(
        details,
        error.response?.statusCode,
      );
      if (snapshotFailure != null) {
        throw LibraryBookPublicationException(snapshotFailure);
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
        400 || 422 => 'Could not prepare this collection for publishing.',
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
  // A folder that can never become a book (subscribed, liked games) has no
  // publication to withdraw, and asking would refuse the delete.
  if (libraryFolderCanPublish(folder) &&
      (publisher.isConfigured || testAccount)) {
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
  final supabaseUrl = DesktopEnv.maybeGet('SUPABASE_URL')?.trim() ?? '';
  final proxy = DesktopEnv.maybeGet('GAMEBASE_PROXY_BASE')?.trim() ?? '';
  return GamebaseLibraryBookPublisher(
    dio: dio,
    baseUrl: DesktopEnv.maybeGet('LIBRARY_BOOK_PUBLISHING_BASE'),
    // Production reaches gamebase the way every other desktop call does: the
    // proxy edge function, which holds the upstream key (see
    // supabase/functions/gamebase-proxy). Only a production account uses it.
    productionBaseUrl:
        proxy.isNotEmpty
            ? proxy
            : supabaseUrl.isEmpty
            ? null
            : '${supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/functions/v1/gamebase-proxy',
    supabaseUrl: DesktopEnv.maybeGet('SUPABASE_URL'),
    accessToken:
        () => Supabase.instance.client.auth.currentSession?.accessToken,
    anonKey: DesktopEnv.maybeGet('SUPABASE_ANON_KEY'),
  );
});
