import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_browser.dart';
import 'package:chessever/desktop/services/auth/google_oauth_loopback.dart';

/// App Review guideline 4: the Mac App Store edition must finish sign-in
/// without sending the user to their default browser.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chessever.desktop/web_auth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // The loopback round trip below uses real sockets.
    HttpOverrides.global = null;
    DesktopAuthBrowser.debugInAppOverride = true;
  });

  tearDown(() {
    DesktopAuthBrowser.debugInAppOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Google opens in the in-app sheet, which the loopback closes', () async {
    late Uri authorizationUrl;
    late HttpClientResponse loopbackReply;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'start');
      final args = call.arguments as Map<Object?, Object?>;
      expect(args['callbackScheme'], DesktopAuthBrowser.callbackScheme);
      authorizationUrl = Uri.parse(args['url']! as String);
      // Google redirecting the sheet back to the loopback listener.
      final query = authorizationUrl.queryParameters;
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse(query['redirect_uri']!).replace(
          queryParameters: {'code': 'auth-code', 'state': query['state']},
        ),
      );
      request.followRedirects = false;
      loopbackReply = await request.close();
      await loopbackReply.drain<void>();
      client.close();
      return loopbackReply.headers.value(HttpHeaders.locationHeader);
    });

    final tokenRequests = <http.Request>[];
    final result = await http.runWithClient(
      () => GoogleOAuthLoopback(clientId: 'client').signIn(),
      () => MockClient((request) async {
        tokenRequests.add(request);
        return http.Response(
          jsonEncode({
            'id_token': 'id-token',
            'access_token': 'access-token',
            'expires_in': 3600,
            'scope': 'openid email profile',
          }),
          200,
        );
      }),
    );

    expect(authorizationUrl.host, 'accounts.google.com');
    expect(loopbackReply.statusCode, HttpStatus.found);
    expect(
      loopbackReply.headers.value(HttpHeaders.locationHeader),
      DesktopAuthBrowser.completionUri.toString(),
    );
    expect(tokenRequests.single.bodyFields['code'], 'auth-code');
    expect(result.idToken, 'id-token');
  });

  test('closing the sheet cancels sign-in and frees the listener', () async {
    late Uri redirectUri;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'start') return null;
      final url = Uri.parse(
        (call.arguments as Map<Object?, Object?>)['url']! as String,
      );
      redirectUri = Uri.parse(url.queryParameters['redirect_uri']!);
      throw PlatformException(code: 'canceled');
    });

    await expectLater(
      GoogleOAuthLoopback(clientId: 'client').signIn(),
      throwsA(isA<DesktopSignInCancelled>()),
    );
    await expectLater(
      Socket.connect(redirectUri.host, redirectUri.port),
      throwsA(isA<SocketException>()),
    );
  });

  test('only the store edition carries the native Apple entitlement', () {
    const appleSignIn = '<key>com.apple.developer.applesignin</key>';
    expect(
      File('macos/Runner/AppStore.entitlements').readAsStringSync(),
      contains(appleSignIn),
    );
    expect(
      File('macos/Runner/Release.entitlements').readAsStringSync(),
      isNot(contains(appleSignIn)),
    );
    expect(
      File('scripts/build_mac_app_store.sh').readAsStringSync(),
      contains("'com.apple.developer.applesignin'"),
    );
  });

  test('the in-app sheet bridge is compiled and attached', () {
    final project =
        File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, contains('DesktopWebAuthBridge.swift in Sources'));
    expect(
      File('macos/Runner/MainFlutterWindow.swift').readAsStringSync(),
      contains('DesktopWebAuthBridge.shared.attach'),
    );
    expect(
      File('macos/Runner/DesktopWebAuthBridge.swift').readAsStringSync(),
      contains('"chessever.desktop/web_auth"'),
    );
  });
}
