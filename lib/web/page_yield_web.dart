import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

final web.MessageChannel _channel = () {
  final channel = web.MessageChannel();
  channel.port1.onmessage =
      ((web.MessageEvent _) {
        final waiting = _waiting;
        _waiting = null;
        waiting?.complete();
      }).toJS;
  return channel;
}();

Completer<void>? _waiting;

/// A message to ourselves is a new task, like `setTimeout(0)`, without the
/// 4 ms minimum browsers apply to nested timers, which would otherwise cost
/// a third of a worker's time.
Future<void> nextBrowserTask() {
  final waiting = _waiting;
  if (waiting != null) return waiting.future;
  final next = _waiting = Completer<void>();
  _channel.port2.postMessage(null);
  return next.future;
}
