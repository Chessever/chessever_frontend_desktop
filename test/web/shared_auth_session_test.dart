import 'dart:convert';

import 'package:chessever/web/shared_auth_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One cookie jar seen by both addresses, as `Domain=chessever.com` is.
class _Jar implements SharedAuthCookieJar {
  final cookies = <String, String>{};
  @override
  String? read(String name) => cookies[name];
  @override
  void write(String name, String value) {
    expect(value, isNot(contains(';')));
    expect(name.length + value.length, lessThan(4096));
    cookies[name] = value;
  }

  @override
  void delete(String name) => cookies.remove(name);
}

/// An origin's own localStorage.
class _Mirror extends LocalStorage {
  String? value;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => value != null;
  @override
  Future<String?> accessToken() async => value;
  @override
  Future<void> persistSession(String s) async => value = s;
  @override
  Future<void> removePersistedSession() async => value = null;
}

class _Auth extends Mock implements GoTrueClient {}

String _session(String refresh, {int pad = 0}) => jsonEncode({
  'access_token': 'access-$refresh',
  'refresh_token': refresh,
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {'id': 'u1', 'note': 'x' * pad},
});

void main() {
  late _Jar jar;
  late _Mirror appMirror;
  late _Mirror webappMirror;
  late SharedAuthSessionStorage app;
  late SharedAuthSessionStorage webapp;

  setUp(() {
    jar = _Jar();
    appMirror = _Mirror();
    webappMirror = _Mirror();
    app = SharedAuthSessionStorage(jar: jar, mirror: appMirror);
    webapp = SharedAuthSessionStorage(jar: jar, mirror: webappMirror);
  });

  test('a sign-in at one address is the session at the other', () async {
    await app.persistSession(_session('r1'));
    expect(await webapp.accessToken(), _session('r1'));
    expect(await webapp.hasAccessToken(), isTrue);
  });

  test('a sign-out at one address signs the other out', () async {
    await app.persistSession(_session('r1'));
    webappMirror.value = _session('r1');
    await app.removePersistedSession();
    expect(await webapp.accessToken(), isNull);
    expect(await webapp.hasAccessToken(), isFalse);
  });

  test('an existing sign-in carries over before the cookie exists', () async {
    appMirror.value = _session('r1');
    expect(await webapp.accessToken(), isNull);
    expect(await app.accessToken(), _session('r1'));
    expect(await webapp.accessToken(), _session('r1'));
  });

  test('a damaged cookie falls back to the own copy, never signs out', () async {
    await app.persistSession(_session('r1'));
    jar.cookies['chessever-app-session.0'] = 'not-base64!';
    expect(await app.accessToken(), _session('r1'));
  });

  test('large sessions split into parts and shrink back', () async {
    const codec = SharedAuthCookieCodec(chunkSize: 100);
    final big = _session('r1', pad: 3000);
    final small = _session('r2');
    final storage = SharedAuthSessionStorage(
      jar: jar,
      mirror: appMirror,
      codec: codec,
    );
    await storage.persistSession(big);
    final bigParts = int.parse(jar.cookies['chessever-app-session']!);
    expect(bigParts, greaterThan(1));
    expect(codec.read(jar).sessionJson, big);
    await storage.persistSession(small);
    expect(codec.read(jar).sessionJson, small);
    final parts = int.parse(jar.cookies['chessever-app-session']!);
    expect(
      jar.cookies.keys.where((k) => k.startsWith('chessever-app-session.')),
      hasLength(parts),
    );
  });

  group('SharedAuthSessionSync', () {
    late _Auth auth;
    late SharedAuthSessionSync sync;

    setUp(() {
      auth = _Auth();
      sync = SharedAuthSessionSync(storage: webapp, auth: auth);
      when(() => auth.recoverSession(any())).thenAnswer(
        (_) async => AuthResponse(),
      );
      when(
        () => auth.signOut(scope: any(named: 'scope')),
      ).thenAnswer((_) async {});
    });

    setUpAll(() => registerFallbackValue(SignOutScope.local));

    test('adopts a token refreshed at the other address', () async {
      await webapp.persistSession(_session('r1'));
      when(() => auth.currentSession).thenReturn(
        Session.fromJson(jsonDecode(_session('r1'))),
      );
      await sync.check();
      verifyNever(() => auth.recoverSession(any()));

      await app.persistSession(_session('r2'));
      await sync.check();
      verify(() => auth.recoverSession(_session('r2'))).called(1);
    });

    test('signs out when the other address signed out', () async {
      await webapp.persistSession(_session('r1'));
      when(() => auth.currentSession).thenReturn(
        Session.fromJson(jsonDecode(_session('r1'))),
      );
      await app.removePersistedSession();
      await sync.check();
      verify(() => auth.signOut(scope: SignOutScope.local)).called(1);
    });

    test('nothing changed: no calls', () async {
      await webapp.persistSession(_session('r1'));
      await sync.check();
      await sync.check();
      verifyNever(() => auth.recoverSession(any()));
      verifyNever(() => auth.signOut(scope: any(named: 'scope')));
    });
  });
}
