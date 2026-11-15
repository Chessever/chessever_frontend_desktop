import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

/// Where a dragged game or board tab lands on the Board workspace.
///
/// The edge zones open the dropped board beside the target: [left] and
/// [right] add a column, [top] and [bottom] split the target's column into
/// two rows. [replace] puts the dropped board in the target's place.
enum BoardSplitZone { left, right, top, bottom, replace }

/// Gap between two cells of a split Board workspace. Matches the resize
/// gutter of `ResizableSplitView`, so a split cell and the panes inside a
/// board share one divider language.
const double kBoardSplitGutter = 8;

/// Height of the strip above each cell of a split workspace that names its
/// game and holds its close actions.
const double kBoardSplitCellHeaderHeight = 32;

/// Smallest cell the divider drag may leave. A board pane below this stops
/// being usable; the window still wins when it is smaller than two of them.
const double kBoardSplitMinCellWidth = 300;
const double kBoardSplitMinCellHeight = 220;

/// Up to four Board tabs shown at once: at most two columns, and each column
/// split into at most two rows.
///
/// Columns come first: a column always spans the full height, and a row
/// split only ever divides one column. Every member is a real Board tab, so
/// the tab strip, keyboard shortcuts and per-tab state keep working; the
/// layout only decides where on screen each tab is drawn.
@immutable
class BoardSplitLayout {
  BoardSplitLayout({
    required this.id,
    required List<List<String>> columns,
    double columnFraction = 0.5,
    List<double>? rowFractions,
  }) : columns = List.unmodifiable([
         for (final column in columns) List<String>.unmodifiable(column),
       ]),
       columnFraction = _clampFraction(columnFraction),
       rowFractions = List.unmodifiable([
         for (var i = 0; i < columns.length; i++)
           _clampFraction(
             rowFractions != null && i < rowFractions.length
                 ? rowFractions[i]
                 : 0.5,
           ),
       ]) {
    assert(columns.isNotEmpty && columns.length <= maxColumns);
    assert(columns.every((c) => c.isNotEmpty && c.length <= maxRows));
  }

  /// The unsplit view of one tab: what a drop target sees before any split.
  factory BoardSplitLayout.single(String tabId) => BoardSplitLayout(
    id: 'single:$tabId',
    columns: [
      [tabId],
    ],
  );

  static const int maxColumns = 2;
  static const int maxRows = 2;
  static const int maxCells = maxColumns * maxRows;

  final String id;

  /// Tab ids by column (left to right), each column top to bottom.
  final List<List<String>> columns;

  /// Share of the width given to the first column when there are two.
  final double columnFraction;

  /// Per column, the share of the height given to its first row.
  final List<double> rowFractions;

  List<String> get tabIds => [for (final column in columns) ...column];
  int get cellCount => columns.fold(0, (sum, column) => sum + column.length);
  bool get isSplit => cellCount > 1;
  bool contains(String tabId) => columns.any((c) => c.contains(tabId));

  ({int column, int row})? locate(String tabId) {
    for (var c = 0; c < columns.length; c++) {
      final r = columns[c].indexOf(tabId);
      if (r >= 0) return (column: c, row: r);
    }
    return null;
  }

  bool get canAddColumn => columns.length < maxColumns;
  bool canSplitColumn(int column) => columns[column].length < maxRows;

  /// Zones a drop over [targetTabId] may use. [incomingTabId] is set when an
  /// existing tab is being dragged; it can never land on itself, and an
  /// unsplit board cannot be "replaced" by another tab (that is just
  /// switching tabs).
  Set<BoardSplitZone> zonesFor(String targetTabId, {String? incomingTabId}) {
    final at = locate(targetTabId);
    if (at == null || incomingTabId == targetTabId) return const {};
    // Moving a member inside its own group: plan against the layout without
    // it, so a full group still offers the edges the move would free up.
    final movingWithin = incomingTabId != null && contains(incomingTabId);
    final base = movingWithin ? without(incomingTabId) : this;
    final baseLayout = base ?? BoardSplitLayout.single(targetTabId);
    final baseAt = baseLayout.locate(targetTabId)!;
    final zones = <BoardSplitZone>{};
    if (baseLayout.canAddColumn) {
      zones
        ..add(BoardSplitZone.left)
        ..add(BoardSplitZone.right);
    }
    if (baseLayout.canSplitColumn(baseAt.column)) {
      zones
        ..add(BoardSplitZone.top)
        ..add(BoardSplitZone.bottom);
    }
    if (isSplit || incomingTabId == null) zones.add(BoardSplitZone.replace);
    return zones;
  }

  /// The layout after [incomingTabId] lands in [zone] of [targetTabId], or
  /// null when that drop is not allowed. Returns a single-cell layout when
  /// the result shows only one board (a replace on an unsplit view).
  BoardSplitLayout? place({
    required String targetTabId,
    required String incomingTabId,
    required BoardSplitZone zone,
  }) {
    if (targetTabId == incomingTabId || locate(targetTabId) == null) {
      return null;
    }
    if (!zonesFor(targetTabId, incomingTabId: incomingTabId).contains(zone)) {
      return null;
    }
    if (zone == BoardSplitZone.replace) {
      if (contains(incomingTabId)) return _swap(targetTabId, incomingTabId);
      return _mapIds((id) => id == targetTabId ? incomingTabId : id);
    }
    final base =
        (contains(incomingTabId) ? without(incomingTabId) : this) ??
        BoardSplitLayout.single(targetTabId);
    final at = base.locate(targetTabId)!;
    final next = [
      for (final column in base.columns) [...column],
    ];
    final rows = [...base.rowFractions];
    var columnFraction = base.columnFraction;
    switch (zone) {
      case BoardSplitZone.left:
      case BoardSplitZone.right:
        if (!base.canAddColumn) return null;
        final insertAt = zone == BoardSplitZone.left ? 0 : next.length;
        next.insert(insertAt, [incomingTabId]);
        rows.insert(insertAt, 0.5);
        columnFraction = 0.5;
      case BoardSplitZone.top:
      case BoardSplitZone.bottom:
        if (!base.canSplitColumn(at.column)) return null;
        final column = next[at.column];
        column.insert(
          zone == BoardSplitZone.top ? 0 : column.length,
          incomingTabId,
        );
        rows[at.column] = 0.5;
      case BoardSplitZone.replace:
        return null;
    }
    return BoardSplitLayout(
      id: isSplit ? id : _newGroupId(),
      columns: next,
      columnFraction: columnFraction,
      rowFractions: rows,
    );
  }

  /// The layout without [tabId]; null once fewer than two boards remain.
  BoardSplitLayout? without(String tabId) {
    final at = locate(tabId);
    if (at == null) return this;
    final next = <List<String>>[];
    final rows = <double>[];
    for (var c = 0; c < columns.length; c++) {
      final column = [
        for (final id in columns[c])
          if (id != tabId) id,
      ];
      if (column.isEmpty) continue;
      next.add(column);
      rows.add(rowFractions[c]);
    }
    if (next.fold(0, (sum, column) => sum + column.length) < 2) return null;
    return BoardSplitLayout(
      id: id,
      columns: next,
      columnFraction: next.length == columns.length ? columnFraction : 0.5,
      rowFractions: rows,
    );
  }

  BoardSplitLayout withColumnFraction(double fraction) => BoardSplitLayout(
    id: id,
    columns: columns,
    columnFraction: fraction,
    rowFractions: rowFractions,
  );

  BoardSplitLayout withRowFraction(int column, double fraction) =>
      BoardSplitLayout(
        id: id,
        columns: columns,
        columnFraction: columnFraction,
        rowFractions: [
          for (var c = 0; c < columns.length; c++)
            c == column ? fraction : rowFractions[c],
        ],
      );

  /// Rect of every cell, header included, inside an area of [size].
  Map<String, Rect> cellRects(Size size) {
    final rects = <String, Rect>{};
    final columnSpans = _spans(
      size.width,
      columns.length,
      columnFraction,
      kBoardSplitMinCellWidth,
    );
    for (var c = 0; c < columns.length; c++) {
      final rowSpans = _spans(
        size.height,
        columns[c].length,
        rowFractions[c],
        kBoardSplitMinCellHeight,
      );
      for (var r = 0; r < columns[c].length; r++) {
        rects[columns[c][r]] = Rect.fromLTRB(
          columnSpans[c].$1,
          rowSpans[r].$1,
          columnSpans[c].$2,
          rowSpans[r].$2,
        );
      }
    }
    return rects;
  }

  /// Rect of the divider between the two columns, when there are two.
  Rect? columnGutterRect(Size size) {
    if (columns.length < 2) return null;
    final spans = _spans(
      size.width,
      2,
      columnFraction,
      kBoardSplitMinCellWidth,
    );
    return Rect.fromLTRB(spans[0].$2, 0, spans[1].$1, size.height);
  }

  /// Rect of the divider between the two rows of [column], when it has two.
  Rect? rowGutterRect(Size size, int column) {
    if (column >= columns.length || columns[column].length < 2) return null;
    final x =
        _spans(
          size.width,
          columns.length,
          columnFraction,
          kBoardSplitMinCellWidth,
        )[column];
    final y = _spans(
      size.height,
      2,
      rowFractions[column],
      kBoardSplitMinCellHeight,
    );
    return Rect.fromLTRB(x.$1, y[0].$2, x.$2, y[1].$1);
  }

  /// Where a board dropped in [zone] of [targetTabId] will sit, so the drop
  /// preview shows the landing area before the user lets go.
  ///
  /// When [incomingTabId] is already a member, the preview is drawn on the
  /// layout without it, which is where the move actually lands.
  Rect? previewRect(
    String targetTabId,
    BoardSplitZone zone,
    Size size, {
    String? incomingTabId,
  }) {
    if (zone != BoardSplitZone.replace &&
        incomingTabId != null &&
        incomingTabId != targetTabId &&
        contains(incomingTabId)) {
      final base =
          without(incomingTabId) ?? BoardSplitLayout.single(targetTabId);
      return base.previewRect(targetTabId, zone, size);
    }
    final target = cellRects(size)[targetTabId];
    if (target == null) return null;
    final halfWidth = (size.width - kBoardSplitGutter) / 2;
    final halfHeight = (size.height - kBoardSplitGutter) / 2;
    switch (zone) {
      case BoardSplitZone.left:
        return Rect.fromLTWH(0, 0, halfWidth, size.height);
      case BoardSplitZone.right:
        return Rect.fromLTWH(size.width - halfWidth, 0, halfWidth, size.height);
      case BoardSplitZone.top:
        final column = _columnSpanOf(targetTabId, size);
        return Rect.fromLTRB(column.$1, 0, column.$2, halfHeight);
      case BoardSplitZone.bottom:
        final column = _columnSpanOf(targetTabId, size);
        return Rect.fromLTRB(
          column.$1,
          size.height - halfHeight,
          column.$2,
          size.height,
        );
      case BoardSplitZone.replace:
        return target;
    }
  }

  (double, double) _columnSpanOf(String tabId, Size size) {
    final rects = cellRects(size);
    final at = locate(tabId)!;
    final first = rects[columns[at.column].first]!;
    return (first.left, first.right);
  }

  BoardSplitLayout _swap(String a, String b) =>
      _mapIds((id) => id == a ? b : (id == b ? a : id));

  BoardSplitLayout _mapIds(String Function(String id) map) => BoardSplitLayout(
    id: id,
    columns: [
      for (final column in columns) [for (final id in column) map(id)],
    ],
    columnFraction: columnFraction,
    rowFractions: rowFractions,
  );

  @override
  bool operator ==(Object other) =>
      other is BoardSplitLayout &&
      other.id == id &&
      other.columnFraction == columnFraction &&
      const DeepCollectionEquality().equals(other.columns, columns) &&
      listEquals(other.rowFractions, rowFractions);

  @override
  int get hashCode => Object.hash(
    id,
    columnFraction,
    const DeepCollectionEquality().hash(columns),
    Object.hashAll(rowFractions),
  );

  @override
  String toString() => 'BoardSplitLayout($id, $columns)';
}

double _clampFraction(double value) =>
    value.isFinite ? value.clamp(0.1, 0.9).toDouble() : 0.5;

int _nextGroupNumber = 0;

/// A fresh id for a new split. Members change over a group's life, so an id
/// built from them could later collide with another group's.
String _newGroupId() => 'split-${_nextGroupNumber++}';

/// Start and end of [count] spans sharing [total] with a gutter between
/// them. With two spans the first gets [fraction] of the room, held at
/// [minSpan] each unless the area cannot fit two of them.
List<(double, double)> _spans(
  double total,
  int count,
  double fraction,
  double minSpan,
) {
  if (count <= 1) return [(0, total)];
  final room = math.max(0.0, total - kBoardSplitGutter);
  final floor = math.min(minSpan, room / 2);
  final first = (room * fraction).clamp(floor, room - floor).toDouble();
  return [(0, first), (first + kBoardSplitGutter, total)];
}

/// Which zone a pointer at [local] inside a cell of [cellSize] picks.
///
/// The outer third on each side is that side's split zone, the middle is
/// [BoardSplitZone.replace]. Near a corner the closer edge wins. When the
/// middle cannot replace (an unsplit board dragged onto by a tab), the
/// nearest allowed edge takes the whole cell so a drop never goes nowhere.
BoardSplitZone? resolveBoardSplitZone({
  required Offset local,
  required Size cellSize,
  required Set<BoardSplitZone> allowed,
}) {
  if (allowed.isEmpty || cellSize.isEmpty) return null;
  final nx = (local.dx / cellSize.width).clamp(0.0, 1.0);
  final ny = (local.dy / cellSize.height).clamp(0.0, 1.0);
  final distances = <BoardSplitZone, double>{
    BoardSplitZone.left: nx,
    BoardSplitZone.right: 1 - nx,
    BoardSplitZone.top: ny,
    BoardSplitZone.bottom: 1 - ny,
  };
  const band = 1 / 3;
  BoardSplitZone? best;
  var bestDistance = double.infinity;
  for (final entry in distances.entries) {
    if (!allowed.contains(entry.key)) continue;
    final inBand = entry.value < band;
    if (!inBand && allowed.contains(BoardSplitZone.replace)) continue;
    if (entry.value < bestDistance) {
      best = entry.key;
      bestDistance = entry.value;
    }
  }
  return best ??
      (allowed.contains(BoardSplitZone.replace)
          ? BoardSplitZone.replace
          : null);
}

/// Every split group of Board tabs. A tab belongs to at most one group.
@immutable
class BoardSplitState {
  const BoardSplitState({this.groups = const <BoardSplitLayout>[]});

  final List<BoardSplitLayout> groups;

  BoardSplitLayout? groupOf(String? tabId) {
    if (tabId == null) return null;
    for (final group in groups) {
      if (group.contains(tabId)) return group;
    }
    return null;
  }
}

class BoardSplitNotifier extends StateNotifier<BoardSplitState> {
  BoardSplitNotifier() : super(const BoardSplitState());

  BoardSplitState get current => state;

  /// The layout a drop over [tabId] plans against: its group, or the board
  /// on its own.
  BoardSplitLayout layoutFor(String tabId) =>
      state.groupOf(tabId) ?? BoardSplitLayout.single(tabId);

  /// Lands [incomingTabId] in [zone] of [targetTabId]. A tab moving from
  /// another group leaves it first. Returns false when the drop is not
  /// allowed and nothing changed.
  bool place({
    required String targetTabId,
    required String incomingTabId,
    required BoardSplitZone zone,
  }) {
    final target = layoutFor(targetTabId);
    final next = target.place(
      targetTabId: targetTabId,
      incomingTabId: incomingTabId,
      zone: zone,
    );
    if (next == null) return false;
    final groups = <BoardSplitLayout>[];
    for (final group in state.groups) {
      if (group.id == target.id) continue;
      if (group.contains(incomingTabId)) {
        final rest = group.without(incomingTabId);
        if (rest != null) groups.add(rest);
        continue;
      }
      groups.add(group);
    }
    if (next.isSplit) groups.add(next);
    state = BoardSplitState(groups: groups);
    return true;
  }

  /// Takes [tabId] out of its group. The tab stays open; a group left with
  /// one board dissolves.
  void remove(String tabId) {
    final group = state.groupOf(tabId);
    if (group == null) return;
    final rest = group.without(tabId);
    state = BoardSplitState(
      groups: [
        for (final g in state.groups)
          if (g.id != group.id) g else if (rest != null) rest,
      ],
    );
  }

  /// Drops every member that is no longer an open Board tab.
  void retainBoardTabs(Set<String> boardTabIds) {
    var changed = false;
    final groups = <BoardSplitLayout>[];
    for (final group in state.groups) {
      BoardSplitLayout? next = group;
      for (final id in group.tabIds) {
        if (boardTabIds.contains(id)) continue;
        next = next?.without(id);
        changed = true;
      }
      if (next != null) groups.add(next);
    }
    if (changed) state = BoardSplitState(groups: groups);
  }

  void setColumnFraction(String groupId, double fraction) =>
      _update(groupId, (g) => g.withColumnFraction(fraction));

  void setRowFraction(String groupId, int column, double fraction) =>
      _update(groupId, (g) => g.withRowFraction(column, fraction));

  void _update(
    String groupId,
    BoardSplitLayout Function(BoardSplitLayout group) change,
  ) {
    var changed = false;
    final groups = [
      for (final group in state.groups)
        if (group.id == groupId)
          () {
            final next = change(group);
            changed = changed || next != group;
            return next;
          }()
        else
          group,
    ];
    if (changed) state = BoardSplitState(groups: groups);
  }
}

final boardSplitProvider =
    StateNotifierProvider<BoardSplitNotifier, BoardSplitState>((ref) {
      final notifier = BoardSplitNotifier();
      // Closing a tab, or navigating it away from the Board, takes it out of
      // its split; the rest of the group closes up around the gap.
      ref.listen<DesktopTabsState>(desktopTabsProvider, (previous, next) {
        notifier.retainBoardTabs({
          for (final tab in next.tabs)
            if (tab.kind == TabKind.board) tab.id,
        });
      });
      return notifier;
    });

/// The split group the workspace shows right now: the active tab's group,
/// or null when the active tab is shown on its own. Board focus mode
/// maximises the focused board, so it shows no split either.
final visibleBoardSplitProvider = Provider<BoardSplitLayout?>((ref) {
  if (ref.watch(boardFocusModeProvider)) return null;
  final activeId = ref.watch(desktopTabsProvider.select((s) => s.activeId));
  return ref.watch(boardSplitProvider.select((s) => s.groupOf(activeId)));
});

/// Whether [tabId] is on screen: the active tab, or a cell of the visible
/// split group even while another cell holds keyboard focus.
///
/// Live moves, clocks and rail rows follow this, because a visible board
/// that froze would be lying. Keyboard focus, shortcuts, sounds, the engine
/// (there is one Stockfish process) and the stream player stay with the
/// active tab alone.
final boardTabOnScreenProvider = Provider.family<bool, String>((ref, tabId) {
  final activeId = ref.watch(desktopTabsProvider.select((s) => s.activeId));
  if (activeId == tabId) return true;
  return ref.watch(visibleBoardSplitProvider)?.contains(tabId) ?? false;
});

/// Where "open beside" puts a board next to [targetTabId]: a new column on
/// the right, else below the target, else below a board in the other column.
/// Null once the split holds four boards.
({String targetTabId, BoardSplitZone zone})? besideBoardPlacement(
  BoardSplitLayout layout,
  String targetTabId,
) {
  final at = layout.locate(targetTabId);
  if (at == null) return null;
  if (layout.canAddColumn) {
    return (targetTabId: targetTabId, zone: BoardSplitZone.right);
  }
  if (layout.canSplitColumn(at.column)) {
    return (targetTabId: targetTabId, zone: BoardSplitZone.bottom);
  }
  for (var c = 0; c < layout.columns.length; c++) {
    if (layout.canSplitColumn(c)) {
      return (
        targetTabId: layout.columns[c].first,
        zone: BoardSplitZone.bottom,
      );
    }
  }
  return null;
}
