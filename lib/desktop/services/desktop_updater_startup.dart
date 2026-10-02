import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chessever/utils/foreground_task_scheduler.dart';

/// Starts the updater once the app is in the foreground, however long that
/// takes.
///
/// A foreground task that comes due while the window is not focused is
/// dropped, not postponed. For most startup work that is right. For the
/// updater it meant a user who launched the app and clicked away within a few
/// seconds got no update check for the whole session. So the start is asked
/// for again each time the app comes back to the foreground, until it has
/// run once.
class DesktopUpdaterStartup {
  DesktopUpdaterStartup({
    required this.start,
    required this.firstDelay,
    this.resumeDelay = kForegroundRefreshDelay,
  });

  /// Starts the updater. Called at most once.
  final Future<void> Function() start;

  /// How long after launch the first attempt is made.
  final Duration firstDelay;

  /// How long after the app returns to the foreground a later attempt is made.
  final Duration resumeDelay;

  static const String _taskKey = 'desktop_startup_desktop_updater';

  bool _started = false;
  AppLifecycleListener? _lifecycle;

  bool get started => _started;

  void schedule() {
    if (_started || _lifecycle != null) return;
    _lifecycle = AppLifecycleListener(onResume: () => _attempt(resumeDelay));
    _attempt(firstDelay);
  }

  void _attempt(Duration delay) {
    if (_started) return;
    ForegroundTaskScheduler.schedule(
      key: _taskKey,
      delay: delay,
      task: () async {
        if (_started) return;
        _started = true;
        _lifecycle?.dispose();
        _lifecycle = null;
        await start();
      },
    );
  }

  void dispose() {
    ForegroundTaskScheduler.cancel(_taskKey);
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
