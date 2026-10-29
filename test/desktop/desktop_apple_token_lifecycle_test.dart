import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chessever/chat/ai_sharing_consent.dart';
import 'package:chessever/desktop/services/auth/desktop_apple_credential_lifecycle.dart';
import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _session(
  String id, {
  String? sessionId,
  int revision = 0,
  bool includeSessionId = true,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${part({'alg': 'HS256'})}.${part({'sub': id, 'iat': now, 'exp': now + 3600, 'test_revision': revision, if (includeSessionId) 'session_id': sessionId ?? 'test-session-$id'})}.test',
    'refresh_token': 'test-refresh-$id-$revision',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': now + 3600,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'app_metadata': {'provider': 'apple'},
      'user_metadata': {},
      'created_at': '2026-10-29T00:00:00Z',
      'identities': [
        {
          'id': 'test-apple-sub',
          'identity_id': 'test-identity',
          'user_id': id,
          'provider': 'apple',
          'identity_data': {'sub': 'test-apple-sub'},
          'created_at': '2026-10-29T00:00:00Z',
        },
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.aboutyou.dart_packages.sign_in_with_apple');
  const stateChannel = MethodChannel('chessever.desktop/apple_credentials');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String nativeNonce;
  late MockClient transport;
  late Future<http.Response> Function(http.Request request) route;
  late List<String> signInEvents;
  StreamSubscription<AuthState>? subscription;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(
      fileInput:
          'SUPABASE_URL=https://example.invalid\nSUPABASE_ANON_KEY=test-public-key',
    );
    route = (request) async {
      if (request.url.path.endsWith('/token')) {
        return http.Response(jsonEncode(_session('new-user')), 200);
      }
      if (request.url.path.endsWith('/logout')) return http.Response('', 204);
      return http.Response(
        '{"stored":true}',
        200,
        headers: {'content-type': 'application/json'},
      );
    };
    transport = MockClient((request) => route(request));
    await Supabase.initialize(
      url: 'https://example.invalid',
      anonKey: 'test-public-key',
      httpClient: transport,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
      debug: false,
    );
    signInEvents = [];
    subscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      state,
    ) {
      if (state.session != null) signInEvents.add(state.session!.user.id);
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'performAuthorizationRequest');
      nativeNonce = ((call.arguments as List).single as Map)['nonce'] as String;
      return {
        'type': 'appleid',
        'userIdentifier': 'test-apple-sub',
        'authorizationCode': 'test-one-use-code',
        'identityToken': 'test-apple-id-token',
      };
    });
  });

  tearDown(() async {
    await subscription?.cancel();
    await DesktopAppleCredentialLifecycle.instance.dispose();
    await Supabase.instance.dispose();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(stateChannel, null);
  });

  group('native Apple token persistence', () {
    test(
      'no main auth session is emitted before encrypted storage succeeds',
      () async {
        final registered = Completer<http.Response>();
        final reached = Completer<void>();
        route = (request) async {
          if (request.url.path.endsWith('/token')) {
            return http.Response(jsonEncode(_session('new-user')), 200);
          }
          expect(request.url.path, '/functions/v1/apple-auth-tokens');
          final payload = jsonDecode(request.body) as Map;
          expect(payload['authorization_code'], 'test-one-use-code');
          expect(payload['identity_token'], 'test-apple-id-token');
          expect(
            sha256.convert(utf8.encode(payload['nonce'] as String)).toString(),
            nativeNonce,
          );
          expect(
            request.headers['Authorization'],
            'Bearer ${_session('new-user')['access_token']}',
          );
          reached.complete();
          return registered.future;
        };
        final pending = http.runWithClient(
          () => DesktopAuthService.instance.signInWithApple(),
          () => transport,
        );
        await reached.future;
        expect(Supabase.instance.client.auth.currentSession, isNull);
        expect(signInEvents, isEmpty);
        registered.complete(
          http.Response(
            '{"stored":true}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        expect((await pending)?.user.id, 'new-user');
        await Future<void>.delayed(Duration.zero);
        expect(Supabase.instance.client.auth.currentUser?.id, 'new-user');
        expect(signInEvents, contains('new-user'));
      },
    );

    for (final original in <String?>[null, 'old-user']) {
      test(
        'registration failure preserves original ${original ?? "signed-out"} session',
        () async {
          if (original != null) {
            await Supabase.instance.client.auth.recoverSession(
              jsonEncode(_session(original)),
            );
          }
          route = (request) async {
            if (request.url.path.endsWith('/token')) {
              return http.Response(jsonEncode(_session('new-user')), 200);
            }
            if (request.url.path.endsWith('/logout')) {
              return http.Response('', 204);
            }
            return http.Response('{"error":"apple_not_configured"}', 503);
          };
          await expectLater(
            http.runWithClient(
              () => DesktopAuthService.instance.signInWithApple(),
              () => transport,
            ),
            throwsStateError,
          );
          expect(Supabase.instance.client.auth.currentUser?.id, original);
          expect(signInEvents, isNot(contains('new-user')));
        },
      );
    }

    test('account switched during registration is never overwritten', () async {
      final reached = Completer<void>();
      final registered = Completer<http.Response>();
      route = (request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(jsonEncode(_session('new-user')), 200);
        }
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        reached.complete();
        return registered.future;
      };
      final pending = http.runWithClient(
        () => DesktopAuthService.instance.signInWithApple(),
        () => transport,
      );
      final failed = expectLater(pending, throwsStateError);
      await reached.future;
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('other-user')),
      );
      registered.complete(
        http.Response(
          '{"stored":true}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await failed;
      expect(Supabase.instance.client.auth.currentUser?.id, 'other-user');
      expect(signInEvents, isNot(contains('new-user')));
    });

    test(
      'failed same-account registration never adopts or signs out the existing session',
      () async {
        final original = _session('old-user');
        final staged = _session(
          'old-user',
          sessionId: 'new-authorization',
          revision: 1,
        );
        final prefs =
            (await SharedPreferencesService.instance.ensureInitialized())!;
        await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
        await prefs.setString(
          'supabase_user',
          jsonEncode({'id': 'old-user', 'name': 'Existing account'}),
        );
        await Supabase.instance.client.auth.recoverSession(
          jsonEncode(original),
        );
        final signedOutTokens = <String>[];
        route = (request) async {
          if (request.url.path.endsWith('/token')) {
            return http.Response(jsonEncode(staged), 200);
          }
          if (request.url.path.endsWith('/logout')) {
            signedOutTokens.add(
              request.headers.entries
                  .firstWhere(
                    (entry) => entry.key.toLowerCase() == 'authorization',
                  )
                  .value,
            );
            return http.Response('', 204);
          }
          return http.Response(
            '{"error":"token_persistence_failed"}',
            503,
            headers: {'content-type': 'application/json'},
          );
        };
        await expectLater(
          http.runWithClient(
            () => DesktopAuthService.instance.signInWithApple(),
            () => transport,
          ),
          throwsStateError,
        );
        expect(
          Supabase.instance.client.auth.currentSession?.accessToken,
          original['access_token'],
        );
        expect(
          Supabase.instance.client.auth.currentSession?.refreshToken,
          original['refresh_token'],
        );
        expect(signedOutTokens, ['Bearer ${staged['access_token']}']);
        expect(prefs.getBool(AiSharingConsent.keyFor('old-user')), isTrue);
        expect(
          jsonDecode(prefs.getString('supabase_user')!)['name'],
          'Existing account',
        );
      },
    );
  }, skip: !Platform.isMacOS || !macAppStoreBuild);

  test(
    'explicit revocation signs out, temporary credential-state errors preserve session',
    () async {
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('old-user')),
      );
      messenger.setMockMethodCallHandler(stateChannel, (_) async {
        throw PlatformException(code: 'credential_state_unavailable');
      });
      await DesktopAppleCredentialLifecycle.instance.check();
      expect(Supabase.instance.client.auth.currentUser?.id, 'old-user');
      messenger.setMockMethodCallHandler(stateChannel, (_) async => 'revoked');
      await DesktopAppleCredentialLifecycle.instance.check();
      expect(Supabase.instance.client.auth.currentSession, isNull);
    },
  );

  test(
    'late revocation cleans captured account keys while preserving the new account',
    () async {
      final prefs =
          (await SharedPreferencesService.instance.ensureInitialized())!;
      await prefs.setString('supabase_user', jsonEncode({'id': 'old-user'}));
      await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
      await prefs.setBool(AiSharingConsent.keyFor('other-user'), true);
      await prefs.setString(
        'offline_library_directory',
        '/test/offline-library',
      );
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('old-user')),
      );
      final reply = Completer<String>();
      messenger.setMockMethodCallHandler(stateChannel, (_) => reply.future);
      final pending = DesktopAppleCredentialLifecycle.instance.check();
      await Future<void>.delayed(Duration.zero);
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('other-user')),
      );
      await prefs.setString(
        'supabase_session',
        jsonEncode(_session('other-user')),
      );
      reply.complete('revoked');
      await pending;
      expect(Supabase.instance.client.auth.currentUser?.id, 'other-user');
      expect(prefs.containsKey(AiSharingConsent.keyFor('old-user')), isFalse);
      expect(prefs.containsKey('supabase_user'), isFalse);
      expect(prefs.getBool(AiSharingConsent.keyFor('other-user')), isTrue);
      expect(
        (jsonDecode(prefs.getString('supabase_session')!) as Map)['user']['id'],
        'other-user',
      );
      expect(
        prefs.getString('offline_library_directory'),
        '/test/offline-library',
      );
    },
  );

  test(
    'revocation clears only the revoked account preferences before sign-out',
    () async {
      final prefs =
          (await SharedPreferencesService.instance.ensureInitialized())!;
      await prefs.setString(
        'supabase_session',
        jsonEncode(_session('old-user')),
      );
      await prefs.setString('supabase_user', jsonEncode({'id': 'other-user'}));
      await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
      await prefs.setBool(AiSharingConsent.keyFor('other-user'), true);
      await prefs.setString(
        'offline_library_directory',
        '/test/offline-library',
      );
      await prefs.setInt('guest_session_started_at_ms', 1000);
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('old-user')),
      );
      var checkedCleanupBeforeSignOut = false;
      route = (request) async {
        if (request.url.path.endsWith('/logout')) {
          expect(prefs.containsKey('supabase_session'), isFalse);
          expect(
            prefs.containsKey(AiSharingConsent.keyFor('old-user')),
            isFalse,
          );
          checkedCleanupBeforeSignOut = true;
          return http.Response('', 204);
        }
        throw StateError(
          'Unexpected network request in offline revocation test.',
        );
      };
      messenger.setMockMethodCallHandler(stateChannel, (_) async => 'revoked');
      await DesktopAppleCredentialLifecycle.instance.check();
      expect(checkedCleanupBeforeSignOut, isTrue);
      expect(Supabase.instance.client.auth.currentSession, isNull);
      expect(jsonDecode(prefs.getString('supabase_user')!)['id'], 'other-user');
      expect(prefs.getBool(AiSharingConsent.keyFor('other-user')), isTrue);
      expect(
        prefs.getString('offline_library_directory'),
        '/test/offline-library',
      );
      expect(prefs.getInt('guest_session_started_at_ms'), 1000);
    },
  );

  test(
    'stale revocation cannot clear preferences or sign out a newly authorized same account',
    () async {
      final prefs =
          (await SharedPreferencesService.instance.ensureInitialized())!;
      final old = _session('old-user');
      final fresh = _session(
        'old-user',
        sessionId: 'new-authorization',
        revision: 1,
      );
      await Supabase.instance.client.auth.recoverSession(jsonEncode(old));
      final reply = Completer<String>();
      var stateCalls = 0;
      messenger.setMockMethodCallHandler(stateChannel, (_) {
        stateCalls++;
        return reply.future;
      });
      final pending = DesktopAppleCredentialLifecycle.instance.check();
      await Future<void>.delayed(Duration.zero);
      await Supabase.instance.client.auth.recoverSession(jsonEncode(fresh));
      await prefs.setString('supabase_session', jsonEncode(fresh));
      await prefs.setString(
        'supabase_user',
        jsonEncode({'id': 'old-user', 'name': 'New authorization'}),
      );
      await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
      reply.complete('revoked');
      await pending;
      expect(stateCalls, 1);
      expect(
        Supabase.instance.client.auth.currentSession?.accessToken,
        fresh['access_token'],
      );
      expect(prefs.getString('supabase_session'), jsonEncode(fresh));
      expect(
        jsonDecode(prefs.getString('supabase_user')!)['name'],
        'New authorization',
      );
      expect(prefs.getBool(AiSharingConsent.keyFor('old-user')), isTrue);
    },
  );

  test(
    'same-account reauthorization while loading preferences discards the stale verdict before cleanup',
    () async {
      final prefs =
          (await SharedPreferencesService.instance.ensureInitialized())!;
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('old-user')),
      );
      final loading = Completer<void>();
      final loaded = Completer<SharedPreferences?>();
      final lifecycle = DesktopAppleCredentialLifecycle.forTesting(
        loadPreferences: () {
          loading.complete();
          return loaded.future;
        },
      );
      addTearDown(lifecycle.dispose);
      messenger.setMockMethodCallHandler(stateChannel, (_) async => 'revoked');
      final pending = lifecycle.check();
      await loading.future;
      final fresh = _session(
        'old-user',
        sessionId: 'new-authorization',
        revision: 1,
      );
      await Supabase.instance.client.auth.recoverSession(jsonEncode(fresh));
      await prefs.setString('supabase_session', jsonEncode(fresh));
      await prefs.setString(
        'supabase_user',
        jsonEncode({'id': 'old-user', 'name': 'Fresh authorization'}),
      );
      await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
      loaded.complete(prefs);
      await pending;
      expect(
        Supabase.instance.client.auth.currentSession?.accessToken,
        fresh['access_token'],
      );
      expect(prefs.getString('supabase_session'), jsonEncode(fresh));
      expect(
        jsonDecode(prefs.getString('supabase_user')!)['name'],
        'Fresh authorization',
      );
      expect(prefs.getBool(AiSharingConsent.keyFor('old-user')), isTrue);
    },
  );

  for (final includeSessionId in [true, false]) {
    for (final freshState in ['authorized', 'revoked']) {
      test(
        'token rotation ${includeSessionId ? "with" : "without"} session id rechecks native state ($freshState)',
        () async {
          final prefs =
              (await SharedPreferencesService.instance.ensureInitialized())!;
          final original = _session(
            'old-user',
            includeSessionId: includeSessionId,
          );
          final rotated = _session(
            'old-user',
            revision: 1,
            includeSessionId: includeSessionId,
          );
          await prefs.setBool(AiSharingConsent.keyFor('old-user'), true);
          await prefs.setString(
            'supabase_user',
            jsonEncode({'id': 'old-user'}),
          );
          await Supabase.instance.client.auth.recoverSession(
            jsonEncode(original),
          );
          final reply = Completer<String>();
          var stateCalls = 0;
          messenger.setMockMethodCallHandler(stateChannel, (_) {
            stateCalls++;
            return stateCalls == 1 ? reply.future : Future.value(freshState);
          });
          final pending = DesktopAppleCredentialLifecycle.instance.check();
          await Future<void>.delayed(Duration.zero);
          await Supabase.instance.client.auth.recoverSession(
            jsonEncode(rotated),
          );
          reply.complete('revoked');
          await pending;
          expect(stateCalls, 2);
          if (freshState == 'authorized') {
            expect(
              Supabase.instance.client.auth.currentSession?.accessToken,
              rotated['access_token'],
            );
            expect(prefs.getBool(AiSharingConsent.keyFor('old-user')), isTrue);
            expect(prefs.containsKey('supabase_user'), isTrue);
          } else {
            expect(Supabase.instance.client.auth.currentSession, isNull);
            expect(
              prefs.containsKey(AiSharingConsent.keyFor('old-user')),
              isFalse,
            );
            expect(prefs.containsKey('supabase_user'), isFalse);
          }
        },
      );
    }
  }
}
