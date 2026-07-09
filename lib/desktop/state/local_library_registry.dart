import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

const Object _localLibraryUnset = Object();
const String playerWorkspaceLocalLibraryGroupPrefix = 'player-workspace:';
const String playerWorkspaceCombinedSourceKey = 'combined';

String? playerWorkspaceIdFromLocalLibraryGroupId(String? groupId) {
  final clean = groupId?.trim();
  if (clean == null ||
      !clean.startsWith(playerWorkspaceLocalLibraryGroupPrefix)) {
    return null;
  }
  final playerId = clean.substring(
    playerWorkspaceLocalLibraryGroupPrefix.length,
  );
  return playerId.isEmpty ? null : playerId;
}

/// Whether [entry] is the generated Combined database for a Players folder.
///
/// New entries carry an explicit source key. The filename fallback keeps
/// registries written by older app versions correctly ordered.
bool localLibraryEntryIsPlayerWorkspaceCombined(LocalLibraryEntry entry) {
  if (entry.playerWorkspaceSource == playerWorkspaceCombinedSourceKey) {
    return true;
  }
  if (entry.playerWorkspaceSource != null) return false;
  final stem = p.basenameWithoutExtension(entry.path).trim().toLowerCase();
  return stem == playerWorkspaceCombinedSourceKey ||
      stem.startsWith('${playerWorkspaceCombinedSourceKey}_') ||
      stem.startsWith('$playerWorkspaceCombinedSourceKey-');
}

/// Persisted user-registered local PGN folders. Each entry represents a
/// directory on disk the user treats as a chess "database" — games saved
/// here are written as individual `.pgn` files and remain on the user's
/// machine independent of the cloud library.
@immutable
class LocalLibraryEntry {
  const LocalLibraryEntry({
    required this.path,
    required this.addedAt,
    this.gameCount,
    this.indexedAt,
    this.groupId,
    this.groupLabel,
    this.playerWorkspaceSource,
  });

  factory LocalLibraryEntry.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String;
    final explicitGroupId = _stringOrNull(json['groupId']);
    final explicitGroupLabel = _stringOrNull(json['groupLabel']);
    final inferredGroup = _inferPlayerWorkspaceGroup(path);
    return LocalLibraryEntry(
      path: path,
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      gameCount: _jsonInt(json['gameCount']),
      indexedAt: _jsonDateTime(json['indexedAt']),
      groupId: explicitGroupId ?? inferredGroup?.id,
      groupLabel: explicitGroupLabel ?? inferredGroup?.label,
      playerWorkspaceSource: _stringOrNull(json['playerWorkspaceSource']),
    );
  }

  final String path;
  final DateTime addedAt;
  final int? gameCount;
  final DateTime? indexedAt;
  final String? groupId;
  final String? groupLabel;
  final String? playerWorkspaceSource;

  String get displayName {
    return localChessDatabaseDisplayNameForPath(path);
  }

  LocalLibraryEntry copyWith({
    String? path,
    DateTime? addedAt,
    Object? gameCount = _localLibraryUnset,
    Object? indexedAt = _localLibraryUnset,
    Object? groupId = _localLibraryUnset,
    Object? groupLabel = _localLibraryUnset,
    Object? playerWorkspaceSource = _localLibraryUnset,
  }) {
    return LocalLibraryEntry(
      path: path ?? this.path,
      addedAt: addedAt ?? this.addedAt,
      gameCount:
          identical(gameCount, _localLibraryUnset)
              ? this.gameCount
              : gameCount as int?,
      indexedAt:
          identical(indexedAt, _localLibraryUnset)
              ? this.indexedAt
              : indexedAt as DateTime?,
      groupId:
          identical(groupId, _localLibraryUnset)
              ? this.groupId
              : groupId as String?,
      groupLabel:
          identical(groupLabel, _localLibraryUnset)
              ? this.groupLabel
              : groupLabel as String?,
      playerWorkspaceSource:
          identical(playerWorkspaceSource, _localLibraryUnset)
              ? this.playerWorkspaceSource
              : playerWorkspaceSource as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'addedAt': addedAt.toIso8601String(),
      if (gameCount != null) 'gameCount': gameCount,
      if (indexedAt != null) 'indexedAt': indexedAt!.toIso8601String(),
      if (groupId != null) 'groupId': groupId,
      if (groupLabel != null) 'groupLabel': groupLabel,
      if (playerWorkspaceSource != null)
        'playerWorkspaceSource': playerWorkspaceSource,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LocalLibraryEntry &&
            path == other.path &&
            addedAt == other.addedAt &&
            gameCount == other.gameCount &&
            indexedAt == other.indexedAt &&
            groupId == other.groupId &&
            groupLabel == other.groupLabel &&
            playerWorkspaceSource == other.playerWorkspaceSource;
  }

  @override
  int get hashCode => Object.hash(
    path,
    addedAt,
    gameCount,
    indexedAt,
    groupId,
    groupLabel,
    playerWorkspaceSource,
  );
}

@immutable
class LocalLibraryEntryMetadata {
  const LocalLibraryEntryMetadata({
    this.gameCount,
    this.indexedAt,
    this.groupId,
    this.groupLabel,
    this.playerWorkspaceSource,
  });

  factory LocalLibraryEntryMetadata.playerWorkspace({
    required String playerId,
    required String playerName,
    int? gameCount,
    DateTime? indexedAt,
    String? playerWorkspaceSource,
  }) {
    final cleanId = playerId.trim();
    final cleanName = playerName.trim();
    return LocalLibraryEntryMetadata(
      gameCount: gameCount,
      indexedAt: indexedAt,
      groupId:
          cleanId.isEmpty
              ? null
              : '$playerWorkspaceLocalLibraryGroupPrefix$cleanId',
      groupLabel: cleanName.isEmpty ? 'Player databases' : cleanName,
      playerWorkspaceSource: _stringOrNull(playerWorkspaceSource),
    );
  }

  final int? gameCount;
  final DateTime? indexedAt;
  final String? groupId;
  final String? groupLabel;
  final String? playerWorkspaceSource;
}

@immutable
class LocalLibraryRegistryState {
  const LocalLibraryRegistryState({
    this.entries = const <LocalLibraryEntry>[],
    this.loaded = false,
  });

  final List<LocalLibraryEntry> entries;
  final bool loaded;

  LocalLibraryRegistryState copyWith({
    List<LocalLibraryEntry>? entries,
    bool? loaded,
  }) {
    return LocalLibraryRegistryState(
      entries: entries ?? this.entries,
      loaded: loaded ?? this.loaded,
    );
  }
}

class LocalLibraryRegistryNotifier
    extends StateNotifier<LocalLibraryRegistryState> {
  LocalLibraryRegistryNotifier(this._db)
    : super(const LocalLibraryRegistryState()) {
    _hydration = _hydrate();
  }

  static const String _kvKey = 'desktop.local_libraries.v1';

  final AppDatabase _db;
  late final Future<void> _hydration;

  Future<void> _hydrate() async {
    try {
      final raw = await _db.getJson<List<dynamic>>(_kvKey);
      final entries = <LocalLibraryEntry>[];
      if (raw != null) {
        for (final item in raw) {
          if (item is Map) {
            try {
              entries.add(
                LocalLibraryEntry.fromJson(item.cast<String, dynamic>()),
              );
            } catch (_) {}
          }
        }
      }
      if (!mounted) return;
      state = state.copyWith(entries: entries, loaded: true);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loaded: true);
      if (kDebugMode) {
        debugPrint('LocalLibraryRegistry hydrate failed: $e');
      }
    }
  }

  Future<void> _persist(List<LocalLibraryEntry> entries) async {
    try {
      await _db.setJson(_kvKey, entries.map((e) => e.toJson()).toList());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LocalLibraryRegistry persist failed: $e');
      }
    }
  }

  /// Register [path] as a local database root. No-op if already registered.
  /// Returns the (possibly normalized) entry path.
  Future<String> register(String path) async {
    final entries = await registerAll(<String>[path]);
    return entries.isEmpty ? path : entries.first.path;
  }

  /// Register every opened local PGN/file/folder as a removable My Databases item.
  /// Duplicate paths preserve the original entry and insertion time.
  Future<List<LocalLibraryEntry>> registerAll(
    List<String> paths, {
    Map<String, LocalLibraryEntryMetadata> metadataByPath = const {},
  }) async {
    await _hydration;
    if (paths.isEmpty) return const <LocalLibraryEntry>[];

    final normalizedMetadata = <String, LocalLibraryEntryMetadata>{};
    for (final entry in metadataByPath.entries) {
      final normalized = _canonical(entry.key);
      if (normalized.isNotEmpty) normalizedMetadata[normalized] = entry.value;
    }

    final next = <LocalLibraryEntry>[...state.entries];
    final registered = <LocalLibraryEntry>[];
    var changed = false;
    for (final path in paths) {
      final normalized = _canonical(path);
      if (normalized.isEmpty) continue;
      final metadata = normalizedMetadata[normalized];
      final inferredGroup = _inferPlayerWorkspaceGroup(path);
      final hit = next.indexWhere((e) => _canonical(e.path) == normalized);
      if (hit >= 0) {
        final updated = _entryWithMetadata(
          next[hit],
          metadata,
          inferredGroup: inferredGroup,
        );
        if (updated != next[hit]) {
          next[hit] = updated;
          changed = true;
        }
        registered.add(updated);
        continue;
      }
      final entry = LocalLibraryEntry(
        path: path,
        addedAt: DateTime.now(),
        gameCount: metadata?.gameCount,
        indexedAt: metadata?.indexedAt,
        groupId: metadata?.groupId ?? inferredGroup?.id,
        groupLabel: metadata?.groupLabel ?? inferredGroup?.label,
        playerWorkspaceSource: metadata?.playerWorkspaceSource,
      );
      next.add(entry);
      registered.add(entry);
      changed = true;
    }

    if (changed) {
      state = state.copyWith(entries: next);
      await _persist(next);
    }
    return registered;
  }

  /// Drop [path] from the registry. Files on disk are not touched.
  Future<void> unregister(String path) async {
    await _hydration;
    final normalized = _canonical(path);
    final next = state.entries
        .where((e) => _canonical(e.path) != normalized)
        .toList(growable: false);
    if (next.length == state.entries.length) return;
    state = state.copyWith(entries: next);
    await _persist(next);
  }

  /// Drop every registered local database that belongs to a Players workspace.
  ///
  /// [paths] lets callers remove legacy entries whose persisted group id was
  /// inferred from the on-disk player directory rather than the stable player id.
  Future<void> unregisterPlayerWorkspace(
    String playerId, {
    Iterable<String> paths = const <String>[],
  }) async {
    await _hydration;
    final cleanPlayerId = playerId.trim();
    final groupId =
        cleanPlayerId.isEmpty
            ? null
            : '$playerWorkspaceLocalLibraryGroupPrefix$cleanPlayerId';
    final canonicalPaths =
        paths.map(_canonical).where((path) => path.isNotEmpty).toSet();
    final parentDirs = <String>{
      for (final path in canonicalPaths) _canonical(p.dirname(path)),
    }..removeWhere((path) => path.isEmpty || path == '.');
    if (groupId == null && canonicalPaths.isEmpty && parentDirs.isEmpty) return;

    bool belongsToPlayerWorkspace(LocalLibraryEntry entry) {
      final entryGroupId = entry.groupId?.trim();
      if (groupId != null && entryGroupId == groupId) return true;
      final canonicalPath = _canonical(entry.path);
      if (canonicalPaths.contains(canonicalPath)) return true;
      for (final dir in parentDirs) {
        if (canonicalPath == dir || p.isWithin(dir, canonicalPath)) {
          return true;
        }
      }
      return false;
    }

    final next = state.entries
        .where((entry) => !belongsToPlayerWorkspace(entry))
        .toList(growable: false);
    if (next.length == state.entries.length) return;
    state = state.copyWith(entries: next);
    await _persist(next);
  }

  String _canonical(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final normalized = p.normalize(trimmed);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  LocalLibraryEntry _entryWithMetadata(
    LocalLibraryEntry entry,
    LocalLibraryEntryMetadata? metadata, {
    _InferredLocalLibraryGroup? inferredGroup,
  }) {
    if (metadata == null && inferredGroup == null) return entry;
    return entry.copyWith(
      gameCount: metadata?.gameCount ?? entry.gameCount,
      indexedAt: metadata?.indexedAt ?? entry.indexedAt,
      groupId: metadata?.groupId ?? entry.groupId ?? inferredGroup?.id,
      groupLabel:
          metadata?.groupLabel ?? entry.groupLabel ?? inferredGroup?.label,
      playerWorkspaceSource:
          metadata?.playerWorkspaceSource ?? entry.playerWorkspaceSource,
    );
  }
}

final localLibraryRegistryProvider = StateNotifierProvider<
  LocalLibraryRegistryNotifier,
  LocalLibraryRegistryState
>((ref) {
  return LocalLibraryRegistryNotifier(ref.watch(appDatabaseProvider));
});

int? _jsonInt(Object? value) {
  final parsed = switch (value) {
    int() => value,
    num() => value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

DateTime? _jsonDateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

String? _stringOrNull(Object? value) {
  final clean = value?.toString().trim();
  return clean == null || clean.isEmpty ? null : clean;
}

@immutable
class _InferredLocalLibraryGroup {
  const _InferredLocalLibraryGroup({required this.id, required this.label});

  final String id;
  final String label;
}

_InferredLocalLibraryGroup? _inferPlayerWorkspaceGroup(String path) {
  final parts = p.split(p.normalize(path));
  final index = parts.lastIndexWhere((part) => part == 'player-workspace');
  if (index < 0 || index + 1 >= parts.length) return null;
  final directory = parts[index + 1].trim();
  if (directory.isEmpty) return null;
  return _InferredLocalLibraryGroup(
    id: '$playerWorkspaceLocalLibraryGroupPrefix$directory',
    label: _playerWorkspaceGroupLabel(directory),
  );
}

String _playerWorkspaceGroupLabel(String directory) {
  final withoutPrefix = directory.replaceFirst(RegExp(r'^player-\d+-'), '');
  final words = withoutPrefix
      .split(RegExp(r'[-_\s]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return 'Player databases';
  return words
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}
