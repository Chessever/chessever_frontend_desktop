// Release-mode startup logging mirrors desktop_main.dart: these lines are the
// only signal in the browser console when startup goes wrong.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'package:chessever/desktop/auth/desktop_player_profile_access.dart';
import 'package:chessever/desktop/desktop_app.dart';
import 'package:chessever/desktop/services/desktop_push_isolation.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/chessground_image_cache.dart';
import 'package:chessever/web/web_file_system.dart';
import 'package:chessever/web/web_path_provider.dart';
import 'package:chessever/web/web_url_sync.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The app has no Flutter routes to mirror; WebUrlSync owns the address bar
  // and history. Flutter's own strategy would add its sentinel entry and
  // answer Back by itself, fighting the entries WebUrlSync pushes.
  setUrlStrategy(null);
  print('[web] startup begin');

  // Local databases, workspaces and caches are files on desktop; here they
  // live in an IndexedDB-backed filesystem mounted before anything opens one.
  await WebFileSystem.mount();
  PathProviderPlatform.instance = WebPathProvider();
  print('[web] file system mounted');

  // The worker-backed factory needs a SharedWorker, which some browsers lack
  // or refuse; the main-thread factory reads the same IndexedDB storage.
  databaseFactory = databaseFactoryFfiWeb;
  try {
    await AppDatabase.instance.database;
    print('[web] sqlite ready');
  } catch (e) {
    print('[web] sqlite worker unavailable ($e); using main thread');
    databaseFactory = databaseFactoryFfiWebNoWebWorker;
    try {
      await AppDatabase.instance.database;
      print('[web] sqlite ready (main thread)');
    } catch (e, stack) {
      print('[web] sqlite warm-up failed: $e');
      ErrorReporter.report(e, stackTrace: stack, tag: 'web.db_warmup');
    }
  }

  final supabaseReady = await DesktopSupabaseInit.initialize();
  print(
    supabaseReady
        ? '[web] supabase init done'
        : '[web] supabase unavailable; starting offline shell',
  );

  final container = ProviderContainer(
    overrides: [
      desktopSubscriptionOverride,
      desktopPlayerProfileGamesOverride,
      ...desktopPushIsolationOverrides,
    ],
  );

  try {
    final settings = await container.read(boardSettingsProviderNew.future);
    await ChessgroundImageCache.preloadPieceSet(settings.pieceSet);
  } catch (e, stack) {
    print('[web] piece preload failed: $e');
    ErrorReporter.report(e, stackTrace: stack, tag: 'web.piece_preload');
  }

  print('[web] running app');
  runApp(
    UncontrolledProviderScope(container: container, child: const DesktopApp()),
  );
  // Board sounds are a few small files; fetch them once the shell has drawn.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(AudioPlayerService.instance.initializeAndLoadAllAssets());
    // Open the page the address names, then keep the address in step.
    unawaited(WebUrlSync.start(container));
  });
}
