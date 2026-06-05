import 'package:chessground/chessground.dart' show PieceAssets;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/commentary_symbol_shortcuts.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_pointer.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/figurine_notation.dart';

enum NotationLayoutMode { ladder, inline }

class NotationVariationCollapseController {
  Object? _owner;
  VoidCallback? _collapseAll;
  VoidCallback? _expandAll;

  void collapseAll() => _collapseAll?.call();
  void expandAll() => _expandAll?.call();

  void _attach({
    required Object owner,
    required VoidCallback collapseAll,
    required VoidCallback expandAll,
  }) {
    _owner = owner;
    _collapseAll = collapseAll;
    _expandAll = expandAll;
  }

  void _detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _collapseAll = null;
    _expandAll = null;
  }
}

@visibleForTesting
class NotationHeaderMetadata {
  const NotationHeaderMetadata({this.event, this.round, this.date, this.eco});

  final String? event;
  final String? round;
  final String? date;
  final String? eco;

  bool get hasAny =>
      event != null || round != null || date != null || eco != null;
}

@visibleForTesting
NotationHeaderMetadata notationHeaderMetadataFromPgn(
  Map<String, Object?> metadata,
) {
  String? header(String key) {
    final raw = metadata[key]?.toString().trim();
    if (raw == null || raw.isEmpty || raw == '?') return null;
    return raw;
  }

  return NotationHeaderMetadata(
    event: header('Event'),
    round: header('Round'),
    date: header('Date'),
    eco: header('ECO'),
  );
}

/// Vertical ladder rendering of a [ChessGame] tree with arbitrary-depth
/// expand/collapse — the same mental model the mobile token-builder uses
/// (`shouldCollapseByDefault` + `_collapsedVariationIds` /
/// `_expandedVariationIds`), adapted to the desktop's indented layout.
///
/// Click any move chip ⇒ [onJump] receives that pointer.
/// Click a variation chevron ⇒ that variation toggles between expanded
/// and a one-line `… N moves` placeholder. Variations on the path to the
/// active pointer are always force-expanded so the cursor can never hide
/// inside a collapsed branch.
class NotationLadderView extends StatefulWidget {
  const NotationLadderView({
    super.key,
    required this.game,
    required this.activePointer,
    required this.onJump,
    this.lichessAnnotations = const <int, LichessMoveAnnotation>{},
    this.userNags = const <int, List<int>>{},
    this.onSetUserQualityNag,
    this.onToggleUserNag,
    this.onClearUserNags,
    this.onToggleMoveNag,
    this.onClearMoveNags,
    this.onSetMoveComment,
    this.onPromoteVariation,
    this.onDeleteVariation,
    this.onTrimContinuation,
    this.autoCollapseDepth = 1 << 30,
    this.autoCollapseMoveThreshold = 1 << 30,
    this.scrollController,
    this.useFigurine = false,
    this.pieceAssets,
    this.layoutModeController,
    this.visibleMoveOrderController,
    this.variationCollapseController,
    this.showHeader = true,
  });

  /// Optional external controller for the ladder/inline toggle. When
  /// supplied, the view's mode follows the notifier and any internal
  /// toggle (header switch) writes back to it. Lets the host wire a
  /// keyboard shortcut (`Tab`) without the host having to mirror layout
  /// state itself.
  final ValueNotifier<NotationLayoutMode>? layoutModeController;
  final NotationVariationCollapseController? variationCollapseController;

  /// Whether to show the notation header chrome (title, collapse/expand, help).
  /// Compact previews can hide it while keeping the same move rendering.
  final bool showHeader;

  /// Optional sink for the exact visible move-token traversal order rendered
  /// by this widget after expand/collapse state is applied. Board-level
  /// Arrow Up/Down navigation reads this so keyboard highlight movement
  /// matches the user's current notation view.
  final ValueNotifier<List<ChessMovePointer>>? visibleMoveOrderController;

  /// Optional externally-owned scroll controller. When provided, callers
  /// can drive notation scrolling from outside (e.g. the PageUp/PageDown
  /// keyboard shortcut wired on the board pane). When null, the widget
  /// creates and disposes its own controller.
  final ScrollController? scrollController;

  final ChessGame game;
  final ChessMovePointer activePointer;
  final ValueChanged<ChessMovePointer> onJump;

  /// Lichess analysis annotations keyed by zero-based mainline half-move
  /// index (`0` == move #1 white, `1` == move #1 black, ...). Only consulted
  /// for moves on the original mainline path; variation moves never have
  /// entries here.
  final Map<int, LichessMoveAnnotation> lichessAnnotations;

  /// User-applied NAGs (`!`/`?`/...) keyed by the same zero-based mainline
  /// half-move index. Same scope as [lichessAnnotations] — mainline only.
  /// Sideline NAGs are stored directly on the selected [ChessMove].
  final Map<int, List<int>> userNags;

  /// Set or clear the user's quality NAG for a mainline half-move index.
  /// Hooked to the right-click menu on a mainline chip; null hides those
  /// entries.
  final void Function(int ply, int? nag)? onSetUserQualityNag;

  /// Toggle any supported NAG for a mainline half-move. Used by the desktop
  /// annotation toolbar; one active user glyph per NAG category is enforced
  /// by the caller's state layer.
  final void Function(int ply, int nag)? onToggleUserNag;

  /// Clear every user-applied NAG for a mainline half-move.
  final void Function(int ply)? onClearUserNags;

  /// Toggle/clear a NAG on any selected move pointer. Used for sidelines,
  /// where the symbol should live on that variation move, not on the
  /// zero-based mainline NAG overlay.
  final void Function(ChessMovePointer pointer, int nag)? onToggleMoveNag;
  final void Function(ChessMovePointer pointer)? onClearMoveNags;

  /// Set or clear a comment attached to a move pointer. Passing null or an
  /// empty string clears the rendered comment block.
  final void Function(ChessMovePointer pointer, String? comment)?
  onSetMoveComment;

  /// Promote a variation to the mainline. Pointer is the head move of
  /// the variation (depth ≥ 3, i.e. `[…, varIdx, 0]`).
  final void Function(ChessMovePointer variationHeadPointer)?
  onPromoteVariation;

  /// Delete a variation outright. Same pointer shape as promote.
  final void Function(ChessMovePointer variationHeadPointer)? onDeleteVariation;

  /// Trim everything after [pointer] in the current line.
  final void Function(ChessMovePointer pointer)? onTrimContinuation;

  /// Variations are unfolded by default on desktop; callers may pass finite
  /// thresholds to opt back into mobile-style auto-collapse.
  final int autoCollapseDepth;
  final int autoCollapseMoveThreshold;

  /// Render K/Q/R/B/N as piece-set figurines when enabled in board settings.
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  @override
  State<NotationLadderView> createState() => _NotationLadderViewState();
}

class _NotationLadderViewState extends State<NotationLadderView> {
  ScrollController? _ownedScroll;
  ScrollController get _scroll =>
      widget.scrollController ?? (_ownedScroll ??= ScrollController());

  // Manual collapse/expand state, keyed by NotationPointer.encode of the
  // variation's head pointer (`[…, varIdx, 0]`). We track them as two
  // separate sets so we can apply the right resolution rule against the
  // per-variation auto-collapse default (see `_resolveCollapsed`).
  final Set<String> _collapsed = <String>{};
  final Set<String> _expanded = <String>{};

  // Active row key — re-allocated whenever the active pointer changes so
  // `Scrollable.ensureVisible` always finds a fresh widget to scroll to.
  GlobalKey _activeKey = GlobalKey();

  // Root of the rendered inline notation paragraph. Inline Arrow Up/Down must
  // follow Flutter's actual wrapped rows, so after layout we walk this subtree
  // and publish an active-relative row order from each `_InlineMove` box.
  final GlobalKey _inlineNotationKey = GlobalKey();

  // Reset manual collapse state when the underlying tree changes shape
  // (PGN reloaded, mainline length grew, etc.). We can't use ChessGame
  // identity because callers may rebuild the same logical game.
  String? _lastTreeSignature;
  NotationLayoutMode _layoutMode = NotationLayoutMode.ladder;

  @override
  void initState() {
    super.initState();
    final controller = widget.layoutModeController;
    if (controller != null) {
      _layoutMode = controller.value;
      controller.addListener(_onLayoutControllerChanged);
    }
    widget.variationCollapseController?._attach(
      owner: this,
      collapseAll: _collapseAllVariations,
      expandAll: _expandAllVariations,
    );
  }

  @override
  void didUpdateWidget(covariant NotationLadderView old) {
    super.didUpdateWidget(old);
    if (!identical(old.layoutModeController, widget.layoutModeController)) {
      old.layoutModeController?.removeListener(_onLayoutControllerChanged);
      final next = widget.layoutModeController;
      if (next != null) {
        _layoutMode = next.value;
        next.addListener(_onLayoutControllerChanged);
      }
    }
    if (!identical(
      old.variationCollapseController,
      widget.variationCollapseController,
    )) {
      old.variationCollapseController?._detach(this);
      widget.variationCollapseController?._attach(
        owner: this,
        collapseAll: _collapseAllVariations,
        expandAll: _expandAllVariations,
      );
    }
    if (!_pointersEqual(old.activePointer, widget.activePointer)) {
      _activeKey = GlobalKey();
      _scrollActiveIntoView();
    }
  }

  @override
  void dispose() {
    widget.layoutModeController?.removeListener(_onLayoutControllerChanged);
    widget.variationCollapseController?._detach(this);
    _ownedScroll?.dispose();
    super.dispose();
  }

  void _onLayoutControllerChanged() {
    final controller = widget.layoutModeController;
    if (controller == null) return;
    if (controller.value == _layoutMode) return;
    setState(() {
      _layoutMode = controller.value;
      _activeKey = GlobalKey();
    });
    _scrollActiveIntoView();
  }

  void _toggleCollapsed(String id, bool defaultCollapsed) {
    setState(() {
      if (defaultCollapsed) {
        // Default state is collapsed → toggle "manually expanded".
        if (_expanded.remove(id)) {
          // was expanded → collapse (back to default)
        } else {
          _expanded.add(id);
          _collapsed.remove(id);
        }
      } else {
        // Default state is expanded → toggle "manually collapsed".
        if (_collapsed.remove(id)) {
          // was collapsed → expand (back to default)
        } else {
          _collapsed.add(id);
          _expanded.remove(id);
        }
      }
    });
  }

  void _collapseAllVariations() {
    setState(() {
      _expanded.clear();
      _collapsed.clear();
      _collapsed.addAll(_allCollapsibleVariationIds(widget.game.mainline));
    });
  }

  void _expandAllVariations() {
    setState(() {
      _collapsed.clear();
      _expanded.clear();
      _expanded.addAll(_allCollapsibleVariationIds(widget.game.mainline));
    });
  }

  bool get _hasCollapsibleVariations =>
      _allCollapsibleVariationIds(widget.game.mainline).isNotEmpty;

  bool get _allVariationsManuallyCollapsed {
    final ids = _allCollapsibleVariationIds(widget.game.mainline);
    return ids.isNotEmpty && ids.every(_collapsed.contains);
  }

  Future<void> _copyPgnToClipboard() async {
    await Clipboard.setData(ClipboardData(text: exportGameToPgn(widget.game)));
  }

  void _toggleAllVariationsFromMenu() {
    if (_allVariationsManuallyCollapsed) {
      _expandAllVariations();
    } else {
      _collapseAllVariations();
    }
  }

  void _scrollActiveIntoView() {
    if (widget.activePointer.isEmpty) {
      _scrollToTop();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final minExtent = _scroll.position.minScrollExtent;
      if ((_scroll.offset - minExtent).abs() < 0.5) return;
      _scroll.animateTo(
        minExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _publishVisibleMoveOrder(List<ChessMovePointer> order) {
    final controller = widget.visibleMoveOrderController;
    if (controller == null) return;
    if (notationPointerListsEqual(controller.value, order)) return;
    controller.value = order;
  }

  void _scheduleRenderedInlineMoveOrderPublish(
    List<ChessMovePointer> fallbackOrder,
  ) {
    final controller = widget.visibleMoveOrderController;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layoutMode != NotationLayoutMode.inline) return;
      final rootContext = _inlineNotationKey.currentContext;
      if (rootContext == null) {
        _publishVisibleMoveOrder(fallbackOrder);
        return;
      }
      final rootBox = rootContext.findRenderObject();
      if (rootBox is! RenderBox || !rootBox.hasSize) {
        _publishVisibleMoveOrder(fallbackOrder);
        return;
      }

      final positions = <RenderedNotationMovePosition>[];
      void visit(Element element) {
        final elementWidget = element.widget;
        if (elementWidget is _InlineMove) {
          final box = element.renderObject;
          if (box is RenderBox && box.hasSize) {
            final topLeft = box.localToGlobal(Offset.zero, ancestor: rootBox);
            final center = topLeft + box.size.center(Offset.zero);
            positions.add(
              RenderedNotationMovePosition(
                pointer: elementWidget.pointer,
                centerX: center.dx,
                centerY: center.dy,
              ),
            );
          }
        }
        element.visitChildElements(visit);
      }

      rootContext.visitChildElements(visit);
      final renderedOrder = renderedNotationVerticalMoveOrder(
        positions: positions,
        activePointer: widget.activePointer,
      );
      _publishVisibleMoveOrder(
        renderedOrder.isEmpty ? fallbackOrder : renderedOrder,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final mainline = widget.game.mainline;
    final startingPly = _startingPlyFromFen(widget.game.startingFen);
    final gameResult = _formatGameResult(
      widget.game.metadata['Result'] as String?,
    );

    // Drop manual collapse state when the tree shape changes.
    final signature = _treeSignature(mainline);
    if (signature != _lastTreeSignature) {
      _lastTreeSignature = signature;
      _collapsed.clear();
      _expanded.clear();
    }

    // Variations whose head-pointer-id is on the active pointer's path
    // are always force-expanded so the user's cursor cannot hide inside
    // a collapsed branch. Computed each build from the current tree.
    final forcedOpenIds = _ancestorVariationIds(widget.activePointer);
    final activeMove = _moveAtPointer(mainline, widget.activePointer);
    final visibleMoveOrder = visibleNotationMoveOrder(
      game: widget.game,
      activePointer: widget.activePointer,
      forcedOpenIds: forcedOpenIds,
      collapsedIds: _collapsed,
      expandedIds: _expanded,
      autoCollapseDepth: widget.autoCollapseDepth,
      autoCollapseMoveThreshold: widget.autoCollapseMoveThreshold,
    );
    if (_layoutMode == NotationLayoutMode.inline) {
      _scheduleRenderedInlineMoveOrderPublish(visibleMoveOrder);
    } else {
      _publishVisibleMoveOrder(visibleMoveOrder);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true):
            _collapseAllVariations,
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
            _collapseAllVariations,
        const SingleActivator(LogicalKeyboardKey.bracketRight, control: true):
            _expandAllVariations,
        const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
            _expandAllVariations,
      },
      child: Container(
        color: kBlack2Color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader)
              _Header(
                metadata: notationHeaderMetadataFromPgn(widget.game.metadata),
              ),
            Expanded(
              child:
                  mainline.isEmpty
                      ? const _EmptyLadderHint()
                      : _layoutMode == NotationLayoutMode.inline
                      ? SingleChildScrollView(
                        controller: _scroll,
                        physics: const DesktopScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            KeyedSubtree(
                              key: _inlineNotationKey,
                              child: _InlineNotationBlock(
                                line: mainline,
                                pointerPrefix: const <int>[],
                                depth: 0,
                                isMainlineRoot: true,
                                startPly: startingPly,
                                activePointer: widget.activePointer,
                                activeKey: _activeKey,
                                onJump: widget.onJump,
                                lichessAnnotations: widget.lichessAnnotations,
                                userNags: widget.userNags,
                                onSetUserQualityNag: widget.onSetUserQualityNag,
                                onToggleUserNag: widget.onToggleUserNag,
                                onToggleMoveNag: widget.onToggleMoveNag,
                                onSetMoveComment: widget.onSetMoveComment,
                                onPromoteVariation: widget.onPromoteVariation,
                                onDeleteVariation: widget.onDeleteVariation,
                                onTrimContinuation: widget.onTrimContinuation,
                                forcedOpenIds: forcedOpenIds,
                                collapsedIds: _collapsed,
                                expandedIds: _expanded,
                                onToggleCollapsed: _toggleCollapsed,
                                autoCollapseDepth: widget.autoCollapseDepth,
                                autoCollapseMoveThreshold:
                                    widget.autoCollapseMoveThreshold,
                                useFigurine: widget.useFigurine,
                                pieceAssets: widget.pieceAssets,
                              ),
                            ),
                            if (gameResult != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: _GameResultRow(result: gameResult),
                              ),
                          ],
                        ),
                      )
                      : SingleChildScrollView(
                        controller: _scroll,
                        physics: const DesktopScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: _LineBlock(
                          line: mainline,
                          pointerPrefix: const <int>[],
                          depth: 0,
                          isMainlineRoot: true,
                          startPly: startingPly,
                          activePointer: widget.activePointer,
                          activeKey: _activeKey,
                          onJump: widget.onJump,
                          lichessAnnotations: widget.lichessAnnotations,
                          userNags: widget.userNags,
                          onSetUserQualityNag: widget.onSetUserQualityNag,
                          onToggleUserNag: widget.onToggleUserNag,
                          onToggleMoveNag: widget.onToggleMoveNag,
                          onSetMoveComment: widget.onSetMoveComment,
                          onPromoteVariation: widget.onPromoteVariation,
                          onDeleteVariation: widget.onDeleteVariation,
                          onTrimContinuation: widget.onTrimContinuation,
                          forcedOpenIds: forcedOpenIds,
                          collapsedIds: _collapsed,
                          expandedIds: _expanded,
                          onToggleCollapsed: _toggleCollapsed,
                          autoCollapseDepth: widget.autoCollapseDepth,
                          autoCollapseMoveThreshold:
                              widget.autoCollapseMoveThreshold,
                          useFigurine: widget.useFigurine,
                          pieceAssets: widget.pieceAssets,
                          gameResult: gameResult,
                        ),
                      ),
            ),
            if (widget.onToggleUserNag != null ||
                widget.onToggleMoveNag != null ||
                widget.onSetMoveComment != null)
              _NotationAnnotationToolbar(
                activePointer: widget.activePointer,
                activeMove: activeMove,
                fallbackMainlinePly:
                    mainline.isEmpty ? null : mainline.length - 1,
                userNags: widget.userNags,
                onToggleUserNag: widget.onToggleUserNag,
                onClearUserNags: widget.onClearUserNags,
                onToggleMoveNag: widget.onToggleMoveNag,
                onClearMoveNags: widget.onClearMoveNags,
                onSetMoveComment: widget.onSetMoveComment,
                onPromoteVariation: widget.onPromoteVariation,
                onDeleteVariation: widget.onDeleteVariation,
                onTrimContinuation: widget.onTrimContinuation,
              ),
          ],
        ),
      ),
    );
  }
}

class _NotationAnnotationToolbar extends StatelessWidget {
  const _NotationAnnotationToolbar({
    required this.activePointer,
    required this.activeMove,
    required this.fallbackMainlinePly,
    required this.userNags,
    required this.onToggleUserNag,
    required this.onClearUserNags,
    required this.onToggleMoveNag,
    required this.onClearMoveNags,
    required this.onSetMoveComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
  });

  static const List<int> _qualityNags = [3, 1, 5, 6, 2, 4, 7];
  static const List<int> _evaluationNags = [
    18,
    16,
    14,
    10,
    13,
    44,
    15,
    17,
    19,
    132,
  ];
  static const List<int> _observationNags = [146, 140, 36, 40, 32, 138, 22];

  final ChessMovePointer activePointer;
  final ChessMove? activeMove;
  final int? fallbackMainlinePly;
  final Map<int, List<int>> userNags;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(int ply)? onClearUserNags;
  final void Function(ChessMovePointer pointer, int nag)? onToggleMoveNag;
  final void Function(ChessMovePointer pointer)? onClearMoveNags;
  final void Function(ChessMovePointer pointer, String? comment)?
  onSetMoveComment;
  final void Function(ChessMovePointer variationHeadPointer)?
  onPromoteVariation;
  final void Function(ChessMovePointer variationHeadPointer)? onDeleteVariation;
  final void Function(ChessMovePointer pointer)? onTrimContinuation;

  int? get _targetMainlinePly {
    if (activePointer.length == 1 && activeMove != null) {
      return activePointer.last;
    }
    // A fresh Board tab can have moves in notation while the cursor is still
    // at the root. In that common "open board → make moves" flow, make the
    // toolbar annotate the latest mainline move instead of looking inert.
    if (activePointer.isEmpty) return fallbackMainlinePly;
    return null;
  }

  bool get _isMainlineTarget => _targetMainlinePly != null;

  bool get _canAnnotateMove {
    if (_isMainlineTarget) return onToggleUserNag != null;
    return activePointer.isNotEmpty &&
        activeMove != null &&
        onToggleMoveNag != null;
  }

  bool get _canClearMoveNags {
    if (_isMainlineTarget) return onClearUserNags != null;
    return activePointer.isNotEmpty &&
        activeMove != null &&
        onClearMoveNags != null;
  }

  bool get _canComment =>
      activePointer.isNotEmpty &&
      activeMove != null &&
      onSetMoveComment != null;

  bool get _canTrimContinuation =>
      activePointer.isNotEmpty &&
      activeMove != null &&
      onTrimContinuation != null;

  Set<int> get _activeNagSet {
    final ply = _targetMainlinePly;
    if (ply != null) return (userNags[ply] ?? const <int>[]).toSet();
    return (activeMove?.nags ?? const <int>[]).toSet();
  }

  void _toggleNag(int nag) {
    final ply = _targetMainlinePly;
    if (ply != null) {
      onToggleUserNag?.call(ply, nag);
      return;
    }
    if (activePointer.isNotEmpty) onToggleMoveNag?.call(activePointer, nag);
  }

  void _clearNags() {
    final ply = _targetMainlinePly;
    if (ply != null) {
      onClearUserNags?.call(ply);
      return;
    }
    if (activePointer.isNotEmpty) onClearMoveNags?.call(activePointer);
  }

  Future<void> _editComment(BuildContext context) async {
    if (!_canComment || activeMove == null) return;
    final next = await showMoveCommentEditor(
      context,
      initialComment: _firstPgnComment(activeMove!.comments) ?? '',
    );
    if (!context.mounted || next == null) return;
    final comment = next.trim();
    onSetMoveComment!(activePointer, comment.isEmpty ? null : comment);
  }

  @override
  Widget build(BuildContext context) {
    final activeSet = _activeNagSet;
    final hasUserNags = activeSet.isNotEmpty;
    final commentActive =
        (_firstPgnComment(activeMove?.comments) ?? '').trim().isNotEmpty;
    final variationHead = _activeVariationHead(activePointer);
    final canPromoteVariation =
        variationHead != null && onPromoteVariation != null;
    final canDeleteVariation =
        variationHead != null && onDeleteVariation != null;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        height: 48,
        decoration: const BoxDecoration(
          color: kBlack2Color,
          border: Border(top: BorderSide(color: kDividerColor)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              _ToolbarIconButton(
                icon: Icons.arrow_upward_rounded,
                tooltip:
                    canPromoteVariation
                        ? 'Promote variation'
                        : 'Select a variation move to promote',
                active: false,
                foreground: kGreenColor2,
                onPress:
                    canPromoteVariation
                        ? () => onPromoteVariation!(variationHead)
                        : null,
              ),
              const SizedBox(width: 6),
              _ToolbarIconButton(
                icon: Icons.close_rounded,
                tooltip:
                    canDeleteVariation
                        ? 'Delete variation'
                        : 'Select a variation move to delete',
                active: false,
                foreground: kRedColor,
                onPress:
                    canDeleteVariation
                        ? () => onDeleteVariation!(variationHead)
                        : null,
              ),
              const SizedBox(width: 6),
              _ToolbarGlyphButton(
                label: ']',
                tooltip:
                    _canTrimContinuation
                        ? 'Trim continuation after this move'
                        : 'Select a move to trim the continuation',
                active: false,
                onPress:
                    _canTrimContinuation
                        ? () => onTrimContinuation!(activePointer)
                        : null,
              ),
              const SizedBox(width: 6),
              _ToolbarIconButton(
                icon: Icons.add_comment_outlined,
                tooltip: commentActive ? 'Edit comment' : 'Add comment',
                active: commentActive,
                onPress: _canComment ? () => _editComment(context) : null,
              ),

              const _ToolbarDivider(),
              for (final nag in _qualityNags) ...[
                _NagToolbarButton(
                  nag: nag,
                  active: activeSet.contains(nag),
                  enabled: _canAnnotateMove,
                  onPress: () => _toggleNag(nag),
                ),
                const SizedBox(width: 3),
              ],
              const _ToolbarDivider(),
              for (final nag in _evaluationNags) ...[
                _NagToolbarButton(
                  nag: nag,
                  active: activeSet.contains(nag),
                  enabled: _canAnnotateMove,
                  onPress: () => _toggleNag(nag),
                ),
                const SizedBox(width: 3),
              ],
              const SizedBox(width: 3),
              _ToolbarIconButton(
                icon: Icons.clear_rounded,
                tooltip:
                    hasUserNags ? 'Clear move NAGs' : 'No user NAGs to clear',
                active: false,
                onPress: _canClearMoveNags && hasUserNags ? _clearNags : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPress,
    this.foreground,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onPress;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: tooltip,
      child: FButton.icon(
        style: desktopDialogIconButtonStyle(
          tone:
              active
                  ? DesktopDialogButtonTone.primary
                  : DesktopDialogButtonTone.ghost,
          padding: const EdgeInsets.all(7),
          radius: 6,
        ),
        onPress: onPress,
        child: Icon(icon, size: 15, color: foreground),
      ),
    );
  }
}

class _ToolbarGlyphButton extends StatelessWidget {
  const _ToolbarGlyphButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onPress,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: tooltip,
      child: FButton(
        style: desktopDialogButtonStyle(
          tone:
              active
                  ? DesktopDialogButtonTone.primary
                  : DesktopDialogButtonTone.ghost,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          radius: 6,
        ),
        onPress: onPress,
        child: Text(
          label,
          style: TextStyle(
            color:
                onPress == null
                    ? kWhiteColor.withValues(alpha: 0.28)
                    : kWhiteColor70,
            fontSize: 15,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _NagToolbarButton extends StatelessWidget {
  const _NagToolbarButton({
    required this.nag,
    required this.active,
    required this.enabled,
    required this.onPress,
  });

  final int nag;
  final bool active;
  final bool enabled;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final display = getNagDisplay(nag);
    if (display == null) return const SizedBox.shrink();
    final symbol = display.symbol;
    final foreground =
        enabled
            ? (active ? kWhiteColor : display.color.withValues(alpha: 0.96))
            : kWhiteColor.withValues(alpha: 0.28);
    final button = FButton(
      style: desktopDialogButtonStyle(
        tone:
            active
                ? DesktopDialogButtonTone.primary
                : DesktopDialogButtonTone.ghost,
        padding: EdgeInsets.symmetric(
          horizontal: symbol.length > 1 ? 8 : 10,
          vertical: 7,
        ),
        radius: 6,
      ),
      onPress: enabled ? onPress : null,
      child: Text(
        symbol,
        style: TextStyle(
          color: foreground,
          fontSize: symbol.length > 1 ? 12 : 14,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
    return DesktopTooltip(
      message:
          enabled ? _nagTooltip(nag, display) : 'Select a move to annotate',
      child: button,
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: kDividerColor,
    );
  }
}

String _nagTooltip(int nag, NagDisplay display) {
  final name = _nagMenuLabel(nag, display);
  return '$name (${display.symbol})';
}

String _nagMenuLabel(int nag, NagDisplay display) {
  return switch (nag) {
    1 => 'Good move',
    2 => 'Mistake',
    3 => 'Brilliant',
    4 => 'Blunder',
    5 => 'Interesting',
    6 => 'Dubious',
    7 => 'Only move',
    10 => 'Equal',
    13 => 'Unclear',
    14 => 'White slight advantage',
    15 => 'Black slight advantage',
    16 => 'White advantage',
    17 => 'Black advantage',
    18 => 'White winning',
    19 => 'Black winning',
    22 => 'Zugzwang',
    44 => 'Compensation',
    32 => 'Initiative',
    36 => 'Attack',
    40 => 'With idea',
    132 => 'Counterplay',
    138 => 'Time trouble',
    140 => 'Novelty',
    146 => 'Editorial mark',
    _ => display.symbol,
  };
}

/// Renders one [ChessLine] (mainline OR a variation), indenting every
/// nested sub-variation it contains. Variations come with a header
/// (chevron + summary) so the user can collapse / expand them.
class _LineBlock extends StatelessWidget {
  const _LineBlock({
    required this.line,
    required this.pointerPrefix,
    required this.depth,
    required this.isMainlineRoot,
    required this.startPly,
    required this.activePointer,
    required this.activeKey,
    required this.onJump,
    required this.lichessAnnotations,
    required this.userNags,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onToggleMoveNag,
    required this.onSetMoveComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
    required this.forcedOpenIds,
    required this.collapsedIds,
    required this.expandedIds,
    required this.onToggleCollapsed,
    required this.autoCollapseDepth,
    required this.autoCollapseMoveThreshold,
    required this.useFigurine,
    required this.pieceAssets,
    this.gameResult,
  });

  /// Decisive game result text (e.g., `1–0`). Rendered only at the bottom
  /// of the mainline; nested `_LineBlock`s leave this null.
  final String? gameResult;

  final ChessLine line;
  final ChessMovePointer pointerPrefix;
  final int depth;
  final bool isMainlineRoot;
  final int startPly;
  final ChessMovePointer activePointer;
  final GlobalKey activeKey;
  final ValueChanged<ChessMovePointer> onJump;
  final Map<int, LichessMoveAnnotation> lichessAnnotations;
  final Map<int, List<int>> userNags;
  final void Function(int ply, int? nag)? onSetUserQualityNag;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(ChessMovePointer pointer, int nag)? onToggleMoveNag;
  final void Function(ChessMovePointer pointer, String? comment)?
  onSetMoveComment;
  final void Function(ChessMovePointer)? onPromoteVariation;
  final void Function(ChessMovePointer)? onDeleteVariation;
  final void Function(ChessMovePointer)? onTrimContinuation;

  /// Variation IDs whose subtrees contain the active pointer. These get
  /// force-expanded regardless of manual / default state.
  final Set<String> forcedOpenIds;
  final Set<String> collapsedIds;
  final Set<String> expandedIds;
  final void Function(String id, bool defaultCollapsed) onToggleCollapsed;
  final int autoCollapseDepth;
  final int autoCollapseMoveThreshold;
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    var i = 0;
    var ply = startPly;
    while (i < line.length) {
      final isWhiteFirst = ply.isEven;

      ChessMove? whiteMove;
      ChessMovePointer? whitePointer;
      ChessMove? blackMove;
      ChessMovePointer? blackPointer;
      bool showLeadingEllipsis = false;

      if (isWhiteFirst) {
        whiteMove = line[i];
        whitePointer = [...pointerPrefix, i];
        if (i + 1 < line.length) {
          blackMove = line[i + 1];
          blackPointer = [...pointerPrefix, i + 1];
        }
      } else {
        // Variation begins on a black half-move (e.g. 1...c5 alt to 1...e5).
        showLeadingEllipsis = true;
        blackMove = line[i];
        blackPointer = [...pointerPrefix, i];
      }

      final moveNumber = (ply ~/ 2) + 1;
      final pairChildren = <Widget>[];
      final whiteIsActive =
          whitePointer != null && _pointersEqual(whitePointer, activePointer);
      final blackIsActive =
          blackPointer != null && _pointersEqual(blackPointer, activePointer);

      pairChildren.add(
        _PairRow(
          moveNumber: moveNumber,
          showLeadingEllipsis: showLeadingEllipsis,
          depth: depth,
          whiteMove: whiteMove,
          whitePointer: whitePointer,
          blackMove: blackMove,
          blackPointer: blackPointer,
          whiteIsActive: whiteIsActive,
          blackIsActive: blackIsActive,
          activeKey: (whiteIsActive || blackIsActive) ? activeKey : null,
          onJump: onJump,
          whiteNags:
              (depth == 0 && isMainlineRoot && whitePointer != null)
                  ? _mergedMainlineNagsFor(
                    ply: whitePointer.last,
                    baseNags: whiteMove?.nags ?? const [],
                    lichessAnnotations: lichessAnnotations,
                    userNags: userNags,
                  )
                  : (whiteMove?.nags ?? const <int>[]),
          whiteAnnotation:
              (depth == 0 && isMainlineRoot && whitePointer != null)
                  ? lichessAnnotations[whitePointer.last]
                  : null,
          whiteUserHasQuality:
              depth == 0 &&
              isMainlineRoot &&
              whitePointer != null &&
              (userNags[whitePointer.last] ?? const <int>[]).any(
                (n) => n >= 1 && n <= 7,
              ),
          blackNags:
              (depth == 0 && isMainlineRoot && blackPointer != null)
                  ? _mergedMainlineNagsFor(
                    ply: blackPointer.last,
                    baseNags: blackMove?.nags ?? const [],
                    lichessAnnotations: lichessAnnotations,
                    userNags: userNags,
                  )
                  : (blackMove?.nags ?? const <int>[]),
          blackAnnotation:
              (depth == 0 && isMainlineRoot && blackPointer != null)
                  ? lichessAnnotations[blackPointer.last]
                  : null,
          blackUserHasQuality:
              depth == 0 &&
              isMainlineRoot &&
              blackPointer != null &&
              (userNags[blackPointer.last] ?? const <int>[]).any(
                (n) => n >= 1 && n <= 7,
              ),
          onSetUserQualityNag:
              (depth == 0 && isMainlineRoot) ? onSetUserQualityNag : null,
          onToggleUserNag:
              (depth == 0 && isMainlineRoot) ? onToggleUserNag : null,
          onSetWhiteComment:
              (whitePointer != null && onSetMoveComment != null)
                  ? (comment) => onSetMoveComment!(whitePointer!, comment)
                  : null,
          onSetBlackComment:
              (blackPointer != null && onSetMoveComment != null)
                  ? (comment) => onSetMoveComment!(blackPointer!, comment)
                  : null,
          onPromoteVariation: depth > 0 ? onPromoteVariation : null,
          onDeleteVariation: depth > 0 ? onDeleteVariation : null,
          onTrimContinuation: onTrimContinuation,
          // Variation pointer for promote/delete: the head of the
          // *containing* variation. `pointerPrefix` for a variation block
          // is `[…, varIdx]`; appending `0` reaches the head move.
          variationHeadPointer: depth > 0 ? <int>[...pointerPrefix, 0] : null,
          useFigurine: useFigurine,
          pieceAssets: pieceAssets,
        ),
      );

      void appendMoveComments(ChessMove? move) {
        if (move == null) return;
        final sourceLabel = _sourceLabelFromComments(move.comments);
        if (sourceLabel != null) {
          pairChildren.add(
            _MoveSourceMetadata(depth: depth, sourceLabel: sourceLabel),
          );
        }
        final comments = _cleanPgnComments(move.comments);
        if (comments.isEmpty) return;
        pairChildren.add(_MoveComments(depth: depth, comments: comments));
      }

      appendMoveComments(whiteMove);
      appendMoveComments(blackMove);

      // Render variations attached to white move first, then to black. The
      // first move's colour decides whether the branch replaces this move
      // or continues after it; both shapes appear in imported/user analysis.
      void appendVariations(
        ChessMove move,
        ChessMovePointer movePointer,
        int movePly,
      ) {
        final vars = move.variations;
        if (vars == null || vars.isEmpty) return;
        for (var v = 0; v < vars.length; v++) {
          final variationLine = vars[v];
          final variationPrefix = [...movePointer, v];
          final variationHeadId = NotationPointer.encode(<int>[
            ...variationPrefix,
            0,
          ]);
          final defaultCollapsed = _shouldCollapseByDefault(
            depth: depth + 1,
            moveCount: variationLine.length,
          );
          final forcedOpen = forcedOpenIds.contains(variationHeadId);
          final manuallyCollapsed = collapsedIds.contains(variationHeadId);
          final manuallyExpanded = expandedIds.contains(variationHeadId);
          final collapsed =
              forcedOpen
                  ? false
                  : (defaultCollapsed ? !manuallyExpanded : manuallyCollapsed);

          // Ladder variations render Lichess-style: indented inline run
          // under the parent pair row, no heavy box / chevron / branch
          // label — just a tiny `[+]/[−]` toggle, dimmer color, depth indent.
          pairChildren.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 1),
              child: _InlineVariationBlock(
                variationLine: variationLine,
                pointerPrefix: variationPrefix,
                depth: depth + 1,
                startPly: _variationStartPly(
                  parentMove: move,
                  parentPly: movePly,
                  variationLine: variationLine,
                ),
                branchLabel: _branchLabel(v),
                collapsed: collapsed,
                defaultCollapsed: defaultCollapsed,
                onToggle:
                    () => onToggleCollapsed(variationHeadId, defaultCollapsed),
                lichessStyle: true,
                activePointer: activePointer,
                activeKey: activeKey,
                onJump: onJump,
                lichessAnnotations: lichessAnnotations,
                userNags: userNags,
                onSetUserQualityNag: onSetUserQualityNag,
                onToggleUserNag: onToggleUserNag,
                onToggleMoveNag: onToggleMoveNag,
                onSetMoveComment: onSetMoveComment,
                onPromoteVariation: onPromoteVariation,
                onDeleteVariation: onDeleteVariation,
                onTrimContinuation: onTrimContinuation,
                forcedOpenIds: forcedOpenIds,
                collapsedIds: collapsedIds,
                expandedIds: expandedIds,
                onToggleCollapsed: onToggleCollapsed,
                autoCollapseDepth: autoCollapseDepth,
                autoCollapseMoveThreshold: autoCollapseMoveThreshold,
                useFigurine: useFigurine,
                pieceAssets: pieceAssets,
              ),
            ),
          );
        }
      }

      if (whiteMove != null && whitePointer != null) {
        appendVariations(whiteMove, whitePointer, ply);
      }
      if (blackMove != null && blackPointer != null) {
        appendVariations(blackMove, blackPointer, isWhiteFirst ? ply + 1 : ply);
      }

      children.addAll(pairChildren);

      if (isWhiteFirst) {
        i += blackMove != null ? 2 : 1;
        ply += blackMove != null ? 2 : 1;
      } else {
        i += 1;
        ply += 1;
      }
    }

    if (isMainlineRoot && depth == 0 && gameResult != null) {
      children.add(_GameResultRow(result: gameResult!));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  bool _shouldCollapseByDefault({required int depth, required int moveCount}) {
    if (depth >= autoCollapseDepth) return true;
    if (moveCount >= autoCollapseMoveThreshold) return true;
    return false;
  }
}

class _MoveComments extends StatelessWidget {
  const _MoveComments({required this.depth, required this.comments});

  final int depth;
  final List<String> comments;

  @override
  Widget build(BuildContext context) {
    final fg = depth == 0 ? kCommentaryGreen : kCommentaryGreenDim;
    return Padding(
      padding: EdgeInsets.fromLTRB(depth == 0 ? 56 : 28, 2, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final comment in comments)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                comment,
                style: TextStyle(
                  color: fg,
                  fontSize: 12.5,
                  height: 1.45,
                  fontStyle: FontStyle.italic,
                  letterSpacing: 0.05,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MoveSourceMetadata extends StatelessWidget {
  const _MoveSourceMetadata({required this.depth, required this.sourceLabel});

  final int depth;
  final String sourceLabel;

  @override
  Widget build(BuildContext context) {
    final meta = _tryParseGameSourceMetadata(sourceLabel);
    if (meta != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(depth == 0 ? 56 : 28, 6, 18, 6),
        child: _LadderGameSourceCard(metadata: meta, depth: depth),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(depth == 0 ? 56 : 28, 3, 18, 5),
      child: _SourceMetadataPill(sourceLabel: sourceLabel, depth: depth),
    );
  }
}

/// Ladder-mode game-source card. Designed as a quiet "this is where these
/// moves came from" panel under the last inserted move: result chip on
/// the left, two stacked player rows (title · name · Elo) on the right,
/// venue footer line below. The colour spine and corner radii match the
/// `kPopUpColor` cards used by the desktop chrome so it reads as part of
/// the surrounding notation pane rather than as a foreign tooltip.
class _LadderGameSourceCard extends StatelessWidget {
  const _LadderGameSourceCard({required this.metadata, required this.depth});

  final _GameSourceMetadata metadata;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final result = metadata.resultChip;
    final accent =
        depth == 0 ? _resultChipTint(result) : _depthBaseColor(depth);
    final venue = <String>[
      if (metadata.event != null) metadata.event!,
      if (metadata.site != null && metadata.site != metadata.event)
        metadata.site!,
      if (metadata.round != null) 'Round ${metadata.round}',
      if (metadata.year != null) metadata.year!,
    ];
    final pliesText = metadata.plies == null ? null : '${metadata.plies} ply';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Container(
        decoration: BoxDecoration(
          color: kPopUpColor.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor.withValues(alpha: 0.55)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left colour spine — same tint as the result badge so the card
              // looks decisive at a glance even before reading the text.
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (result != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 10, top: 2),
                              child: _ResultBadge(label: result, tint: accent),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _PlayerLine(
                                  swatch: const Color(0xFFF1F3F7),
                                  name: metadata.whiteName,
                                  elo: metadata.whiteElo,
                                  title: metadata.whiteTitle,
                                  federation: metadata.whiteFed,
                                ),
                                if (metadata.whiteName != null &&
                                    metadata.blackName != null)
                                  const SizedBox(height: 4),
                                _PlayerLine(
                                  swatch: const Color(0xFF3C4047),
                                  name: metadata.blackName,
                                  elo: metadata.blackElo,
                                  title: metadata.blackTitle,
                                  federation: metadata.blackFed,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (venue.isNotEmpty || pliesText != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          height: 1,
                          color: kDividerColor.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (venue.isNotEmpty)
                              Expanded(
                                child: _VenueRow(parts: venue, accent: accent),
                              )
                            else
                              const Spacer(),
                            if (pliesText != null) ...[
                              const SizedBox(width: 8),
                              _PliesPill(text: pliesText, accent: accent),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({
    required this.swatch,
    required this.name,
    required this.elo,
    required this.title,
    required this.federation,
  });

  final Color swatch;
  final String? name;
  final int? elo;
  final String? title;
  final String? federation;

  @override
  Widget build(BuildContext context) {
    if (name == null) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // King-square swatch — white for top row, near-black for bottom.
        // The contrast between the two side-by-side swatches says "this is
        // a head-to-head" without needing a "White / Black" label.
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: swatch,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: kDividerColor.withValues(alpha: 0.55),
              width: 0.8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (title != null && title!.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              title!,
              style: TextStyle(
                color: kPrimaryColor.withValues(alpha: 0.95),
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                height: 1.0,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            name!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              height: 1.15,
              letterSpacing: 0.05,
            ),
          ),
        ),
        if (federation != null && federation!.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            federation!,
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: 0.5,
            ),
          ),
        ],
        if (elo != null) ...[
          const SizedBox(width: 8),
          Text(
            '$elo',
            style: TextStyle(
              color: kWhiteColor70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _VenueRow extends StatelessWidget {
  const _VenueRow({required this.parts, required this.accent});

  final List<String> parts;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.event_outlined,
          size: 12,
          color: accent.withValues(alpha: 0.85),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kWhiteColor70,
              fontSize: 11.3,
              fontWeight: FontWeight.w600,
              height: 1.1,
              letterSpacing: 0.05,
            ),
          ),
        ),
      ],
    );
  }
}

class _PliesPill extends StatelessWidget {
  const _PliesPill({required this.text, required this.accent});

  final String text;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: kWhiteColor.withValues(alpha: 0.78),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.0,
          letterSpacing: 0.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Inline notation rendered reference-style: continuous horizontal flow
/// of moves inside a "run", broken into separate vertical blocks at every
/// variation. The mainline (depth 0) sits as the dominant top-level run;
/// each sub-variation becomes an indented, depth-tinted box with a [+]/[−]
/// collapse handle at its head — never a flat PGN blob.
class _InlineNotationBlock extends StatelessWidget {
  const _InlineNotationBlock({
    required this.line,
    required this.pointerPrefix,
    required this.depth,
    required this.isMainlineRoot,
    required this.startPly,
    required this.activePointer,
    required this.activeKey,
    required this.onJump,
    required this.lichessAnnotations,
    required this.userNags,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onToggleMoveNag,
    required this.onSetMoveComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
    required this.forcedOpenIds,
    required this.collapsedIds,
    required this.expandedIds,
    required this.onToggleCollapsed,
    required this.autoCollapseDepth,
    required this.autoCollapseMoveThreshold,
    required this.useFigurine,
    required this.pieceAssets,
    this.lichessStyle = false,
    this.closingBracketGlyph,
    this.closingBracketStyle,
  });

  final ChessLine line;
  final ChessMovePointer pointerPrefix;
  final int depth;
  final bool isMainlineRoot;
  final int startPly;
  final ChessMovePointer activePointer;
  final GlobalKey activeKey;
  final ValueChanged<ChessMovePointer> onJump;
  final Map<int, LichessMoveAnnotation> lichessAnnotations;
  final Map<int, List<int>> userNags;
  final void Function(int ply, int? nag)? onSetUserQualityNag;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(ChessMovePointer pointer, int nag)? onToggleMoveNag;
  final void Function(ChessMovePointer pointer, String? comment)?
  onSetMoveComment;
  final void Function(ChessMovePointer)? onPromoteVariation;
  final void Function(ChessMovePointer)? onDeleteVariation;
  final void Function(ChessMovePointer)? onTrimContinuation;
  final Set<String> forcedOpenIds;
  final Set<String> collapsedIds;
  final Set<String> expandedIds;
  final void Function(String id, bool defaultCollapsed) onToggleCollapsed;
  final int autoCollapseDepth;
  final int autoCollapseMoveThreshold;
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  /// When true, renders variations Lichess-style: no `[ ]`/`( )` bracket
  /// glyphs, no branch-letter chip, smaller `[+]/[−]` toggle, dimmer color.
  /// Used by the ladder layout so variations appear as indented inline
  /// runs under the parent pair row rather than as bracketed blocks.
  final bool lichessStyle;

  /// Optional bracket suffix supplied by `_InlineVariationBlock` so expanded
  /// reference-style variations close next to the last rendered move instead
  /// of reserving a standalone bracket-only row.
  final String? closingBracketGlyph;
  final TextStyle? closingBracketStyle;

  @override
  Widget build(BuildContext context) {
    // Single flowing paragraph: moves, comments, source labels, and
    // variations all share one `Text.rich`. Mainline reads as one stream
    // that Flutter wraps naturally on word boundaries; variation blocks
    // sit inline as `WidgetSpan`s carrying their own depth-tinted cluster
    // so the eye can bind every row inside a `[ ... ]` or `( ... )` to
    // the analyst's authored group without any forced extra line break
    // between mainline runs.
    final spans = <InlineSpan>[];

    final commentColor = depth == 0 ? kCommentaryGreen : kCommentaryGreenDim;
    final commentStyle = TextStyle(
      color: commentColor,
      fontSize: depth == 0 ? 12.5 : 11.5,
      fontStyle: FontStyle.italic,
      height: 1.32,
      letterSpacing: 0.05,
    );

    var ply = startPly;
    for (var i = 0; i < line.length; i++) {
      final move = line[i];
      final pointer = <int>[...pointerPrefix, i];
      final selected = _pointersEqual(pointer, activePointer);
      final isMainlineMove = depth == 0 && isMainlineRoot;
      final variationHeadPointer =
          depth > 0 ? <int>[...pointerPrefix, 0] : null;

      // Inside a variation, the first move is the "blue clickable link"
      // that database users scan for to locate the branch entry point.
      final isVariationHead = depth > 0 && i == 0;

      final separatesPreviousWhiteMove =
          i > 0 && ply.isOdd && (line[i - 1].variations?.isNotEmpty ?? false);
      final moveWidget = _InlineMove(
        prefix: _inlineMovePrefix(
          ply,
          isLineStart: i == 0,
          forceBlackMoveNumber: separatesPreviousWhiteMove,
        ),
        move: move,
        pointer: pointer,
        selected: selected,
        depth: depth,
        isVariationHead: isVariationHead,
        onJump: onJump,
        nags:
            isMainlineMove
                ? _mergedMainlineNagsFor(
                  ply: pointer.last,
                  baseNags: move.nags ?? const <int>[],
                  lichessAnnotations: lichessAnnotations,
                  userNags: userNags,
                )
                : (move.nags ?? const <int>[]),
        annotation: isMainlineMove ? lichessAnnotations[pointer.last] : null,
        userHasQualityNag:
            isMainlineMove &&
            (userNags[pointer.last] ?? const <int>[]).any(
              (n) => n >= 1 && n <= 7,
            ),
        onSetUserQualityNag: isMainlineMove ? onSetUserQualityNag : null,
        onToggleUserNag: isMainlineMove ? onToggleUserNag : null,
        onSetComment:
            onSetMoveComment == null
                ? null
                : (comment) => onSetMoveComment!(pointer, comment),
        onPromoteVariation: depth > 0 ? onPromoteVariation : null,
        onDeleteVariation: depth > 0 ? onDeleteVariation : null,
        onTrimContinuation: onTrimContinuation,
        variationHeadPointer: variationHeadPointer,
        useFigurine: useFigurine,
        pieceAssets: pieceAssets,
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          baseline: TextBaseline.alphabetic,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: KeyedSubtree(
              key: selected ? activeKey : null,
              child: moveWidget,
            ),
          ),
        ),
      );

      final sourceLabel = _sourceLabelFromComments(move.comments);
      if (sourceLabel != null) {
        // `_InlineSourceMetadata` renders either the richer reference-style
        // game footer banner (when the label parses as players+result+date)
        // or a typographic pill fallback (for short labels). Either way it
        // surfaces a standalone Text widget so `find.text(sourceLabel)`
        // still hits the source label the tests assert on.
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _InlineSourceMetadata(
                depth: depth,
                sourceLabel: sourceLabel,
              ),
            ),
          ),
        );
      }

      for (final comment in _cleanPgnComments(move.comments)) {
        // Bare text — flows with the move stream and breaks at word
        // boundaries when the column wraps, instead of forcing its own row.
        spans.add(TextSpan(text: '$comment ', style: commentStyle));
      }

      final vars = move.variations;
      if (vars != null && vars.isNotEmpty) {
        // Variations slot directly into the parent run as a WidgetSpan,
        // so Flutter can flow the closing-bracket cluster back into the
        // mainline without forcing a Column break either side. Each
        // variation widget owns its own depth-tinted background so the
        // analyst's group binding stays legible inside the continuous
        // paragraph.
        for (var v = 0; v < vars.length; v++) {
          final variationLine = vars[v];
          final variationPrefix = <int>[...pointer, v];
          final variationHeadId = NotationPointer.encode(<int>[
            ...variationPrefix,
            0,
          ]);
          final defaultCollapsed = _shouldCollapseByDefaultInline(
            depth: depth + 1,
            moveCount: variationLine.length,
            autoCollapseDepth: autoCollapseDepth,
            autoCollapseMoveThreshold: autoCollapseMoveThreshold,
          );
          final forcedOpen = forcedOpenIds.contains(variationHeadId);
          final manuallyCollapsed = collapsedIds.contains(variationHeadId);
          final manuallyExpanded = expandedIds.contains(variationHeadId);
          final collapsed =
              forcedOpen
                  ? false
                  : (defaultCollapsed ? !manuallyExpanded : manuallyCollapsed);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: _InlineVariationBlock(
                variationLine: variationLine,
                pointerPrefix: variationPrefix,
                depth: depth + 1,
                startPly: _variationStartPly(
                  parentMove: move,
                  parentPly: ply,
                  variationLine: variationLine,
                ),
                branchLabel: _branchLabel(v),
                collapsed: collapsed,
                defaultCollapsed: defaultCollapsed,
                onToggle:
                    () => onToggleCollapsed(variationHeadId, defaultCollapsed),
                activePointer: activePointer,
                activeKey: activeKey,
                onJump: onJump,
                lichessAnnotations: lichessAnnotations,
                userNags: userNags,
                onSetUserQualityNag: onSetUserQualityNag,
                onToggleUserNag: onToggleUserNag,
                onToggleMoveNag: onToggleMoveNag,
                onSetMoveComment: onSetMoveComment,
                onPromoteVariation: onPromoteVariation,
                onDeleteVariation: onDeleteVariation,
                onTrimContinuation: onTrimContinuation,
                forcedOpenIds: forcedOpenIds,
                collapsedIds: collapsedIds,
                expandedIds: expandedIds,
                onToggleCollapsed: onToggleCollapsed,
                autoCollapseDepth: autoCollapseDepth,
                autoCollapseMoveThreshold: autoCollapseMoveThreshold,
                useFigurine: useFigurine,
                pieceAssets: pieceAssets,
                lichessStyle: lichessStyle,
              ),
            ),
          );
        }
      }

      ply += 1;
    }

    final closeGlyph = closingBracketGlyph;
    final closeStyle = closingBracketStyle;
    if (closeGlyph != null && closeGlyph.isNotEmpty && closeStyle != null) {
      spans.add(TextSpan(text: '$closeGlyph ', style: closeStyle));
    }

    if (spans.isEmpty) return const SizedBox.shrink();
    return Text.rich(
      TextSpan(children: spans),
      // Comment TextSpans set their own color/italic; mainline chips bring
      // their own typography. Base style only matters when nothing overrides
      // it, which in practice means orphan whitespace.
      style: commentStyle,
    );
  }
}

/// One indented, depth-tinted variation block. Header carries the [+]/[−]
/// collapse handle, the branch letter (`A`, `B`, `C`...), and — when
/// collapsed — the first move SAN in cyan as a "blue clickable link" the
/// user can jump to directly. When expanded, body is a nested
/// `_InlineNotationBlock` flowing inside the box.
class _InlineVariationBlock extends StatelessWidget {
  const _InlineVariationBlock({
    required this.variationLine,
    required this.pointerPrefix,
    required this.depth,
    required this.startPly,
    required this.branchLabel,
    required this.collapsed,
    required this.defaultCollapsed,
    required this.onToggle,
    required this.activePointer,
    required this.activeKey,
    required this.onJump,
    required this.lichessAnnotations,
    required this.userNags,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onToggleMoveNag,
    required this.onSetMoveComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
    required this.forcedOpenIds,
    required this.collapsedIds,
    required this.expandedIds,
    required this.onToggleCollapsed,
    required this.autoCollapseDepth,
    required this.autoCollapseMoveThreshold,
    required this.useFigurine,
    required this.pieceAssets,
    this.lichessStyle = false,
  });

  final ChessLine variationLine;
  final ChessMovePointer pointerPrefix;
  final int depth;
  final int startPly;
  final String branchLabel;
  final bool collapsed;
  final bool defaultCollapsed;
  final VoidCallback onToggle;

  final ChessMovePointer activePointer;
  final GlobalKey activeKey;
  final ValueChanged<ChessMovePointer> onJump;
  final Map<int, LichessMoveAnnotation> lichessAnnotations;
  final Map<int, List<int>> userNags;
  final void Function(int ply, int? nag)? onSetUserQualityNag;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(ChessMovePointer pointer, int nag)? onToggleMoveNag;
  final void Function(ChessMovePointer pointer, String? comment)?
  onSetMoveComment;
  final void Function(ChessMovePointer)? onPromoteVariation;
  final void Function(ChessMovePointer)? onDeleteVariation;
  final void Function(ChessMovePointer)? onTrimContinuation;
  final Set<String> forcedOpenIds;
  final Set<String> collapsedIds;
  final Set<String> expandedIds;
  final void Function(String id, bool defaultCollapsed) onToggleCollapsed;
  final int autoCollapseDepth;
  final int autoCollapseMoveThreshold;
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  /// Lichess look: drop reference database `[ ]`/`( )` brackets + branch chip; use a
  /// compact `[+]/[−]` toggle prefix, dimmer per-depth color, tighter
  /// indent. Variations recurse with the same flag so nested branches stay
  /// Lichess-styled all the way down.
  final bool lichessStyle;

  @override
  Widget build(BuildContext context) {
    if (lichessStyle) return _buildLichess(context);
    return _buildReferenceStyle(context);
  }

  Widget _buildLichess(BuildContext context) {
    final firstMove = variationLine.isEmpty ? null : variationLine.first;
    final firstPointer = <int>[...pointerPrefix, 0];
    final firstSelected =
        firstMove != null && _pointersEqual(firstPointer, activePointer);
    final firstMoveNumber = (startPly ~/ 2) + 1;
    final firstPrefix =
        startPly.isEven ? '$firstMoveNumber.' : '$firstMoveNumber...';

    // Compact `[+]`/`[−]` text toggle — no bordered chip, no branch label.
    // Cyan when collapsed (the actionable expand affordance Lichess users
    // scan for); dim when expanded.
    final toggleColor =
        collapsed ? kPrimaryColor : kWhiteColor70.withValues(alpha: 0.55);
    final toggle = ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Text(
            collapsed ? '[+]' : '[−]',
            style: TextStyle(
              color: toggleColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );

    if (collapsed && firstMove != null) {
      final remaining = variationLine.length - 1;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          toggle,
          const SizedBox(width: 4),
          _InlineMove(
            prefix: firstPrefix,
            move: firstMove,
            pointer: firstPointer,
            selected: firstSelected,
            depth: depth,
            isVariationHead: true,
            onJump: onJump,
            nags: firstMove.nags ?? const <int>[],
            annotation: null,
            userHasQualityNag: false,
            onSetUserQualityNag: null,
            onToggleUserNag: null,
            onSetComment:
                onSetMoveComment == null
                    ? null
                    : (comment) => onSetMoveComment!(firstPointer, comment),
            onPromoteVariation: onPromoteVariation,
            onDeleteVariation: onDeleteVariation,
            onTrimContinuation: onTrimContinuation,
            variationHeadPointer: firstPointer,
            useFigurine: useFigurine,
            pieceAssets: pieceAssets,
          ),
          if (remaining > 0) ...[
            const SizedBox(width: 6),
            Text(
              '+$remaining',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      );
    }

    // Bind every row of the sub-variation under one subtle depth-tinted
    // background so the analyst's grouping reads at a glance. Container is
    // intentionally thin (no border, low-alpha bg) — clusters without
    // shouting.
    return Container(
      decoration: BoxDecoration(
        color: _depthBgColor(depth),
        borderRadius: BorderRadius.circular(3),
      ),
      padding: const EdgeInsets.fromLTRB(2, 0, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: toggle),
          const SizedBox(width: 4),
          Expanded(
            child: _InlineNotationBlock(
              line: variationLine,
              pointerPrefix: pointerPrefix,
              depth: depth,
              isMainlineRoot: false,
              startPly: startPly,
              activePointer: activePointer,
              activeKey: activeKey,
              onJump: onJump,
              lichessAnnotations: lichessAnnotations,
              userNags: userNags,
              onSetUserQualityNag: onSetUserQualityNag,
              onToggleUserNag: onToggleUserNag,
              onToggleMoveNag: onToggleMoveNag,
              onSetMoveComment: onSetMoveComment,
              onPromoteVariation: onPromoteVariation,
              onDeleteVariation: onDeleteVariation,
              onTrimContinuation: onTrimContinuation,
              forcedOpenIds: forcedOpenIds,
              collapsedIds: collapsedIds,
              expandedIds: expandedIds,
              onToggleCollapsed: onToggleCollapsed,
              autoCollapseDepth: autoCollapseDepth,
              autoCollapseMoveThreshold: autoCollapseMoveThreshold,
              useFigurine: useFigurine,
              pieceAssets: pieceAssets,
              lichessStyle: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReferenceStyle(BuildContext context) {
    final base = _depthBaseColor(depth);

    // Reference delimiter convention: depth-1 wraps in [ ], depth ≥ 2 wraps
    // in ( ). Toggle character `+`/`−` is glued to the opening bracket so
    // the pair reads as one reference-style affordance: `[+ 5...Bc5]`
    // (collapsed), `[− 5...d6? 6.Nc3 Bg4 ...]` (expanded). No branch letter —
    // the reference notation doesn't show one and adding it adds visual noise.
    final useSquare = depth <= 1;
    final openGlyph = useSquare ? '[' : '(';
    final closeGlyph = useSquare ? ']' : ')';

    final firstMove = variationLine.isEmpty ? null : variationLine.first;
    final firstPointer = <int>[...pointerPrefix, 0];
    final firstSelected =
        firstMove != null && _pointersEqual(firstPointer, activePointer);
    final firstMoveNumber = (startPly ~/ 2) + 1;
    final firstPrefix =
        startPly.isEven ? '$firstMoveNumber.' : '$firstMoveNumber...';

    final bracketStyle = TextStyle(
      color: base,
      fontSize: depth <= 1 ? 15 : 14,
      fontWeight: FontWeight.w800,
      height: 1.0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final toggleGlyph = collapsed ? '+' : '−';
    // `[+ ` / `[− ` (or `(+ `, `(− `) as one tappable bracket+toggle glyph.
    final openBracketWithToggle = ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text('$openGlyph$toggleGlyph', style: bracketStyle),
        ),
      ),
    );

    Widget content;
    if (collapsed && firstMove != null) {
      final remaining = variationLine.length - 1;
      content = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          openBracketWithToggle,
          _InlineMove(
            prefix: firstPrefix,
            move: firstMove,
            pointer: firstPointer,
            selected: firstSelected,
            depth: depth,
            isVariationHead: true,
            onJump: onJump,
            nags: firstMove.nags ?? const <int>[],
            annotation: null,
            userHasQualityNag: false,
            onSetUserQualityNag: null,
            onToggleUserNag: null,
            onSetComment:
                onSetMoveComment == null
                    ? null
                    : (comment) => onSetMoveComment!(firstPointer, comment),
            onPromoteVariation: onPromoteVariation,
            onDeleteVariation: onDeleteVariation,
            onTrimContinuation: onTrimContinuation,
            variationHeadPointer: firstPointer,
            useFigurine: useFigurine,
            pieceAssets: pieceAssets,
          ),
          if (remaining > 0) ...[
            const SizedBox(width: 6),
            Text(
              '+$remaining',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(width: 2),
          Text(closeGlyph, style: bracketStyle),
        ],
      );
    } else {
      // Expanded: bracket+toggle prefix glued to the FIRST line of the body
      // (so `[− 5...d6? Leniart-Warakomski 2020 6.Nc3 ...` reads as one
      // paragraph). The closing bracket is appended by `_InlineNotationBlock`,
      // so it stays next to the final move as the variation grows instead of
      // consuming its own bracket-only row.
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: openBracketWithToggle,
          ),
          Expanded(
            child: _InlineNotationBlock(
              line: variationLine,
              pointerPrefix: pointerPrefix,
              depth: depth,
              isMainlineRoot: false,
              startPly: startPly,
              activePointer: activePointer,
              activeKey: activeKey,
              onJump: onJump,
              lichessAnnotations: lichessAnnotations,
              userNags: userNags,
              onSetUserQualityNag: onSetUserQualityNag,
              onToggleUserNag: onToggleUserNag,
              onToggleMoveNag: onToggleMoveNag,
              onSetMoveComment: onSetMoveComment,
              onPromoteVariation: onPromoteVariation,
              onDeleteVariation: onDeleteVariation,
              onTrimContinuation: onTrimContinuation,
              forcedOpenIds: forcedOpenIds,
              collapsedIds: collapsedIds,
              expandedIds: expandedIds,
              onToggleCollapsed: onToggleCollapsed,
              autoCollapseDepth: autoCollapseDepth,
              autoCollapseMoveThreshold: autoCollapseMoveThreshold,
              useFigurine: useFigurine,
              pieceAssets: pieceAssets,
              closingBracketGlyph: closeGlyph,
              closingBracketStyle: bracketStyle,
            ),
          ),
        ],
      );
    }

    // Indent each depth level so nested brackets read as a tree. 14 px per
    // level lines up with the closing bracket's column. Subtle depth-tinted
    // bg binds every row in the variation into a single eye-group so
    // sub-vars, NAGs, comments — everything between `[` and `]` — reads as
    // one cluster the analyst authored together.
    return Padding(
      padding: EdgeInsets.fromLTRB(14.0 * (depth - 1).clamp(0, 8), 1, 0, 1),
      child: Container(
        decoration: BoxDecoration(
          color: _depthBgColor(depth),
          borderRadius: BorderRadius.circular(3),
        ),
        padding: const EdgeInsets.fromLTRB(4, 1, 6, 1),
        child: Align(alignment: Alignment.topLeft, child: content),
      ),
    );
  }
}

class _InlineMove extends StatelessWidget {
  const _InlineMove({
    required this.prefix,
    required this.move,
    required this.pointer,
    required this.selected,
    required this.depth,
    required this.onJump,
    required this.nags,
    required this.annotation,
    required this.userHasQualityNag,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onSetComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
    required this.variationHeadPointer,
    required this.useFigurine,
    required this.pieceAssets,
    this.isVariationHead = false,
  });

  final String prefix;
  final ChessMove move;
  final ChessMovePointer pointer;
  final bool selected;
  final int depth;
  final ValueChanged<ChessMovePointer> onJump;
  final List<int> nags;
  final LichessMoveAnnotation? annotation;
  final bool userHasQualityNag;
  final void Function(int ply, int? nag)? onSetUserQualityNag;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(String? comment)? onSetComment;
  final void Function(ChessMovePointer)? onPromoteVariation;
  final void Function(ChessMovePointer)? onDeleteVariation;
  final void Function(ChessMovePointer)? onTrimContinuation;
  final ChessMovePointer? variationHeadPointer;
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  /// True for the first move of any variation. Renders the SAN in cyan
  /// (kPrimaryColor) so it reads as a clickable "branch entry" link —
  /// the affordance Vasif specifically asked for after the dark-theme
  /// reference image.
  final bool isVariationHead;

  @override
  Widget build(BuildContext context) {
    final prefixColor =
        selected
            ? kPrimaryColor
            : (depth == 0 ? kLightGreyColor : kWhiteColor70);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (prefix.isNotEmpty) ...[
          Text(
            prefix,
            style: TextStyle(
              color: prefixColor,
              fontSize: depth == 0 ? 12 : 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 2),
        ],
        _LadderChip(
          san: move.san,
          fen: move.fen,
          uci: move.uci,
          selected: selected,
          depth: depth,
          onTap: () => onJump(pointer),
          nags: nags,
          annotationComment: annotation?.comment,
          commentText: _firstPgnComment(move.comments),
          userHasQualityNag: userHasQualityNag,
          clockText: _formatClockChip(move.clockTime),
          clockSeconds: _clockSeconds(move.clockTime),
          onSetUserQualityNag:
              onSetUserQualityNag == null
                  ? null
                  : (nag) => onSetUserQualityNag!(pointer.last, nag),
          onToggleUserNag:
              onToggleUserNag == null
                  ? null
                  : (nag) => onToggleUserNag!(pointer.last, nag),
          onSetComment: onSetComment,
          onPromoteVariation:
              onPromoteVariation == null || variationHeadPointer == null
                  ? null
                  : () => onPromoteVariation!(variationHeadPointer!),
          onDeleteVariation:
              onDeleteVariation == null || variationHeadPointer == null
                  ? null
                  : () => onDeleteVariation!(variationHeadPointer!),
          onTrimFromHere:
              onTrimContinuation == null
                  ? null
                  : () => onTrimContinuation!(pointer),
          useFigurine: useFigurine,
          pieceAssets: pieceAssets,
          compact: true,
          variationHead: isVariationHead,
          mainlineDominant: depth == 0,
        ),
      ],
    );
  }
}

class _InlineSourceMetadata extends StatelessWidget {
  const _InlineSourceMetadata({required this.depth, required this.sourceLabel});

  final int depth;
  final String sourceLabel;

  @override
  Widget build(BuildContext context) {
    final meta = _tryParseGameSourceMetadata(sourceLabel);
    if (meta != null) {
      return _InlineGameSourceBanner(metadata: meta, depth: depth);
    }
    return _SourceMetadataPill(
      sourceLabel: sourceLabel,
      depth: depth,
      inline: true,
    );
  }
}

/// Inline reference-style game footer rendered at the end of an inserted
/// continuation: `1–0 (38) Sindarov, J (2776) − Gukesh, D (2732) Warsaw 2026`.
///
/// Stays on the same Wrap-row as the trailing moves so it reads as the
/// natural tail of the run. The result and Elo numbers use tabular
/// figures to keep digit columns even when re-rendered.
class _InlineGameSourceBanner extends StatelessWidget {
  const _InlineGameSourceBanner({required this.metadata, required this.depth});

  final _GameSourceMetadata metadata;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final result = metadata.resultChip;
    final resultTint = _resultChipTint(result);
    final baseColor =
        depth == 0 ? kWhiteColor.withValues(alpha: 0.85) : kWhiteColor70;
    final dimColor = depth == 0 ? kWhiteColor70 : kLightGreyColor;
    final spans = <InlineSpan>[];

    void addText(String text, {required TextStyle style}) {
      spans.add(TextSpan(text: text, style: style));
    }

    final baseStyle = TextStyle(
      color: baseColor,
      fontSize: depth == 0 ? 12.4 : 11.2,
      height: 1.25,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.05,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dimStyle = baseStyle.copyWith(color: dimColor);
    final boldStyle = baseStyle.copyWith(
      color: depth == 0 ? kWhiteColor : kWhiteColor70,
      fontWeight: FontWeight.w700,
    );
    final venueStyle = baseStyle.copyWith(
      color: dimColor,
      fontStyle: FontStyle.italic,
    );

    if (result != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _ResultBadge(label: result, tint: resultTint, compact: true),
        ),
      );
    }
    if (metadata.plies != null) {
      if (spans.isNotEmpty) addText(' ', style: dimStyle);
      addText('(${metadata.plies})', style: dimStyle);
    }

    void addPlayer(String? name, int? elo, String? title) {
      if (name == null) return;
      if (spans.isNotEmpty) addText('  ', style: baseStyle);
      if (title != null && title.isNotEmpty) {
        addText(
          '$title ',
          style: dimStyle.copyWith(fontWeight: FontWeight.w700),
        );
      }
      addText(name, style: boldStyle);
      if (elo != null) {
        addText(' ', style: baseStyle);
        addText('($elo)', style: dimStyle);
      }
    }

    final hasWhite = metadata.whiteName != null;
    final hasBlack = metadata.blackName != null;
    addPlayer(metadata.whiteName, metadata.whiteElo, metadata.whiteTitle);
    if (hasWhite && hasBlack) {
      addText('  − ', style: dimStyle);
    }
    addPlayer(metadata.blackName, metadata.blackElo, metadata.blackTitle);

    final venue = <String>[
      if (metadata.event != null) metadata.event!,
      if (metadata.site != null && metadata.site != metadata.event)
        metadata.site!,
      if (metadata.round != null) 'R${metadata.round}',
      if (metadata.year != null) metadata.year!,
    ];
    if (venue.isNotEmpty) {
      if (spans.isNotEmpty) addText('  ', style: baseStyle);
      addText(venue.join(' · '), style: venueStyle);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 2),
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Compact result pill used inline next to the inserted line and inside the
/// ladder source card. Mirrors the larger `_GameResultRow` chip so the eye
/// links the inline footer to the terminal banner at the bottom of the line.
class _ResultBadge extends StatelessWidget {
  const _ResultBadge({
    required this.label,
    required this.tint,
    this.compact = false,
  });

  final String label;
  final Color tint;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(compact ? 4 : 5),
        border: Border.all(color: tint.withValues(alpha: 0.55), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tint,
          fontSize: compact ? 11 : 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          height: 1.0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _SourceMetadataPill extends StatelessWidget {
  const _SourceMetadataPill({
    required this.sourceLabel,
    required this.depth,
    this.inline = false,
  });

  final String sourceLabel;
  final int depth;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final accent =
        depth == 0
            ? kPrimaryColor
            : _depthBaseColor(depth).withValues(alpha: 0.95);
    final display = _sourceMetadataDisplay(sourceLabel);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: inline ? 320 : 460),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: inline ? 7 : 8,
          vertical: inline ? 3 : 4,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: inline ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: accent.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: inline ? 12 : 13,
              color: accent.withValues(alpha: 0.95),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: kWhiteColor.withValues(alpha: 0.82),
                  fontSize: inline ? 10.8 : 11.4,
                  height: 1.05,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.05,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.metadata});

  final NotationHeaderMetadata metadata;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [Expanded(child: _PgnMetadataHeader(metadata: metadata))],
      ),
    );
  }
}

class _PgnMetadataHeader extends StatelessWidget {
  const _PgnMetadataHeader({required this.metadata});

  final NotationHeaderMetadata metadata;

  @override
  Widget build(BuildContext context) {
    if (!metadata.hasAny) return const SizedBox.shrink();

    final event = metadata.event ?? metadata.date ?? metadata.eco!;
    final chips = <Widget>[
      if (metadata.round != null) _MetadataChip(label: 'Rd ${metadata.round}'),
      if (metadata.date != null && metadata.event != null)
        _MetadataChip(label: metadata.date!),
      if (metadata.eco != null && metadata.eco != event)
        _MetadataChip(label: metadata.eco!),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final veryCompact = constraints.maxWidth < 260;
        return Row(
          children: [
            Expanded(
              child: Text(
                event,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: kWhiteColor.withValues(alpha: 0.92),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.04,
                ),
              ),
            ),
            if (!veryCompact && chips.isNotEmpty) ...[
              const SizedBox(width: 8),
              Wrap(spacing: 5, runSpacing: 4, children: chips),
            ],
          ],
        );
      },
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kPrimaryColor.withValues(alpha: 0.95),
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.15,
          height: 1.0,
        ),
      ),
    );
  }
}

class _PairRow extends StatelessWidget {
  const _PairRow({
    required this.moveNumber,
    required this.showLeadingEllipsis,
    required this.depth,
    required this.whiteMove,
    required this.whitePointer,
    required this.blackMove,
    required this.blackPointer,
    required this.whiteIsActive,
    required this.blackIsActive,
    required this.activeKey,
    required this.onJump,
    required this.whiteNags,
    required this.whiteAnnotation,
    required this.whiteUserHasQuality,
    required this.blackNags,
    required this.blackAnnotation,
    required this.blackUserHasQuality,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onSetWhiteComment,
    required this.onSetBlackComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimContinuation,
    required this.variationHeadPointer,
    required this.useFigurine,
    required this.pieceAssets,
  });

  final int moveNumber;
  final bool showLeadingEllipsis;
  final int depth;
  final ChessMove? whiteMove;
  final ChessMovePointer? whitePointer;
  final ChessMove? blackMove;
  final ChessMovePointer? blackPointer;
  final bool whiteIsActive;
  final bool blackIsActive;
  final GlobalKey? activeKey;
  final ValueChanged<ChessMovePointer> onJump;

  final List<int> whiteNags;
  final LichessMoveAnnotation? whiteAnnotation;
  final bool whiteUserHasQuality;
  final List<int> blackNags;
  final LichessMoveAnnotation? blackAnnotation;
  final bool blackUserHasQuality;

  final void Function(int ply, int? nag)? onSetUserQualityNag;
  final void Function(int ply, int nag)? onToggleUserNag;
  final void Function(String? comment)? onSetWhiteComment;
  final void Function(String? comment)? onSetBlackComment;
  final void Function(ChessMovePointer)? onPromoteVariation;
  final void Function(ChessMovePointer)? onDeleteVariation;
  final void Function(ChessMovePointer)? onTrimContinuation;
  final ChessMovePointer? variationHeadPointer;
  final bool useFigurine;
  final PieceAssets? pieceAssets;

  @override
  Widget build(BuildContext context) {
    final rowActive = whiteIsActive || blackIsActive;
    // Lichess-density pair row: tight padding, no heavy outer border, just
    // a slim left accent + subtle bg tint when the row owns the cursor.
    return Padding(
      key: activeKey,
      padding: EdgeInsets.fromLTRB(depth == 0 ? 8 : 2, 0, 8, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 1, 4, 1),
        decoration: BoxDecoration(
          color:
              rowActive
                  ? kPrimaryColor.withValues(alpha: 0.10)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(
              color: rowActive ? kPrimaryColor : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$moveNumber.',
                style: TextStyle(
                  color:
                      depth == 0
                          ? (rowActive ? kPrimaryColor : kLightGreyColor)
                          : kWhiteColor70,
                  fontSize: 12,
                  fontWeight: rowActive ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child:
                  showLeadingEllipsis
                      ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '…',
                          style: TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      )
                      : whiteMove == null
                      ? const SizedBox.shrink()
                      : _LadderChip(
                        san: whiteMove!.san,
                        fen: whiteMove!.fen,
                        uci: whiteMove!.uci,
                        selected: whiteIsActive,
                        depth: depth,
                        onTap: () => onJump(whitePointer!),
                        nags: whiteNags,
                        annotationComment: whiteAnnotation?.comment,
                        userHasQualityNag: whiteUserHasQuality,
                        clockText: _formatClockChip(whiteMove!.clockTime),
                        clockSeconds: _clockSeconds(whiteMove!.clockTime),
                        onSetUserQualityNag:
                            onSetUserQualityNag == null
                                ? null
                                : (nag) => onSetUserQualityNag!(
                                  whitePointer!.last,
                                  nag,
                                ),
                        onToggleUserNag:
                            onToggleUserNag == null
                                ? null
                                : (nag) =>
                                    onToggleUserNag!(whitePointer!.last, nag),
                        commentText: _firstPgnComment(whiteMove!.comments),
                        onSetComment: onSetWhiteComment,
                        onPromoteVariation:
                            onPromoteVariation == null ||
                                    variationHeadPointer == null
                                ? null
                                : () =>
                                    onPromoteVariation!(variationHeadPointer!),
                        onDeleteVariation:
                            onDeleteVariation == null ||
                                    variationHeadPointer == null
                                ? null
                                : () =>
                                    onDeleteVariation!(variationHeadPointer!),
                        onTrimFromHere:
                            onTrimContinuation == null
                                ? null
                                : () => onTrimContinuation!(whitePointer!),
                        useFigurine: useFigurine,
                        pieceAssets: pieceAssets,
                      ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child:
                  blackMove == null
                      ? const SizedBox.shrink()
                      : _LadderChip(
                        san: blackMove!.san,
                        fen: blackMove!.fen,
                        uci: blackMove!.uci,
                        selected: blackIsActive,
                        depth: depth,
                        onTap: () => onJump(blackPointer!),
                        nags: blackNags,
                        annotationComment: blackAnnotation?.comment,
                        userHasQualityNag: blackUserHasQuality,
                        clockText: _formatClockChip(blackMove!.clockTime),
                        clockSeconds: _clockSeconds(blackMove!.clockTime),
                        onSetUserQualityNag:
                            onSetUserQualityNag == null
                                ? null
                                : (nag) => onSetUserQualityNag!(
                                  blackPointer!.last,
                                  nag,
                                ),
                        onToggleUserNag:
                            onToggleUserNag == null
                                ? null
                                : (nag) =>
                                    onToggleUserNag!(blackPointer!.last, nag),
                        commentText: _firstPgnComment(blackMove!.comments),
                        onSetComment: onSetBlackComment,
                        onPromoteVariation:
                            onPromoteVariation == null ||
                                    variationHeadPointer == null
                                ? null
                                : () =>
                                    onPromoteVariation!(variationHeadPointer!),
                        onDeleteVariation:
                            onDeleteVariation == null ||
                                    variationHeadPointer == null
                                ? null
                                : () =>
                                    onDeleteVariation!(variationHeadPointer!),
                        onTrimFromHere:
                            onTrimContinuation == null
                                ? null
                                : () => onTrimContinuation!(blackPointer!),
                        useFigurine: useFigurine,
                        pieceAssets: pieceAssets,
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LadderChip extends StatefulWidget {
  const _LadderChip({
    required this.san,
    required this.fen,
    required this.uci,
    required this.selected,
    required this.depth,
    required this.onTap,
    required this.nags,
    required this.annotationComment,
    required this.commentText,
    required this.userHasQualityNag,
    required this.onSetUserQualityNag,
    required this.onToggleUserNag,
    required this.onSetComment,
    required this.onPromoteVariation,
    required this.onDeleteVariation,
    required this.onTrimFromHere,
    required this.useFigurine,
    required this.pieceAssets,
    this.compact = false,
    this.clockText,
    this.clockSeconds,
    this.variationHead = false,
    this.mainlineDominant = false,
  });

  final String san;
  final String fen;
  final String uci;
  final bool selected;
  final int depth;
  final VoidCallback onTap;
  final List<int> nags;
  final String? annotationComment;
  final String? commentText;
  final bool userHasQualityNag;
  final void Function(int? nag)? onSetUserQualityNag;
  final void Function(int nag)? onToggleUserNag;
  final void Function(String? comment)? onSetComment;
  final VoidCallback? onPromoteVariation;
  final VoidCallback? onDeleteVariation;
  final VoidCallback? onTrimFromHere;
  final bool useFigurine;
  final PieceAssets? pieceAssets;
  final bool compact;

  /// True when this chip renders the first move of a variation — paints
  /// the SAN in cyan so it reads as a "blue clickable link" entry point
  /// (the dark-theme reference image asked for this).
  final bool variationHead;

  /// True for mainline (depth-0) chips in the inline layout — bumps SAN
  /// size and weight so the mainline visually dominates sub-variations,
  /// matching the reference hierarchy.
  final bool mainlineDominant;

  /// Compact `M:SS` derived from a `[%clk]` PGN extension. Null hides the
  /// trailing clock pill. Only mainline moves currently carry this.
  final String? clockText;

  /// Total seconds remaining at the clock annotation; used to colour
  /// the badge red when under 30s (time-pressure indicator).
  final int? clockSeconds;

  @override
  State<_LadderChip> createState() => _LadderChipState();
}

class _LadderChipState extends State<_LadderChip> {
  bool _hovered = false;

  Future<void> _showContextMenu(BuildContext context, Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final canSetQuality = widget.onSetUserQualityNag != null;
    final canToggleNag = widget.onToggleUserNag != null;
    final canAnnotate = canSetQuality || canToggleNag;
    final canComment = widget.onSetComment != null;
    final canPromote = widget.onPromoteVariation != null;
    final canDelete = widget.onDeleteVariation != null;
    final canTrim = widget.onTrimFromHere != null;
    final notationState =
        context.findAncestorStateOfType<_NotationLadderViewState>();
    final selected = await showMenu<_LadderAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      color: kBlack2Color,
      items: [
        if (notationState?._hasCollapsibleVariations ?? false)
          PopupMenuItem<_LadderAction>(
            value: _LadderAction.toggleAllVariations,
            child: _MenuLabel(
              icon:
                  (notationState?._allVariationsManuallyCollapsed ?? false)
                      ? Icons.unfold_more_rounded
                      : Icons.unfold_less_rounded,
              label:
                  (notationState?._allVariationsManuallyCollapsed ?? false)
                      ? 'Unfold all'
                      : 'Fold all',
            ),
          ),
        const PopupMenuItem<_LadderAction>(
          value: _LadderAction.copyPgn,
          child: _MenuLabel(icon: Icons.copy_all_rounded, label: 'Copy PGN'),
        ),
        const PopupMenuItem<_LadderAction>(
          value: _LadderAction.copyFen,
          child: _MenuLabel(
            icon: Icons.format_quote_rounded,
            label: 'Copy FEN',
          ),
        ),
        if (canTrim) ...[
          const PopupMenuDivider(height: 1),
          const PopupMenuItem<_LadderAction>(
            value: _LadderAction.trim,
            child: _MenuLabel(
              icon: Icons.content_cut_rounded,
              label: 'Trim line from here',
            ),
          ),
        ],
        if (canPromote || canDelete) ...[
          const PopupMenuDivider(height: 1),
          if (canPromote)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.promote,
              child: _MenuLabel(
                icon: Icons.arrow_upward_rounded,
                label: 'Promote to mainline',
              ),
            ),
          if (canDelete)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.delete,
              child: _MenuLabel(
                icon: Icons.delete_outline_rounded,
                label: 'Delete variation',
              ),
            ),
        ],
        if (canAnnotate) ...[
          const PopupMenuDivider(height: 1),
          if (canSetQuality)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.openQualityAnnotations,
              child: _MenuLabel(
                icon: Icons.chevron_right_rounded,
                label: '!, ?, ...',
              ),
            ),
          if (canToggleNag)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.openEvaluationAnnotations,
              child: _MenuLabel(
                icon: Icons.chevron_right_rounded,
                label: '+-, =, ...',
              ),
            ),
          if (canToggleNag)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.openIdeaAnnotations,
              child: _MenuLabel(
                icon: Icons.chevron_right_rounded,
                label: 'Special annotations',
              ),
            ),
          if (canSetQuality && widget.userHasQualityNag)
            const PopupMenuItem<_LadderAction>(
              value: _LadderAction.clearAnnotation,
              child: _MenuLabel(
                icon: Icons.clear_rounded,
                label: 'Clear move symbol',
              ),
            ),
        ],
        if (canComment) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem<_LadderAction>(
            value: _LadderAction.editComment,
            child: _MenuLabel(
              icon: Icons.add_comment_outlined,
              label:
                  (widget.commentText ?? '').trim().isEmpty
                      ? 'Add comment'
                      : 'Edit comment',
            ),
          ),
        ],
      ],
    );

    if (selected == null) return;
    if (!mounted) return;
    switch (selected) {
      case _LadderAction.toggleAllVariations:
        notationState?._toggleAllVariationsFromMenu();
      case _LadderAction.copyPgn:
        await notationState?._copyPgnToClipboard();
      case _LadderAction.copyFen:
        if (widget.fen.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: widget.fen));
        }
      case _LadderAction.trim:
        widget.onTrimFromHere?.call();
      case _LadderAction.promote:
        widget.onPromoteVariation?.call();
      case _LadderAction.delete:
        widget.onDeleteVariation?.call();
      case _LadderAction.openQualityAnnotations:
        final nag = await _showNagSubmenu(
          this.context,
          globalPos,
          _NotationAnnotationToolbar._qualityNags,
        );
        if (!mounted) return;
        if (nag != null) widget.onSetUserQualityNag?.call(nag);
      case _LadderAction.openEvaluationAnnotations:
        final nag = await _showNagSubmenu(
          this.context,
          globalPos,
          _NotationAnnotationToolbar._evaluationNags,
        );
        if (!mounted) return;
        if (nag != null) widget.onToggleUserNag?.call(nag);
      case _LadderAction.openIdeaAnnotations:
        final nag = await _showNagSubmenu(
          this.context,
          globalPos,
          _NotationAnnotationToolbar._observationNags,
        );
        if (!mounted) return;
        if (nag != null) widget.onToggleUserNag?.call(nag);
      case _LadderAction.clearAnnotation:
        widget.onSetUserQualityNag?.call(null);
      case _LadderAction.editComment:
        if (!context.mounted) return;
        final next = await showMoveCommentEditor(
          context,
          initialComment: widget.commentText ?? '',
        );
        if (next != null) {
          widget.onSetComment?.call(next.trim().isEmpty ? null : next.trim());
        }
    }
  }

  Future<int?> _showNagSubmenu(
    BuildContext context,
    Offset globalPos,
    List<int> nags,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    const submenuWidth = 240.0;
    final maxLeft = overlay.size.width - submenuWidth;
    final left =
        (globalPos.dx + 180) > maxLeft
            ? (maxLeft < 0 ? 0.0 : maxLeft)
            : (globalPos.dx + 180);
    return showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        left,
        globalPos.dy,
        overlay.size.width - left - submenuWidth,
        overlay.size.height - globalPos.dy,
      ),
      color: kBlack2Color,
      items: [
        for (final nag in nags)
          if (getNagDisplay(nag) case final display?)
            PopupMenuItem<int>(
              value: nag,
              child: _NagLabel(
                glyph: display.symbol,
                label: _nagMenuLabel(nag, display),
                color: display.color,
              ),
            ),
      ],
    );
  }

  List<NagDisplay> _resolvedNags() {
    final out = <NagDisplay>[];
    final seen = <int>{};
    for (final code in widget.nags) {
      if (!seen.add(code)) continue;
      final d = getNagDisplay(code);
      if (d != null) out.add(d);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final isVariation = widget.depth > 0;
    final fg =
        widget.selected
            ? kBackgroundColor
            : (isVariation ? kWhiteColor70 : kWhiteColor);
    final bg =
        widget.selected
            ? kPrimaryColor
            : (_hovered ? kBlack3Color : Colors.transparent);
    final nags = _resolvedNags();
    final firstQualityNag = nags.cast<NagDisplay?>().firstWhere(
      (d) => d?.isQuality == true,
      orElse: () => null,
    );
    final sanColor =
        widget.selected
            ? kBackgroundColor
            : widget.variationHead
            ? kPrimaryColor
            : (firstQualityNag?.color ?? fg);

    // Typography hierarchy: mainline = upright bold and visually dominant,
    // depth-1 = upright medium-weight, depth-2+ = italic, slightly smaller.
    // The inline (compact) layout bumps mainline a touch larger/heavier so
    // it still wins over depth-tinted variation blocks beneath it.
    final isDeepVariation = widget.depth >= 2;
    final double sanFontSize;
    if (widget.compact) {
      if (widget.mainlineDominant) {
        sanFontSize = 13.5;
      } else if (isDeepVariation) {
        sanFontSize = 11.5;
      } else {
        sanFontSize = 12.0;
      }
    } else {
      sanFontSize = isDeepVariation ? 11.5 : (isVariation ? 12.0 : 13.0);
    }
    final FontWeight sanWeight;
    if (widget.selected) {
      sanWeight = FontWeight.w800;
    } else if (widget.mainlineDominant) {
      sanWeight = FontWeight.w800;
    } else if (widget.variationHead) {
      sanWeight = FontWeight.w700;
    } else if (isDeepVariation) {
      sanWeight = FontWeight.w500;
    } else {
      sanWeight = FontWeight.w600;
    }

    final sanText = RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        children: _sanSpans(
          widget.san,
          style: TextStyle(
            color: sanColor,
            fontSize: sanFontSize,
            fontWeight: sanWeight,
            fontStyle: isDeepVariation ? FontStyle.italic : FontStyle.normal,
            // Variation entry moves carry a cyan underline so the eye
            // groups them as the "clickable branch link" — same color cue
            // the dark-theme database reference uses to bind every new
            // sub-line to its expand affordance.
            decoration:
                widget.variationHead && !widget.selected
                    ? TextDecoration.underline
                    : TextDecoration.none,
            decorationColor: kPrimaryColor.withValues(alpha: 0.85),
            decorationThickness: 1.4,
          ),
          useFigurine: widget.useFigurine,
          pieceAssets: widget.pieceAssets,
          pieceSize: widget.compact ? 13 : 14,
        ),
      ),
    );

    final clockText = widget.clockText;
    final children = <Widget>[
      if (widget.compact) sanText else Flexible(child: sanText),
      for (final d in nags) ...[
        const SizedBox(width: 3),
        Text(
          d.symbol,
          style: TextStyle(
            color: widget.selected ? kBackgroundColor : d.color,
            fontSize: d.isQuality ? 13 : 12,
            fontWeight: d.isQuality ? FontWeight.w800 : FontWeight.w600,
            height: 1.0,
            letterSpacing: -0.2,
          ),
        ),
      ],
      if (clockText != null) ...[
        const SizedBox(width: 6),
        _ClockBadge(
          text: clockText,
          selected: widget.selected,
          totalSeconds: widget.clockSeconds,
        ),
      ],
    ];

    final chip = ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapUp:
              (details) => _showContextMenu(context, details.globalPosition),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: isVariation ? 22 : 24,
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 6 : 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );

    // Mini-board hover preview: replays nothing (the move's resulting
    // FEN is already stored on the ChessMove) so the popup just has to
    // render that position. Wraps every chip with a fen so even deep
    // sub-variations get the preview that database users expect.
    final preview =
        widget.fen.isEmpty
            ? chip
            : MoveHoverPreview(
              startingFen: widget.fen,
              movesUpToHover: const <String>[],
              lastMoveUci: widget.uci.isEmpty ? null : widget.uci,
              size: 200,
              child: chip,
            );

    final comment = widget.annotationComment;
    if (comment != null && comment.trim().isNotEmpty) {
      return DesktopTooltip(message: comment, child: preview);
    }
    return preview;
  }
}

enum _LadderAction {
  toggleAllVariations,
  copyPgn,
  copyFen,
  trim,
  promote,
  delete,
  openQualityAnnotations,
  openEvaluationAnnotations,
  openIdeaAnnotations,
  clearAnnotation,
  editComment,
}

Future<String?> showMoveCommentEditor(
  BuildContext context, {
  required String initialComment,
}) {
  return showDesktopModal<String>(
    context,
    title: 'Move comment',
    maxWidth: 520,
    builder: (_) => _MoveCommentEditor(initialComment: initialComment),
  );
}

class _MoveCommentEditor extends StatefulWidget {
  const _MoveCommentEditor({required this.initialComment});

  final String initialComment;

  @override
  State<_MoveCommentEditor> createState() => _MoveCommentEditorState();
}

class _MoveCommentEditorState extends State<_MoveCommentEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialComment);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);
  void _clear() => Navigator.of(context).pop('');
  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Comment',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            CommentarySymbolShortcuts(
              controller: _controller,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: kBlack3Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 600,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    height: 1.35,
                  ),
                  cursorColor: kPrimaryColor,
                  decoration: const InputDecoration(
                    hintText: 'Add a note for this move',
                    hintStyle: TextStyle(color: kLightGreyColor, fontSize: 13),
                    border: InputBorder.none,
                    counterText: '',
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (widget.initialComment.trim().isNotEmpty)
                  DesktopDialogButton(label: 'Clear', onPress: _clear),
                const Spacer(),
                DesktopDialogButton(label: 'Cancel', onPress: _cancel),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'Save',
                  tone: DesktopDialogButtonTone.primary,
                  onPress: _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          Icon(icon, size: 14, color: kWhiteColor70),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kWhiteColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _NagLabel extends StatelessWidget {
  const _NagLabel({
    required this.glyph,
    required this.label,
    required this.color,
  });
  final String glyph;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              glyph,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kWhiteColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiny `M:SS` pill rendered to the right of a move chip when the PGN
/// supplied a `[%clk]` extension. Inverts color when the chip is selected
/// so it stays readable on the cyan active background. Goes red under
/// 30s remaining as a time-pressure cue chess masters scan for.
class _ClockBadge extends StatelessWidget {
  const _ClockBadge({
    required this.text,
    required this.selected,
    this.totalSeconds,
  });

  final String text;
  final bool selected;
  final int? totalSeconds;

  @override
  Widget build(BuildContext context) {
    final lowOnTime = totalSeconds != null && totalSeconds! < 30;
    final Color fg;
    if (selected) {
      fg = kBackgroundColor.withValues(alpha: 0.85);
    } else if (lowOnTime) {
      fg = kRedColor;
    } else {
      fg = const Color(0xFF8E8E93);
    }
    return Text(
      text,
      style: TextStyle(
        color: fg,
        fontSize: 10,
        fontWeight: lowOnTime ? FontWeight.w700 : FontWeight.w500,
        height: 1.0,
        letterSpacing: -0.2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Final score banner appended after the mainline. Visually anchors the
/// notation pane so the eye lands on the outcome immediately when scrolled
/// to the end. Hidden for `*` (in-progress) games.
class _GameResultRow extends StatelessWidget {
  const _GameResultRow({required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    Color tintFor(String r) {
      switch (r) {
        case '1–0':
          return kPrimaryColor;
        case '0–1':
          return const Color(0xFFFF8A65); // warm coral, matches black-move tone
        case '½–½':
          return const Color(0xFF9AA3AD);
        default:
          return kWhiteColor70;
      }
    }

    final tint = tintFor(result);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: kDividerColor.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: tint.withValues(alpha: 0.5), width: 1),
            ),
            child: Text(
              result,
              style: TextStyle(
                color: tint,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              color: kDividerColor.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLadderHint extends StatelessWidget {
  const _EmptyLadderHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'No move played yet.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: kLightGreyColor.withValues(alpha: 0.78),
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

ChessMove? _moveAtPointer(ChessLine mainline, ChessMovePointer pointer) {
  if (pointer.isEmpty) return null;
  ChessLine line = mainline;
  ChessMove? move;
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (index < 0 || index >= line.length) return null;
    move = line[index];
    if (i == pointer.length - 1) return move;
    i += 1;
    if (i >= pointer.length) return null;
    final variationIndex = pointer[i];
    final variations = move.variations;
    if (variations == null ||
        variationIndex < 0 ||
        variationIndex >= variations.length) {
      return null;
    }
    line = variations[variationIndex];
  }
  return move;
}

ChessMovePointer? _activeVariationHead(ChessMovePointer pointer) {
  if (pointer.length < 3) return null;
  for (var i = pointer.length - 2; i >= 1; i--) {
    if (i.isOdd) {
      return <int>[...pointer.sublist(0, i + 1), 0];
    }
  }
  return null;
}

bool _pointersEqual(ChessMovePointer a, ChessMovePointer b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _startingPlyFromFen(String fen) {
  final parts = fen.split(' ');
  if (parts.length < 6) return 0;
  final turn = parts[1];
  final fullmove = int.tryParse(parts[5]) ?? 1;
  final base = (fullmove - 1) * 2;
  return turn == 'w' ? base : base + 1;
}

int _variationStartPly({
  required ChessMove parentMove,
  required int parentPly,
  required ChessLine variationLine,
}) {
  if (variationLine.isEmpty) return parentPly + 1;
  return variationLine.first.turn == parentMove.turn
      ? parentPly
      : parentPly + 1;
}

/// Muted sage green for prose-style commentary. Picked to read on the
/// kBlack2Color notation background without competing with cyan accents
/// or the bright-white mainline — the "readable on dark mode" green the
/// design brief asked for.
const Color kCommentaryGreen = Color(0xFF95CFAA);
const Color kCommentaryGreenDim = Color(0xFF7CB492);

/// Default-collapse decision shared by the ladder _LineBlock and the
/// inline _InlineNotationBlock. Keeps both layouts in lockstep so the
/// global Collapse / Expand-all toggles produce identical structure.
bool _shouldCollapseByDefaultInline({
  required int depth,
  required int moveCount,
  required int autoCollapseDepth,
  required int autoCollapseMoveThreshold,
}) {
  if (depth >= autoCollapseDepth) return true;
  if (moveCount >= autoCollapseMoveThreshold) return true;
  return false;
}

/// Base hue per variation depth at full opacity. Callers pick alpha for
/// rail (0.9), label (1.0), or background tint (0.07).
Color _depthBaseColor(int depth) {
  switch (depth) {
    case 1:
      return kPrimaryColor; // cyan
    case 2:
      return const Color(0xFFEA45D8); // magenta
    case 3:
      return const Color(0xFFFABE46); // amber
    case 4:
      return const Color(0xFF45C86E); // green
    case 5:
      return const Color(0xFFF39FD5); // pink
    case 6:
      return const Color(0xFF9D7BFF); // violet
    default:
      return const Color(0xFFB8C4D0); // slate
  }
}

/// Subtle depth-tinted background used to visually bind every row inside a
/// variation block. Alpha is intentionally tiny — the eye reads "this
/// paragraph cluster belongs together" without the box dominating the page.
Color _depthBgColor(int depth) =>
    _depthBaseColor(depth).withValues(alpha: 0.045);

/// Branch label A/B/C... per variation index. Lowercase after 26, numeric
/// after 52 — keeps a single short token even in absurd trees.
String _branchLabel(int variationIndex) {
  if (variationIndex < 26) {
    return String.fromCharCode(65 + variationIndex);
  }
  if (variationIndex < 52) {
    return String.fromCharCode(97 + (variationIndex - 26));
  }
  return '${variationIndex - 51}';
}

/// Compact clock display from `[%clk H:MM:SS]`: drops leading zero hour,
/// shows `M:SS` under a minute. Returns null when input is null/empty.
String? _formatClockChip(String? clockTime) {
  if (clockTime == null || clockTime.isEmpty) return null;
  final parts = clockTime.trim().split(':');
  if (parts.length == 3) {
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2]) ?? 0;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}';
    if (m > 0) return '$m:${s.toString().padLeft(2, '0')}';
    return '0:${s.toString().padLeft(2, '0')}';
  }
  return clockTime.trim();
}

/// Total seconds remaining at a `[%clk H:MM:SS]` annotation. Returns
/// null on parse failure. Used by the chip badge to colour clocks under
/// 30s red — the visual cue chess masters use to spot time-pressure
/// blunders when reviewing a game.
int? _clockSeconds(String? clockTime) {
  if (clockTime == null || clockTime.isEmpty) return null;
  final parts = clockTime.trim().split(':');
  if (parts.length == 3) {
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return h * 3600 + m * 60 + s;
  }
  if (parts.length == 2) {
    final m = int.tryParse(parts[0]);
    final s = int.tryParse(parts[1]);
    if (m == null || s == null) return null;
    return m * 60 + s;
  }
  return null;
}

/// Result chip text from PGN headers. Returns "1–0", "0–1", "½–½", or
/// null when game isn't decided.
String? _formatGameResult(String? raw) {
  if (raw == null) return null;
  switch (raw.trim()) {
    case '1-0':
      return '1–0';
    case '0-1':
      return '0–1';
    case '1/2-1/2':
      return '½–½';
    case '*':
      return null;
    default:
      return null;
  }
}

int? _nagForLichessAnnotation(LichessMoveAnnotationType type) {
  switch (type) {
    case LichessMoveAnnotationType.brilliant:
      return 3;
    case LichessMoveAnnotationType.missedWin:
      return 4;
    case LichessMoveAnnotationType.blunder:
      return 4;
    case LichessMoveAnnotationType.mistake:
      return 2;
    case LichessMoveAnnotationType.inaccuracy:
      return 6;
    case LichessMoveAnnotationType.goodMove:
      return 1;
    case LichessMoveAnnotationType.bestMove:
      return 1;
    case LichessMoveAnnotationType.bookMove:
      return null;
  }
}

List<int> _mergedMainlineNagsFor({
  required int ply,
  required List<int> baseNags,
  required Map<int, LichessMoveAnnotation> lichessAnnotations,
  required Map<int, List<int>> userNags,
}) {
  final lichess = lichessAnnotations[ply];
  final lichessNag =
      lichess == null ? null : _nagForLichessAnnotation(lichess.type);
  final user = userNags[ply] ?? const <int>[];
  final userHasQuality = user.any((n) => n >= 1 && n <= 7);
  final out = <int>[];
  final seen = <int>{};

  void addAll(Iterable<int> source) {
    for (final n in source) {
      if (seen.add(n)) out.add(n);
    }
  }

  addAll(baseNags);
  if (lichessNag != null && !userHasQuality) {
    addAll(<int>[lichessNag]);
  }
  addAll(user);
  return out;
}

List<InlineSpan> _sanSpans(
  String san, {
  required TextStyle style,
  required bool useFigurine,
  required PieceAssets? pieceAssets,
  required double pieceSize,
}) {
  if (!useFigurine || pieceAssets == null) {
    return <InlineSpan>[TextSpan(text: san, style: style)];
  }
  return _buildDesktopFigurineSpans(
    text: san,
    pieceAssets: pieceAssets,
    style: style,
    pieceSize: pieceSize,
  );
}

String _inlineMovePrefix(
  int ply, {
  required bool isLineStart,
  bool forceBlackMoveNumber = false,
}) {
  final moveNumber = (ply ~/ 2) + 1;
  if (ply.isEven) return '$moveNumber.';
  return isLineStart || forceBlackMoveNumber ? '$moveNumber...' : '';
}

List<InlineSpan> _buildDesktopFigurineSpans({
  required String text,
  required PieceAssets pieceAssets,
  required TextStyle style,
  required double pieceSize,
}) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flushBuffer() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString(), style: style));
    buffer.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final pieceKind = pieceLetterToKind[char];
    if (pieceKind == null) {
      buffer.write(char);
      continue;
    }

    flushBuffer();
    final pieceImage = pieceAssets[pieceKind];
    if (pieceImage == null) {
      buffer.write(char);
      continue;
    }

    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 1),
          child: Builder(
            builder: (context) {
              final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
              final cachePx = (pieceSize * dpr).ceil();
              return Image(
                image: ResizeImage.resizeIfNeeded(cachePx, cachePx, pieceImage),
                width: pieceSize,
                height: pieceSize,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                isAntiAlias: true,
              );
            },
          ),
        ),
      ),
    );
  }

  flushBuffer();
  return spans;
}

/// Encode a stable signature of the tree's *shape* — used to drop manual
/// collapse state when the underlying game changes (PGN reloaded, new
/// variations grown, etc). Walks every variation so any insertion or
/// deletion shifts the signature.
String _treeSignature(ChessLine mainline) {
  final buf = StringBuffer();
  void walk(ChessLine line) {
    for (final m in line) {
      buf.write(m.uci);
      buf.write('|');
      final vars = m.variations;
      if (vars != null) {
        for (var v = 0; v < vars.length; v++) {
          buf.write('[');
          walk(vars[v]);
          buf.write(']');
        }
      }
    }
  }

  walk(mainline);
  return buf.toString();
}

/// Walk the active pointer prefix and emit the encoded ID of every
/// variation we step into. These IDs name `[…, varIdx, 0]` heads so they
/// match what `_VariationBlock` registers — keeping the variation that
/// holds the cursor (and all its ancestors) force-expanded.
Set<String> _ancestorVariationIds(ChessMovePointer pointer) {
  if (pointer.length < 3) return const <String>{};
  final out = <String>{};
  for (var i = 1; i < pointer.length; i += 2) {
    // Variation index sits at odd positions; head pointer is the prefix
    // ending in [..., varIdx, 0]. If the active pointer is exactly that
    // visible head, keep the branch foldable/collapsed; only force-open
    // true ancestors that contain a deeper cursor.
    final headEnd = i + 2;
    if (headEnd == pointer.length) continue;
    final headPointer = <int>[...pointer.sublist(0, i + 1), 0];
    out.add(NotationPointer.encode(headPointer));
  }
  return out;
}

/// Enumerate every variation head id under `mainline` so the
/// "Collapse all" / "Expand all" header buttons can flip them in bulk.
Set<String> _allCollapsibleVariationIds(ChessLine mainline) {
  final out = <String>{};
  void walk(ChessLine line, ChessMovePointer prefix) {
    for (var i = 0; i < line.length; i++) {
      final move = line[i];
      final movePointer = <int>[...prefix, i];
      final vars = move.variations;
      if (vars == null) continue;
      for (var v = 0; v < vars.length; v++) {
        final variationPrefix = <int>[...movePointer, v];
        final headId = NotationPointer.encode(<int>[...variationPrefix, 0]);
        out.add(headId);
        walk(vars[v], variationPrefix);
      }
    }
  }

  walk(mainline, const <int>[]);
  return out;
}

List<String> _cleanPgnComments(List<String>? comments) {
  if (comments == null || comments.isEmpty) return const <String>[];
  final out = <String>[];
  for (final comment in comments) {
    final clean =
        comment
            .replaceAll(_sourceDirectiveRegex, '')
            .replaceAll(RegExp(r'\[%clk\s+[^\]]+\]'), '')
            .replaceAll(RegExp(r'\[%eval\s+[^\]]+\]'), '')
            .replaceAll(RegExp(r'\[%cal\s+[^\]]+\]'), '')
            .replaceAll(RegExp(r'\[%csl\s+[^\]]+\]'), '')
            .replaceAll(RegExp(r'\[%emt\s+[^\]]+\]'), '')
            .replaceAll(RegExp(r'\[%tag\s+[^\]]+\]'), '')
            .trim();
    if (clean.isNotEmpty) out.add(clean);
  }
  return out;
}

String? _sourceLabelFromComments(List<String>? comments) {
  if (comments == null || comments.isEmpty) return null;
  for (final comment in comments) {
    final match = _sourceDirectiveRegex.firstMatch(comment);
    final label = match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label != null && label.isNotEmpty) return label;
  }
  return null;
}

String _sourceMetadataDisplay(String sourceLabel) {
  final parts = sourceLabel
      .split(',')
      .map((part) => part.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return sourceLabel.trim();
  return parts.join(' · ');
}

String? _firstPgnComment(List<String>? comments) {
  final cleaned = _cleanPgnComments(comments);
  return cleaned.isEmpty ? null : cleaned.first;
}

final _sourceDirectiveRegex = RegExp(r'\[%src\s+([^\]]+)\]');

/// Structured game-header payload encoded by the explorer/games-table when
/// it inserts a continuation into the active board. Carries the data needed
/// to render a reference-style "1-0 (38) Sindarov,J (2776) − Gukesh,D (2732)
/// Warsaw 2026" footer instead of a plain flat label.
class _GameSourceMetadata {
  const _GameSourceMetadata({
    this.result,
    this.plies,
    this.whiteName,
    this.whiteElo,
    this.whiteTitle,
    this.whiteFed,
    this.blackName,
    this.blackElo,
    this.blackTitle,
    this.blackFed,
    this.event,
    this.site,
    this.round,
    this.year,
  });

  final String? result;
  final int? plies;
  final String? whiteName;
  final int? whiteElo;
  final String? whiteTitle;
  final String? whiteFed;
  final String? blackName;
  final int? blackElo;
  final String? blackTitle;
  final String? blackFed;
  final String? event;
  final String? site;
  final String? round;
  final String? year;

  bool get hasAnyPlayer => whiteName != null || blackName != null;
  bool get hasAnyVenue => event != null || site != null || year != null;

  /// Resolve the headline result chip text. Normalises hyphen-minus to
  /// the en-dash version so the footer matches the trailing
  /// `_GameResultRow` chip in the ladder.
  String? get resultChip {
    final raw = result;
    if (raw == null) return null;
    switch (raw.trim()) {
      case '1-0':
        return '1–0';
      case '0-1':
        return '0–1';
      case '1/2-1/2':
      case '½-½':
        return '½–½';
      case '*':
        return null;
      default:
        return raw.trim();
    }
  }

  /// Plain text version a screen reader / clipboard copy can ingest. Mirrors
  /// the visual rendering as closely as possible without colour tinting.
  String toPlainText() {
    final out = StringBuffer();
    final r = resultChip;
    if (r != null) out.write(r);
    if (plies != null) {
      if (out.isNotEmpty) out.write(' ');
      out.write('(${plies!})');
    }
    final players = _playerPairLine();
    if (players.isNotEmpty) {
      if (out.isNotEmpty) out.write(' ');
      out.write(players);
    }
    final venue = _venueLine();
    if (venue.isNotEmpty) {
      if (out.isNotEmpty) out.write(' ');
      out.write(venue);
    }
    return out.toString();
  }

  String _playerPairLine() {
    String formatSide(String? name, int? elo) {
      if (name == null) return '';
      return elo == null ? name : '$name ($elo)';
    }

    final w = formatSide(whiteName, whiteElo);
    final b = formatSide(blackName, blackElo);
    if (w.isEmpty && b.isEmpty) return '';
    if (w.isEmpty) return b;
    if (b.isEmpty) return w;
    return '$w − $b';
  }

  String _venueLine() {
    final parts = <String>[
      if (event != null) event!,
      if (site != null && site != event) site!,
      if (round != null) 'Round $round',
      if (year != null) year!,
    ];
    return parts.join(' · ');
  }
}

_GameSourceMetadata? _tryParseGameSourceMetadata(String sourceLabel) {
  // Structured payload is `key=value|key=value|...`. Fall back to null when
  // the directive carries the legacy flat "white vs black, event, year"
  // string so the existing `_SourceMetadataPill` rendering still applies.
  if (!sourceLabel.contains('=')) return null;
  final map = <String, String>{};
  for (final entry in sourceLabel.split('|')) {
    final eq = entry.indexOf('=');
    if (eq <= 0 || eq == entry.length - 1) continue;
    final key = entry.substring(0, eq).trim();
    final value = entry.substring(eq + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    map[key] = value;
  }
  if (map.isEmpty) return null;

  int? readInt(String key) {
    final raw = map[key];
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  final meta = _GameSourceMetadata(
    result: map['result'],
    plies: readInt('plies'),
    whiteName: map['white'],
    whiteElo: readInt('whiteElo'),
    whiteTitle: map['whiteTitle'],
    whiteFed: map['whiteFed'],
    blackName: map['black'],
    blackElo: readInt('blackElo'),
    blackTitle: map['blackTitle'],
    blackFed: map['blackFed'],
    event: map['event'],
    site: map['site'],
    round: map['round'],
    year: map['year'],
  );
  if (!meta.hasAnyPlayer && !meta.hasAnyVenue && meta.resultChip == null) {
    return null;
  }
  return meta;
}

Color _resultChipTint(String? chip) {
  switch (chip) {
    case '1–0':
      return kPrimaryColor;
    case '0–1':
      return const Color(0xFFFF8A65);
    case '½–½':
      return const Color(0xFF9AA3AD);
    default:
      return kWhiteColor70;
  }
}
