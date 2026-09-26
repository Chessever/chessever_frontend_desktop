import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Short, debug-only timing windows for diagnosing local PGN UI lag.
/// Deliberately logs counts and durations rather than paths or PGN contents.
class LocalPgnPerformanceLog {
  LocalPgnPerformanceLog._();

  static _LocalPgnFrameWindow? _window;

  static void event(String phase, String details) {
    if (!kDebugMode) return;
    debugPrint('[PGN-PERF] $phase $details');
  }

  static void watchFrames(String phase) {
    if (!kDebugMode) return;
    _window?.finish();
    _window = _LocalPgnFrameWindow(phase);
  }
}

class _LocalPgnFrameWindow {
  _LocalPgnFrameWindow(this.phase) {
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    _heartbeat = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = _clock.elapsedMilliseconds;
      final delay = now - _lastHeartbeatMs - 250;
      if (delay > _maxEventLoopDelayMs) _maxEventLoopDelayMs = delay;
      _lastHeartbeatMs = now;
    });
    _summary = Timer.periodic(const Duration(seconds: 5), (_) => _print());
    _end = Timer(const Duration(seconds: 15), finish);
  }

  final String phase;
  final Stopwatch _clock = Stopwatch()..start();
  late final Timer _heartbeat;
  late final Timer _summary;
  late final Timer _end;
  int _lastHeartbeatMs = 0;
  int _maxEventLoopDelayMs = 0;
  int _frames = 0;
  int _slowFrames = 0;
  int _slowUiFrames = 0;
  int _slowRasterFrames = 0;
  double _maxBuildMs = 0;
  double _maxRasterMs = 0;
  bool _finished = false;

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      _frames++;
      if (buildMs + rasterMs > 16.6) _slowFrames++;
      if (buildMs > 16.6) _slowUiFrames++;
      if (rasterMs > 16.6) _slowRasterFrames++;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;
    }
  }

  void _print() {
    LocalPgnPerformanceLog.event(
      'frames',
      'phase=$phase elapsedMs=${_clock.elapsedMilliseconds} '
          'frames=$_frames slow=$_slowFrames uiSlow=$_slowUiFrames '
          'rasterSlow=$_slowRasterFrames '
          'maxBuildMs=${_maxBuildMs.toStringAsFixed(1)} '
          'maxRasterMs=${_maxRasterMs.toStringAsFixed(1)} '
          'maxEventLoopDelayMs=$_maxEventLoopDelayMs',
    );
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    _print();
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _heartbeat.cancel();
    _summary.cancel();
    _end.cancel();
    if (identical(LocalPgnPerformanceLog._window, this)) {
      LocalPgnPerformanceLog._window = null;
    }
  }
}
