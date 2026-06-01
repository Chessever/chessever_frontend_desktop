import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_pointer.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';

const int kDefaultNotationAutoCollapseDepth = 3;
const int kDefaultNotationAutoCollapseMoveThreshold = 12;

enum NotationVerticalDirection { up, down }

/// Resolves the next/previous visible notation line anchor in reference-style
/// traversal order. Arrow Down does not walk every token on the same inline
/// row; it jumps to the next visible line/variation anchor: a variation head,
/// a folded variation head, or the first continuation move after a visible
/// variation block. Arrow Up reverses the same order.
///
/// When [visibleMoveOrder] is supplied, it is treated as authoritative. This
/// lets `NotationLadderView` pass the exact anchor order it rendered after
/// local expand/collapse state has been applied. The active pointer is inserted
/// into that order by the widget when it is not itself an anchor.
ChessMovePointer? notationVerticalPointer({
  required ChessGame game,
  required ChessMovePointer activePointer,
  required NotationVerticalDirection direction,
  List<ChessMovePointer>? visibleMoveOrder,
  Set<String> forcedOpenIds = const <String>{},
  Set<String> collapsedIds = const <String>{},
  Set<String> expandedIds = const <String>{},
  int autoCollapseDepth = kDefaultNotationAutoCollapseDepth,
  int autoCollapseMoveThreshold = kDefaultNotationAutoCollapseMoveThreshold,
}) {
  final order = visibleMoveOrder == null || visibleMoveOrder.isEmpty
      ? visibleNotationMoveOrder(
          game: game,
          activePointer: activePointer,
          forcedOpenIds: forcedOpenIds,
          collapsedIds: collapsedIds,
          expandedIds: expandedIds,
          autoCollapseDepth: autoCollapseDepth,
          autoCollapseMoveThreshold: autoCollapseMoveThreshold,
        )
      : visibleMoveOrder;
  return notationVerticalPointerInOrder(
    order: order,
    activePointer: activePointer,
    direction: direction,
  );
}

/// Resolves the move on the visual ladder row above or below [activePointer].
///
/// This preserves the original ladder-mode behavior: rows contain white/black
/// pairs, and vertical movement keeps the closest white/black column instead
/// of using inline branch anchors.
ChessMovePointer? notationLadderVerticalPointer({
  required ChessGame game,
  required ChessMovePointer activePointer,
  required NotationVerticalDirection direction,
}) {
  final rows = notationNavigationRows(game);
  if (rows.isEmpty) return null;

  if (activePointer.isEmpty) {
    return direction == NotationVerticalDirection.down
        ? rows.first.entries.first.pointer
        : null;
  }

  final active = _findEntry(rows, activePointer);
  if (active == null) return null;

  final targetRowIndex =
      active.rowIndex + (direction == NotationVerticalDirection.down ? 1 : -1);
  if (targetRowIndex < 0 || targetRowIndex >= rows.length) return null;

  return _closestEntry(rows[targetRowIndex], active.entry.column).pointer;
}

ChessMovePointer? notationVerticalPointerInOrder({
  required List<ChessMovePointer> order,
  required ChessMovePointer activePointer,
  required NotationVerticalDirection direction,
}) {
  if (order.isEmpty) return null;

  if (activePointer.isEmpty) {
    return direction == NotationVerticalDirection.down ? order.first : null;
  }

  final activeIndex = order.indexWhere(
    (pointer) => _pointersEqual(pointer, activePointer),
  );
  if (activeIndex < 0) return null;

  final targetIndex =
      activeIndex + (direction == NotationVerticalDirection.down ? 1 : -1);
  if (targetIndex < 0 || targetIndex >= order.length) return null;
  return order[targetIndex];
}

/// Visible vertical navigation anchors in the same order the inline notation
/// presents branches. This list intentionally contains *line starts*, not every
/// move token on a line. If [activePointer] is a visible non-anchor move (e.g.
/// `5.c4` at the end of the mainline row), it is inserted at its token position
/// so Arrow Down can still land on the next branch anchor (`5.a3`).
List<ChessMovePointer> visibleNotationMoveOrder({
  required ChessGame game,
  ChessMovePointer activePointer = const <int>[],
  Set<String> forcedOpenIds = const <String>{},
  Set<String> collapsedIds = const <String>{},
  Set<String> expandedIds = const <String>{},
  int autoCollapseDepth = kDefaultNotationAutoCollapseDepth,
  int autoCollapseMoveThreshold = kDefaultNotationAutoCollapseMoveThreshold,
}) {
  final model = _visibleNotationModel(
    game: game,
    activePointer: activePointer,
    forcedOpenIds: forcedOpenIds,
    collapsedIds: collapsedIds,
    expandedIds: expandedIds,
    autoCollapseDepth: autoCollapseDepth,
    autoCollapseMoveThreshold: autoCollapseMoveThreshold,
  );
  final order = List<ChessMovePointer>.of(model.anchors);
  if (activePointer.isNotEmpty &&
      !order.any((pointer) => _pointersEqual(pointer, activePointer))) {
    final tokenIndex = model.tokens.indexWhere(
      (pointer) => _pointersEqual(pointer, activePointer),
    );
    if (tokenIndex >= 0) {
      final insertAt = order.indexWhere((pointer) {
        final pointerTokenIndex = model.tokens.indexWhere(
          (token) => _pointersEqual(token, pointer),
        );
        return pointerTokenIndex > tokenIndex;
      });
      if (insertAt < 0) {
        order.add(activePointer);
      } else {
        order.insert(insertAt, activePointer);
      }
    }
  }
  return List<ChessMovePointer>.unmodifiable(order);
}

({List<ChessMovePointer> tokens, List<ChessMovePointer> anchors})
_visibleNotationModel({
  required ChessGame game,
  required ChessMovePointer activePointer,
  required Set<String> forcedOpenIds,
  required Set<String> collapsedIds,
  required Set<String> expandedIds,
  required int autoCollapseDepth,
  required int autoCollapseMoveThreshold,
}) {
  final effectiveForcedOpenIds = <String>{
    ...forcedOpenIds,
    ...notationAncestorVariationIds(activePointer),
  };
  final tokens = <ChessMovePointer>[];
  final anchors = <ChessMovePointer>[];

  void addAnchor(ChessMovePointer pointer) {
    if (!anchors.any((existing) => _pointersEqual(existing, pointer))) {
      anchors.add(pointer);
    }
  }

  void walkLine(ChessLine line, ChessMovePointer prefix, int depth) {
    var segmentStart = true;
    for (var i = 0; i < line.length; i++) {
      final move = line[i];
      final pointer = <int>[...prefix, i];
      final startsSegment = segmentStart;
      tokens.add(pointer);
      if (startsSegment) addAnchor(pointer);

      final vars = move.variations;
      if (vars == null || vars.isEmpty) {
        segmentStart = false;
        continue;
      }

      for (var v = 0; v < vars.length; v++) {
        final variationLine = vars[v];
        if (variationLine.isEmpty) continue;
        final variationPrefix = <int>[...pointer, v];
        final headPointer = <int>[...variationPrefix, 0];
        final headId = NotationPointer.encode(headPointer);
        final defaultCollapsed = shouldCollapseNotationVariationByDefault(
          depth: depth + 1,
          moveCount: variationLine.length,
          autoCollapseDepth: autoCollapseDepth,
          autoCollapseMoveThreshold: autoCollapseMoveThreshold,
        );
        final collapsed = effectiveForcedOpenIds.contains(headId)
            ? false
            : (defaultCollapsed
                  ? !expandedIds.contains(headId)
                  : collapsedIds.contains(headId));
        if (collapsed) {
          tokens.add(headPointer);
          addAnchor(headPointer);
        } else {
          walkLine(variationLine, variationPrefix, depth + 1);
        }
      }
      // If the branch was attached to the first move of an already-visible
      // segment (e.g. `5...Nf6 6.Nc3 ...`), returning from the branch should
      // continue that same visual row. If the branch was attached mid/end row
      // (e.g. after `5.c4` or `11.Rad1`), the continuation starts the next
      // visible row and becomes the next vertical target.
      segmentStart = !startsSegment;
    }
  }

  walkLine(game.mainline, const <int>[], 0);
  return (
    tokens: List<ChessMovePointer>.unmodifiable(tokens),
    anchors: List<ChessMovePointer>.unmodifiable(anchors),
  );
}

bool shouldCollapseNotationVariationByDefault({
  required int depth,
  required int moveCount,
  required int autoCollapseDepth,
  required int autoCollapseMoveThreshold,
}) {
  if (depth >= autoCollapseDepth) return true;
  if (moveCount >= autoCollapseMoveThreshold) return true;
  return false;
}

Set<String> notationAncestorVariationIds(ChessMovePointer pointer) {
  if (pointer.length < 3) return const <String>{};
  final out = <String>{};
  for (var i = 1; i < pointer.length; i += 2) {
    // If the active pointer is exactly this variation's visible head
    // (`[..., varIdx, 0]`), the collapsed header itself is selectable and
    // should remain folded. Only force-open true ancestors that contain the
    // cursor deeper than their head.
    final headEnd = i + 2;
    if (headEnd == pointer.length) continue;
    final headPointer = <int>[...pointer.sublist(0, i + 1), 0];
    out.add(NotationPointer.encode(headPointer));
  }
  return out;
}

bool notationPointerListsEqual(
  List<ChessMovePointer> a,
  List<ChessMovePointer> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_pointersEqual(a[i], b[i])) return false;
  }
  return true;
}

class RenderedNotationMovePosition {
  const RenderedNotationMovePosition({
    required this.pointer,
    required this.centerX,
    required this.centerY,
  });

  final ChessMovePointer pointer;
  final double centerX;
  final double centerY;
}

/// Builds the active-relative order consumed by [notationVerticalPointerInOrder]
/// from actual rendered inline move positions. Inline notation wraps according
/// to Flutter layout, comments, variation widgets, and pane width, so structural
/// PGN order alone cannot answer Arrow Up/Down. The returned list intentionally
/// contains only the nearest move on the row above, the active move, and the
/// nearest move on the row below.
List<ChessMovePointer> renderedNotationVerticalMoveOrder({
  required List<RenderedNotationMovePosition> positions,
  required ChessMovePointer activePointer,
  double rowTolerance = 7,
}) {
  if (positions.isEmpty) return const <ChessMovePointer>[];

  final sorted = List<RenderedNotationMovePosition>.of(positions)..sort((a, b) {
    final dy = a.centerY.compareTo(b.centerY);
    if ((a.centerY - b.centerY).abs() > rowTolerance) return dy;
    return a.centerX.compareTo(b.centerX);
  });

  final rows = <List<RenderedNotationMovePosition>>[];
  for (final position in sorted) {
    if (rows.isEmpty) {
      rows.add([position]);
      continue;
    }
    final row = rows.last;
    final rowCenter =
        row.fold<double>(0, (sum, item) => sum + item.centerY) / row.length;
    if ((position.centerY - rowCenter).abs() <= rowTolerance) {
      row.add(position);
    } else {
      rows.add([position]);
    }
  }

  for (final row in rows) {
    row.sort((a, b) => a.centerX.compareTo(b.centerX));
  }

  if (activePointer.isEmpty) {
    return List<ChessMovePointer>.unmodifiable([rows.first.first.pointer]);
  }

  var activeRowIndex = -1;
  RenderedNotationMovePosition? activePosition;
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    for (final position in rows[rowIndex]) {
      if (_pointersEqual(position.pointer, activePointer)) {
        activeRowIndex = rowIndex;
        activePosition = position;
        break;
      }
    }
    if (activePosition != null) break;
  }
  if (activePosition == null || activeRowIndex < 0) {
    return const <ChessMovePointer>[];
  }

  final activeX = activePosition.centerX;

  ChessMovePointer? nearestInRow(int rowIndex) {
    if (rowIndex < 0 || rowIndex >= rows.length) return null;
    RenderedNotationMovePosition? best;
    for (final candidate in rows[rowIndex]) {
      if (best == null) {
        best = candidate;
        continue;
      }
      final candidateDistance = (candidate.centerX - activeX).abs();
      final bestDistance = (best.centerX - activeX).abs();
      if (candidateDistance < bestDistance ||
          (candidateDistance == bestDistance &&
              candidate.centerX < best.centerX)) {
        best = candidate;
      }
    }
    return best?.pointer;
  }

  final order = <ChessMovePointer>[
    if (nearestInRow(activeRowIndex - 1) case final up?) up,
    activePointer,
    if (nearestInRow(activeRowIndex + 1) case final down?) down,
  ];
  return List<ChessMovePointer>.unmodifiable(order);
}

/// Row model used by ladder-mode vertical navigation.
List<NotationNavigationRow> notationNavigationRows(ChessGame game) {
  final tree = NotationTreeBuilder.build(game);
  final rows = <NotationNavigationRow>[];
  _appendLineRows(tree.mainline, rows);
  return rows;
}

void _appendLineRows(
  List<NotationMoveNode> line,
  List<NotationNavigationRow> rows,
) {
  var i = 0;
  while (i < line.length) {
    final first = line[i];
    NotationMoveNode? white;
    NotationMoveNode? black;

    if (first.isWhiteMove) {
      white = first;
      if (i + 1 < line.length && !line[i + 1].isWhiteMove) {
        black = line[i + 1];
      }
    } else {
      black = first;
    }

    final entries = <NotationNavigationEntry>[
      if (white != null)
        NotationNavigationEntry(pointer: white.pointer, column: 0),
      if (black != null)
        NotationNavigationEntry(pointer: black.pointer, column: 1),
    ];
    if (entries.isNotEmpty) {
      rows.add(NotationNavigationRow(List.unmodifiable(entries)));
    }

    void appendVariations(NotationMoveNode? node) {
      if (node == null) return;
      for (final variation in node.variations) {
        _appendLineRows(variation.moves, rows);
      }
    }

    appendVariations(white);
    appendVariations(black);

    if (white != null) {
      i += black != null ? 2 : 1;
    } else {
      i += 1;
    }
  }
}

({int rowIndex, NotationNavigationEntry entry})? _findEntry(
  List<NotationNavigationRow> rows,
  ChessMovePointer pointer,
) {
  for (var r = 0; r < rows.length; r++) {
    for (final entry in rows[r].entries) {
      if (_pointersEqual(entry.pointer, pointer)) {
        return (rowIndex: r, entry: entry);
      }
    }
  }
  return null;
}

NotationNavigationEntry _closestEntry(
  NotationNavigationRow row,
  int targetColumn,
) {
  var best = row.entries.first;
  var bestDistance = (best.column - targetColumn).abs();
  for (final entry in row.entries.skip(1)) {
    final distance = (entry.column - targetColumn).abs();
    if (distance < bestDistance) {
      best = entry;
      bestDistance = distance;
    }
  }
  return best;
}

bool _pointersEqual(ChessMovePointer a, ChessMovePointer b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class NotationNavigationRow {
  const NotationNavigationRow(this.entries);

  final List<NotationNavigationEntry> entries;
}

class NotationNavigationEntry {
  const NotationNavigationEntry({required this.pointer, required this.column});

  final ChessMovePointer pointer;
  final int column;
}
