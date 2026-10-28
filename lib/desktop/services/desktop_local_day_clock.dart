import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Local midnight at the start of [now]'s calendar day.
DateTime desktopLocalDay(DateTime now) =>
    DateTime(now.year, now.month, now.day);

/// The next local midnight after [now].
///
/// Calendar arithmetic (`day + 1`), not `add(Duration(days: 1))`: on a
/// daylight-saving transition a 24-hour step lands at 23:00 or 01:00 instead
/// of midnight.
DateTime desktopNextLocalMidnight(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1);

/// Today's LOCAL calendar day, republished at local midnight and whenever the
/// app resumes or is shown again.
///
/// Date-bound access (the seven-day Likes window, today-only Miniatures) is
/// computed from this so a pane left open across midnight, or a laptop woken
/// from sleep on a later day, re-renders its locked state without a restart.
/// Tap-time checks still read the wall clock directly; this only keeps what is
/// drawn at rest honest.
final desktopLocalDayProvider =
    StateNotifierProvider<DesktopLocalDayClock, DateTime>(
      (ref) => DesktopLocalDayClock(),
    );

class DesktopLocalDayClock extends StateNotifier<DateTime> {
  DesktopLocalDayClock({
    DateTime Function()? clock,
    bool listenToLifecycle = true,
  }) : _clock = clock ?? DateTime.now,
       super(desktopLocalDay((clock ?? DateTime.now)())) {
    _scheduleMidnight();
    if (listenToLifecycle) {
      _lifecycle = AppLifecycleListener(onResume: refresh, onShow: refresh);
    }
  }

  final DateTime Function() _clock;
  Timer? _midnightTimer;
  AppLifecycleListener? _lifecycle;

  /// Re-reads the wall clock. Publishes only when the local day changed.
  void refresh() {
    if (!mounted) return;
    final today = desktopLocalDay(_clock());
    if (today != state) state = today;
    _scheduleMidnight();
  }

  void _scheduleMidnight() {
    _midnightTimer?.cancel();
    final now = _clock();
    // One second past midnight so the re-read lands firmly on the new day.
    final delay =
        desktopNextLocalMidnight(now).difference(now) +
        const Duration(seconds: 1);
    _midnightTimer = Timer(delay, refresh);
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
