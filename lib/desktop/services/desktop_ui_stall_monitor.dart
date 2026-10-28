import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:chessever/utils/host_platform.dart';

/// Detects Windows UI-isolate stalls after the event loop becomes responsive.
///
/// Sentry's native Flutter App Hang integration does not support Windows. A
/// periodic timer gives us a low-overhead recovery signal instead: when a tick
/// arrives substantially later than expected, the UI isolate was unable to
/// process events for at least that long. The report includes recent Sentry
/// breadcrumbs so the interaction immediately preceding the stall is visible.
class DesktopUiStallMonitor with WidgetsBindingObserver {
  DesktopUiStallMonitor._();

  static final DesktopUiStallMonitor instance = DesktopUiStallMonitor._();

  static const Duration pollInterval = Duration(seconds: 1);
  static const Duration stallThreshold = Duration(seconds: 5);
  static const Duration reportCooldown = Duration(seconds: 30);

  /// Windows sends no lifecycle change for sleep, hibernate or a locked
  /// session, so the first tick after waking looks like a stall of minutes
  /// with nothing in the breadcrumbs before it (CHESSEVER-1S6: 73s to 429s,
  /// each after minutes of silence, while real stalls ran 5s to 36s). No
  /// genuine freeze runs this long without the user closing the app.
  static const Duration suspendThreshold = Duration(seconds: 60);

  Timer? _timer;
  Stopwatch? _clock;
  Duration _lastTick = Duration.zero;
  Duration? _lastReport;
  AppLifecycleState? _lifecycleState;

  void start() {
    if (!hostIsWindows || _timer != null) return;

    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _lifecycleState = binding.lifecycleState;
    _clock = Stopwatch()..start();
    _lastTick = _clock!.elapsed;
    _timer = Timer.periodic(pollInterval, (_) => _onTick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    final clock = _clock;
    if (clock != null) _lastTick = clock.elapsed;
  }

  void _onTick() {
    final clock = _clock;
    if (clock == null) return;

    final now = clock.elapsed;
    final elapsed = now - _lastTick;
    _lastTick = now;

    // Minimized, suspended, and background windows naturally stop receiving
    // frames. Reset the baseline instead of reporting those as freezes.
    final lifecycle = _lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;

    final stall = elapsed - pollInterval;
    if (stall < stallThreshold) return;
    if (stall >= suspendThreshold) {
      unawaited(
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'ui.suspend',
            message: 'Windows UI isolate resumed after a probable suspend',
            data: <String, Object>{'gap_ms': stall.inMilliseconds},
          ),
        ),
      );
      return;
    }
    final lastReport = _lastReport;
    if (lastReport != null && now - lastReport < reportCooldown) return;
    _lastReport = now;

    final stallMs = stall.inMilliseconds;
    final breadcrumb = Breadcrumb(
      category: 'ui.stall',
      message: 'Windows UI isolate recovered after a stall',
      level: SentryLevel.warning,
      data: <String, Object>{'stall_ms': stallMs},
    );
    unawaited(Sentry.addBreadcrumb(breadcrumb));
    unawaited(
      Sentry.captureException(
        DesktopUiStallException(stall),
        stackTrace: StackTrace.current,
        withScope: (scope) {
          scope.setTag('source', 'desktop.ui_stall_watchdog');
          scope.setTag('desktop_platform', 'windows');
          scope.setContexts('ui_stall', <String, Object>{
            'stall_ms': stallMs,
            'poll_interval_ms': pollInterval.inMilliseconds,
            'detection': 'reported_after_event_loop_recovered',
          });
        },
      ).catchError((Object _) => SentryId.empty()),
    );
  }
}

class DesktopUiStallException implements Exception {
  const DesktopUiStallException(this.duration);

  final Duration duration;

  @override
  String toString() =>
      'DesktopUiStallException: UI isolate stalled for '
      '${duration.inMilliseconds} ms';
}
