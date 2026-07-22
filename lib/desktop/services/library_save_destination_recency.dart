import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LibrarySaveDestinationRecency {
  const LibrarySaveDestinationRecency({
    this.cloudFolderIds = const <String>[],
    this.localPathKeys = const <String>[],
  });

  final List<String> cloudFolderIds;
  final List<String> localPathKeys;
}

class LibrarySaveDestinationRecencyStore {
  const LibrarySaveDestinationRecencyStore();

  static const String _cloudKey =
      'desktop.library_save_recent_cloud_destinations.v1';
  static const String _localKey =
      'desktop.library_save_recent_local_destinations.v1';
  static const int _maxRemembered = 50;

  Future<LibrarySaveDestinationRecency> load() async {
    final prefs = await SharedPreferences.getInstance();
    return LibrarySaveDestinationRecency(
      cloudFolderIds: List<String>.unmodifiable(
        prefs.getStringList(_cloudKey) ?? const <String>[],
      ),
      localPathKeys: List<String>.unmodifiable(
        prefs.getStringList(_localKey) ?? const <String>[],
      ),
    );
  }

  Future<void> recordSuccessfulSave({
    required List<String> cloudFolderIds,
    required List<String> localPathKeys,
  }) async {
    if (cloudFolderIds.isEmpty && localPathKeys.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (cloudFolderIds.isNotEmpty) {
      await prefs.setStringList(
        _cloudKey,
        _promote(
          prefs.getStringList(_cloudKey) ?? const <String>[],
          cloudFolderIds,
        ),
      );
    }
    if (localPathKeys.isNotEmpty) {
      await prefs.setStringList(
        _localKey,
        _promote(
          prefs.getStringList(_localKey) ?? const <String>[],
          localPathKeys,
        ),
      );
    }
  }

  List<String> _promote(List<String> current, List<String> used) {
    final promoted = <String>[];
    final seen = <String>{};
    for (final key in <String>[...used, ...current]) {
      final clean = key.trim();
      if (clean.isEmpty || !seen.add(clean)) continue;
      promoted.add(clean);
      if (promoted.length == _maxRemembered) break;
    }
    return promoted;
  }
}

/// Recency is a convenience only. Once cloud/local writes have committed, a
/// preferences failure must not make the save look failed or invite a retry.
Future<bool> persistLibrarySaveRecencyBestEffort(
  Future<void> Function() persist,
) async {
  try {
    await persist();
    return true;
  } on Object {
    return false;
  }
}

/// Stable most-recent-first ordering used independently by the cloud and local
/// groups in the Library save dialog.
List<T> orderLibrarySaveDestinationsByRecent<T>({
  required List<T> values,
  required List<String> recentKeys,
  required String Function(T value) keyOf,
}) {
  if (values.length < 2 || recentKeys.isEmpty) {
    return List<T>.of(values, growable: false);
  }

  final recentRank = <String, int>{};
  for (var index = 0; index < recentKeys.length; index++) {
    recentRank.putIfAbsent(recentKeys[index], () => index);
  }
  final originalIndex = <T, int>{
    for (var index = 0; index < values.length; index++) values[index]: index,
  };
  final ordered = List<T>.of(values);
  ordered.sort((a, b) {
    final aRank = recentRank[keyOf(a)];
    final bRank = recentRank[keyOf(b)];
    if (aRank != null || bRank != null) {
      if (aRank == null) return 1;
      if (bRank == null) return -1;
      final recentComparison = aRank.compareTo(bRank);
      if (recentComparison != 0) return recentComparison;
    }
    return originalIndex[a]!.compareTo(originalIndex[b]!);
  });
  return List<T>.unmodifiable(ordered);
}

/// Recency-sorts cloud destinations while preserving folder hierarchy.
///
/// A recent nested database promotes its whole branch, then appears before its
/// siblings. Parents remain immediately before their descendants.
List<LibraryFolder> orderLibrarySaveCloudFolders({
  required List<LibraryFolder> folders,
  required List<String> recentFolderIds,
}) {
  if (folders.isEmpty) return const <LibraryFolder>[];

  final ids = folders.map((folder) => folder.id).toSet();
  final originalIndex = <String, int>{
    for (var index = 0; index < folders.length; index++)
      folders[index].id: index,
  };
  final recentRank = <String, int>{};
  for (var index = 0; index < recentFolderIds.length; index++) {
    recentRank.putIfAbsent(recentFolderIds[index], () => index);
  }

  final byParent = <String?, List<LibraryFolder>>{};
  for (final folder in folders) {
    final parentId = folder.parentId;
    final effectiveParent =
        parentId == null || parentId == folder.id || !ids.contains(parentId)
            ? null
            : parentId;
    byParent.putIfAbsent(effectiveParent, () => <LibraryFolder>[]).add(folder);
  }

  final rankMemo = <String, int>{};
  final ranking = <String>{};
  const notRecent = 1 << 30;
  int subtreeRank(LibraryFolder folder) {
    final cached = rankMemo[folder.id];
    if (cached != null) return cached;
    if (!ranking.add(folder.id)) return recentRank[folder.id] ?? notRecent;
    var rank = recentRank[folder.id] ?? notRecent;
    for (final child in byParent[folder.id] ?? const <LibraryFolder>[]) {
      final childRank = subtreeRank(child);
      if (childRank < rank) rank = childRank;
    }
    ranking.remove(folder.id);
    rankMemo[folder.id] = rank;
    return rank;
  }

  void sortSiblings(List<LibraryFolder> siblings) {
    siblings.sort((a, b) {
      final recentComparison = subtreeRank(a).compareTo(subtreeRank(b));
      if (recentComparison != 0) return recentComparison;
      final orderComparison = a.orderIndex.compareTo(b.orderIndex);
      if (orderComparison != 0) return orderComparison;
      return originalIndex[a.id]!.compareTo(originalIndex[b.id]!);
    });
  }

  final ordered = <LibraryFolder>[];
  final visited = <String>{};
  void visit(String? parentId) {
    final children = byParent[parentId];
    if (children == null) return;
    sortSiblings(children);
    for (final child in children) {
      if (!visited.add(child.id)) continue;
      ordered.add(child);
      visit(child.id);
    }
  }

  visit(null);
  if (ordered.length != folders.length) {
    final remaining = folders
        .where((folder) => !visited.contains(folder.id))
        .toList(growable: true);
    sortSiblings(remaining);
    for (final folder in remaining) {
      if (!visited.add(folder.id)) continue;
      ordered.add(folder);
      visit(folder.id);
    }
  }
  return List<LibraryFolder>.unmodifiable(ordered);
}
