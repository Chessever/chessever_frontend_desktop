import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_browser.dart';
import 'package:chessever/desktop/services/auth/google_oauth_loopback.dart';
import 'package:chessever/desktop/services/auth/supabase_oauth_loopback.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';

/// Desktop-friendly auth surface used by the shell and panes.
///
/// Mirrors the parts of the mobile `AuthRepository` that desktop actually
/// needs: sign in with Google (via the loopback flow, not `google_sign_in`)
/// and sign in with Apple (native in the Mac App Store edition,
/// Supabase-hosted OAuth in the website builds).
class DesktopAuthService {
  DesktopAuthService._();
  static final DesktopAuthService instance = DesktopAuthService._();

  /// Runs the OAuth loopback flow, then exchanges the resulting `id_token`
  /// for a Supabase session. Returns the new session on success.
  ///
  /// Throws [StateError] if `GOOGLE_DESKTOP_CLIENT_ID` is not configured —
  /// that's a setup problem, not a recoverable runtime error.
  Future<Session?> signInWithGoogle() async {
    if (kIsWeb) return _signInWithRedirect(OAuthProvider.google);
    final clientId = DesktopEnv.maybeGet('GOOGLE_DESKTOP_CLIENT_ID');
    if (clientId == null || clientId.isEmpty) {
      final legacyClientId = DesktopEnv.maybeGet('GOOGLE_WEB_CLIENT_ID');
      if (legacyClientId != null && legacyClientId.isNotEmpty) {
        throw StateError(
          'GOOGLE_DESKTOP_CLIENT_ID is not configured for desktop. '
          'Desktop Google OAuth no longer reads GOOGLE_WEB_CLIENT_ID because '
          'that key usually points at a Web OAuth client. Pass the Desktop-app '
          'OAuth client ID as --dart-define=GOOGLE_DESKTOP_CLIENT_ID.',
        );
      }
      throw StateError(
        'GOOGLE_DESKTOP_CLIENT_ID is not configured for desktop. '
        'Create a Google Cloud OAuth client with application type '
        '"Desktop app", then add it to .env (debug) or pass '
        '--dart-define=GOOGLE_DESKTOP_CLIENT_ID (release).',
      );
    }
    final clientSecret = DesktopEnv.maybeGet('GOOGLE_DESKTOP_CLIENT_SECRET');
    if (kDebugMode) {
      // ignore: avoid_print
      print(
        '[auth] starting Google OAuth, clientId=${_redact(clientId)}, '
        'clientSecret=${clientSecret == null ? "absent" : "present"}',
      );
    }
    final flow = GoogleOAuthLoopback(
      clientId: clientId,
      clientSecret: clientSecret,
    );
    final tokens = await flow.signIn();
    if (kDebugMode) {
      // ignore: avoid_print
      print(
        '[auth] got Google tokens: id_token len=${tokens.idToken.length}, '
        'access_token len=${tokens.accessToken.length}, '
        'scope=${tokens.scope}',
      );
    }

    final supabase = Supabase.instance.client;
    try {
      final response = await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      if (kDebugMode) {
        // ignore: avoid_print
        print(
          '[auth] supabase signInWithIdToken ok, '
          'user=${response.user?.email}',
        );
      }
      return response.session;
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.supabase_google');
      rethrow;
    }
  }

  /// Signs in with Apple.
  ///
  /// The Mac App Store edition shows the native sheet: App Review requires
  /// Apple sign-in to finish without leaving the app (guideline 4), and the
  /// store profile grants `com.apple.developer.applesignin`.
  ///
  /// The website builds run Supabase-hosted Apple OAuth through a loopback
  /// callback. Our direct-download Developer ID release path cannot rely on
  /// that entitlement, and Windows has no native Apple sheet at all.
  Future<Session?> signInWithApple() async {
    if (kIsWeb) {
      return _signInWithRedirect(OAuthProvider.apple, scopes: 'name email');
    }
    if (isMacAppStore) return _signInWithAppleNatively();
    if (kDebugMode) {
      // ignore: avoid_print
      print('[auth] starting Apple OAuth loopback');
    }
    try {
      final session =
          await SupabaseOAuthLoopback(
            provider: OAuthProvider.apple,
            scopes: 'name email',
          ).signIn();
      if (kDebugMode) {
        // ignore: avoid_print
        print('[auth] supabase Apple OAuth ok, user=${session?.user.email}');
      }
      return session;
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.supabase_apple');
      rethrow;
    }
  }

  /// Browser sign-in: Supabase-hosted OAuth in the same tab. A tab cannot
  /// run the loopback server, so the page leaves for the provider and comes
  /// back to this origin with a PKCE code, which `Supabase.initialize`
  /// exchanges for a session on the next load. This returns `null`; the
  /// guest gate replays a pending guest merge once the permanent account
  /// appears. The origin must be on the Supabase Auth redirect list.
  Future<Session?> _signInWithRedirect(
    OAuthProvider provider, {
    String? scopes,
  }) async {
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        provider,
        redirectTo: '${Uri.base.origin}/',
        scopes: scopes,
      );
      return null;
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.web_${provider.name}');
      rethrow;
    }
  }

  /// The phone's native flow: Apple signs a SHA-256 of a one-time nonce and
  /// Supabase checks the raw nonce against the identity token.
  Future<Session?> _signInWithAppleNatively() async {
    final auth = Supabase.instance.client.auth;
    final previousUserId = auth.currentUser?.id;
    final rawNonce = _randomNonce();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const DesktopSignInCancelled();
      }
      rethrow;
    }
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw StateError('Apple did not return an identity token.');
    }

    // Stage auth in memory. The application auth stream must not expose a new
    // session until the server has durably stored its Apple revocation token.
    // A failed attempt never changes a returning user's persisted session.
    final staged = SupabaseClient(
      DesktopEnv.require('SUPABASE_URL'),
      DesktopEnv.require('SUPABASE_ANON_KEY'),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    var adopted = false;
    try {
      final response = await staged.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      final session = response.session;
      if (session == null) {
        throw StateError('Apple sign-in did not create a session.');
      }
      try {
        final registration = await staged.functions.invoke(
          'apple-auth-tokens',
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
          body: {
            'authorization_code': credential.authorizationCode,
            'identity_token': idToken,
            'nonce': rawNonce,
          },
        );
        if (registration.status != 200 ||
            registration.data is! Map ||
            (registration.data as Map)['stored'] != true) {
          throw StateError('Apple credential storage was not confirmed.');
        }
      } catch (_) {
        // Never attach platform credentials or raw function exceptions to
        // telemetry: the request contains a one-use code and an identity JWT.
        throw StateError(
          'Apple sign-in could not securely save your authorization. '
          'Please try again.',
        );
      }
      if (auth.currentUser?.id != previousUserId) {
        throw StateError('The signed-in account changed. Please try again.');
      }
      await auth.recoverSession(jsonEncode(session.toJson()));
      adopted = true;
      // Apple shares the name only on the first authorization.
      final fullName =
          [
            credential.givenName,
            credential.familyName,
          ].whereType<String>().join(' ').trim();
      if (fullName.isNotEmpty) {
        try {
          await auth.updateUser(UserAttributes(data: {'full_name': fullName}));
        } catch (e, st) {
          ErrorReporter.report(e, stackTrace: st, tag: 'auth.apple_name');
        }
      }
      return response.session;
    } catch (_, st) {
      ErrorReporter.report(
        StateError('Native Apple sign-in did not complete.'),
        stackTrace: st,
        tag: 'auth.supabase_apple',
      );
      rethrow;
    } finally {
      if (!adopted) {
        try {
          await staged.auth.signOut(scope: SignOutScope.local);
        } catch (_) {
          // The main app session is untouched even if cleanup is offline.
        }
      }
      await staged.dispose();
    }
  }

  String _randomNonce() {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  String _redact(String s) =>
      s.length <= 12
          ? '***'
          : '${s.substring(0, 8)}…${s.substring(s.length - 4)}';

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.signout');
    }
  }

  Session? get currentSession => Supabase.instance.client.auth.currentSession;
}
