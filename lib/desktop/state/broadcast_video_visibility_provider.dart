import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local spectator preference, like the remembered stream language.
/// Keyed by the stable owning event, never the round, game or resolved stream
/// source (several events can inherit the same source). It intentionally also
/// applies while signed out; it is not a cloud/account setting.
class BroadcastVideoVisibility extends FamilyAsyncNotifier<bool, String> {
  static String storageKey(String eventId) => 'ce-video-visible.v1:$eventId';

  Future<void> _writes = Future<void>.value();

  @override
  Future<bool> build(String arg) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(storageKey(arg)) ?? true;
  }

  /// Called only after restoration completes. Publish intent synchronously;
  /// serialize disk writes so a slower hide cannot overwrite a later show.
  Future<void> remember(bool visible) {
    state = AsyncData(visible);
    final key = storageKey(arg);
    final write = _writes.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool(key, visible)) {
        throw StateError('Could not save video visibility');
      }
    });
    // A failed write must not poison the queue for the next explicit choice.
    _writes = write.catchError((Object _) {});
    return write;
  }
}

final broadcastVideoVisibilityProvider =
    AsyncNotifierProvider.family<BroadcastVideoVisibility, bool, String>(
      BroadcastVideoVisibility.new,
    );
