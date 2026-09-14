import 'dart:async';

/// Serializes quota admission (COUNT, then INSERT) within one process.
///
/// Snapshot the previous tail before registering this operation. Completion,
/// including failure, always releases successors; no request awaits itself.
///
/// This is a client admission aid, not a reservation: separate devices or
/// processes can still race, and only an atomic server transaction can
/// enforce a cross-device quota.
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
