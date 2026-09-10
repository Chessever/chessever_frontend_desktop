/// One Board save transaction per UI isolate, shared across tabs and remounts.
/// Acquire before capturing a snapshot; hold through picker/dialog, durable
/// writes and baseline/identity completion. A duplicate is rejected, not queued
/// with a stale snapshot. Detached windows have their own isolate.
final boardSaveBoundary = BoardSaveBoundary();

/// Route dismissal is not cancellation of an already-started write. The list
/// is populated synchronously by dialog actions before their first suspension.
Future<T> waitForSaveDialogWrites<T>(
  Future<T> route,
  List<Future<void>> pendingWrites,
) async {
  try {
    return await route;
  } finally {
    await Future.wait(pendingWrites);
  }
}

class BoardSaveBoundary {
  bool _busy = false;

  Future<bool> tryRun(Future<void> Function() action) async {
    if (_busy) return false;
    _busy = true;
    try {
      await action();
      return true;
    } finally {
      _busy = false;
    }
  }
}
