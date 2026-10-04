/// A section header stays in the projection even when its rows are hidden.
class LibraryCatalogSectionRow<T> {
  const LibraryCatalogSectionRow.header(this.section) : treeRow = null;
  const LibraryCatalogSectionRow.item(this.treeRow) : section = null;
  final int? section;
  final LibraryFolderTreeRow<T>? treeRow;
}

List<LibraryCatalogSectionRow<T>> projectLibraryCatalogSections<T>({
  required List<LibraryFolderTreeRow<T>> rows,
  required int Function(T) sectionOfRoot,
  required bool foldersExpanded,
  bool showSections = true,
}) {
  final result = <LibraryCatalogSectionRow<T>>[];
  int? previous;
  for (final row in rows) {
    final section = sectionOfRoot(row.root);
    if (showSections && section != previous) {
      result.add(LibraryCatalogSectionRow.header(section));
    }
    if (!showSections || section != 1 || foldersExpanded) {
      result.add(LibraryCatalogSectionRow.item(row));
    }
    previous = section;
  }
  return result;
}

class LibraryFolderTreeRow<T> {
  const LibraryFolderTreeRow(this.item, this.root, this.depth, this.expanded);
  final T item;
  final T root;
  final int depth;
  final bool expanded;
}

List<LibraryFolderTreeRow<T>> projectLibraryFolderTree<T>({
  required List<T> roots,
  required String Function(T) keyOf,
  required List<T> Function(T) childrenOf,
  required bool Function(T) isExpanded,
  bool Function(T)? matches,
}) {
  final rootKeys = roots.map(keyOf).toSet();
  final children = <String, List<T>>{};
  final parents = <String, Set<String>>{};
  final items = <String, T>{};
  final pending = roots.reversed.toList();
  while (pending.isNotEmpty) {
    final item = pending.removeLast();
    final key = keyOf(item);
    if (items.containsKey(key)) continue;
    items[key] = item;
    final next = childrenOf(item)
        .where((child) => !rootKeys.contains(keyOf(child)))
        .toList(growable: false);
    children[key] = next;
    for (final child in next) {
      parents.putIfAbsent(keyOf(child), () => <String>{}).add(key);
    }
    pending.addAll(next.reversed);
  }
  final matching = <String>{};
  if (matches != null) {
    final work = <String>[
      for (final entry in items.entries)
        if (matches(entry.value)) entry.key,
    ];
    while (work.isNotEmpty) {
      final key = work.removeLast();
      if (!matching.add(key)) continue;
      work.addAll(parents[key] ?? const <String>{});
    }
  }
  final result = <LibraryFolderTreeRow<T>>[];
  final seen = <String>{};
  final stack = <({T item, T root, int depth})>[
    for (final root in roots.reversed) (item: root, root: root, depth: 0),
  ];
  while (stack.isNotEmpty) {
    final row = stack.removeLast();
    final key = keyOf(row.item);
    if (!seen.add(key) || (matches != null && !matching.contains(key))) {
      continue;
    }
    final next = children[key] ?? <T>[];
    final showMatches =
        matches != null && next.any((child) => matching.contains(keyOf(child)));
    final expanded = isExpanded(row.item) || showMatches;
    result.add(LibraryFolderTreeRow(row.item, row.root, row.depth, expanded));
    if (expanded) {
      stack.addAll([
        for (final child in next.reversed)
          (item: child, root: row.root, depth: row.depth + 1),
      ]);
    }
  }
  return result;
}

Map<String, bool> readLibraryFolderExpansion(Object? raw) {
  if (raw is! Map) return const <String, bool>{};
  return Map<String, bool>.unmodifiable({
    for (final entry in raw.entries)
      if (entry.key is String &&
          (entry.key as String).trim().isNotEmpty &&
          entry.value is bool)
        (entry.key as String).trim(): entry.value as bool,
  });
}

Map<String, bool> toggleLibraryFolderExpansion(
  Map<String, bool> state,
  String key, {
  bool defaultExpanded = false,
}) => Map<String, bool>.unmodifiable({
  ...state,
  key: !(state[key] ?? defaultExpanded),
});
List<T> libraryFolderTreeRoots<T>({
  required List<T> items,
  required String Function(T) keyOf,
  required String? Function(T) parentKeyOf,
}) {
  final ids = items.map(keyOf).toSet();
  final byParent = <String?, List<T>>{};
  for (final item in items) {
    byParent.putIfAbsent(parentKeyOf(item), () => <T>[]).add(item);
  }
  final roots = <T>[];
  final covered = <String>{};
  void cover(T root) {
    final stack = <T>[root];
    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      final key = keyOf(item);
      if (!covered.add(key)) continue;
      stack.addAll(byParent[key] ?? <T>[]);
    }
  }

  for (final item in items) {
    final parent = parentKeyOf(item);
    if (parent == null || !ids.contains(parent)) {
      roots.add(item);
      cover(item);
    }
  }
  for (final item in items) {
    if (covered.contains(keyOf(item))) continue;
    roots.add(item);
    cover(item);
  }
  return roots;
}
