import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/repository/sqlite/app_database.dart';

@immutable
class MyDatabasesFocusState {
  factory MyDatabasesFocusState({
    Set<String> hiddenCloudFolderIds = const <String>{},
    List<String>? orderedPinnedDatabaseKeys,
    Set<String>? pinnedDatabaseKeys,
    bool pinnedOrderCustomized = false,
    List<String> orderedFolderKeys = const <String>[],
    Map<String, DateTime> lastOpenedAtByItemKey = const <String, DateTime>{},
    Map<String, double> catalogColumnWidths = const <String, double>{},
    bool listViewPreferred = true,
    bool loaded = false,
  }) {
    final pins = _normalizedStringList(
      orderedPinnedDatabaseKeys ?? pinnedDatabaseKeys ?? const <String>[],
    );
    return MyDatabasesFocusState._(
      hiddenCloudFolderIds: Set<String>.unmodifiable(
        _normalizedStringList(hiddenCloudFolderIds),
      ),
      orderedPinnedDatabaseKeys: List<String>.unmodifiable(pins),
      pinnedDatabaseKeys: Set<String>.unmodifiable(pins),
      pinnedOrderCustomized: pinnedOrderCustomized,
      orderedFolderKeys: List<String>.unmodifiable(
        _normalizedStringList(orderedFolderKeys),
      ),
      lastOpenedAtByItemKey: Map<String, DateTime>.unmodifiable(
        _normalizedLastOpenedAt(lastOpenedAtByItemKey),
      ),
      catalogColumnWidths: Map<String, double>.unmodifiable(
        _normalizedColumnWidths(catalogColumnWidths),
      ),
      listViewPreferred: listViewPreferred,
      loaded: loaded,
    );
  }

  const MyDatabasesFocusState._({
    required this.hiddenCloudFolderIds,
    required this.orderedPinnedDatabaseKeys,
    required this.pinnedDatabaseKeys,
    required this.pinnedOrderCustomized,
    required this.orderedFolderKeys,
    required this.lastOpenedAtByItemKey,
    required this.catalogColumnWidths,
    required this.listViewPreferred,
    required this.loaded,
  });

  final Set<String> hiddenCloudFolderIds;
  final List<String> orderedPinnedDatabaseKeys;

  /// Compatibility membership view for existing Library consumers.
  final Set<String> pinnedDatabaseKeys;
  final bool pinnedOrderCustomized;
  final List<String> orderedFolderKeys;
  final Map<String, DateTime> lastOpenedAtByItemKey;
  final Map<String, double> catalogColumnWidths;
  final bool listViewPreferred;
  final bool loaded;

  MyDatabasesFocusState copyWith({
    Set<String>? hiddenCloudFolderIds,
    List<String>? orderedPinnedDatabaseKeys,
    Set<String>? pinnedDatabaseKeys,
    bool? pinnedOrderCustomized,
    List<String>? orderedFolderKeys,
    Map<String, DateTime>? lastOpenedAtByItemKey,
    Map<String, double>? catalogColumnWidths,
    bool? listViewPreferred,
    bool? loaded,
  }) {
    return MyDatabasesFocusState(
      hiddenCloudFolderIds: hiddenCloudFolderIds ?? this.hiddenCloudFolderIds,
      orderedPinnedDatabaseKeys:
          orderedPinnedDatabaseKeys ??
          (pinnedDatabaseKeys == null ? this.orderedPinnedDatabaseKeys : null),
      pinnedDatabaseKeys: pinnedDatabaseKeys,
      pinnedOrderCustomized:
          pinnedOrderCustomized ?? this.pinnedOrderCustomized,
      orderedFolderKeys: orderedFolderKeys ?? this.orderedFolderKeys,
      lastOpenedAtByItemKey:
          lastOpenedAtByItemKey ?? this.lastOpenedAtByItemKey,
      catalogColumnWidths: catalogColumnWidths ?? this.catalogColumnWidths,
      listViewPreferred: listViewPreferred ?? this.listViewPreferred,
      loaded: loaded ?? this.loaded,
    );
  }
}

String libraryCloudDatabasePinKey(String folderId) {
  return 'cloud:${folderId.trim()}';
}

String libraryLocalDatabasePinKey(String path) {
  final normalized = p.normalize(path.trim());
  final canonical = Platform.isWindows ? normalized.toLowerCase() : normalized;
  return 'local:$canonical';
}

int compareLibraryDatabaseCatalogPinState(bool aPinned, bool bPinned) {
  if (aPinned == bPinned) return 0;
  return aPinned ? -1 : 1;
}

List<String> _normalizedStringList(Iterable<Object?> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    if (value is! String) continue;
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) result.add(trimmed);
  }
  return result;
}

List<String> _stringListField(Object? raw) {
  if (raw is! List<dynamic>) return const <String>[];
  return _normalizedStringList(raw);
}

Map<String, DateTime> _normalizedLastOpenedAt(Map<String, DateTime> values) {
  return <String, DateTime>{
    for (final entry in values.entries)
      if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value.toUtc(),
  };
}

Map<String, DateTime> _lastOpenedAtField(Object? raw) {
  if (raw is! Map<dynamic, dynamic>) return const <String, DateTime>{};
  final result = <String, DateTime>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! String || key.trim().isEmpty) continue;
    final parsed = DateTime.tryParse(value);
    if (parsed != null) result[key.trim()] = parsed.toUtc();
  }
  return result;
}

Map<String, double> _normalizedColumnWidths(Map<String, double> values) {
  return <String, double>{
    for (final entry in values.entries)
      if (entry.key.trim().isNotEmpty &&
          entry.value.isFinite &&
          entry.value > 0)
        entry.key.trim(): entry.value,
  };
}

Map<String, double> _columnWidthsField(Object? raw) {
  if (raw is! Map<dynamic, dynamic>) return const <String, double>{};
  final result = <String, double>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! num || key.trim().isEmpty) continue;
    final width = value.toDouble();
    if (width.isFinite && width > 0) result[key.trim()] = width;
  }
  return result;
}

class MyDatabasesFocusNotifier extends StateNotifier<MyDatabasesFocusState> {
  MyDatabasesFocusNotifier(this._db) : super(MyDatabasesFocusState()) {
    _hydration = _hydrate();
  }

  static const int _recordVersion = 2;
  static const String _stateKvKey = 'desktop.my_databases.focus.v2';
  static const String _hiddenV1KvKey =
      'desktop.my_databases.hidden_cloud_ids.v1';
  static const String _pinnedV1KvKey =
      'desktop.my_databases.pinned_database_keys.v1';

  final AppDatabase _db;
  late final Future<void> _hydration;
  Future<void> _mutationQueue = Future<void>.value();

  @visibleForTesting
  Future<void> get loaded => _hydration;

  Future<void> _hydrate() async {
    final v2 = await _readV2State();
    if (v2 != null) {
      if (!mounted) return;
      state = v2.copyWith(loaded: true);
      return;
    }

    final legacyValues = await Future.wait(<Future<List<String>>>[
      _readLegacyStringList(_hiddenV1KvKey, 'hidden cloud folders'),
      _readLegacyStringList(_pinnedV1KvKey, 'pinned databases'),
    ]);
    final migrated = MyDatabasesFocusState(
      hiddenCloudFolderIds: legacyValues[0].toSet(),
      orderedPinnedDatabaseKeys: legacyValues[1],
      loaded: true,
    );
    if (!mounted) return;
    state = migrated;
    try {
      await _persistSnapshot(migrated);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('MyDatabasesFocus v1 migration persist failed: $error');
      }
    }
  }

  Future<MyDatabasesFocusState?> _readV2State() async {
    Object? raw;
    try {
      raw = await _db.getJson<Object?>(_stateKvKey);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('MyDatabasesFocus v2 hydrate failed: $error');
      }
      return null;
    }
    if (raw is! Map<dynamic, dynamic> || raw['version'] != _recordVersion) {
      return null;
    }
    return MyDatabasesFocusState(
      hiddenCloudFolderIds:
          _stringListField(raw['hiddenCloudFolderIds']).toSet(),
      orderedPinnedDatabaseKeys: _stringListField(
        raw['orderedPinnedDatabaseKeys'],
      ),
      pinnedOrderCustomized:
          raw['pinnedOrderCustomized'] is bool
              ? raw['pinnedOrderCustomized'] as bool
              : false,
      orderedFolderKeys: _stringListField(raw['orderedFolderKeys']),
      lastOpenedAtByItemKey: _lastOpenedAtField(raw['lastOpenedAtByItemKey']),
      catalogColumnWidths: _columnWidthsField(raw['catalogColumnWidths']),
      listViewPreferred:
          raw['listViewPreferred'] is bool
              ? raw['listViewPreferred'] as bool
              : true,
    );
  }

  Future<List<String>> _readLegacyStringList(String key, String label) async {
    try {
      return _stringListField(await _db.getJson<Object?>(key));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('MyDatabasesFocus $label v1 hydrate failed: $error');
      }
      return const <String>[];
    }
  }

  Future<void> hideCloudFolder(String folderId) {
    final id = folderId.trim();
    if (id.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      final pinKey = libraryCloudDatabasePinKey(id);
      final alreadyHidden = current.hiddenCloudFolderIds.contains(id);
      final isPinned = current.pinnedDatabaseKeys.contains(pinKey);
      if (alreadyHidden && !isPinned) return current;
      return current.copyWith(
        hiddenCloudFolderIds: <String>{...current.hiddenCloudFolderIds, id},
        orderedPinnedDatabaseKeys: <String>[
          for (final key in current.orderedPinnedDatabaseKeys)
            if (key != pinKey) key,
        ],
      );
    });
  }

  Future<void> showCloudFolder(String folderId) {
    final id = folderId.trim();
    if (id.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      if (!current.hiddenCloudFolderIds.contains(id)) return current;
      return current.copyWith(
        hiddenCloudFolderIds: (<String>{...current.hiddenCloudFolderIds}
          ..remove(id)),
      );
    });
  }

  Future<void> pinDatabase(String databaseKey) {
    final key = databaseKey.trim();
    if (key.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      if (current.pinnedDatabaseKeys.contains(key)) return current;
      return current.copyWith(
        orderedPinnedDatabaseKeys: <String>[
          ...current.orderedPinnedDatabaseKeys,
          key,
        ],
        pinnedOrderCustomized: true,
      );
    });
  }

  Future<void> unpinDatabase(String databaseKey) {
    final key = databaseKey.trim();
    if (key.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      if (!current.pinnedDatabaseKeys.contains(key)) return current;
      return current.copyWith(
        orderedPinnedDatabaseKeys: <String>[
          for (final candidate in current.orderedPinnedDatabaseKeys)
            if (candidate != key) candidate,
        ],
      );
    });
  }

  Future<void> reorderPinnedDatabase(String databaseKey, int newIndex) {
    final key = databaseKey.trim();
    if (key.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      final reordered = _reordered(
        current.orderedPinnedDatabaseKeys,
        key,
        newIndex,
      );
      if (reordered == null) return current;
      return current.copyWith(
        orderedPinnedDatabaseKeys: reordered,
        pinnedOrderCustomized: true,
      );
    });
  }

  Future<void> setPinnedDatabaseOrder(Iterable<String> databaseKeys) {
    final normalized = _normalizedStringList(databaseKeys);
    return _queueMutation((current) {
      final requested = normalized
          .where(current.pinnedDatabaseKeys.contains)
          .toList(growable: true);
      for (final key in current.orderedPinnedDatabaseKeys) {
        if (!requested.contains(key)) requested.add(key);
      }
      if (listEquals(current.orderedPinnedDatabaseKeys, requested)) {
        return current;
      }
      return current.copyWith(
        orderedPinnedDatabaseKeys: requested,
        pinnedOrderCustomized: true,
      );
    });
  }

  Future<void> setFolderOrder(Iterable<String> folderKeys) {
    final normalized = _normalizedStringList(folderKeys);
    return _queueMutation((current) {
      if (listEquals(current.orderedFolderKeys, normalized)) return current;
      return current.copyWith(orderedFolderKeys: normalized);
    });
  }

  Future<void> reorderFolder(String folderKey, int newIndex) {
    final key = folderKey.trim();
    if (key.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      final reordered = _reordered(current.orderedFolderKeys, key, newIndex);
      if (reordered == null) return current;
      return current.copyWith(orderedFolderKeys: reordered);
    });
  }

  Future<void> recordSuccessfulOpen(String itemKey, {DateTime? openedAt}) {
    final key = itemKey.trim();
    if (key.isEmpty) return Future<void>.value();
    final timestamp = (openedAt ?? DateTime.now()).toUtc();
    return _queueMutation((current) {
      if (current.lastOpenedAtByItemKey[key] == timestamp) return current;
      return current.copyWith(
        lastOpenedAtByItemKey: <String, DateTime>{
          ...current.lastOpenedAtByItemKey,
          key: timestamp,
        },
      );
    });
  }

  Future<void> setCatalogColumnWidth(String columnKey, double width) {
    final key = columnKey.trim();
    if (key.isEmpty || !width.isFinite || width <= 0) {
      return Future<void>.value();
    }
    return _queueMutation((current) {
      if (current.catalogColumnWidths[key] == width) return current;
      return current.copyWith(
        catalogColumnWidths: <String, double>{
          ...current.catalogColumnWidths,
          key: width,
        },
      );
    });
  }

  Future<void> clearCatalogColumnWidth(String columnKey) {
    final key = columnKey.trim();
    if (key.isEmpty) return Future<void>.value();
    return _queueMutation((current) {
      if (!current.catalogColumnWidths.containsKey(key)) return current;
      return current.copyWith(
        catalogColumnWidths: (<String, double>{...current.catalogColumnWidths}
          ..remove(key)),
      );
    });
  }

  Future<void> resetCatalogColumnWidths() {
    return _queueMutation((current) {
      if (current.catalogColumnWidths.isEmpty) return current;
      return current.copyWith(catalogColumnWidths: const <String, double>{});
    });
  }

  Future<void> setListViewPreferred(bool preferred) {
    return _queueMutation((current) {
      if (current.listViewPreferred == preferred) return current;
      return current.copyWith(listViewPreferred: preferred);
    });
  }

  Future<void> _queueMutation(
    MyDatabasesFocusState Function(MyDatabasesFocusState current) mutation,
  ) {
    final result = _mutationQueue.then((_) async {
      await _hydration;
      if (!mounted) return;
      final previous = state;
      final next = mutation(previous);
      if (identical(previous, next)) return;

      state = next;
      try {
        await _persistSnapshot(next);
      } catch (error, stackTrace) {
        if (mounted && identical(state, next)) state = previous;
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _persistSnapshot(MyDatabasesFocusState snapshot) {
    final hidden = snapshot.hiddenCloudFolderIds.toList()..sort();
    final timestamps = <String, String>{};
    final timestampKeys = snapshot.lastOpenedAtByItemKey.keys.toList()..sort();
    for (final key in timestampKeys) {
      timestamps[key] =
          snapshot.lastOpenedAtByItemKey[key]!.toUtc().toIso8601String();
    }
    final widths = <String, double>{};
    final widthKeys = snapshot.catalogColumnWidths.keys.toList()..sort();
    for (final key in widthKeys) {
      widths[key] = snapshot.catalogColumnWidths[key]!;
    }
    return _db.setJson(_stateKvKey, <String, Object?>{
      'version': _recordVersion,
      'hiddenCloudFolderIds': hidden,
      'orderedPinnedDatabaseKeys': snapshot.orderedPinnedDatabaseKeys.toList(),
      'pinnedOrderCustomized': snapshot.pinnedOrderCustomized,
      'orderedFolderKeys': snapshot.orderedFolderKeys.toList(),
      'lastOpenedAtByItemKey': timestamps,
      'catalogColumnWidths': widths,
      'listViewPreferred': snapshot.listViewPreferred,
    });
  }

  static List<String>? _reordered(
    List<String> values,
    String key,
    int newIndex,
  ) {
    final oldIndex = values.indexOf(key);
    if (oldIndex < 0 || values.length < 2) return null;
    final targetIndex =
        newIndex < 0
            ? 0
            : newIndex >= values.length
            ? values.length - 1
            : newIndex;
    if (oldIndex == targetIndex) return null;
    final reordered = values.toList()..removeAt(oldIndex);
    reordered.insert(targetIndex, key);
    return reordered;
  }
}

final myDatabasesFocusProvider =
    StateNotifierProvider<MyDatabasesFocusNotifier, MyDatabasesFocusState>((
      ref,
    ) {
      return MyDatabasesFocusNotifier(ref.watch(appDatabaseProvider));
    });
