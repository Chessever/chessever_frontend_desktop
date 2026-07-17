import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

/// Small shared cache for Player Overview and Games.
///
/// Both surfaces need the same header-only PGN catalog. Keeping the most recent
/// catalogs here avoids a second file scan when the user switches tabs, while
/// the file stat and workspace revision still invalidate stale data.
class PlayerPgnCatalog {
  PlayerPgnCatalog._();

  static final PlayerPgnCatalog instance = PlayerPgnCatalog._();

  static const int _maxEntries = 3;
  final Map<String, _PlayerPgnCatalogEntry> _entries =
      <String, _PlayerPgnCatalogEntry>{};

  Future<LocalChessSource> load(String path) async {
    final clean = p.normalize(path.trim());
    if (clean.isEmpty) throw ArgumentError('No PGN path was provided.');
    final stat = await File(clean).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Player PGN is not available.', clean);
    }
    final key = Platform.isWindows ? clean.toLowerCase() : clean;
    final cached = _entries[key];
    if (cached != null &&
        cached.sizeBytes == stat.size &&
        cached.modifiedAt == stat.modified) {
      // Refresh insertion order so the active player's sources stay cached.
      _entries
        ..remove(key)
        ..[key] = cached;
      return cached.source;
    }

    final source = scanLocalChessPgnCatalog(clean);
    _entries[key] = _PlayerPgnCatalogEntry(
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      source: source,
    );
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    try {
      return await source;
    } catch (_) {
      if (identical(_entries[key]?.source, source)) _entries.remove(key);
      rethrow;
    }
  }

  void invalidate(String path) {
    final clean = p.normalize(path.trim());
    final key = Platform.isWindows ? clean.toLowerCase() : clean;
    _entries.remove(key);
  }

  void clear() => _entries.clear();
}

class _PlayerPgnCatalogEntry {
  const _PlayerPgnCatalogEntry({
    required this.sizeBytes,
    required this.modifiedAt,
    required this.source,
  });

  final int sizeBytes;
  final DateTime modifiedAt;
  final Future<LocalChessSource> source;
}
