import 'dart:async';

/// Serializes quota admission within one process, first in first out.
///
/// Lifted from PR #238. The previous tail is snapshotted before this operation
/// registers itself, so no request ever awaits its own completion, and the
/// slot is released in `finally`, so an action that throws never stalls the
/// requests queued behind it.
///
/// Scope is one Dart isolate. A detached board window runs its own engine and
/// Riverpod container and therefore its own queue. Races across processes and
/// devices are settled by the server (`docs/freemium_quota_contract.sql`),
/// never by this queue.
class FreemiumQuotaQueue {
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
