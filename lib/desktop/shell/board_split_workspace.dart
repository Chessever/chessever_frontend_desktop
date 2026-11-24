import 'dart:async';
import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/board_unsaved_analysis_dialog.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_compact_player_identity.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/game_drag_source.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

/// A Board tab pulled from the tab strip or a watched board returned to it.
@immutable
class BoardTabDragPayload {
  const BoardTabDragPayload({
    required this.tabId,
    required this.label,
    this.fromWall = false,
  });

  final String tabId;
  final String label;
  final bool fromWall;
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

/// One persistent slot per Board pane. Only the main pane paints; the other
/// Board panes in the group keep their game state and publish watch positions.
class DesktopWorkspaceSlots extends StatelessWidget {
  const DesktopWorkspaceSlots({
    super.key,
    required this.pages,
    required this.activeIndex,
    this.split,
    this.onActivateCell,
  });

  final List<DesktopWorkspacePage> pages;
  final int activeIndex;
  final BoardSplitLayout? split;
  final ValueChanged<String>? onActivateCell;

  @override
  Widget build(BuildContext context) {
    final group = split;
    return CustomMultiChildLayout(
      delegate: _WorkspaceSlotsDelegate(
        slotIds: [for (final page in pages) page.slotId],
        activeIndex: activeIndex,
        hasWall: group != null,
      ),
      children: [
        for (var index = 0; index < pages.length; index++)
          _slot(pages[index], visible: index == activeIndex),
        if (group != null)
          LayoutId(
            id: _wallSlot,
            child: _RoundWall(group: group, onPromote: onActivateCell),
          ),
      ],
    );
  }

  Widget _slot(DesktopWorkspacePage page, {required bool visible}) => LayoutId(
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
              child: RepaintBoundary(child: page.child),
            ),
          ),
        ),
      ),
    ),
  );
}

const _wallSlot = 'round-wall';
const _wallGap = 10.0;

Rect _wallRect(Size size) {
  final width = math.min(
    size.width * .46,
    math.max(size.width * .30, size.height - 204),
  );
  return Rect.fromLTWH(size.width - width, 0, width, size.height);
}

class _WorkspaceSlotsDelegate extends MultiChildLayoutDelegate {
  _WorkspaceSlotsDelegate({
    required this.slotIds,
    required this.activeIndex,
    required this.hasWall,
  });

  final List<String> slotIds;
  final int activeIndex;
  final bool hasWall;

  @override
  void performLayout(Size size) {
    final wall = hasWall ? _wallRect(size) : null;
    final main = Size(
      wall == null ? size.width : math.max(0, wall.left - _wallGap),
      size.height,
    );
    for (var index = 0; index < slotIds.length; index++) {
      final id = slotIds[index];
      layoutChild(id, BoxConstraints.tight(index == activeIndex ? main : size));
      positionChild(id, Offset.zero);
    }
    if (wall != null) {
      layoutChild(_wallSlot, BoxConstraints.tight(wall.size));
      positionChild(_wallSlot, wall.topLeft);
    }
  }

  @override
  bool shouldRelayout(_WorkspaceSlotsDelegate oldDelegate) =>
      activeIndex != oldDelegate.activeIndex ||
      hasWall != oldDelegate.hasWall ||
      !listEquals(slotIds, oldDelegate.slotIds);
}

class _RoundWall extends StatelessWidget {
  const _RoundWall({required this.group, required this.onPromote});

  final BoardSplitLayout group;
  final ValueChanged<String>? onPromote;

  @override
  Widget build(BuildContext context) {
    final watched = group.watchedTabIds.toList(growable: false);
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 10, 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Round Wall',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${watched.length}',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const gap = 8.0;
                const chrome = 47.0;
                final width = constraints.maxWidth;
                final columns = width >= 316 ? 3 : (width >= 204 ? 2 : 1);
                final gapWidth = (columns - 1) * gap;
                final tile = math.min(
                  (width - gapWidth) / columns,
                  math.max(
                    90.0,
                    (constraints.maxHeight - 2 * gap) / 3 - chrome,
                  ),
                );
                final inset = math.max(
                  0.0,
                  (width - gapWidth - columns * tile) / 2,
                );
                return GridView.builder(
                  key: PageStorageKey<String>(group.id),
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: tile + chrome,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                  ),
                  itemCount: watched.length,
                  itemBuilder: (context, index) {
                    final id = watched[index];
                    return _WatchedBoard(
                      key: ValueKey(id),
                      tabId: id,
                      size: tile,
                      onPromote:
                          onPromote == null ? null : () => onPromote!(id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchedBoard extends ConsumerStatefulWidget {
  const _WatchedBoard({
    super.key,
    required this.tabId,
    required this.size,
    required this.onPromote,
  });

  final String tabId;
  final double size;
  final VoidCallback? onPromote;

  @override
  ConsumerState<_WatchedBoard> createState() => _WatchedBoardState();
}

class _WatchedBoardState extends ConsumerState<_WatchedBoard> {
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    final id = widget.tabId;
    if (boardTabHasUnsavedAnalysis(tabId: id, read: ref.read)) {
      _closing = true;
      final confirmed = await confirmDiscardBoardAnalysis(
        context,
      ).whenComplete(() => _closing = false);
      if (!mounted || !confirmed) return;
    }
    ref.read(desktopTabsProvider.notifier).close(id);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.tabId;
    final title = ref.watch(
      desktopTabsProvider.select(
        (state) =>
            state.tabs.where((tab) => tab.id == id).firstOrNull?.title ??
            'Board',
      ),
    );
    final args = ref.watch(
      boardTabGameArgsByTabIdProvider.select((byTab) => byTab[id]),
    );
    final fen = ref.watch(boardTabFenProvider.select((byTab) => byTab[id]));
    final preview = ref.watch(
      boardTabWatchPreviewProvider.select((byTab) => byTab[id]),
    );
    final label =
        args != null && args.whiteName.isNotEmpty && args.blackName.isNotEmpty
            ? '${args.whiteName} vs ${args.blackName}'
            : title;
    final pairing =
        args != null && args.whiteName.isNotEmpty && args.blackName.isNotEmpty
            ? '${desktopCompactPlayerNameParts(args.whiteName).lastName} – ${desktopCompactPlayerNameParts(args.blackName).lastName}'
            : title;
    final drag = BoardTabDragPayload(tabId: id, label: label, fromWall: true);
    final clocks = [
      for (final clock in [preview?.whiteClock, preview?.blackClock])
        if (clock != null && clock.isNotEmpty) formatPgnClockForDisplay(clock),
    ];
    final result = switch (preview?.result) {
      '1/2-1/2' => '½–½',
      '1-0' => '1–0',
      '0-1' => '0–1',
      _ => '',
    };
    final settings = ref.watch(boardSettingsProviderNew).valueOrNull;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 25,
            child: BoardTabDragSource(
              payload: drag,
              child: Padding(
                padding: const EdgeInsets.only(left: 5, right: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        clocks.isEmpty || widget.size < 118
                            ? ''
                            : clocks.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: kWhiteColor70,
                        ),
                      ),
                    ),
                    _HeaderIconButton(
                      tooltip: 'Move to its own tab',
                      icon: Icons.open_in_full_rounded,
                      onPress:
                          () =>
                              ref.read(boardSplitProvider.notifier).remove(id),
                    ),
                    _HeaderIconButton(
                      tooltip: 'Close board',
                      icon: Icons.close_rounded,
                      onPress: () => unawaited(_close()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          BoardTabDragSource(
            payload: drag,
            child: _PromoteWatchedBoard(
              label: 'Make $label the main board',
              onPromote: widget.onPromote,
              child: cg.StaticChessboard(
                size: widget.size,
                fen:
                    (fen?.isNotEmpty ?? false)
                        ? fen!
                        : args?.fenSeed ?? Chess.initial.fen,
                orientation:
                    (preview?.flipped ?? args?.initialBoardFlipped ?? false)
                        ? Side.black
                        : Side.white,
                lastMove: preview?.lastMove,
                settings: cg.StaticChessboardSettings.fromBoardSettings(
                  cg.ChessboardSettings(
                    enableCoordinates: false,
                    colorScheme:
                        settings?.colorScheme ?? cg.ChessboardColorScheme.blue,
                    pieceAssets:
                        settings?.pieceAssets ?? cg.PieceSet.cburnettAssets,
                    animationDuration: Duration.zero,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 22,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      pairing,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: kWhiteColor70,
                      ),
                    ),
                  ),
                  if (result.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        result,
                        style: const TextStyle(
                          fontSize: 10,
                          color: kWhiteColor70,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PromoteWatchedBoard extends StatelessWidget {
  const _PromoteWatchedBoard({
    required this.label,
    required this.onPromote,
    required this.child,
  });

  final String label;
  final VoidCallback? onPromote;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final promote = onPromote;
    return DesktopTooltip(
      message: label,
      child: FocusableActionDetector(
        enabled: promote != null,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              promote?.call();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          label: label,
          child: GestureDetector(onTap: promote, child: child),
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
    required this.rect,
    required this.label,
    required this.layoutKey,
    required this.groupId,
    this.busy = false,
  });

  final String targetTabId;
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
      other.rect == rect &&
      other.label == label &&
      other.layoutKey == layoutKey &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(targetTabId, rect, label, layoutKey, busy);
}

/// Accepts game rows and Board tabs dropped on the Board workspace and
/// adds the game to the Round Wall. A preview shows the watched area.
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
      data is GameTabDragPayload ||
      (data is BoardTabDragPayload && !data.fromWall);

  /// Which boards are shown where, and which one is focused.
  static String _layoutKey(String activeId, BoardSplitLayout layout) =>
      '$activeId|${layout.id}|${layout.tabIds.join(',')}';

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
    if (!layout.hasRoom) return null;
    if (data is BoardTabDragPayload && layout.contains(data.tabId)) return null;
    if (data is GameTabDragPayload) {
      final args = ref.read(boardTabGameArgsByTabIdProvider);
      final duplicate = layout.tabIds.any((id) {
        final game = args[id];
        return game?.gameId == data.id || game?.gameListSelectedId == data.id;
      });
      // A row released in its source rail is not intended for the wall.
      if (duplicate || local.dx < math.min(230, size.width * .23)) return null;
    }
    final premium =
        ref.read(boardSplitAccessProvider).outcome ==
        DesktopAccess.premiumRequired;
    return _DropPlan(
      targetTabId: activeId,
      rect: _wallRect(size).deflate(8),
      label: premium ? 'Add to Round Wall · Premium' : 'Add to Round Wall',
      layoutKey: _layoutKey(activeId, layout),
      groupId: layout.id,
    );
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
        if (open()) {
          split.watch(
            targetTabId: shown.targetTabId,
            incomingTabId: data.tabId,
          );
        }
      }

      if (open() && _admitSplit('board_split_tab_drop', shown, place)) place();
      return;
    }
    if (data is! GameTabDragPayload) return;
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
    final split = ref.read(boardSplitProvider.notifier);
    final targetIsBoard = ref
        .read(desktopTabsProvider)
        .tabs
        .any((tab) => tab.id == plan.targetTabId && tab.kind == TabKind.board);
    final originalSingle = BoardSplitLayout.single(plan.targetTabId).id;
    final group =
        split.current.groups
            .where((group) => group.id == plan.groupId)
            .firstOrNull;
    final target =
        group?.mainTabId ??
        (targetIsBoard && plan.groupId == originalSingle
            ? plan.targetTabId
            : null);
    if (target != null) {
      split.watch(targetTabId: target, incomingTabId: opened);
    }
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

/// The Round Wall landing area appears in place during a drag.
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

/// Rebuilds the slots when a game joins the wall or takes the main position.
class BoardSplitWorkspaceHost extends ConsumerWidget {
  const BoardSplitWorkspaceHost({super.key, required this.builder});

  final Widget Function(BuildContext context, BoardSplitLayout? split) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      builder(context, ref.watch(visibleBoardSplitProvider));
}
