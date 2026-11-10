// Release-mode startup logging mirrors desktop_main.dart: these lines are the
// only signal in the browser console when startup goes wrong.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'package:chessever/desktop/auth/desktop_player_profile_access.dart';
import 'package:chessever/desktop/desktop_app.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/desktop/services/desktop_push_isolation.dart';
import 'package:chessever/desktop/services/desktop_sentry_filter.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/chessground_image_cache.dart';
import 'package:chessever/web/web_file_system.dart';
import 'package:chessever/web/web_storage_notice.dart';
import 'package:chessever/web/web_frame_stats.dart';
import 'package:chessever/web/web_path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:web/web.dart' as web;

/// Browser startup for the desktop shell.
///
/// Runs the parts of `desktopMain` that make sense in a tab: SQLite (backed by
/// IndexedDB through sqflite's web factory), Supabase, the same provider
/// overrides, and [DesktopApp]. Window management, multi-window boards, the
/// updater, file-open forwarding, local engines and the local chess library
/// are desktop-only and never start here.
Future<void> runChessEverWeb() async {
  await runZonedGuarded(_boot, (error, stack) {
    print('[web] uncaught error: $error');
    ErrorReporter.report(error, stackTrace: stack, tag: 'web.fatal');
  });
}

/// Error reporting for the browser build, with the DSN the desktop app
/// ships (a DSN only accepts events; it grants nothing else).
///
/// Never awaited: the SDK loads its script from Sentry's CDN, which content
/// blockers commonly refuse, and startup must not wait on that. Until it is
/// up, [ErrorReporter] reports are dropped, as they are without a DSN.
Future<void> _startSentry() async {
  final dsn = DesktopEnv.maybeGet('SENTRY_FLUTTER');
  if (dsn == null || dsn.isEmpty) {
    print('[web] Sentry disabled; SENTRY_FLUTTER not configured');
    return;
  }
  try {
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.environment = kReleaseMode ? 'production-web' : 'debug-web';
      options.sendDefaultPii = false;
      options.tracesSampleRate = 0.0;
      options.enableAutoPerformanceTracing = false;
      options.attachScreenshot = false;
      options.maxBreadcrumbs = 100;
      options.enableAutoSessionTracking = false;
      options.sampleRate = 1.0;
      options.beforeSend =
          (event, hint) => shouldDropDesktopSentryEvent(event) ? null : event;
    });
    print('[web] Sentry ready');
  } catch (e) {
    print('[web] Sentry unavailable: $e');
  }
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_startSentry());
  // The app has no Flutter routes to mirror; WebUrlSync owns the address bar
  // and history. Flutter's own strategy would add its sentinel entry and
  // answer Back by itself, fighting the entries WebUrlSync pushes.
  setUrlStrategy(null);
  // Right-click belongs to the app, as on desktop: the board draws arrows and
  // rows, cards and panes open their own menus. The browser's menu would
  // cover them, and while it is enabled text fields defer to it instead of
  // showing Flutter's own copy/paste toolbar.
  await BrowserContextMenu.disableContextMenu();
  print('[web] startup begin');
  // Skwasm rasterizes on a Web Worker only in a cross-origin isolated page
  // (web/_headers sends Document-Isolation-Policy). `false` here means every
  // frame is drawn on the main thread, which is what makes animations stutter.
  print('[web] cross-origin isolated: ${web.window.crossOriginIsolated}');
  final stopwatch = Stopwatch()..start();
  String elapsed() => '${stopwatch.elapsedMilliseconds} ms';

  // Supabase keeps its session in SharedPreferences (localStorage), not in
  // the file system or SQLite below, so its init (which may refresh the
  // session over the network) runs while those come up instead of after.
  final supabaseInit = DesktopSupabaseInit.initialize();

  // Local databases, workspaces and caches are files on desktop; here they
  // live in an IndexedDB-backed filesystem mounted before anything opens one.
  await WebFileSystem.mount();
  PathProviderPlatform.instance = WebPathProvider();
  print('[web] file system mounted (${elapsed()})');

  // The worker-backed factory needs a SharedWorker, which some browsers lack
  // or refuse; the main-thread factory reads the same IndexedDB storage.
  databaseFactory = databaseFactoryFfiWeb;
  try {
    await AppDatabase.instance.database;
    print('[web] sqlite ready (${elapsed()})');
  } catch (e) {
    print('[web] sqlite worker unavailable ($e); using main thread');
    databaseFactory = databaseFactoryFfiWebNoWebWorker;
    try {
      await AppDatabase.instance.database;
      print('[web] sqlite ready (main thread, ${elapsed()})');
    } catch (e, stack) {
      print('[web] sqlite warm-up failed: $e');
      ErrorReporter.report(e, stackTrace: stack, tag: 'web.db_warmup');
    }
  }

  final container = ProviderContainer(
    overrides: [
      desktopSubscriptionOverride,
      desktopPlayerProfileGamesOverride,
      forYouGamesPerEventLimitProvider.overrideWithValue(
        kDesktopForYouGamesPerEvent,
      ),
      ...desktopPushIsolationOverrides,
    ],
  );

  // Board settings come from SQLite and preload the saved piece set; that
  // overlaps with whatever is left of the Supabase init.
  Future<void> preloadBoard() async {
    try {
      final settings = await container.read(boardSettingsProviderNew.future);
      await ChessgroundImageCache.preloadPieceSet(settings.pieceSet);
      print('[web] piece set ready (${elapsed()})');
    } catch (e, stack) {
      print('[web] piece preload failed: $e');
      ErrorReporter.report(e, stackTrace: stack, tag: 'web.piece_preload');
    }
  }

  final boardReady = preloadBoard();
  final supabaseReady = await supabaseInit;
  print(
    supabaseReady
        ? '[web] supabase init done (${elapsed()})'
        : '[web] supabase unavailable; starting offline shell',
  );
  await boardReady;

  print('[web] running app (${elapsed()})');
  runApp(
    UncontrolledProviderScope(container: container, child: const DesktopApp()),
  );
  WebFrameStats.startIfEnabled();
  // Board sounds are a few small files; fetch them once the shell has drawn.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    watchWebFileStorage();
    unawaited(AudioPlayerService.instance.initializeAndLoadAllAssets());
    // URL routing starts at the authenticated gate, not while a visitor is
    // viewing the inert destination backdrop.
  });
}
