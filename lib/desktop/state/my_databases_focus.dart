import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/sqlite/app_database.dart';

@immutable
class MyDatabasesFocusState {
  const MyDatabasesFocusState({
    this.hiddenCloudFolderIds = const <String>{},
    this.loaded = false,
  });

  final Set<String> hiddenCloudFolderIds;
  final bool loaded;

  MyDatabasesFocusState copyWith({
    Set<String>? hiddenCloudFolderIds,
    bool? loaded,
  }) {
    return MyDatabasesFocusState(
      hiddenCloudFolderIds: hiddenCloudFolderIds ?? this.hiddenCloudFolderIds,
      loaded: loaded ?? this.loaded,
    );
  }
}

class MyDatabasesFocusNotifier extends StateNotifier<MyDatabasesFocusState> {
  MyDatabasesFocusNotifier(this._db) : super(const MyDatabasesFocusState()) {
    _hydrate();
  }

  static const String _kvKey = 'desktop.my_databases.hidden_cloud_ids.v1';

  final AppDatabase _db;

  Future<void> _hydrate() async {
    try {
      final raw = await _db.getJson<List<dynamic>>(_kvKey);
      final ids = <String>{};
      if (raw != null) {
        for (final item in raw) {
          if (item is String && item.trim().isNotEmpty) ids.add(item.trim());
        }
      }
      if (!mounted) return;
      state = state.copyWith(hiddenCloudFolderIds: ids, loaded: true);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loaded: true);
      if (kDebugMode) {
        debugPrint('MyDatabasesFocus hydrate failed: $e');
      }
    }
  }

  Future<void> hideCloudFolder(String folderId) async {
    final id = folderId.trim();
    if (id.isEmpty || state.hiddenCloudFolderIds.contains(id)) return;
    final next = <String>{...state.hiddenCloudFolderIds, id};
    state = state.copyWith(hiddenCloudFolderIds: next);
    await _persist(next);
  }

  Future<void> showCloudFolder(String folderId) async {
    final id = folderId.trim();
    if (id.isEmpty || !state.hiddenCloudFolderIds.contains(id)) return;
    final next = <String>{...state.hiddenCloudFolderIds}..remove(id);
    state = state.copyWith(hiddenCloudFolderIds: next);
    await _persist(next);
  }

  Future<void> _persist(Set<String> ids) async {
    try {
      final sorted = ids.toList()..sort();
      await _db.setJson(_kvKey, sorted);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('MyDatabasesFocus persist failed: $e');
      }
    }
  }
}

final myDatabasesFocusProvider =
    StateNotifierProvider<MyDatabasesFocusNotifier, MyDatabasesFocusState>((
      ref,
    ) {
      return MyDatabasesFocusNotifier(ref.watch(appDatabaseProvider));
    });
