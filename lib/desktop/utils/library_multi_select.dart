import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Pure helper for reference-style row selection in desktop game lists.
///
/// It intentionally has no Ctrl/Cmd-click toggle path because that modifier is
/// reserved elsewhere for opening games/items in a new tab/window.
class LibraryMultiSelect {
  const LibraryMultiSelect._();

  static bool rangeModifierPressed(Set<LogicalKeyboardKey> pressedKeys) =>
      pressedKeys.contains(LogicalKeyboardKey.shift) ||
      pressedKeys.contains(LogicalKeyboardKey.shiftLeft) ||
      pressedKeys.contains(LogicalKeyboardKey.shiftRight);

  static Set<String> clampToRows(Set<String> selected, List<String> rowIds) {
    final visible = rowIds.toSet();
    return selected.where(visible.contains).toSet();
  }

  /// Uses the desktop-file-browser convention for a row context menu: retain
  /// the current selection when the clicked row already belongs to it;
  /// otherwise make that row the sole selection.
  static Set<String> contextMenuSelection({
    required Set<String> selectedIds,
    required String rowId,
  }) {
    if (selectedIds.contains(rowId)) return Set<String>.of(selectedIds);
    return <String>{rowId};
  }

  static Set<String> range({
    required List<String> rowIds,
    required int from,
    required int to,
  }) {
    if (rowIds.isEmpty) return <String>{};
    final start = math.min(from, to).clamp(0, rowIds.length - 1).toInt();
    final end = math.max(from, to).clamp(0, rowIds.length - 1).toInt();
    return {for (var i = start; i <= end; i++) rowIds[i]};
  }

  static int? nextAnchor({
    required List<String> rowIds,
    required int? anchor,
    required int delta,
  }) => nextExtent(rowIds: rowIds, extent: anchor, delta: delta);

  static int? nextExtent({
    required List<String> rowIds,
    required int? extent,
    required int delta,
  }) {
    if (rowIds.isEmpty) return null;
    final current = (extent ?? 0).clamp(0, rowIds.length - 1).toInt();
    return (current + delta).clamp(0, rowIds.length - 1).toInt();
  }
}
