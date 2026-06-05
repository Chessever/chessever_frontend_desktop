import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/repository/sqlite/app_database.dart';

/// Persisted user-registered local PGN folders. Each entry represents a
/// directory on disk the user treats as a chess "database" — games saved
/// here are written as individual `.pgn` files and remain on the user's
/// machine independent of the cloud library.
@immutable
class LocalLibraryEntry {
  const LocalLibraryEntry({required this.path, required this.addedAt});

  factory LocalLibraryEntry.fromJson(Map<String, dynamic> json) {
    return LocalLibraryEntry(
      path: json['path'] as String,
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  final String path;
  final DateTime addedAt;

  String get displayName {
    final base = p.basename(p.normalize(path));
    return base.isEmpty ? path : base;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'addedAt': addedAt.toIso8601String(),
  };
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
    _hydrate();
  }

  static const String _kvKey = 'desktop.local_libraries.v1';

  final AppDatabase _db;

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
  Future<List<LocalLibraryEntry>> registerAll(List<String> paths) async {
    if (paths.isEmpty) return const <LocalLibraryEntry>[];

    final next = <LocalLibraryEntry>[...state.entries];
    final registered = <LocalLibraryEntry>[];
    var changed = false;
    for (final path in paths) {
      final normalized = _canonical(path);
      if (normalized.isEmpty) continue;
      final hit = next.indexWhere((e) => _canonical(e.path) == normalized);
      if (hit >= 0) {
        registered.add(next[hit]);
        continue;
      }
      final entry = LocalLibraryEntry(path: path, addedAt: DateTime.now());
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
    final normalized = _canonical(path);
    final next = state.entries
        .where((e) => _canonical(e.path) != normalized)
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
}

final localLibraryRegistryProvider = StateNotifierProvider<
  LocalLibraryRegistryNotifier,
  LocalLibraryRegistryState
>((ref) {
  return LocalLibraryRegistryNotifier(ref.watch(appDatabaseProvider));
});
