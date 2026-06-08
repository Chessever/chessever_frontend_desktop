// Release-mode startup logging is intentional here — these are the only
// signals users see when something goes wrong before the window appears.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/desktop_app.dart';
import 'package:chessever/desktop/services/billing/desktop_deep_link_listener.dart';
import 'package:chessever/desktop/services/desktop_db_init.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_file_open_service.dart';
import 'package:chessever/desktop/services/desktop_shutdown_coordinator.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/desktop/services/desktop_window.dart';
import 'package:chessever/desktop/services/window_state_persistence.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/foreground_task_scheduler.dart';

/// Stripped-down startup path for the macOS / Windows builds.
///
/// Differs from the mobile `main()` in that it never imports OneSignal,
/// Clarity, AppsFlyer, native-splash, or any other
/// mobile-only plugin. Each of those is being replaced per the matrix in
/// `CLAUDE.md` §6 — the shell is brought up first so the rest can land
/// behind a working window.
///
/// Logs use `print()` (not `debugPrint`) so release builds also surface
/// startup progress and any errors that escape the try/catch — release
/// users were seeing only the sqflite warning before.
Future<void> desktopMain({
  List<String> initialArguments = const <String>[],
}) async {
  final releaseEnvProbe = _releaseEnvProbeArgument(initialArguments);
  if (releaseEnvProbe != null) {
    await _runReleaseEnvProbe(releaseEnvProbe);
    return;
  }

  final forwardedToPrimary = await DesktopFileOpenService.instance
      .forwardToPrimaryIfRunning(initialArguments: initialArguments);
  if (forwardedToPrimary) {
    print('[desktop] forwarded launch to running ChessEver instance');
    exit(0);
  }

  // Wrap everything so a release-mode crash gets logged before the OS kills
  // the process. Without this, errors after `runApp` would silently exit.
  await runZonedGuarded(
    () => _desktopMainWithSentry(initialArguments: initialArguments),
    (error, stack) {
      print('[desktop] fatal error (details sent to Sentry)');
      ErrorReporter.report(error, stackTrace: stack, tag: 'desktop.fatal');
    },
  );
}

const String _releaseEnvProbeFlag = '--verify-release-env';

String? _releaseEnvProbeArgument(List<String> arguments) {
  for (final argument in arguments) {
    if (argument == _releaseEnvProbeFlag ||
        argument.startsWith('$_releaseEnvProbeFlag=')) {
      return argument;
    }
  }
  return null;
}

Future<void> _runReleaseEnvProbe(String argument) async {
  final keys = _releaseEnvProbeKeys(argument);
  final presence = DesktopEnv.releasePresenceFor(keys);
  final missing = presence.entries
      .where((entry) => !entry.value)
      .map((entry) => entry.key)
      .toList(growable: false);

  stdout.writeln(
    jsonEncode(<String, Object>{
      'ok': missing.isEmpty,
      'checked': presence.keys.toList(growable: false),
      'missing': missing,
    }),
  );
  await stdout.flush();

  if (missing.isNotEmpty) {
    exit(78);
  }
  exit(0);
}

List<String> _releaseEnvProbeKeys(String argument) {
  final separator = argument.indexOf('=');
  if (separator == -1 || separator == argument.length - 1) {
    return DesktopEnv.requiredReleaseKeys;
  }

  final keys = argument
      .substring(separator + 1)
      .split(',')
      .map((key) => key.trim())
      .where((key) => key.isNotEmpty)
      .toList(growable: false);
  return keys.isEmpty ? DesktopEnv.requiredReleaseKeys : keys;
}

Future<void>? _desktopBootFuture;
DesktopShutdownCoordinator? _desktopShutdownCoordinator;

Future<void> _desktopBootOnce({
  List<String> initialArguments = const <String>[],
}) {
  return _desktopBootFuture ??= _desktopBoot(
    initialArguments: initialArguments,
  );
}

Future<void> _desktopMainWithSentry({
  List<String> initialArguments = const <String>[],
}) async {
  if (kDebugMode) {
    await DesktopEnv.loadDebugDotenv();
  }

  final sentryDsn = DesktopEnv.maybeGet('SENTRY_FLUTTER');
  if (sentryDsn == null || sentryDsn.isEmpty) {
    print('[desktop] Sentry disabled; SENTRY_FLUTTER not configured');
    await _desktopBootOnce(initialArguments: initialArguments);
    return;
  }

  try {
    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        options.environment = kReleaseMode ? 'production' : 'debug';
        options.sendDefaultPii = true;

        // Keep desktop monitoring focused on errors. Performance/session
        // features can be enabled later once the shell is stable.
        options.tracesSampleRate = 0.0;
        options.enableAutoPerformanceTracing = false;
        options.enableUserInteractionTracing = false;
        options.attachScreenshot = false;
        options.maxBreadcrumbs = 50;
        options.enableAutoNativeBreadcrumbs = false;
        options.enableUserInteractionBreadcrumbs = false;
        options.enableAutoSessionTracking = false;
        options.sampleRate = 1.0;
      },
      appRunner: () => _desktopBootOnce(initialArguments: initialArguments),
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () async {
        print('[desktop] Sentry init timed out; starting app anyway');
        await _desktopBootOnce(initialArguments: initialArguments);
      },
    );
  } catch (e, stack) {
    print('[desktop] Sentry init failed; starting app anyway');
    ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.sentry_init');
    await _desktopBootOnce(initialArguments: initialArguments);
  }
}

Future<void> _desktopBoot({
  List<String> initialArguments = const <String>[],
}) async {
  print('[desktop] startup begin (${Platform.operatingSystem})');
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    throw StateError(
      'desktopMain() called on a non-desktop platform: ${Platform.operatingSystem}',
    );
  }

  WidgetsFlutterBinding.ensureInitialized();
  print('[desktop] flutter binding ready');

  // SQLite must be initialized before any AppDatabase access.
  initializeDesktopDatabaseFactory();
  print('[desktop] sqflite ffi initialized');

  // Window manager wiring (size, min size, hide-until-ready).
  await DesktopWindow.initialize();
  print('[desktop] window manager initialized');

  // Restore the window's last known position/size before showing it. The
  // listener picks up subsequent moves/resizes for next launch.
  try {
    await WindowStatePersistence.instance.restore();
    await WindowStatePersistence.instance.startTracking();
    print('[desktop] window-state persistence wired');
  } catch (e, stack) {
    print('[desktop] ⚠️ window-state persistence failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.window_state');
  }

  // Local debug builds use .env; release builds receive --dart-define values.
  if (kDebugMode) {
    final loadedEnv = await DesktopEnv.loadDebugDotenv();
    print(
      loadedEnv
          ? '[desktop] .env loaded from local file (debug)'
          : '[desktop] ⚠️ .env not found (continuing without)',
    );
  }

  // Open the local SQLite DB once so the rest of the app can rely on it.
  // Failures here are non-fatal — AppDatabase has internal recovery.
  try {
    await AppDatabase.instance.database;
    print('[desktop] sqlite ready');
  } catch (e, stack) {
    print('[desktop] ⚠️ AppDatabase warm-up failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.db_warmup');
  }

  // Supabase brings auth and remote data online. If env is missing the shell
  // still renders so we can develop the UI without the backend.
  final supabaseReady = await DesktopSupabaseInit.initialize();
  print(
    supabaseReady
        ? '[desktop] supabase init done'
        : '[desktop] ⚠️ supabase unavailable; starting offline shell',
  );

  final startupOpenPaths = await DesktopFileOpenService.instance.start(
    initialArguments: initialArguments,
  );

  // Do not warm Stockfish on desktop startup. Analysis must remain completely
  // idle until the user explicitly enables the engine from the board rail.
  // Audio assets can still preload after first paint without spawning engine work.
  ForegroundTaskScheduler.schedule(
    key: 'desktop_startup_audio_assets',
    delay: kStartupWarmupDelay + const Duration(seconds: 1),
    task: () async {
      try {
        await AudioPlayerService.instance.initializeAndLoadAllAssets();
      } catch (e, stack) {
        print('[desktop] ⚠️ audio init failed');
        ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.audio_init');
      }
    },
  );

  // Auto-updater: bootstrap after first frame so the network probe never races
  // the window appearing. The chip in the top bar appears only after a
  // verified update is staged.
  ForegroundTaskScheduler.schedule(
    key: 'desktop_startup_desktop_updater',
    delay: kStartupWarmupDelay + const Duration(seconds: 2),
    task: () async {
      try {
        await DesktopUpdaterService.instance.initialize();
      } catch (e, stack) {
        print('[desktop] ⚠️ auto-updater init failed');
        ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.updater_init');
      }
    },
  );

  print('[desktop] running app');
  final container = ProviderContainer(
    // The desktop subscription notifier polls our /entitlement edge
    // function (backed by public.subscriptions, which mirrors both Stripe
    // web and RevenueCat mobile state). Replaces the stub-true override.
    overrides: [desktopSubscriptionOverride],
  );
  _desktopShutdownCoordinator = DesktopShutdownCoordinator(container);
  try {
    await _desktopShutdownCoordinator!.start();
    print('[desktop] shutdown coordinator wired');
  } catch (e, stack) {
    print('[desktop] ⚠️ shutdown coordinator failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.shutdown');
  }

  DesktopFileOpenService.instance.openPaths.listen((paths) {
    unawaited(_openLocalChessPaths(container, paths, 'Opened local files'));
  });
  if (startupOpenPaths.isNotEmpty) {
    unawaited(
      _openLocalChessPaths(container, startupOpenPaths, 'Opened local files'),
    );
  }

  // Listen for desktop app links. Billing keeps the existing entitlement
  // refresh path; broadcast website links route into a desktop tournament tab.
  // ignore: discarded_futures
  DesktopDeepLinkListener.instance.start(
    onLink: (uri) {
      if (uri.scheme == 'chessever' && uri.host == 'billing') {
        switch (uri.path) {
          case '/success':
          case '/portal-return':
            // ignore: discarded_futures
            DesktopSubscriptionNotifier.current?.refreshFromBackend(
              forceSessionRefresh: true,
            );
            break;
          case '/cancel':
            // user closed the Stripe tab — nothing to refresh
            break;
          default:
            break;
        }
        return;
      }
      unawaited(DesktopDeepLinkRouter.instance.handle(uri, container));
    },
  );
  for (final uri in desktopDeepLinkUrisFromArguments(initialArguments)) {
    unawaited(DesktopDeepLinkRouter.instance.handle(uri, container));
  }

  runApp(
    UncontrolledProviderScope(container: container, child: const DesktopApp()),
  );
}

Future<void> _openLocalChessPaths(
  ProviderContainer container,
  List<String> paths,
  String sourceLabel,
) async {
  if (paths.isEmpty) return;
  try {
    final opened = await container
        .read(localChessLibraryProvider.notifier)
        .openPaths(paths, sourceLabel: sourceLabel);
    if (!opened) {
      print('[desktop] ⚠️ local file open was not activated');
      return;
    }
    final state = container.read(localChessLibraryProvider);
    final path = state.selectedPath;
    if (path == null || path.isEmpty) {
      container.read(desktopTabsProvider.notifier).open(TabKind.library);
      print('[desktop] opened ${paths.length} local chess path(s) in Library');
      return;
    }
    final workspacePath = localDatabaseWorkspacePath(state.source, path);

    openDatabaseWorkspaceTabForContainer(
      container,
      DatabaseWorkspaceArgs.local(
        localPath: workspacePath,
        title: localDatabaseWorkspaceTitle(state.source, workspacePath),
      ),
    );
    print(
      '[desktop] opened ${paths.length} local chess path(s) in database tab',
    );
  } catch (e, stack) {
    print('[desktop] ⚠️ local file open failed');
    ErrorReporter.report(e, stackTrace: stack, tag: 'desktop.local_open');
  }
}
