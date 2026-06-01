import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Google OAuth 2.0 "loopback IP" flow for desktop apps.
///
/// `google_sign_in` does not exist on Windows and uses platform-specific
/// helpers on macOS that are awkward to wire from a Flutter desktop shell.
/// The loopback flow is what Google's own Python / Go desktop SDKs use:
///
/// 1. Bind an `HttpServer` to `127.0.0.1:0` (any free port).
/// 2. Open the user's browser to Google's auth URL with
///    `redirect_uri=http://127.0.0.1:<port>` and a PKCE challenge.
/// 3. Wait for the browser to redirect back with `?code=…`.
/// 4. Exchange the code at `https://oauth2.googleapis.com/token` to get an
///    `id_token` we can forward to Supabase.
///
/// This file does the OAuth dance only. Wiring the resulting `id_token` /
/// `access_token` into the existing Supabase auth repository is a separate
/// step (see `desktop_auth_service.dart`).
class GoogleOAuthLoopback {
  GoogleOAuthLoopback({
    required this.clientId,
    this.clientSecret,
    this.scopes = const <String>['openid', 'email', 'profile'],
  });

  /// OAuth client ID issued in Google Cloud Console (Desktop application
  /// type for shipped desktop apps).
  final String clientId;

  /// "Client secret" issued alongside the Desktop client ID. Google documents
  /// it as optional for installed apps, but if it is provided it must be the
  /// exact secret for [clientId]; otherwise the token endpoint returns
  /// `invalid_client`.
  ///
  /// This value is "secret" in name only: RFC 8252 §8.5 acknowledges that
  /// native apps cannot keep client secrets confidential because the binary
  /// ships to user devices. The actual security guarantees come from the
  /// PKCE flow (S256 challenge) and the loopback redirect — the secret here
  /// is fine to embed in the binary or the bundled `.env`.
  final String? clientSecret;

  final List<String> scopes;

  static const String _authEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  /// Runs the full flow and returns the resulting tokens. Throws on user
  /// cancellation, server errors, or transport failures so the caller can
  /// surface a meaningful error.
  ///
  /// Binds an OS-assigned port on the loopback interface — Google's
  /// "Desktop application" OAuth client type accepts any
  /// `http://127.0.0.1:<port>` redirect without pre-registering individual
  /// ports. RFC 8252 §7.3 is the spec; gcloud, VS Code, GitHub Desktop,
  /// Postman, and Google's own desktop SDKs all do the same thing. The
  /// [clientId] passed in must be a Desktop-type client; Web-type clients
  /// require every redirect URI to be exactly registered and don't fit
  /// the use case.
  Future<GoogleOAuthResult> signIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final redirectUri = 'http://127.0.0.1:$port';

    final state = _randomString(32);
    final verifier = _randomString(64);
    final challenge = _pkceChallenge(verifier);

    final authUri = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        // `select_account` is friendlier than the default — desktop users
        // expect to confirm which Google account they want to use, not to be
        // silently signed in as the last one.
        'prompt': 'select_account',
      },
    );

    final codeCompleter = Completer<String>();
    late StreamSubscription<HttpRequest> sub;
    sub = server.listen((request) async {
      final params = request.uri.queryParameters;
      final responseHtml = _renderResponse(
        success: params['error'] == null,
        message: params['error'] ?? 'You can close this window.',
      );
      request.response.headers.contentType = ContentType.html;
      request.response.write(responseHtml);
      await request.response.close();

      final returnedState = params['state'];
      if (returnedState != state) {
        codeCompleter.completeError(
          StateError('OAuth state mismatch (CSRF guard).'),
        );
      } else if (params['error'] != null) {
        codeCompleter.completeError(
          StateError('OAuth error: ${params['error']}'),
        );
      } else if (params['code'] != null) {
        codeCompleter.complete(params['code']!);
      }
      await sub.cancel();
      await server.close(force: true);
    });

    final launched = await launchUrl(
      authUri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      await server.close(force: true);
      throw StateError('Failed to open browser for OAuth.');
    }

    final code = await codeCompleter.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        throw TimeoutException('OAuth flow timed out.');
      },
    );

    final cs = clientSecret ?? '';
    // ignore: avoid_print
    print(
      '[auth] token-exchange body: '
      'client_id.len=${clientId.length} '
      'client_secret=${cs.isEmpty ? "absent" : "present"} '
      'redirect_uri=$redirectUri',
    );

    final tokenResp = await http.post(
      Uri.parse(_tokenEndpoint),
      body: <String, String>{
        'client_id': clientId,
        if (cs.isNotEmpty) 'client_secret': cs,
        'code': code,
        'code_verifier': verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri,
      },
    );
    if (tokenResp.statusCode != 200) {
      throw StateError(
        'OAuth token exchange failed (${tokenResp.statusCode}): '
        '${tokenResp.body}',
      );
    }
    final tokenJson = jsonDecode(tokenResp.body) as Map<String, dynamic>;
    return GoogleOAuthResult(
      idToken: tokenJson['id_token'] as String,
      accessToken: tokenJson['access_token'] as String,
      refreshToken: tokenJson['refresh_token'] as String?,
      expiresIn: Duration(
        seconds: (tokenJson['expires_in'] as num?)?.toInt() ?? 0,
      ),
      scope: tokenJson['scope'] as String? ?? '',
    );
  }

  String _pkceChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes).bytes;
    return base64Url.encode(digest).replaceAll('=', '');
  }

  String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List<String>.generate(
      length,
      (_) => chars[rand.nextInt(chars.length)],
    ).join();
  }

  String _renderResponse({required bool success, required String message}) {
    if (success) {
      return '<!doctype html><html><head><meta charset="utf-8"><title>'
          'Signed in to ChessEver</title><style>body{background:#0C0C0E;'
          'color:#fff;font:16px -apple-system,Segoe UI,Roboto,sans-serif;'
          'display:flex;align-items:center;justify-content:center;'
          'height:100vh;margin:0;}div{text-align:center;}h1{margin:0 0 8px;'
          'font-weight:600;}p{color:#999;margin:0;}</style></head><body>'
          '<div><h1>You are signed in.</h1><p>$message</p>'
          '<p style="margin-top:16px;color:#666;">You can close this tab '
          'and return to ChessEver.</p></div></body></html>';
    }
    return '<!doctype html><html><head><meta charset="utf-8"><title>'
        'Sign-in failed</title><style>body{background:#0C0C0E;color:#fff;'
        'font:16px -apple-system,Segoe UI,Roboto,sans-serif;display:flex;'
        'align-items:center;justify-content:center;height:100vh;margin:0;}'
        'div{text-align:center;}h1{margin:0 0 8px;font-weight:600;}'
        'p{color:#F5453A;margin:0;}</style></head><body><div>'
        '<h1>Sign-in failed.</h1><p>$message</p>'
        '<p style="margin-top:16px;color:#666;">You can close this tab '
        'and return to ChessEver.</p></div></body></html>';
  }
}

class GoogleOAuthResult {
  const GoogleOAuthResult({
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.scope,
  });

  final String idToken;
  final String accessToken;
  final String? refreshToken;
  final Duration expiresIn;
  final String scope;
}

/// Convenience helper that exposes [Function] symbol so callers can probe the
/// whole flow at runtime without instantiating in non-desktop tests.
@visibleForTesting
GoogleOAuthLoopback debugInstantiate(String clientId) =>
    GoogleOAuthLoopback(clientId: clientId);
