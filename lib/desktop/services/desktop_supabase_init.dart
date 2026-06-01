import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/repository/local_storage/supabase_safe_storage.dart';

/// Initializes Supabase for the desktop build.
///
/// Mirrors the mobile `_initializeSupabaseWithRecovery` flow: cleans
/// corrupted persisted sessions, retries once after wiping tokens, and
/// applies a hard timeout so a flaky network never blocks startup.
class DesktopSupabaseInit {
  DesktopSupabaseInit._();

  static const Duration _initTimeout = Duration(seconds: 6);
  static bool _initialized = false;

  static bool get isInitialized {
    if (_initialized) return true;
    try {
      _initialized = Supabase.instance.isInitialized;
      return _initialized;
    } catch (_) {
      return false;
    }
  }

  /// Returns the persist-session key used by Supabase auth, derived from the
  /// project URL. Matches the mobile helper so users signed in via mobile
  /// would recognize the same key shape if we ever sync sessions.
  static String persistSessionKey(String supabaseUrl) {
    final host = Uri.parse(supabaseUrl).host.split('.').first;
    return 'sb-$host-auth-token';
  }

  static Future<bool> initialize() async {
    if (isInitialized) return true;

    final url = DesktopEnv.maybeGet('SUPABASE_URL');
    final anonKey = DesktopEnv.maybeGet('SUPABASE_ANON_KEY');

    if (url == null || anonKey == null) {
      debugPrint(
        '⚠️ Supabase env not configured for desktop; skipping init. '
        'Auth and remote data will be disabled.',
      );
      return false;
    }

    final sessionKey = persistSessionKey(url);
    final authOptions = FlutterAuthClientOptions(
      localStorage: SafeSupabaseLocalStorage(persistSessionKey: sessionKey),
      pkceAsyncStorage: SafeGotrueAsyncStorage(),
    );

    try {
      await Supabase.initialize(
        url: url,
        anonKey: anonKey,
        authOptions: authOptions,
      ).timeout(
        _initTimeout,
        onTimeout:
            () => throw TimeoutException('Supabase.initialize timed out'),
      );
      _initialized = isInitialized;
      return _initialized;
    } catch (e) {
      debugPrint('⚠️ Supabase init failed on desktop: $e');
      if (isInitialized) return true;
      // The app continues without remote — the shell still renders, the
      // panes will show empty states. Auth-required actions surface their
      // own error UX; we don't crash the entire window.
      return false;
    }
  }
}
