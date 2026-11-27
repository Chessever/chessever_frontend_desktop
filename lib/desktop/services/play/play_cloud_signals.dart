import 'dart:async';

/// Process-wide signals between the Play stores on this device and the
/// cloud sync (`playCloudSyncProvider`).
///
/// [localChanged] fires when a Play document changed on this device and
/// should reach the server soon (a claimed badge, a profile edit).
/// [localReplaced] fires when the sync rewrote the device's Play documents
/// from the server (a newer rewards state, a switch to another account),
/// so in-memory copies such as `PlayAchievementsNotifier` reload them.
class PlayCloudSignals {
  PlayCloudSignals._();

  static final StreamController<void> _changed =
      StreamController<void>.broadcast();
  static final StreamController<bool> _replaced =
      StreamController<bool>.broadcast();

  static Stream<void> get localChanged => _changed.stream;

  /// Carries true when the documents now belong to another account.
  static Stream<bool> get localReplaced => _replaced.stream;

  static void notifyLocalChanged() => _changed.add(null);
  static void notifyLocalReplaced({bool accountChanged = false}) =>
      _replaced.add(accountChanged);
}
