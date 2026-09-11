import 'dart:async';

/// Snapshot the previous tail before registering this operation. Completion,
/// including failure, always releases successors; no request awaits itself.
class DesktopQuotaQueue {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }
}
