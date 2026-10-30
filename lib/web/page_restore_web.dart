import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Completes with true when the browser shows this page again from its
/// back-forward cache (the user pressed Back), or false after [timeout] if
/// the page never left. Once the page unloads, neither ever happens.
Future<bool> awaitPageRestore(Duration timeout) {
  final completer = Completer<bool>();
  late final JSFunction listener;
  late final Timer timer;
  void finish(bool restored) {
    if (completer.isCompleted) return;
    timer.cancel();
    web.window.removeEventListener('pageshow', listener);
    completer.complete(restored);
  }

  listener =
      ((web.PageTransitionEvent event) {
        if (event.persisted) finish(true);
      }).toJS;
  timer = Timer(timeout, () => finish(false));
  web.window.addEventListener('pageshow', listener);
  return completer.future;
}
