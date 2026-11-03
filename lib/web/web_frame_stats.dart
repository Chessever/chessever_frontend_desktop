// Release-mode console output is the point of this file.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:web/web.dart' as web;

/// Opt-in frame timing for the browser build.
///
/// Turn it on from the console with
/// `localStorage.setItem('chessever.frameStats', '1')` and reload; remove the
/// key to turn it off. Every 5 s, while frames are drawn, it prints how many
/// frames there were and the median, 95th percentile and worst build (Dart:
/// build, layout, paint recording) and raster times, plus how many missed a
/// 120 Hz (8.3 ms) and a 60 Hz (16.7 ms) budget. Build time is what the app
/// code controls; raster time runs on Skwasm's worker when the page is
/// cross-origin isolated.
class WebFrameStats {
  WebFrameStats._();

  static const storageKey = 'chessever.frameStats';

  static void startIfEnabled() {
    String? flag;
    try {
      flag = web.window.localStorage.getItem(storageKey);
    } catch (_) {
      return;
    }
    if (flag == null || flag.isEmpty || flag == '0') return;
    final build = <double>[];
    final raster = <double>[];
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final FrameTiming timing in timings) {
        build.add(timing.buildDuration.inMicroseconds / 1000);
        raster.add(timing.rasterDuration.inMicroseconds / 1000);
      }
    });
    print('[frames] frame stats on; remove localStorage "$storageKey" to stop');
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (build.isEmpty) return;
      final total = [
        for (var i = 0; i < build.length; i++) build[i] + raster[i],
      ];
      print(
        '[frames] n=${build.length} '
        'build ${_summary(build)} | raster ${_summary(raster)} | '
        'over 8.3 ms: ${total.where((t) => t > 8.3).length}, '
        'over 16.7 ms: ${total.where((t) => t > 16.7).length}',
      );
      build.clear();
      raster.clear();
    });
  }

  static String _summary(List<double> values) {
    final sorted = [...values]..sort();
    double at(double q) =>
        sorted[math.min(sorted.length - 1, (sorted.length * q).floor())];
    String ms(double v) => v.toStringAsFixed(1);
    return 'p50 ${ms(at(0.5))} p95 ${ms(at(0.95))} max ${ms(sorted.last)}';
  }
}
