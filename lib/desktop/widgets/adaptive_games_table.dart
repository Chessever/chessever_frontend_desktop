import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/theme/app_theme.dart';

/// Per-column sort spec passed to [AdaptiveGamesTable].
///
/// Clicking the column header issues `onChanged` with the next state:
///   * inactive  → active asc
///   * active asc → active desc
///   * active desc → inactive (back to caller's default)
class AdaptiveSortState {
  const AdaptiveSortState({required this.field, required this.direction});

  final GamebaseSortField field;
  final GamebaseSortDirection direction;
}

/// Column spec for [AdaptiveGamesTable]. Widths come from Flutter's
/// [IntrinsicColumnWidth] over the actual cell content — nothing in the
/// spec encodes pixels.
///
/// `flex` (rare) opts a column into [FlexColumnWidth] so it expands into
/// horizontal slack remaining after every intrinsic column has consumed
/// its content width. Useful for a "notation" / "opening" column that
/// should grow into rail slack but never force the table narrower than
/// its content.
class AdaptiveColumn<T> {
  const AdaptiveColumn({
    required this.id,
    required this.label,
    required this.cellBuilder,
    this.headerAlignment = Alignment.centerLeft,
    this.cellAlignment = Alignment.centerLeft,
    this.flex,
    this.minWidth,
    this.tooltip,
    this.sortField,
  });

  /// When set, the column header becomes clickable and toggles the active
  /// sort. The table only renders the click affordance + arrow when both
  /// this and `AdaptiveGamesTable.onSortChanged` are non-null.
  final GamebaseSortField? sortField;

  /// Stable identifier — used as the storage key for per-column UI state
  /// (sort, visibility) the caller may layer on top.
  final String id;

  /// Header label. Empty string renders no header glyph (useful for icon-
  /// only columns); whitespace alone is rendered.
  final String label;

  /// Builds the cell for a given row. Receives a [BuildContext] so cells
  /// can reach theme/Riverpod via inherited widgets. Return type is `Widget`
  /// and rendering details (padding, vertical alignment) are owned by
  /// [AdaptiveGamesTable]; cells should focus on content only.
  final Widget Function(BuildContext context, T row) cellBuilder;

  final Alignment headerAlignment;
  final Alignment cellAlignment;

  /// If non-null, the column uses [FlexColumnWidth(flex)] instead of
  /// [IntrinsicColumnWidth]. Flex columns share leftover horizontal slack
  /// after the intrinsic columns are sized.
  final double? flex;

  /// Optional floor for the measured column width. This is most useful for
  /// flex columns whose cells must remain readable even when later intrinsic
  /// columns are present; without a floor, a flex column can collapse to
  /// zero once the non-flex columns consume the table's minimum width.
  final double? minWidth;

  /// Optional hover-tooltip rendered on the header label.
  final String? tooltip;
}

/// Games table whose header, every row, and every subline live inside a
/// single [Table] — column widths are therefore measured against the union
/// of all visible content and align exactly across rows.
///
/// Previously this widget rendered each row in its own per-row [Table]
/// with [IntrinsicColumnWidth]. Per-row Tables sized columns independently
/// from each row's local content, which caused visible column drift as
/// rows with longer player names / longer Elo digits / longer titles
/// pushed their column wider. The single-Table design fixes that by
/// construction: the framework runs `IntrinsicColumnWidth` once over the
/// entire content set.
///
/// Layout
/// ```
/// LayoutBuilder
/// └─ Scrollbar (horizontal)
///    └─ SingleChildScrollView (horizontal)
///       └─ ConstrainedBox(minWidth: effectiveMinWidth)
///          └─ (SingleChildScrollView vertical, optional)
///             └─ Table
///                ├─ headerRow                ← visible header row
///                ├─ for each data row:
///                │   ├─ cellRow              ← visible cells
///                │   └─ sublineRow?          ← optional subline, full-width
///                └─ footerRow?               ← optional footer
/// ```
///
/// **Sublines** render as a separate TableRow following their data row's
/// cell row. To avoid bloating column 0's intrinsic width with the long
/// notation continuation, the subline cell uses a custom render object
/// (`_SublineCellRender`) that reports 0 intrinsic width but lays out and
/// paints its child at `sublineTargetWidth` — the row's full width. The
/// other columns of the subline row collapse to zero width, so the
/// subline visually spans the entire row without disturbing column
/// alignment.
///
/// **Sticky header**: not provided. The whole Table is the unit of
/// vertical scroll — the header scrolls with the body. The trade-off is
/// deliberate: with separate header / body Tables, column widths drift;
/// with measurement-row tricks they align but produce duplicate widgets
/// in the tree (breaking `find.text(..., findsOneWidget)` semantics and
/// any caller-level introspection). For our games tables, all current
/// callers stack a rail header (count + filter chips) outside the table
/// — that header remains sticky.
class AdaptiveGamesTable<T> extends StatelessWidget {
  const AdaptiveGamesTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.scrollController,
    this.horizontalScrollController,
    this.headerHeight = 28,
    this.rowMinHeight = 38,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.rowSeparator = true,
    this.useFixedRowAlignment = false,
    this.minTableWidth,
    this.onRowTap,
    this.onRowDoubleTap,
    this.onRowSecondaryTap,
    this.onRowHover,
    this.rowSublineBuilder,
    this.rowDecorationBuilder,
    this.rowKeyBuilder,
    this.enableRowHover = true,
    this.footer,
    this.emptyState,
    this.sortState,
    this.onSortChanged,
  });

  /// Active sort. When null, the table reads as the caller's default.
  final AdaptiveSortState? sortState;

  /// Header click handler. When null, headers are not interactive even when
  /// their column declares a `sortField`. The table passes the *next* state
  /// (or null when cycling back to default) — callers translate that into a
  /// query parameter.
  final void Function(AdaptiveSortState? next)? onSortChanged;

  final List<AdaptiveColumn<T>> columns;
  final List<T> rows;

  /// Owned by the caller. Lets the caller drive pagination, prefetch on
  /// scroll-near-bottom, "jump to top on FEN change" etc.
  final ScrollController scrollController;

  /// Optional explicit horizontal scroll controller. Provide one if the
  /// caller wants to sync the table's h-scroll with another widget
  /// (rare). Defaults to a fresh internal controller per build.
  final ScrollController? horizontalScrollController;

  final double headerHeight;
  final double rowMinHeight;
  final EdgeInsetsGeometry padding;
  final bool rowSeparator;

  /// When true, the table doesn't wrap itself in an internal vertical
  /// scroll view — use when an outer scroll view owns the vertical axis
  /// (e.g. a round-grouped games rail). Column alignment is identical
  /// either way; this flag only changes scroll ownership.
  final bool useFixedRowAlignment;

  /// Minimum horizontal content width before the table starts scrolling.
  /// Leave null to fill the host rail exactly. Set this for resizable rails
  /// where the default width should show all columns, but dragging narrower
  /// should keep the table readable via horizontal scroll.
  final double? minTableWidth;

  /// Single-click row handler. In table view this should select/highlight the
  /// row only. Opening a game belongs to [onRowDoubleTap] or caller-owned
  /// Enter-key handling.
  final void Function(T row, {required bool inNewTab})? onRowTap;

  /// Double-click row handler. Use this for opening games from table view.
  final void Function(T row, {required bool inNewTab})? onRowDoubleTap;
  final void Function(T row, Offset globalPosition)? onRowSecondaryTap;

  /// Called when the mouse enters a data row. Keyboard-driven selection is
  /// still owned by callers; this hook lets a host mirror mouse hover into
  /// that same single selection/focus model.
  final void Function(T row, int rowIndex)? onRowHover;

  /// Optional full-width line rendered below each row's column cells. The
  /// builder may return null to keep that row single-line. This is useful for
  /// dense chess continuations where the text should consume the visible rail
  /// width instead of competing with metadata columns.
  final Widget? Function(BuildContext context, T row)? rowSublineBuilder;

  /// Hook for hover / selected-state row backgrounds. Receives the row and
  /// must return a [BoxDecoration] (or null for the default).
  final BoxDecoration? Function(T row, bool hovered)? rowDecorationBuilder;

  /// When false, pointer movement over rows remains passive: no hover
  /// background and no [onRowHover] callback.
  final bool enableRowHover;

  /// Optional key placed on the row host. Useful for callers that need to
  /// keep the selected row scrolled into view.
  final Key? Function(T row)? rowKeyBuilder;

  final Widget? footer;
  final Widget? emptyState;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty && emptyState != null) return emptyState!;

    // Auto-append an invisible flex spacer when no caller-supplied column
    // claims slack. The Table widget doesn't stretch its intrinsic columns
    // to fill the host rail; without a flex column, sums of intrinsic
    // widths < rail width leave dead space on the right. The spacer column
    // absorbs that slack so the table always reads as edge-to-edge.
    final hasFlex = columns.any((c) => c.flex != null);
    final effectiveColumns =
        hasFlex ? columns : <AdaptiveColumn<T>>[...columns, _spacerColumn<T>()];

    final colWidths = <int, TableColumnWidth>{
      for (var i = 0; i < effectiveColumns.length; i++)
        i: _columnWidthFor(effectiveColumns[i]),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final hCtrl = horizontalScrollController ?? ScrollController();
        final effectiveMinWidth =
            minTableWidth == null || constraints.maxWidth >= minTableWidth!
                ? constraints.maxWidth
                : minTableWidth!;
        return Scrollbar(
          controller: hCtrl,
          thumbVisibility: false,
          // Horizontal scrollbar is opt-in: we only want it visible while
          // the user is actively scrolling sideways. Default thumbVisibility
          // off + interactive on = matches macOS Finder's column view.
          interactive: true,
          child: SingleChildScrollView(
            controller: hCtrl,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: effectiveMinWidth),
              child: _SingleTableBody<T>(
                columns: effectiveColumns,
                rows: rows,
                colWidths: colWidths,
                headerHeight: headerHeight,
                rowMinHeight: rowMinHeight,
                padding: padding,
                rowSeparator: rowSeparator,
                onRowTap: onRowTap,
                onRowDoubleTap: onRowDoubleTap,
                onRowSecondaryTap: onRowSecondaryTap,
                onRowHover: onRowHover,
                rowSublineBuilder: rowSublineBuilder,
                rowDecorationBuilder: rowDecorationBuilder,
                rowKeyBuilder: rowKeyBuilder,
                enableRowHover: enableRowHover,
                footer: footer,
                sublineTargetWidth: effectiveMinWidth,
                scrollController: scrollController,
                useInternalVerticalScroll: !useFixedRowAlignment,
                maxHeight: constraints.maxHeight,
                sortState: sortState,
                onSortChanged: onSortChanged,
              ),
            ),
          ),
        );
      },
    );
  }
}

TableColumnWidth _columnWidthFor<T>(AdaptiveColumn<T> column) {
  final minWidth = column.minWidth;
  if (column.flex != null) {
    final flex = FlexColumnWidth(column.flex!);
    if (minWidth == null) return flex;
    return MaxColumnWidth(FixedColumnWidth(minWidth), flex);
  }
  if (minWidth == null) return const IntrinsicColumnWidth();
  return MaxColumnWidth(
    FixedColumnWidth(minWidth),
    const IntrinsicColumnWidth(),
  );
}

/// Stateful host that owns hover state and renders the single combined
/// [Table]. When [useInternalVerticalScroll] is true, the Table is wrapped
/// in a vertical [SingleChildScrollView]; otherwise the parent is expected
/// to own vertical scrolling.
class _SingleTableBody<T> extends StatefulWidget {
  const _SingleTableBody({
    required this.columns,
    required this.rows,
    required this.colWidths,
    required this.headerHeight,
    required this.rowMinHeight,
    required this.padding,
    required this.rowSeparator,
    required this.onRowTap,
    required this.onRowDoubleTap,
    required this.onRowSecondaryTap,
    required this.onRowHover,
    required this.rowSublineBuilder,
    required this.rowDecorationBuilder,
    required this.rowKeyBuilder,
    required this.enableRowHover,
    required this.footer,
    required this.sublineTargetWidth,
    required this.scrollController,
    required this.useInternalVerticalScroll,
    required this.maxHeight,
    required this.sortState,
    required this.onSortChanged,
  });

  final List<AdaptiveColumn<T>> columns;
  final List<T> rows;
  final Map<int, TableColumnWidth> colWidths;
  final double headerHeight;
  final double rowMinHeight;
  final EdgeInsetsGeometry padding;
  final bool rowSeparator;
  final void Function(T row, {required bool inNewTab})? onRowTap;
  final void Function(T row, {required bool inNewTab})? onRowDoubleTap;
  final void Function(T row, Offset globalPosition)? onRowSecondaryTap;
  final void Function(T row, int rowIndex)? onRowHover;
  final Widget? Function(BuildContext context, T row)? rowSublineBuilder;
  final BoxDecoration? Function(T row, bool hovered)? rowDecorationBuilder;
  final Key? Function(T row)? rowKeyBuilder;
  final bool enableRowHover;
  final Widget? footer;
  final double sublineTargetWidth;
  final ScrollController scrollController;
  final bool useInternalVerticalScroll;
  final double maxHeight;
  final AdaptiveSortState? sortState;
  final void Function(AdaptiveSortState? next)? onSortChanged;

  @override
  State<_SingleTableBody<T>> createState() => _SingleTableBodyState<T>();
}

class _SingleTableBodyState<T> extends State<_SingleTableBody<T>> {
  int? _hoveredIndex;

  void _setHover(int? next) {
    if (!widget.enableRowHover) return;
    if (_hoveredIndex == next) return;
    setState(() => _hoveredIndex = next);
    if (next == null || next < 0 || next >= widget.rows.length) return;
    widget.onRowHover?.call(widget.rows[next], next);
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Pre-resolve sublines so we don't ask the builder twice per row.
    final sublines = <int, Widget>{};
    if (widget.rowSublineBuilder != null) {
      for (var i = 0; i < widget.rows.length; i++) {
        final s = widget.rowSublineBuilder!(context, widget.rows[i]);
        if (s != null) sublines[i] = s;
      }
    }

    final table = Table(
      columnWidths: widget.colWidths,
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        _headerRow(),
        for (var i = 0; i < widget.rows.length; i++) ...[
          _bodyRow(i, hasSubline: sublines.containsKey(i)),
          if (sublines.containsKey(i)) _sublineRow(i, sublines[i]!),
        ],
        if (widget.footer != null) _footerRow(),
      ],
    );

    Widget content =
        widget.enableRowHover
            ? MouseRegion(onExit: (_) => _setHover(null), child: table)
            : table;

    if (widget.useInternalVerticalScroll) {
      final double maxBodyHeight =
          widget.maxHeight.isFinite ? widget.maxHeight : 600.0;
      content = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxBodyHeight),
        child: SingleChildScrollView(
          controller: widget.scrollController,
          physics: const DesktopScrollPhysics(),
          child: content,
        ),
      );
    }

    return content;
  }

  // ---------------------------------------------------------------------
  // TableRow builders
  // ---------------------------------------------------------------------

  TableRow _headerRow() {
    return TableRow(
      decoration: const BoxDecoration(
        color: kBackgroundColor,
        border: Border(bottom: BorderSide(color: kDividerColor, width: 1)),
      ),
      children: [
        for (final col in widget.columns)
          Padding(
            padding: widget.padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.headerHeight),
              child: Align(
                alignment: col.headerAlignment,
                child: _buildHeaderCell(col),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderCell(AdaptiveColumn<T> col) {
    final canSort = col.sortField != null && widget.onSortChanged != null;
    final active = canSort && widget.sortState?.field == col.sortField;
    final direction = active ? widget.sortState!.direction : null;
    final label = _HeaderLabel(label: col.label, emphasized: active);

    Widget headerContent;
    if (!canSort) {
      headerContent = label;
    } else {
      headerContent = _SortableHeader(
        label: label,
        direction: direction,
        alignment: col.headerAlignment,
        onTap: () => _cycleSort(col.sortField!),
      );
    }

    if (col.tooltip == null) return headerContent;
    return DesktopTooltip(message: col.tooltip!, child: headerContent);
  }

  void _cycleSort(GamebaseSortField field) {
    final cb = widget.onSortChanged;
    if (cb == null) return;
    final current = widget.sortState;
    if (current == null || current.field != field) {
      cb(
        AdaptiveSortState(field: field, direction: GamebaseSortDirection.desc),
      );
      return;
    }
    if (current.direction == GamebaseSortDirection.desc) {
      cb(AdaptiveSortState(field: field, direction: GamebaseSortDirection.asc));
      return;
    }
    cb(null);
  }

  TableRow _bodyRow(int rowIndex, {required bool hasSubline}) {
    final row = widget.rows[rowIndex];
    final hovered = _hoveredIndex == rowIndex;
    final decoration = _decorationFor(
      row: row,
      hovered: hovered,
      // When the row has a subline, the bottom separator lives on the
      // subline row instead — keeping the divider snug under the subline.
      includeBottomSeparator: !hasSubline && rowIndex < widget.rows.length - 1,
    );

    return TableRow(
      decoration: decoration,
      children: [
        for (var colIndex = 0; colIndex < widget.columns.length; colIndex++)
          _buildInteractiveCell(
            row: row,
            rowIndex: rowIndex,
            col: widget.columns[colIndex],
            rowKey: colIndex == 0 ? widget.rowKeyBuilder?.call(row) : null,
          ),
      ],
    );
  }

  TableRow _sublineRow(int rowIndex, Widget subline) {
    final row = widget.rows[rowIndex];
    final hovered = _hoveredIndex == rowIndex;
    final decoration = _decorationFor(
      row: row,
      hovered: hovered,
      includeBottomSeparator: rowIndex < widget.rows.length - 1,
    );

    final sublineContent = MouseRegion(
      onEnter: widget.enableRowHover ? (_) => _setHover(rowIndex) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap:
            widget.onRowTap == null
                ? null
                : () =>
                    widget.onRowTap!(row, inNewTab: isNewTabModifierPressed()),
        onDoubleTap:
            widget.onRowDoubleTap == null
                ? null
                : () => widget.onRowDoubleTap!(
                  row,
                  inNewTab: isNewTabModifierPressed(),
                ),
        onSecondaryTapUp:
            widget.onRowSecondaryTap == null
                ? null
                : (d) => widget.onRowSecondaryTap!(row, d.globalPosition),
        child: Padding(
          padding: widget.padding.add(const EdgeInsets.only(bottom: 7)),
          child: subline,
        ),
      ),
    );

    return TableRow(
      decoration: decoration,
      children: [
        // Column 0 paints the subline at full row width via a custom
        // RenderObject whose intrinsic width is 0 — so the subline never
        // bloats column 0's measurement — but whose paint footprint spans
        // `sublineTargetWidth`. Other columns collapse to zero width.
        _SublineCell(
          targetWidth: widget.sublineTargetWidth,
          child: sublineContent,
        ),
        for (var i = 1; i < widget.columns.length; i++) const SizedBox.shrink(),
      ],
    );
  }

  TableRow _footerRow() {
    return TableRow(
      children: [
        for (var i = 0; i < widget.columns.length; i++)
          if (i == 0)
            Padding(
              padding: widget.padding.add(
                const EdgeInsets.symmetric(vertical: 6),
              ),
              child: widget.footer!,
            )
          else
            const SizedBox.shrink(),
      ],
    );
  }

  BoxDecoration _decorationFor({
    required T row,
    required bool hovered,
    required bool includeBottomSeparator,
  }) {
    final override = widget.rowDecorationBuilder?.call(row, hovered);
    if (override != null) return override;
    return BoxDecoration(
      color: hovered ? kBlack3Color : Colors.transparent,
      border:
          includeBottomSeparator && widget.rowSeparator
              ? const Border(
                bottom: BorderSide(color: kDividerColor, width: 0.5),
              )
              : null,
    );
  }

  // ---------------------------------------------------------------------
  // Cell builders
  // ---------------------------------------------------------------------

  Widget _buildInteractiveCell({
    required T row,
    required int rowIndex,
    required AdaptiveColumn<T> col,
    required Key? rowKey,
  }) {
    Widget child = ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.rowMinHeight),
      child: Padding(
        padding: widget.padding.add(const EdgeInsets.symmetric(vertical: 6)),
        child: Align(
          alignment: col.cellAlignment,
          child: col.cellBuilder(context, row),
        ),
      ),
    );
    if (rowKey != null) {
      child = KeyedSubtree(key: rowKey, child: child);
    }

    return MouseRegion(
      onEnter: widget.enableRowHover ? (_) => _setHover(rowIndex) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap:
            widget.onRowTap == null
                ? null
                : () =>
                    widget.onRowTap!(row, inNewTab: isNewTabModifierPressed()),
        onDoubleTap:
            widget.onRowDoubleTap == null
                ? null
                : () => widget.onRowDoubleTap!(
                  row,
                  inNewTab: isNewTabModifierPressed(),
                ),
        onSecondaryTapUp:
            widget.onRowSecondaryTap == null
                ? null
                : (d) => widget.onRowSecondaryTap!(row, d.globalPosition),
        child: child,
      ),
    );
  }
}

// =====================================================================
// Subline cell — zero intrinsic width, paints child at row-width.
// =====================================================================

/// Cell widget whose render object reports `0` for intrinsic width but
/// lays out its child at `targetWidth` and paints it from the cell's
/// origin. The other cells in the subline row collapse to 0 width, so the
/// child visually spans the entire row without inflating column 0's
/// measured width.
class _SublineCell extends SingleChildRenderObjectWidget {
  const _SublineCell({required this.targetWidth, required Widget child})
    : super(child: child);

  final double targetWidth;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _SublineCellRender(targetWidth: targetWidth);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _SublineCellRender renderObject,
  ) {
    renderObject.targetWidth = targetWidth;
  }
}

class _SublineCellRender extends RenderProxyBox {
  _SublineCellRender({required double targetWidth})
    : _targetWidth = targetWidth;

  double _targetWidth;
  double get targetWidth => _targetWidth;
  set targetWidth(double value) {
    if (value == _targetWidth) return;
    _targetWidth = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;
  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(_targetWidth) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(_targetWidth) ?? 0;

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = Size.zero;
      return;
    }
    c.layout(
      BoxConstraints(
        minWidth: 0,
        maxWidth: _targetWidth,
        minHeight: 0,
        maxHeight: double.infinity,
      ),
      parentUsesSize: true,
    );
    // Intrinsic width stays zero via compute*IntrinsicWidth above; the
    // laid-out box still has to satisfy the table cell's tight width
    // constraint on recent Flutter builds.
    final cellWidth =
        constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : constraints.minWidth;
    size = constraints.constrain(Size(cellWidth, c.size.height));
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Default hitTest clips to size (0, height); the child paints across
    // the full row width, so we hand-roll a hit test that delegates to
    // the child within its painted bounds.
    final c = child;
    if (c == null) return false;
    if (position.dx < 0 ||
        position.dx > _targetWidth ||
        position.dy < 0 ||
        position.dy > size.height) {
      return false;
    }
    final hit = result.addWithPaintOffset(
      offset: Offset.zero,
      position: position,
      hitTest: (BoxHitTestResult childResult, Offset transformed) {
        return c.hitTest(childResult, position: transformed);
      },
    );
    if (hit) {
      result.add(BoxHitTestEntry(this, position));
    }
    return hit;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    context.paintChild(c, offset);
  }
}

/// Invisible flex column auto-appended when no caller column claims slack.
/// Keeps every TableRow at the rail's full width so the table reads as
/// edge-to-edge instead of left-aligned with empty space on the right.
AdaptiveColumn<T> _spacerColumn<T>() {
  return AdaptiveColumn<T>(
    id: '__adaptive_spacer__',
    label: '',
    flex: 1,
    cellBuilder: (_, __) => const SizedBox.shrink(),
  );
}

class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel({required this.label, this.emphasized = false});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: emphasized ? kPrimaryColor : kLightGreyColor,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.55,
      ),
    );
  }
}

/// Clickable header with sort-direction indicator. Hover affordance is a
/// faint underline + cursor change; active sort tints the label and shows
/// the arrow inline. Click cycles desc → asc → off.
class _SortableHeader extends StatefulWidget {
  const _SortableHeader({
    required this.label,
    required this.direction,
    required this.alignment,
    required this.onTap,
  });

  final Widget label;
  final GamebaseSortDirection? direction;
  final Alignment alignment;
  final VoidCallback onTap;

  @override
  State<_SortableHeader> createState() => _SortableHeaderState();
}

class _SortableHeaderState extends State<_SortableHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dir = widget.direction;
    final arrow =
        dir == null
            ? null
            : Icon(
              dir == GamebaseSortDirection.asc
                  ? Icons.arrow_drop_up_rounded
                  : Icons.arrow_drop_down_rounded,
              size: 14,
              color: kPrimaryColor,
            );
    // Hover-only arrow so users can see the affordance before they commit
    // to a sort. The faint outlined glyph hints that the column is
    // sortable without competing with the active sort's filled arrow.
    final hoverHint =
        (dir == null && _hovered)
            ? const Padding(
              padding: EdgeInsets.only(left: 2),
              child: Icon(
                Icons.unfold_more_rounded,
                size: 12,
                color: kWhiteColor70,
              ),
            )
            : null;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                widget.alignment.x > 0
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
            children: [
              Flexible(child: widget.label),
              if (arrow != null) arrow,
              if (hoverHint != null) hoverHint,
            ],
          ),
        ),
      ),
    );
  }
}
