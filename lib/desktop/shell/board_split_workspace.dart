import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/board_unsaved_analysis_dialog.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/game_drag_source.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

/// An open Board tab being dragged: from the tab strip, or by the header of
/// a split cell to move it to another place in the split.
@immutable
class BoardTabDragPayload {
  const BoardTabDragPayload({required this.tabId, required this.label});

  final String tabId;
  final String label;
}

/// Drags an open Board tab by [child]. A drag starts only on deliberate
/// travel, so it never steals a click; on the tab strip ([pullDownOnly]) it
/// also leaves sideways travel to tab reordering.
class BoardTabDragSource extends Draggable<BoardTabDragPayload> {
  BoardTabDragSource({
    super.key,
    required BoardTabDragPayload payload,
    required super.child,
    this.pullDownOnly = false,
    this.canStart,
    this.pullDistance,
    super.onDragStarted,
    super.onDragEnd,
  }) : super(
         data: payload,
         maxSimultaneousDrags: 1,
         dragAnchorStrategy: pointerDragAnchorStrategy,
         feedback: GameDragChip(label: payload.label),
       );

  /// Starts only on a downward pull (the tab strip sits at the top, the
  /// boards below it); otherwise any deliberate travel starts the drag.
  final bool pullDownOnly;

  /// Asked on each press; false leaves that press alone (no drag).
  final bool Function()? canStart;

  /// Asked on each press: how far down the pointer must travel before the
  /// pull starts. The tab strip passes the distance to the chip's bottom
  /// edge, so a wobbly click inside the chip never becomes a pull.
  final double Function()? pullDistance;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      pullDownOnly
            ? _DownwardDragGestureRecognizer(
              debugOwner: this,
              canStart: canStart,
              pullDistance: pullDistance,
            )
            : DeliberateMultiDragGestureRecognizer(debugOwner: this)
        ..onStart = onStart;
}

class _DownwardDragGestureRecognizer extends MultiDragGestureRecognizer {
  _DownwardDragGestureRecognizer({
    super.debugOwner,
    this.canStart,
    this.pullDistance,
  });

  final bool Function()? canStart;
  final double Function()? pullDistance;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (canStart?.call() ?? true) && super.isPointerAllowed(event);

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _DownwardPointerState(
        event.position,
        event.kind,
        gestureSettings,
        math.max(10, pullDistance?.call() ?? 10),
      );

  @override
  String get debugDescription => 'board tab pull into split';
}

class _DownwardPointerState extends MultiDragPointerState {
  _DownwardPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    this._distance,
  );

  final double _distance;
  GestureMultiDragStartCallback? _starter;

  bool get _pulledDown {
    final delta = pendingDelta!;
    return delta.dy > _distance && delta.dy > delta.dx.abs() * 1.2;
  }

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta!;
    // Sideways travel is a reorder; give the arena up to it.
    if (delta.dx.abs() > 10 && delta.dx.abs() > delta.dy.abs()) {
      resolve(GestureDisposition.rejected);
      return;
    }
    if (!_pulledDown) return;
    final starter = _starter;
    if (starter != null) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_pulledDown) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _starter = null;
    super.dispose();
  }
}

/// One page of the workspace: a tab's content and the id its slot is laid
/// out under.
@immutable
class DesktopWorkspacePage {
  const DesktopWorkspacePage({
    required this.slotId,
    required this.tabId,
    required this.child,
  });

  final String slotId;
  final String tabId;
  final Widget child;
}

/// Every tab page stays mounted. One page is shown, or every cell of the
/// visible [split], each at its own rect.
///
/// Pages are never re-parented: entering, resizing or leaving a split only
/// moves where a slot is laid out, so a board keeps its state, its live
/// stream and its video while the layout changes around it. Hidden pages get
/// the same treatment as `PersistentIndexedStack` (no tickers, no focus, no
/// paint, frozen layout and MediaQuery).
class DesktopWorkspaceSlots extends StatelessWidget {
  const DesktopWorkspaceSlots({
    super.key,
    required this.pages,
    required this.activeIndex,
    this.split,
    this.splitGeometry,
    this.onActivateCell,
  });

  final List<DesktopWorkspacePage> pages;
  final int activeIndex;
  final BoardSplitLayout? split;

  /// Live sizes of [split] while a divider is dragged. Changes only lay the
  /// cells out again; nothing is rebuilt.
  final ValueListenable<BoardSplitLayout?>? splitGeometry;

  /// Called when a press lands in a split cell that is not the active tab.
  final ValueChanged<String>? onActivateCell;

  @override
  Widget build(BuildContext context) {
    final split = this.split;
    final members = split?.tabIds.toSet() ?? const <String>{};
    final activeTabId =
        activeIndex >= 0 && activeIndex < pages.length
            ? pages[activeIndex].tabId
            : null;
    return CustomMultiChildLayout(
      delegate: _WorkspaceSlotsDelegate(
        slotIds: [for (final page in pages) page.slotId],
        slotTabIds: [for (final page in pages) page.tabId],
        split: split,
        geometry: splitGeometry,
      ),
      children: [
        for (var i = 0; i < pages.length; i++)
          _slot(
            pages[i],
            visible:
                split == null
                    ? i == activeIndex
                    : members.contains(pages[i].tabId),
            inSplit: split != null && members.contains(pages[i].tabId),
          ),
        if (split != null) ...[
          for (final tabId in split.tabIds)
            LayoutId(
              id: _headerId(tabId),
              child: BoardSplitCellHeader(
                tabId: tabId,
                focused: tabId == activeTabId,
              ),
            ),
          if (split.columns.length > 1)
            LayoutId(
              id: _columnGutterId,
              child: _SplitGutter(axis: Axis.horizontal, groupId: split.id),
            ),
          for (var c = 0; c < split.columns.length; c++)
            if (split.columns[c].length > 1)
              LayoutId(
                id: _rowGutterId(c),
                child: _SplitGutter(
                  axis: Axis.vertical,
                  groupId: split.id,
                  column: c,
                ),
              ),
        ],
      ],
    );
  }

  Widget _slot(
    DesktopWorkspacePage page, {
    required bool visible,
    required bool inSplit,
  }) {
    final activate = onActivateCell;
    return LayoutId(
      id: page.slotId,
      child: TickerMode(
        enabled: visible,
        child: Offstage(
          offstage: !visible,
          child: FreezeLayoutWhenHidden(
            frozen: !visible,
            child: FreezeMediaQueryWhenHidden(
              frozen: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: RepaintBoundary(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    // A press anywhere in a split cell makes its board the
                    // active tab, so keys, the engine and sounds follow the
                    // board being worked on.
                    onPointerDown:
                        inSplit && activate != null
                            ? (_) => activate(page.tabId)
                            : null,
                    child: page.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const String _columnGutterId = 'split-gutter:column';
String _rowGutterId(int column) => 'split-gutter:row:$column';
String _headerId(String tabId) => 'split-header:$tabId';

class _WorkspaceSlotsDelegate extends MultiChildLayoutDelegate {
  _WorkspaceSlotsDelegate({
    required this.slotIds,
    required this.slotTabIds,
    required this.split,
    this.geometry,
  }) : super(relayout: geometry);

  final List<String> slotIds;
  final List<String> slotTabIds;
  final BoardSplitLayout? split;
  final ValueListenable<BoardSplitLayout?>? geometry;

  /// [split] with the latest divider positions, when they belong to it.
  BoardSplitLayout? get _layout {
    final split = this.split;
    final live = geometry?.value;
    if (split == null || live == null || live.id != split.id) return split;
    return const DeepCollectionEquality().equals(live.columns, split.columns)
        ? live
        : split;
  }

  @override
  void performLayout(Size size) {
    final split = _layout;
    final rects = split?.cellRects(size) ?? const <String, Rect>{};
    for (var i = 0; i < slotIds.length; i++) {
      final cell = rects[slotTabIds[i]];
      if (cell == null) {
        layoutChild(slotIds[i], BoxConstraints.tight(size));
        positionChild(slotIds[i], Offset.zero);
        continue;
      }
      final headerHeight =
          cell.height < kBoardSplitCellHeaderHeight
              ? cell.height
              : kBoardSplitCellHeaderHeight;
      final content = Rect.fromLTRB(
        cell.left,
        cell.top + headerHeight,
        cell.right,
        cell.bottom,
      );
      layoutChild(slotIds[i], BoxConstraints.tight(content.size));
      positionChild(slotIds[i], content.topLeft);
      final header = _headerId(slotTabIds[i]);
      if (hasChild(header)) {
        layoutChild(
          header,
          BoxConstraints.tight(Size(cell.width, headerHeight)),
        );
        positionChild(header, cell.topLeft);
      }
    }
    if (split == null) return;
    final columnGutter = split.columnGutterRect(size);
    if (columnGutter != null && hasChild(_columnGutterId)) {
      layoutChild(_columnGutterId, BoxConstraints.tight(columnGutter.size));
      positionChild(_columnGutterId, columnGutter.topLeft);
    }
    for (var c = 0; c < split.columns.length; c++) {
      final rowGutter = split.rowGutterRect(size, c);
      if (rowGutter != null && hasChild(_rowGutterId(c))) {
        layoutChild(_rowGutterId(c), BoxConstraints.tight(rowGutter.size));
        positionChild(_rowGutterId(c), rowGutter.topLeft);
      }
    }
  }

  @override
  bool shouldRelayout(_WorkspaceSlotsDelegate oldDelegate) =>
      oldDelegate.split != split ||
      oldDelegate.geometry != geometry ||
      !listEquals(oldDelegate.slotIds, slotIds) ||
      !listEquals(oldDelegate.slotTabIds, slotTabIds);
}

/// The divider between two columns ([Axis.horizontal]) or the two rows of a
/// column ([Axis.vertical]). Same line and hit width as the dividers inside
/// a board, so the whole workspace reads as one set of resizable panes.
class _SplitGutter extends ConsumerStatefulWidget {
  const _SplitGutter({required this.axis, required this.groupId, this.column});

  final Axis axis;
  final String groupId;
  final int? column;

  @override
  ConsumerState<_SplitGutter> createState() => _SplitGutterState();
}

class _SplitGutterState extends ConsumerState<_SplitGutter> {
  bool _hovered = false;
  bool _dragging = false;

  void _dragTo(Offset globalPosition) {
    final box =
        context
            .findAncestorRenderObjectOfType<RenderCustomMultiChildLayoutBox>();
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(globalPosition);
    final size = box.size;
    final notifier = ref.read(boardSplitProvider.notifier);
    if (widget.axis == Axis.horizontal) {
      final room = size.width - kBoardSplitGutter;
      if (room <= 0) return;
      notifier.setColumnFraction(
        widget.groupId,
        (local.dx - kBoardSplitGutter / 2) / room,
      );
    } else {
      final room = size.height - kBoardSplitGutter;
      if (room <= 0) return;
      notifier.setRowFraction(
        widget.groupId,
        widget.column ?? 0,
        (local.dy - kBoardSplitGutter / 2) / room,
      );
    }
  }

  void _reset() {
    final notifier = ref.read(boardSplitProvider.notifier);
    if (widget.axis == Axis.horizontal) {
      notifier.setColumnFraction(widget.groupId, 0.5);
    } else {
      notifier.setRowFraction(widget.groupId, widget.column ?? 0, 0.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor:
          horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _reset,
        onHorizontalDragStart:
            horizontal ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragUpdate:
            horizontal ? (d) => _dragTo(d.globalPosition) : null,
        onHorizontalDragEnd:
            horizontal ? (_) => setState(() => _dragging = false) : null,
        onVerticalDragStart:
            horizontal ? null : (_) => setState(() => _dragging = true),
        onVerticalDragUpdate:
            horizontal ? null : (d) => _dragTo(d.globalPosition),
        onVerticalDragEnd:
            horizontal ? null : (_) => setState(() => _dragging = false),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            width: horizontal ? (active ? 2 : 1) : null,
            height: horizontal ? null : (active ? 2 : 1),
            margin:
                horizontal
                    ? const EdgeInsets.symmetric(vertical: 6)
                    : const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: kDividerColor.withValues(alpha: active ? 0.95 : 0.55),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip above a split cell: which game it holds, and how to take it
/// out of the split. Its title tone marks the cell that has the keyboard.
/// Dragging the strip moves the cell to another place in the split.
class BoardSplitCellHeader extends ConsumerStatefulWidget {
  const BoardSplitCellHeader({
    super.key,
    required this.tabId,
    required this.focused,
  });

  final String tabId;
  final bool focused;

  @override
  ConsumerState<BoardSplitCellHeader> createState() =>
      _BoardSplitCellHeaderState();
}

class _BoardSplitCellHeaderState extends ConsumerState<BoardSplitCellHeader> {
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    if (boardTabHasUnsavedAnalysis(tabId: widget.tabId, read: ref.read)) {
      _closing = true;
      final confirmed = await confirmDiscardBoardAnalysis(
        context,
      ).whenComplete(() => _closing = false);
      if (!mounted || !confirmed) return;
    }
    ref.read(desktopTabsProvider.notifier).close(widget.tabId);
  }

  void _moveToOwnTab() {
    ref.read(boardSplitProvider.notifier).remove(widget.tabId);
    ref.read(desktopTabsProvider.notifier).activate(widget.tabId);
  }

  @override
  Widget build(BuildContext context) {
    final title = ref.watch(
      desktopTabsProvider.select(
        (s) =>
            s.tabs
                .firstWhere(
                  (t) => t.id == widget.tabId,
                  orElse:
                      () => DesktopTab(
                        id: widget.tabId,
                        kind: TabKind.board,
                        title: 'Board',
                      ),
                )
                .title,
      ),
    );
    final focused = widget.focused;
    final strip = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: focused ? kBlack3Color : kBlack2Color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 140),
              style: DefaultTextStyle.of(context).style.merge(
                TextStyle(
                  color:
                      focused
                          ? kWhiteColor
                          : kWhiteColor.withValues(alpha: 0.55),
                  fontSize: 12.5,
                  fontWeight: focused ? FontWeight.w600 : FontWeight.w500,
                  height: 1.2,
                ),
              ),
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          _HeaderIconButton(
            tooltip: 'Move to its own tab',
            icon: Icons.open_in_full_rounded,
            onPress: _moveToOwnTab,
          ),
          _HeaderIconButton(
            tooltip: 'Close board',
            icon: Icons.close_rounded,
            onPress: () => unawaited(_close()),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: focused ? '$title, active board' : title,
      child: BoardTabDragSource(
        payload: BoardTabDragPayload(tabId: widget.tabId, label: title),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap:
              () =>
                  ref.read(desktopTabsProvider.notifier).activate(widget.tabId),
          child: Padding(padding: const EdgeInsets.only(top: 4), child: strip),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPress,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPress;

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hovered || _focused;
    return DesktopTooltip(
      message: widget.tooltip,
      child: ClickCursor(
        // Reachable with Tab and pressed with Enter or Space, like the rest
        // of the shell's buttons.
        child: FocusableActionDetector(
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPress();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            label: widget.tooltip,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPress,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color:
                      lit
                          ? kWhiteColor.withValues(alpha: 0.08)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color:
                        _focused
                            ? kWhiteColor.withValues(alpha: 0.32)
                            : Colors.transparent,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  widget.icon,
                  size: 15,
                  color: lit ? kWhiteColor : kWhiteColor70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a drop over the workspace would do, shown before the user lets go.
@immutable
class _DropPlan {
  const _DropPlan({
    required this.targetTabId,
    required this.zone,
    required this.rect,
    required this.label,
    required this.layoutKey,
    required this.groupId,
    this.busy = false,
  });

  final String targetTabId;
  final BoardSplitZone zone;
  final Rect rect;
  final String label;

  /// The visible layout this plan was made against (see `_layoutKey`).
  final String layoutKey;

  /// The split the drop is aimed at, or the single board's own id.
  final String groupId;

  /// Shown while a dropped game is still opening: marks the workspace busy
  /// and is never acted on.
  final bool busy;

  /// [layoutKey] without the focused board: which boards are where.
  String get boardsKey => layoutKey.substring(layoutKey.indexOf('|') + 1);

  _DropPlan asBusy() => _DropPlan(
    targetTabId: targetTabId,
    zone: zone,
    rect: rect,
    label: 'Opening\u2026',
    layoutKey: layoutKey,
    groupId: groupId,
    busy: true,
  );

  @override
  bool operator ==(Object other) =>
      other is _DropPlan &&
      other.targetTabId == targetTabId &&
      other.zone == zone &&
      other.rect == rect &&
      other.label == label &&
      other.layoutKey == layoutKey &&
      other.busy == busy;

  @override
  int get hashCode =>
      Object.hash(targetTabId, zone, rect, label, layoutKey, busy);
}

/// Accepts game rows and Board tabs dropped on the Board workspace and
/// splits it: the outer third of a board opens the dropped game beside it,
/// the middle replaces it. A preview shows the landing area while dragging.
///
/// Inactive unless a Board tab is the active tab (and focus mode is off).
class BoardSplitDropLayer extends ConsumerStatefulWidget {
  const BoardSplitDropLayer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<BoardSplitDropLayer> createState() =>
      _BoardSplitDropLayerState();
}

class _BoardSplitDropLayerState extends ConsumerState<BoardSplitDropLayer> {
  _DropPlan? _plan;

  /// Where the drag came onto the workspace. A row dragged out of a board's
  /// own rail starts here already, so the drop arms only once the pointer
  /// has clearly moved on: a sloppy click released on the rail splits
  /// nothing.
  Offset? _entry;
  bool _armed = false;
  static const double _armDistance = 24;

  void _track(Offset globalPointer) {
    final entry = _entry ??= globalPointer;
    if (!_armed && (globalPointer - entry).distance >= _armDistance) {
      _armed = true;
    }
  }

  void _resetTracking() {
    _entry = null;
    _armed = false;
  }

  String? get _activeBoardTabId {
    final tabs = ref.read(desktopTabsProvider);
    final active = tabs.active;
    if (active == null || active.kind != TabKind.board) return null;
    if (!tabs.tabs.any((t) => t.id == active.id)) return null;
    if (ref.read(boardFocusModeProvider)) return null;
    return active.id;
  }

  bool _accepts(Object? data) =>
      data is GameTabDragPayload || data is BoardTabDragPayload;

  /// Which boards are shown where, and which one is focused.
  static String _layoutKey(String activeId, BoardSplitLayout layout) =>
      '$activeId|${layout.id}|'
      '${layout.columns.map((c) => c.join(',')).join(';')}';

  String? get _currentLayoutKey {
    final activeId = _activeBoardTabId;
    if (activeId == null) return null;
    return _layoutKey(
      activeId,
      ref.read(visibleBoardSplitProvider) ?? BoardSplitLayout.single(activeId),
    );
  }

  /// The drag hovering the workspace, kept so the preview can be planned
  /// again when the layout changes under a pointer that is not moving.
  Object? _hoverData;
  Offset? _hoverPointer;

  @override
  void initState() {
    super.initState();
    // After the frame: the cells have their new sizes by then, and the
    // provider change is not still being delivered.
    void replan() {
      if (_hoverData == null && _pendingPlan == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final data = _hoverData;
        final pointer = _hoverPointer;
        if (data != null && pointer != null) {
          _hover(data, pointer);
        } else {
          // Redraw the "Opening…" marker against the boards now shown.
          setState(() {});
        }
      });
    }

    ref.listenManual<BoardSplitLayout?>(
      visibleBoardSplitProvider,
      (_, __) => replan(),
    );
    ref.listenManual<String?>(
      desktopTabsProvider.select((s) => s.activeId),
      (_, __) => replan(),
    );
  }

  _DropPlan? _planFor(Object? data, Offset globalPointer) {
    final activeId = _activeBoardTabId;
    final box = context.findRenderObject();
    if (activeId == null || box is! RenderBox || !box.hasSize) return null;
    final size = box.size;
    final local = box.globalToLocal(globalPointer);
    final layout =
        ref.read(visibleBoardSplitProvider) ??
        BoardSplitLayout.single(activeId);
    final rects = layout.cellRects(size);
    String? target;
    var bestDistance = double.infinity;
    for (final entry in rects.entries) {
      if (entry.value.contains(local)) {
        target = entry.key;
        break;
      }
      // Over a gutter: take the nearest cell.
      final d = (entry.value.center - local).distance;
      if (d < bestDistance) {
        bestDistance = d;
        target = entry.key;
      }
    }
    if (target == null) return null;
    final incoming = data is BoardTabDragPayload ? data.tabId : null;
    final allowed = layout.zonesFor(target, incomingTabId: incoming);
    final cell = rects[target]!;
    final zone = resolveBoardSplitZone(
      local: local - cell.topLeft,
      cellSize: cell.size,
      allowed: allowed,
    );
    if (zone == null) return null;
    final rect = layout.previewRect(
      target,
      zone,
      size,
      incomingTabId: incoming,
    );
    if (rect == null) return null;
    var label = _labelFor(zone, layout, incoming);
    // A drop that would show more than one board needs Premium: say so on
    // the landing area, so the prompt the drop opens is no surprise.
    final opensAlone = zone == BoardSplitZone.replace && !layout.isSplit;
    if (!opensAlone &&
        ref.read(boardSplitAccessProvider).outcome ==
            DesktopAccess.premiumRequired) {
      label = '$label \u00b7 Premium';
    }
    return _DropPlan(
      targetTabId: target,
      zone: zone,
      rect: rect,
      label: label,
      layoutKey: _layoutKey(activeId, layout),
      groupId: layout.id,
    );
  }

  String _labelFor(
    BoardSplitZone zone,
    BoardSplitLayout layout,
    String? incoming,
  ) {
    switch (zone) {
      case BoardSplitZone.left:
        return 'Split left';
      case BoardSplitZone.right:
        return 'Split right';
      case BoardSplitZone.top:
        return 'Split up';
      case BoardSplitZone.bottom:
        return 'Split down';
      case BoardSplitZone.replace:
        if (!layout.isSplit) return 'Open here';
        if (incoming != null && layout.contains(incoming)) return 'Swap boards';
        return 'Replace this board';
    }
  }

  void _hover(Object? data, Offset globalPointer) {
    _hoverData = data;
    _hoverPointer = globalPointer;
    _track(globalPointer);
    // While a dropped game is opening, the workspace is busy: say so where
    // the pointer is, instead of offering a landing area a drop would not
    // honour.
    var plan = _armed ? _planFor(data, globalPointer) : null;
    if (plan != null && _pendingPlan != null) plan = plan.asBusy();
    if (plan != _plan) setState(() => _plan = plan);
  }

  void _endHover() {
    _hoverData = null;
    _hoverPointer = null;
    _resetTracking();
    if (_plan != null) setState(() => _plan = null);
  }

  void _drop(Object? data) {
    final armed = _armed;
    // Act on the landing area the user saw, and only if the boards have not
    // moved since it was planned.
    final shown = _plan;
    _endHover();
    final split = ref.read(boardSplitProvider.notifier);
    final tabs = ref.read(desktopTabsProvider.notifier);
    if (!armed) {
      // A tab let go before the drop armed was a click on it.
      if (data is BoardTabDragPayload) tabs.activate(data.tabId);
      return;
    }
    if (shown == null || shown.busy || shown.layoutKey != _currentLayoutKey) {
      return;
    }
    if (data is BoardTabDragPayload) {
      bool open() => tabs.currentState.tabs.any(
        (t) => t.id == data.tabId && t.kind == TabKind.board,
      );
      void place() {
        if (open() &&
            split.place(
              targetTabId: shown.targetTabId,
              incomingTabId: data.tabId,
              zone: shown.zone,
            )) {
          tabs.activate(data.tabId);
        }
      }

      // Every place a tab can land shows it beside another board.
      if (open() && _admitSplit('board_split_tab_drop', shown, place)) {
        place();
      }
      return;
    }
    if (data is! GameTabDragPayload) return;
    if (!split.layoutFor(shown.targetTabId).isSplit &&
        shown.zone == BoardSplitZone.replace) {
      // Nothing to split: open the game the way the tab strip does. Free
      // for everyone, as it was before boards could be split.
      unawaited(
        data
            .spawnAdmitted(ref, focus: true, surface: 'board_drop')
            .catchError(_reportDropError),
      );
      return;
    }
    void open() =>
        unawaited(_openInSplit(data, shown).catchError(_reportDropError));
    if (_admitSplit('board_split_game_drop', shown, open)) open();
  }

  /// Admission for a drop that splits the workspace. Allowed now: true.
  /// Otherwise the Premium prompt opens and the drop is not taken; a
  /// verified purchase replays it once, if the boards it was aimed at are
  /// still where they were.
  bool _admitSplit(String surface, _DropPlan shown, void Function() replay) =>
      admitBoardSplit(
        ProviderScope.containerOf(context, listen: false),
        surface: surface,
        resume: DesktopAccessResume(
          run: () {
            if (mounted) replay();
          },
          stillMatches: () => mounted && shown.layoutKey == _currentLayoutKey,
        ),
      );

  void _reportDropError(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'board split view',
        context: ErrorDescription('while opening a game dropped into a split'),
      ),
    );
  }

  /// The drop being opened. One at a time: until its board lands (or the
  /// marker gives up), the workspace takes no other split drop.
  _DropPlan? _pendingPlan;
  int _pendingToken = 0;

  Future<void> _openInSplit(GameTabDragPayload data, _DropPlan plan) async {
    if (!mounted) return;
    final tabs = ref.read(desktopTabsProvider.notifier);
    final token = ++_pendingToken;
    setState(() => _pendingPlan = plan);
    void settle() {
      if (mounted && token == _pendingToken && _pendingPlan != null) {
        setState(() => _pendingPlan = null);
      }
    }

    final before = {for (final t in tabs.currentState.tabs) t.id};
    var finished = false;
    // A slow fetch must not hold the workspace hostage: after a few seconds
    // the marker lets go and drops are taken again. A board that opens
    // later still lands if its split is still there.
    final release = Timer(const Duration(seconds: 6), settle);
    try {
      await data
          .spawnAdmitted(ref, focus: false, surface: 'board_split_drop')
          .then<void>((_) {
            finished = true;
          });
    } finally {
      release.cancel();
      settle();
    }
    if (!mounted) return;
    final opened = _openedBoardFor(data, before, spawnFinished: finished);
    if (opened == null) return;
    // Show the new board only to someone still on a board of the split it
    // lands in (judged before placing: a replace takes the focused board
    // itself out of the split).
    final activeBoard = _activeBoardTabId;
    final landedIn = _landInSplit(opened, plan);
    if (landedIn != null &&
        activeBoard != null &&
        landedIn.contains(activeBoard)) {
      tabs.activate(opened);
    }
  }

  /// Places [opened] where [plan] aimed, inside the split it was aimed at.
  /// If that zone is gone, beside a board still in that split. Never builds
  /// a new split around a board that has left it or stopped being a Board.
  /// Returns that split as it was before [opened] joined it, or null when
  /// nothing was placed.
  BoardSplitLayout? _landInSplit(String opened, _DropPlan plan) {
    final split = ref.read(boardSplitProvider.notifier);
    final targetIsBoard = ref
        .read(desktopTabsProvider)
        .tabs
        .any((t) => t.id == plan.targetTabId && t.kind == TabKind.board);
    final targetLayout = split.layoutFor(plan.targetTabId);
    final sameSplit = targetIsBoard && targetLayout.id == plan.groupId;
    if (sameSplit &&
        split.place(
          targetTabId: plan.targetTabId,
          incomingTabId: opened,
          zone: plan.zone,
        )) {
      return targetLayout;
    }
    // The split the drop was aimed at, wherever its boards are now.
    BoardSplitLayout? aimed;
    for (final group in split.current.groups) {
      if (group.id == plan.groupId) aimed = group;
    }
    // Aimed at a board shown on its own that has since joined a split:
    // that split is what the user now sees around it.
    aimed ??=
        sameSplit
            ? targetLayout
            : targetIsBoard &&
                plan.groupId == BoardSplitLayout.single(plan.targetTabId).id
            ? split.current.groupOf(plan.targetTabId)
            : null;
    if (aimed == null) return null;
    final anchor =
        aimed.contains(plan.targetTabId)
            ? plan.targetTabId
            : aimed.tabIds.first;
    final beside = besideBoardPlacement(aimed, anchor);
    if (beside == null) return null;
    final placed = split.place(
      targetTabId: beside.targetTabId,
      incomingTabId: opened,
      zone: beside.zone,
    );
    return placed ? aimed : null;
  }

  /// The Board tab [payload] opened: a tab that appeared since [before]
  /// showing that game. When the spawn finished and exactly one Board tab
  /// appeared that names no other game, that one (some sources key their
  /// tabs differently). Anything else adopts nothing.
  String? _openedBoardFor(
    GameTabDragPayload payload,
    Set<String> before, {
    required bool spawnFinished,
  }) {
    final args = ref.read(boardTabGameArgsByTabIdProvider);
    final fresh = [
      for (final t in ref.read(desktopTabsProvider).tabs)
        if (t.kind == TabKind.board && !before.contains(t.id)) t.id,
    ];
    for (final id in fresh) {
      final a = args[id];
      if (a != null &&
          (a.gameId == payload.id || a.gameListSelectedId == payload.id)) {
        return id;
      }
    }
    if (!spawnFinished || fresh.length != 1) return null;
    // A tab the user opened and is looking at is theirs, not the drop's.
    if (fresh.single == ref.read(desktopTabsProvider).activeId) return null;
    final a = args[fresh.single];
    final namesOtherGame =
        a != null &&
        ((a.gameId != null && a.gameId != payload.id) ||
            (a.gameListSelectedId != null &&
                a.gameListSelectedId != payload.id));
    return namesOtherGame ? null : fresh.single;
  }

  /// The "Opening…" marker, drawn only while the board it waits on is on
  /// screen and the boards have not moved since.
  _DropPlan? get _visiblePending {
    final pending = _pendingPlan;
    final current = _currentLayoutKey;
    if (pending == null || current == null) return null;
    // Moving focus between the boards does not move them; only a change of
    // which boards are where hides the marker.
    final boards = current.substring(current.indexOf('|') + 1);
    return pending.boardsKey == boards ? pending : null;
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<Object>(
      // Accept on payload type alone. A target that rejects a drag on entry
      // never becomes its drop target, yet keeps receiving its moves; the
      // board state is checked while hovering and at the drop instead.
      onWillAcceptWithDetails: (details) {
        if (!_accepts(details.data)) return false;
        _hover(details.data, details.offset);
        return true;
      },
      onMove: (details) {
        if (!_accepts(details.data)) return;
        _hover(details.data, details.offset);
      },
      onLeave: (_) => _endHover(),
      onAcceptWithDetails: (details) => _drop(details.data),
      builder: (context, candidates, rejected) {
        final pending = _visiblePending;
        final plan = _plan ?? pending;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            IgnorePointer(
              child: _DropPreview(
                plan: plan,
                opening:
                    (_plan?.busy ?? false) ||
                    (_plan == null && pending != null),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The landing area of a drop. It glides between zones as the pointer moves
/// so the user sees the split take shape before letting go. It appears in
/// place and fades out where it was, instead of sliding in from a corner.
class _DropPreview extends StatefulWidget {
  const _DropPreview({required this.plan, required this.opening});

  final _DropPlan? plan;
  final bool opening;

  @override
  State<_DropPreview> createState() => _DropPreviewState();
}

class _DropPreviewState extends State<_DropPreview> {
  _DropPlan? _shown;
  bool _glide = false;

  @override
  void didUpdateWidget(covariant _DropPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Glide only from one zone to the next; a fresh preview snaps in.
    _glide = oldWidget.plan != null && widget.plan != null;
    if (widget.plan != null) _shown = widget.plan;
  }

  @override
  void initState() {
    super.initState();
    _shown = widget.plan;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final visible = widget.plan != null;
    if (shown == null) return const SizedBox.shrink();
    final rect = shown.rect.deflate(6);
    final label = widget.opening ? 'Opening…' : shown.label;
    return Stack(
      children: [
        AnimatedPositioned(
          duration: _glide ? const Duration(milliseconds: 160) : Duration.zero,
          curve: Curves.easeOutCubic,
          left: rect.left,
          top: rect.top,
          width: rect.width < 0 ? 0 : rect.width,
          height: rect.height < 0 ? 0 : rect.height,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            opacity: visible ? 1 : 0,
            onEnd: () {
              // Faded out: drop it from the tree until the next drag.
              if (mounted && widget.plan == null && _shown != null) {
                setState(() => _shown = null);
              }
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: kBlack2Color.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kWhiteColor.withValues(alpha: 0.26)),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    child: Text(
                      label,
                      key: ValueKey<String>(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Feeds the visible split to [builder]. It rebuilds only when the split's
/// boards change; dragging a divider moves [BoardSplitLayout] fractions
/// through the geometry listenable, which lays the cells out again without
/// rebuilding the shell or any board.
class BoardSplitWorkspaceHost extends ConsumerStatefulWidget {
  const BoardSplitWorkspaceHost({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    BoardSplitLayout? split,
    ValueListenable<BoardSplitLayout?> geometry,
  )
  builder;

  @override
  ConsumerState<BoardSplitWorkspaceHost> createState() =>
      _BoardSplitWorkspaceHostState();
}

class _BoardSplitWorkspaceHostState
    extends ConsumerState<BoardSplitWorkspaceHost> {
  final ValueNotifier<BoardSplitLayout?> _geometry = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    ref.listenManual<BoardSplitLayout?>(
      visibleBoardSplitProvider,
      (_, next) => _geometry.value = next,
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _geometry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on which boards are shown and where, not on their sizes.
    ref.watch(
      visibleBoardSplitProvider.select(
        (group) =>
            group == null
                ? null
                : '${group.id}|${group.columns.map((c) => c.join(',')).join(';')}',
      ),
    );
    return widget.builder(
      context,
      ref.read(visibleBoardSplitProvider),
      _geometry,
    );
  }
}
