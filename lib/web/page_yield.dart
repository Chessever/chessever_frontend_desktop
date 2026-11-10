// The local library's workers are isolates on desktop. The browser build
// runs the same code on the page's only thread (shims/isolate_web.dart), so a
// long parse or tree build there has to hand the thread back now and then,
// or the page neither paints nor sees a click on Cancel until it ends.
//
// Call this from a worker's per-item loop:
//
//     if (pageYieldDue) await yieldToPage();
//
// Native builds compile the check to `false`.
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:chessever/web/page_yield_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/page_yield_web.dart';

/// Work allowed between two yields: long enough to keep the overhead small,
/// short enough for the page to paint and answer input in between.
const int _budgetMicros = 12000;

final Stopwatch _sinceYield = Stopwatch()..start();

bool get pageYieldDue =>
    kIsWeb && _sinceYield.elapsedMicroseconds >= _budgetMicros;

/// Returns after the browser has run its pending events and, if one was
/// due, painted a frame.
Future<void> yieldToPage() async {
  await nextBrowserTask();
  _sinceYield.reset();
}
