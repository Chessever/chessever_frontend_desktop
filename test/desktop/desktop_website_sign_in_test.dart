import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_browser.dart';
import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/services/auth/google_oauth_loopback.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const browserChannel = MethodChannel('plugins.flutter.io/url_launcher');
  const sheetChannel = MethodChannel('chessever.desktop/web_auth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late int sheetCalls;
  late HttpOverrides? previousHttpOverrides;

  setUp(() {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    sheetCalls = 0;
    // Exercise the real website default, without overriding edition detection.
    expect(isMacAppStore, isFalse);
    expect(DesktopAuthBrowser.inApp, isFalse);
    messenger.setMockMethodCallHandler(sheetChannel, (_) async {
      sheetCalls++;
      fail('Website sign-in must not use the store sheet.');
    });
  });

  tearDown(() {
    HttpOverrides.global = previousHttpOverrides;
    messenger.setMockMethodCallHandler(browserChannel, null);
    messenger.setMockMethodCallHandler(sheetChannel, null);
    expect(sheetCalls, 0);
  });

  test(
    'website Google keeps external browser, PKCE and HTML callback',
    () async {
      late Uri authorizationUrl;
      late String callbackHtml;
      messenger.setMockMethodCallHandler(browserChannel, (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        expect(call.method, 'launch');
        expect(args['useWebView'], isFalse);
        expect(args['useSafariVC'], isFalse);
        authorizationUrl = Uri.parse(args['url']! as String);
        final query = authorizationUrl.queryParameters;
        callbackHtml = await _callback(
          Uri.parse(query['redirect_uri']!).replace(
            queryParameters: {'code': 'google-code', 'state': query['state']},
          ),
        );
        return true;
      });

      late http.Request tokenRequest;
      final result = await http.runWithClient(
        () => GoogleOAuthLoopback(clientId: 'desktop-client').signIn(),
        () => MockClient((request) async {
          tokenRequest = request;
          return http.Response(
            jsonEncode({
              'id_token': 'id-token',
              'access_token': 'access-token',
            }),
            200,
          );
        }),
      );

      expect(authorizationUrl.host, 'accounts.google.com');
      expect(callbackHtml, contains('You are signed in.'));
      expect(callbackHtml, contains('return to ChessEver'));
      expect(result.idToken, 'id-token');
      expect(tokenRequest.bodyFields['code'], 'google-code');
      expect(
        tokenRequest.bodyFields['redirect_uri'],
        authorizationUrl.queryParameters['redirect_uri'],
      );
      final verifier = tokenRequest.bodyFields['code_verifier']!;
      expect(
        authorizationUrl.queryParameters['code_challenge'],
        base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', ''),
      );
      expect(authorizationUrl.queryParameters['code_challenge_method'], 'S256');
    },
  );

  test(
    'website Google launch failure releases the loopback listener',
    () async {
      late Uri redirectUri;
      messenger.setMockMethodCallHandler(browserChannel, (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        final authorizationUrl = Uri.parse(args['url']! as String);
        redirectUri = Uri.parse(
          authorizationUrl.queryParameters['redirect_uri']!,
        );
        return false;
      });

      await expectLater(
        GoogleOAuthLoopback(clientId: 'desktop-client').signIn(),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        Socket.connect(redirectUri.host, redirectUri.port),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'website Apple keeps Supabase browser OAuth and session exchange',
    () async {
      SharedPreferences.setMockInitialValues({});
      late http.Request tokenRequest;
      await Supabase.initialize(
        url: 'https://example.supabase.co',
        anonKey: 'placeholder-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage(),
        ),
        httpClient: MockClient((request) async {
          tokenRequest = request;
          final payload = base64Url.encode(
            utf8.encode(
              jsonEncode({
                'exp':
                    DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch ~/
                    1000,
              }),
            ),
          );
          return http.Response(
            jsonEncode({
              'access_token': 'header.$payload.signature',
              'refresh_token': 'refresh-token',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': 'account-id',
                'aud': 'authenticated',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-01-01T00:00:00Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(() => Supabase.instance.dispose());

      late Uri authorizationUrl;
      late String callbackHtml;
      messenger.setMockMethodCallHandler(browserChannel, (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        expect(args['useWebView'], isFalse);
        expect(args['useSafariVC'], isFalse);
        authorizationUrl = Uri.parse(args['url']! as String);
        callbackHtml = await _callback(
          Uri.parse(
            authorizationUrl.queryParameters['redirect_to']!,
          ).replace(queryParameters: {'code': 'apple-code'}),
        );
        return true;
      });

      final session = await DesktopAuthService.instance.signInWithApple();

      expect(authorizationUrl.host, 'example.supabase.co');
      expect(authorizationUrl.queryParameters['provider'], 'apple');
      expect(authorizationUrl.queryParameters['code_challenge'], isNotEmpty);
      expect(callbackHtml, contains('You are signed in.'));
      expect(session?.user.id, 'account-id');
      expect(tokenRequest.url.queryParameters['grant_type'], 'pkce');
      expect((jsonDecode(tokenRequest.body) as Map)['auth_code'], 'apple-code');
      expect(Supabase.instance.client.auth.currentSession, session);
    },
  );
}

Future<String> _callback(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value(HttpHeaders.locationHeader), isNull);
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}
