import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_browser.dart';
import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';

// app.chessever.com signs in by sending the tab to the provider. `launchUrl`
// resolves before the tab leaves, and returning then made every sign-in
// surface flash "Sign-in did not finish" while Google's page loaded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const browserChannel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late bool launchResult;
  late int launches;

  setUp(() async {
    launchResult = true;
    launches = 0;
    messenger.setMockMethodCallHandler(browserChannel, (call) async {
      launches++;
      return launchResult;
    });
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'placeholder-key',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(browserChannel, null);
    await Supabase.instance.dispose();
  });

  Future<Session?> redirect(Future<bool> Function(Duration) awaitRestore) =>
      DesktopAuthService.instance.signInWithRedirect(
        OAuthProvider.google,
        redirectTo: 'https://app.chessever.com/',
        awaitRestore: awaitRestore,
      );

  test('stays pending while the tab leaves for the provider', () async {
    final leaving = Completer<bool>();
    var settled = false;
    unawaited(
      redirect(
        (_) => leaving.future,
      ).then((_) => settled = true, onError: (Object _) => settled = true),
    );
    await pumpEventQueue();

    expect(launches, 1);
    expect(settled, isFalse);
  });

  test('coming Back to the cached page is a cancellation', () async {
    await expectLater(
      redirect((_) async => true),
      throwsA(isA<DesktopSignInCancelled>()),
    );
  });

  test('a tab that never leaves times out instead of hanging', () async {
    late Duration waited;
    await expectLater(
      redirect((timeout) async {
        waited = timeout;
        return false;
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(waited, DesktopAuthService.webRedirectTimeout);
  });

  test('a refused launch fails instead of waiting', () async {
    launchResult = false;
    var waited = false;
    await expectLater(
      redirect((_) async {
        waited = true;
        return false;
      }),
      throwsA(isA<StateError>()),
    );
    expect(waited, isFalse);
  });
}
