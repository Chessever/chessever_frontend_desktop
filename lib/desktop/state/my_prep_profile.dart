import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

/// Which Players (Prepare) workspace profile is the signed-in user's own.
///
/// Mobile's My Prep keeps the reader's own profile (`PrepKind.mine`) apart
/// from the opponents they prepare against. Desktop prep profiles all live in
/// the Players workspace, so "mine" is a pointer to one of them, kept outside
/// the workspace snapshot so the prep model and its persistence stay
/// untouched. A pointer whose profile was removed reads as unlinked.
class MyPrepProfileStore {
  MyPrepProfileStore({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  static const String storageKey = 'desktop_my_prep_player_id';

  final AppDatabase _database;

  Future<String?> read() async {
    final raw = await _database.getJson<Object?>(storageKey);
    if (raw is! Map) return null;
    final id = raw['playerId']?.toString().trim();
    return id == null || id.isEmpty ? null : id;
  }

  Future<void> write(String? playerId) async {
    final id = playerId?.trim();
    if (id == null || id.isEmpty) {
      await _database.remove(storageKey);
      return;
    }
    await _database.setJson(storageKey, <String, Object?>{'playerId': id});
  }
}

final myPrepProfileStoreProvider = Provider<MyPrepProfileStore>(
  (_) => MyPrepProfileStore(),
);

class MyPrepPlayerIdNotifier extends StateNotifier<AsyncValue<String?>> {
  MyPrepPlayerIdNotifier(this._store) : super(const AsyncValue.loading()) {
    _load();
  }

  final MyPrepProfileStore _store;

  Future<void> _load() async {
    try {
      final id = await _store.read();
      if (mounted) state = AsyncValue.data(id);
    } catch (error, stackTrace) {
      debugPrint('My prep profile could not load: $error');
      if (mounted) state = AsyncValue.error(error, stackTrace);
    }
  }

  /// Marks [playerId] as the user's own prep profile.
  Future<void> link(String playerId) async {
    final id = playerId.trim();
    if (id.isEmpty) return;
    state = AsyncValue.data(id);
    await _store.write(id);
  }

  /// Forgets the pointer. The prep profile itself stays in Players.
  Future<void> unlink() async {
    state = const AsyncValue.data(null);
    await _store.write(null);
  }
}

final myPrepPlayerIdProvider =
    StateNotifierProvider<MyPrepPlayerIdNotifier, AsyncValue<String?>>(
      (ref) => MyPrepPlayerIdNotifier(ref.watch(myPrepProfileStoreProvider)),
    );

/// The user's own prep profile, or null while unlinked or when the linked
/// profile no longer exists in the Players workspace.
final myPrepPlayerIdIfPresentProvider = Provider<String?>((ref) {
  final id = ref.watch(myPrepPlayerIdProvider).valueOrNull;
  if (id == null) return null;
  final exists = ref.watch(
    playerWorkspaceProvider.select(
      (state) => state.players.any((player) => player.id == id),
    ),
  );
  return exists ? id : null;
});
