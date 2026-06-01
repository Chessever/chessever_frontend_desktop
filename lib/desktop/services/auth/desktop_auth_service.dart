import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/google_oauth_loopback.dart';
import 'package:chessever/desktop/services/auth/supabase_oauth_loopback.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/desktop/services/error_reporter.dart';

/// Desktop-friendly auth surface used by the shell and panes.
///
/// Mirrors the parts of the mobile `AuthRepository` that desktop actually
/// needs: sign in with Google (via the loopback flow, not `google_sign_in`)
/// and sign in with Apple (via Supabase-hosted OAuth on every desktop OS).
class DesktopAuthService {
  DesktopAuthService._();
  static final DesktopAuthService instance = DesktopAuthService._();

  /// Runs the OAuth loopback flow, then exchanges the resulting `id_token`
  /// for a Supabase session. Returns the new session on success.
  ///
  /// Throws [StateError] if `GOOGLE_DESKTOP_CLIENT_ID` is not configured —
  /// that's a setup problem, not a recoverable runtime error.
  Future<Session?> signInWithGoogle() async {
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

  /// Runs Supabase-hosted Apple OAuth through a loopback callback.
  ///
  /// Native macOS Sign in with Apple depends on the
  /// `com.apple.developer.applesignin` entitlement being present in the final
  /// signed app. Our direct-download Developer ID release path cannot rely on
  /// that entitlement, and Windows has no native Apple sheet at all. Desktop
  /// Apple auth therefore uses Supabase's hosted OAuth provider instead of
  /// `AuthenticationServices`, matching the web account page.
  Future<Session?> signInWithApple() async {
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
