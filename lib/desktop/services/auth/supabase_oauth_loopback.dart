import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Browser-based Supabase OAuth flow for desktop providers.
///
/// This is deliberately provider-agnostic, but it is primarily used for Apple
/// on desktop builds. Native Sign in with Apple requires Apple platform
/// capabilities, and Windows has no native Apple sheet, so desktop Apple auth
/// goes through Supabase's hosted OAuth provider and returns to a loopback
/// callback just like the Google flow.
class SupabaseOAuthLoopback {
  SupabaseOAuthLoopback({
    required this.provider,
    this.scopes,
    this.queryParams,
  });

  final OAuthProvider provider;
  final String? scopes;
  final Map<String, String>? queryParams;

  Future<Session?> signIn() async {
    final supabase = Supabase.instance.client;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/auth/callback';

    final codeCompleter = Completer<String>();
    var serverClosed = false;

    Future<void> closeServer() async {
      if (serverClosed) return;
      serverClosed = true;
      await server.close(force: true);
    }

    late final StreamSubscription<HttpRequest> sub;
    sub = server.listen((request) async {
      final params = request.uri.queryParameters;
      final hasResult =
          params.containsKey('code') || params.containsKey('error');

      if (!hasResult) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_renderFragmentRelay());
        await request.response.close();
        return;
      }

      final success = params['error'] == null;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        _renderResponse(
          success: success,
          message:
              success
                  ? 'You can close this window.'
                  : (params['error_description'] ??
                      params['error'] ??
                      'OAuth failed.'),
        ),
      );
      await request.response.close();

      if (codeCompleter.isCompleted) return;

      if (params['error'] != null) {
        codeCompleter.completeError(
          DesktopOAuthException(
            '${_providerLabel()} sign-in failed: '
            '${params['error_description'] ?? params['error']}',
          ),
        );
      } else if (params['code'] != null) {
        codeCompleter.complete(params['code']!);
      }

      await sub.cancel();
      await closeServer();
    });

    try {
      final response = await supabase.auth.getOAuthSignInUrl(
        provider: provider,
        redirectTo: redirectUri,
        scopes: scopes,
        queryParams: queryParams,
      );

      final launched = await launchUrl(
        Uri.parse(response.url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw DesktopOAuthException(
          'Could not open the browser for ${_providerLabel()} sign-in.',
        );
      }

      final code = await codeCompleter.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw DesktopOAuthException(
            '${_providerLabel()} sign-in timed out. Check that Supabase OAuth '
            'is enabled and that this redirect URL is allowed in Supabase: '
            'http://127.0.0.1:*/auth/callback',
          );
        },
      );

      final sessionResponse = await supabase.auth.exchangeCodeForSession(code);
      return sessionResponse.session;
    } finally {
      await sub.cancel();
      await closeServer();
    }
  }

  String _renderFragmentRelay() {
    return '<!doctype html><html><head><meta charset="utf-8"><title>'
        'Finishing sign-in</title></head><body><script>'
        'if (window.location.hash.length > 1) {'
        'window.location.replace(window.location.pathname + "?" + '
        'window.location.hash.substring(1));'
        '}'
        '</script></body></html>';
  }

  String _renderResponse({required bool success, required String message}) {
    final escaped = _escapeHtml(message);
    if (success) {
      return '<!doctype html><html><head><meta charset="utf-8"><title>'
          'Signed in to ChessEver</title><style>body{background:#0C0C0E;'
          'color:#fff;font:16px -apple-system,Segoe UI,Roboto,sans-serif;'
          'display:flex;align-items:center;justify-content:center;'
          'height:100vh;margin:0;}div{text-align:center;}h1{margin:0 0 8px;'
          'font-weight:600;}p{color:#999;margin:0;}</style></head><body>'
          '<div><h1>You are signed in.</h1><p>$escaped</p>'
          '<p style="margin-top:16px;color:#666;">Return to ChessEver.</p>'
          '</div></body></html>';
    }
    return '<!doctype html><html><head><meta charset="utf-8"><title>'
        'Sign-in failed</title><style>body{background:#0C0C0E;color:#fff;'
        'font:16px -apple-system,Segoe UI,Roboto,sans-serif;display:flex;'
        'align-items:center;justify-content:center;height:100vh;margin:0;}'
        'div{text-align:center;}h1{margin:0 0 8px;font-weight:600;}'
        'p{color:#F5453A;margin:0;}</style></head><body><div>'
        '<h1>Sign-in failed.</h1><p>$escaped</p>'
        '<p style="margin-top:16px;color:#666;">Return to ChessEver.</p>'
        '</div></body></html>';
  }

  String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  String _providerLabel() {
    final value = provider.name;
    if (value.isEmpty) return 'Provider';
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }
}

class DesktopOAuthException implements Exception {
  const DesktopOAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
