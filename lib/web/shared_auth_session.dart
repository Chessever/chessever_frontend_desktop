// One Supabase session for both addresses of the browser build.
//
// app.chessever.com and chessever.com/webapp are separate browser origins
// (lib/web/web_mount.dart), so each has its own localStorage and, on its own,
// its own sign-in. Both hosts share the registrable domain chessever.com,
// though, and a cookie set with `Domain=chessever.com` is readable from both.
// [SharedAuthSessionStorage] keeps the persisted session in such a cookie, so
// signing in or out at one address is the same at the other, and
// [SharedAuthSessionSync] carries sign-in, sign-out and token refreshes into
// a page that is already open at the other address.
//
// The cookie only ever holds the session the page already keeps in its own
// localStorage (the mirror below), readable by the same scripts. It is
// written by this page's script and is never needed by a server.
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and writes cookies scoped to the shared parent domain.
abstract class SharedAuthCookieJar {
  /// Value of the cookie [name], or null when it is not set.
  String? read(String name);

  /// Sets [name] to [value] (cookie-safe characters only).
  void write(String name, String value);

  /// Removes [name].
  void delete(String name);
}

/// Splits the session into cookies and joins it back.
///
/// `<prefix>` holds the number of parts (`0` after a sign-out, so the other
/// address can tell a sign-out from a cookie that was never written) and
/// `<prefix>.0`, `<prefix>.1`, ... hold the gzip-compressed, base64url-encoded
/// session JSON. Each cookie stays well under the 4096-byte browser limit.
@visibleForTesting
class SharedAuthCookieCodec {
  const SharedAuthCookieCodec({
    this.prefix = 'chessever-app-session',
    this.chunkSize = 3600,
    this.maxChunks = 8,
  });

  final String prefix;
  final int chunkSize;
  final int maxChunks;

  String partName(int index) => '$prefix.$index';

  /// Encoded parts of [sessionJson], or null when it would not fit.
  List<String>? encode(String sessionJson) {
    final zipped = const GZipEncoder().encodeBytes(utf8.encode(sessionJson));
    final text = base64Url.encode(zipped).replaceAll('=', '');
    final parts = <String>[
      for (var i = 0; i < text.length; i += chunkSize)
        text.substring(
          i,
          i + chunkSize > text.length ? text.length : i + chunkSize,
        ),
    ];
    return parts.length > maxChunks ? null : parts;
  }

  /// Writes [sessionJson], or the signed-out marker when it is null.
  /// Returns false when the session is too large to share.
  bool write(SharedAuthCookieJar jar, String? sessionJson) {
    final previous = _count(jar) ?? 0;
    final parts = sessionJson == null ? const <String>[] : encode(sessionJson);
    if (parts == null) return false;
    for (var i = 0; i < parts.length; i++) {
      jar.write(partName(i), parts[i]);
    }
    for (var i = parts.length; i < previous; i++) {
      jar.delete(partName(i));
    }
    jar.write(prefix, '${parts.length}');
    return true;
  }

  /// The shared state: [SharedAuthCookieState.absent] when no address has
  /// written it, `signedOut` after a sign-out, otherwise the session JSON.
  /// A half-written or damaged cookie reads as [SharedAuthCookieState.absent]
  /// so the caller falls back to its own copy instead of signing out.
  SharedAuthCookieState read(SharedAuthCookieJar jar) {
    final count = _count(jar);
    if (count == null || count < 0 || count > maxChunks) {
      return SharedAuthCookieState.absent;
    }
    if (count == 0) return SharedAuthCookieState.signedOut;
    final buffer = StringBuffer();
    for (var i = 0; i < count; i++) {
      final part = jar.read(partName(i));
      if (part == null || part.isEmpty) return SharedAuthCookieState.absent;
      buffer.write(part);
    }
    try {
      final text = base64Url.normalize(buffer.toString());
      final json = utf8.decode(
        const GZipDecoder().decodeBytes(base64Url.decode(text)),
      );
      if (json.isEmpty) return SharedAuthCookieState.absent;
      return SharedAuthCookieState.session(json);
    } catch (_) {
      return SharedAuthCookieState.absent;
    }
  }

  int? _count(SharedAuthCookieJar jar) {
    final raw = jar.read(prefix);
    return raw == null ? null : int.tryParse(raw);
  }
}

/// What the shared cookie says about the session.
@immutable
class SharedAuthCookieState {
  const SharedAuthCookieState._(this.kind, this.sessionJson);

  const SharedAuthCookieState.session(String json)
    : this._(SharedAuthCookieKind.session, json);

  static const absent = SharedAuthCookieState._(
    SharedAuthCookieKind.absent,
    null,
  );
  static const signedOut = SharedAuthCookieState._(
    SharedAuthCookieKind.signedOut,
    null,
  );

  final SharedAuthCookieKind kind;
  final String? sessionJson;

  @override
  bool operator ==(Object other) =>
      other is SharedAuthCookieState &&
      other.kind == kind &&
      other.sessionJson == sessionJson;

  @override
  int get hashCode => Object.hash(kind, sessionJson);
}

enum SharedAuthCookieKind { absent, signedOut, session }

/// Supabase session storage shared between app.chessever.com and
/// chessever.com/webapp.
///
/// The shared cookie decides. [mirror] (this origin's localStorage) keeps a
/// copy, which is used when the cookie is missing: before either address has
/// written it (the first visit after this shipped, which carries an existing
/// sign-in over) and after a browser expired it (Safari caps script-set
/// cookies at seven days).
class SharedAuthSessionStorage extends LocalStorage {
  SharedAuthSessionStorage({
    required this.jar,
    required this.mirror,
    this.codec = const SharedAuthCookieCodec(),
  });

  final SharedAuthCookieJar jar;
  final LocalStorage mirror;
  final SharedAuthCookieCodec codec;

  /// The session this page last read from or wrote to the cookie.
  SharedAuthCookieState get lastShared => _lastShared;
  SharedAuthCookieState _lastShared = SharedAuthCookieState.absent;

  /// Reads the cookie now and remembers it as [lastShared].
  SharedAuthCookieState readShared() => _lastShared = codec.read(jar);

  @override
  Future<void> initialize() => mirror.initialize();

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;

  @override
  Future<String?> accessToken() async {
    final shared = readShared();
    switch (shared.kind) {
      case SharedAuthCookieKind.session:
        return shared.sessionJson;
      case SharedAuthCookieKind.signedOut:
        return null;
      case SharedAuthCookieKind.absent:
        final local = await mirror.accessToken();
        if (local != null) _share(local);
        return local;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    _share(persistSessionString);
    await mirror.persistSession(persistSessionString);
  }

  @override
  Future<void> removePersistedSession() async {
    _share(null);
    await mirror.removePersistedSession();
  }

  void _share(String? sessionJson) {
    if (codec.write(jar, sessionJson)) {
      _lastShared =
          sessionJson == null
              ? SharedAuthCookieState.signedOut
              : SharedAuthCookieState.session(sessionJson);
    }
  }
}

/// Applies a sign-in, sign-out or token refresh made at the other address to
/// this page, which already has the session loaded in memory.
class SharedAuthSessionSync {
  SharedAuthSessionSync({required this.storage, required this.auth});

  final SharedAuthSessionStorage storage;
  final GoTrueClient auth;

  bool _busy = false;

  /// Compares the cookie with what this page last saw and catches up when the
  /// other address changed it. Call it often (it is a cookie read when
  /// nothing changed) and whenever the page becomes visible again, before
  /// Supabase's auto refresh would run with a refresh token the other
  /// address has already used.
  Future<void> check() async {
    if (_busy) return;
    final before = storage.lastShared;
    final now = storage.readShared();
    if (now == before) return;
    _busy = true;
    try {
      switch (now.kind) {
        case SharedAuthCookieKind.absent:
          return;
        case SharedAuthCookieKind.signedOut:
          if (auth.currentSession != null) {
            await auth.signOut(scope: SignOutScope.local);
          }
        case SharedAuthCookieKind.session:
          final json = now.sessionJson!;
          if (_sameTokens(auth.currentSession, json)) return;
          await auth.recoverSession(json);
      }
    } catch (e) {
      debugPrint('[web] shared sign-in sync failed: $e');
    } finally {
      _busy = false;
    }
  }

  static bool _sameTokens(Session? current, String json) {
    if (current == null) return false;
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      return data['refresh_token'] == current.refreshToken &&
          data['access_token'] == current.accessToken;
    } catch (_) {
      return false;
    }
  }
}
