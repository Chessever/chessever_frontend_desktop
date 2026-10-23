// Startup progress goes to the browser console in release builds too, like
// the native desktop entrypoint's logging.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:chessever/desktop/auth/desktop_player_profile_access.dart';
import 'package:chessever/desktop/desktop_app.dart';
import 'package:chessever/desktop/services/desktop_db_init.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/desktop/services/desktop_push_isolation.dart';
import 'package:chessever/desktop/services/desktop_sentry_filter.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/web/soloud_web_module.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/memorial_player_local_search.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/services/analytics/analytics_service.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/chessground_image_cache.dart';
import 'package:chessever/utils/foreground_task_scheduler.dart';

/// Startup path for the browser build (app.chessever.com).
///
/// It boots the same [DesktopApp] shell as the native entrypoint and leaves
/// out everything a browser tab cannot do: window management, extra board
/// windows and picture-in-picture, the auto-updater, single-instance file
/// forwarding, OS deep links and local engine processes. Features built on
/// those check `kIsWeb` where they are offered, and the panes that need the
/// user's computer are listed in `desktop_web_support.dart`.
///
/// Firebase is not initialized: there is no Firebase web app registered for
/// this origin, and the browser build would otherwise load Google's analytics
/// script before first paint.
Future<void> webMain() async {
  await runZonedGuarded(_webBoot, (error, stack) {
    print('[web] fatal error (details sent to Sentry)');
    ErrorReporter.report(error, stackTrace: stack, tag: 'web.fatal');
  });
}

Future<void> _webBoot() async {
  WidgetsFlutterBinding.ensureInitialized();
  print('[web] flutter binding ready');

  // The shell draws its own context menus (board, game rows, tabs). Without
  // this the browser's menu opens on top of them on every right click.
  await BrowserContextMenu.disableContextMenu();

  final sentryDsn = DesktopEnv.maybeGet('SENTRY_FLUTTER');
  if (sentryDsn == null || sentryDsn.isEmpty) {
    await _webStart();
    return;
  }
  try {
    await SentryFlutter.init((options) {
      options.dsn = sentryDsn;
      options.environment = kReleaseMode ? 'web' : 'web-debug';
      options.tracesSampleRate = 0.0;
      options.enableAutoPerformanceTracing = false;
      options.maxBreadcrumbs = 100;
      options.enableAutoSessionTracking = false;
      options.beforeSend =
          (event, hint) => shouldDropDesktopSentryEvent(event) ? null : event;
    }, appRunner: _webStart).timeout(
      const Duration(seconds: 5),
      onTimeout: () async {
        print('[web] Sentry init timed out; starting app anyway');
        await _webStart();
      },
    );
  } catch (e, stack) {
    print('[web] Sentry init failed; starting app anyway');
    ErrorReporter.report(e, stackTrace: stack, tag: 'web.sentry_init');
    await _webStart();
  }
}

Future<void>? _webStartFuture;

Future<void> _webStart() => _webStartFuture ??= _webStartOnce();

Future<void> _webStartOnce() async {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(warmBundledMemorialPlayerCatalog());
  });

  // sqlite3.wasm behind the same sqflite API the desktop store uses, so
  // settings, caches and favorites survive a reload.
  initializeDesktopDatabaseFactory();

  // Warm the store and Supabase together: both are network or worker bound,
  // and neither waits on the other.
  await Future.wait<void>([
    _warmAppDatabase(),
    _initializeSupabase(),
    AnalyticsService.instance.initialize(),
  ]);

  // Move sounds use flutter_soloud's own wasm module. Fetch it now, in
  // parallel with the first frame, and start the engine once things settle.
  final soloudModule = loadSoloudWebModule()..ignore();
  ForegroundTaskScheduler.schedule(
    key: 'web_startup_audio_assets',
    delay: kStartupWarmupDelay + const Duration(seconds: 1),
    task: () async {
      try {
        await soloudModule;
        await AudioPlayerService.instance.initializeAndLoadAllAssets();
      } catch (e, stack) {
        print('[web] ⚠️ audio init failed');
        ErrorReporter.report(e, stackTrace: stack, tag: 'web.audio_init');
      }
    },
  );

  final container = ProviderContainer(
    overrides: [
      desktopSubscriptionOverride,
      desktopPlayerProfileGamesOverride,
      ...desktopPushIsolationOverrides,
    ],
  );
  await _preloadChessgroundPieceImages(container);

  print('[web] running app');
  runApp(
    SentryWidget(
      child: UncontrolledProviderScope(
        container: container,
        child: const DesktopApp(),
      ),
    ),
  );
}

Future<void> _warmAppDatabase() async {
  try {
    await AppDatabase.instance.database;
    print('[web] sqlite ready');
  } catch (e, stack) {
    print('[web] ⚠️ AppDatabase warm-up failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'web.db_warmup');
  }
}

Future<void> _initializeSupabase() async {
  final ready = await DesktopSupabaseInit.initialize();
  print(
    ready
        ? '[web] supabase init done'
        : '[web] ⚠️ supabase unavailable; starting offline shell',
  );
}

Future<void> _preloadChessgroundPieceImages(ProviderContainer container) async {
  try {
    final settings = await container.read(boardSettingsProviderNew.future);
    await ChessgroundImageCache.preloadPieceSet(settings.pieceSet);
  } catch (e, stack) {
    print('[web] ⚠️ chessground piece cache preload failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'web.chessground_preload');
  }
}
