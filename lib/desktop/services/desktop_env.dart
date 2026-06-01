import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Resolves environment values for the desktop build.
///
/// Mirrors the mobile `_getEnv` helper: debug builds read `.env`, release
/// builds read `--dart-define` values supplied at build time. Only the keys
/// the desktop path and shared desktop repositories actually consume are
/// listed here; mobile-only keys (OneSignal, AppsFlyer, Clarity) are
/// intentionally absent.
class DesktopEnv {
  DesktopEnv._();

  static const List<String> requiredReleaseKeys = <String>[
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
    'GOOGLE_DESKTOP_CLIENT_ID',
    'GOOGLE_DESKTOP_CLIENT_SECRET',
    'SENTRY_FLUTTER',
  ];

  static const Map<String, String> _release = <String, String>{
    'SUPABASE_URL': String.fromEnvironment('SUPABASE_URL', defaultValue: ''),
    'SUPABASE_ANON_KEY': String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: '',
    ),
    'GOOGLE_DESKTOP_CLIENT_ID': String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_ID',
      defaultValue: '',
    ),
    'GOOGLE_WEB_CLIENT_ID': String.fromEnvironment(
      'GOOGLE_WEB_CLIENT_ID',
      defaultValue: '',
    ),
    'GOOGLE_DESKTOP_CLIENT_SECRET': String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_SECRET',
      defaultValue: '',
    ),
    'SENTRY_FLUTTER': String.fromEnvironment(
      'SENTRY_FLUTTER',
      defaultValue: '',
    ),
    'BILLING_API_BASE': String.fromEnvironment(
      'BILLING_API_BASE',
      defaultValue: '',
    ),
    'GAMEBASE_PROXY_BASE': String.fromEnvironment(
      'GAMEBASE_PROXY_BASE',
      defaultValue: '',
    ),
  };

  /// Loads the repo-local `.env` file for debug desktop runs without bundling
  /// it as a Flutter asset.
  ///
  /// `flutter_dotenv.load()` reads through `rootBundle`, so it only works when
  /// `.env` is declared in `pubspec.yaml`. Desktop releases must use
  /// `--dart-define`; local debug runs can read the ignored file directly.
  static Future<bool> loadDebugDotenv() async {
    if (!kDebugMode) return false;
    if (dotenv.isInitialized) return true;

    final file = await _findDebugDotenvFile();
    if (file == null) return false;

    dotenv.testLoad(fileInput: await file.readAsString());
    return true;
  }

  /// Returns the env value for [key], or `null` if unavailable. Unlike the
  /// mobile helper this never throws — desktop services should degrade
  /// gracefully when optional configuration is absent.
  static String? maybeGet(String key) {
    final release = _release[key];
    if (release != null && release.isNotEmpty) return release;
    if (kDebugMode) {
      try {
        final value = dotenv.env[key];
        if (value != null && value.isNotEmpty) return value;
      } catch (_) {
        // dotenv not initialized — caller will see null.
      }
    }
    return null;
  }

  /// Like [maybeGet] but throws when the key is missing. Use only when the
  /// caller cannot proceed without the value (e.g. Supabase URL).
  static String require(String key) {
    final value = maybeGet(key);
    if (value == null || value.isEmpty) {
      throw StateError(
        'Missing required environment variable "$key". '
        'Add it to .env (debug) or pass --dart-define=$key=... (release).',
      );
    }
    return value;
  }

  /// Returns a key-only presence map for release CI checks. Values are never
  /// exposed so secrets do not leak into Codemagic logs.
  static Map<String, bool> releasePresenceFor(Iterable<String> keys) {
    return <String, bool>{
      for (final key in keys) key: (_release[key]?.isNotEmpty ?? false),
    };
  }

  static List<String> missingReleaseKeys(Iterable<String> keys) {
    return releasePresenceFor(keys).entries
        .where((entry) => !entry.value)
        .map((entry) => entry.key)
        .toList(growable: false);
  }

  static Future<File?> _findDebugDotenvFile() async {
    final starts = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    final visited = <String>{};

    for (final start in starts) {
      Directory dir;
      try {
        dir = start.absolute;
      } catch (_) {
        continue;
      }

      while (visited.add(dir.path)) {
        final candidate = File('${dir.path}${Platform.pathSeparator}.env');
        if (await candidate.exists()) {
          return candidate;
        }

        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }

    return null;
  }
}
