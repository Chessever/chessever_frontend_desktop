import 'dart:async';
import 'dart:io' show Platform;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/utils/list_keyboard_nav.dart';
import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/explorer_filter_bar.dart';
import 'package:chessever/desktop/widgets/explorer_filters_popover.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/variation_fork_chooser.dart';
import 'package:chessever/screens/gamebase/models/move_aggregate.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';

/// Per-board-tab active page index for the right-rail Notation / Explorer /
/// Games tab strip. Survives board-tab switches so the user returns to the
/// page they were last on. Keyed by the board tab id; falls back to a shared
/// `__none__` slot for the scratch board / pre-tab boots.
final rightRailActivePageProvider = StateProvider.family<int, String>(
  (ref, _) => 0,
);

class ExplorerContinuationInsertion {
  const ExplorerContinuationInsertion({required this.ucis, this.sourceLabel});

  final List<String> ucis;
  final String? sourceLabel;
}

/// Three-page panel that lives in the right rail of the Board pane:
/// page 0 = move notation (caller-supplied), page 1 = opening explorer,
/// page 2 = indexed games for the current position.
///
/// Mirrors the mobile `_AnalysisSwipePanels` (chess_board_screen_new.dart),
/// adapted for desktop ergonomics: a forui-feel segmented switcher pinned
/// to the top so mouse users can click between pages, plus the underlying
/// `PageView` so trackpad swipes work too.
///
/// The opening explorer uses the existing `gamebaseExplorerProvider`
/// directly — we feed the current FEN + UCI move-list-up-to-cursor in a
/// `useEffect`-style listener. The Explorer page keeps the opening move table
/// on the left and the indexed games table on the right.
class NotationOpeningPanel extends ConsumerStatefulWidget {
  const NotationOpeningPanel({
    super.key,
    required this.notationChild,
    required this.currentFen,
    required this.startingFen,
    required this.lineUcis,
    required this.onPlayUciMove,
    this.onPlayEngineMove,
    this.onPlayUciLine,
    this.previewLineStep = 0,
    this.previewLineAutoplay = false,
    this.onPreviewUciMove,
    this.onPreviewUciLine,
    this.onClearPreviewUciMove,
    this.tabId,
    this.explorerScope,
    this.onNotationVertical,
    this.onNotationStep,
    this.onNotationJumpToHead,
    this.onNotationJumpToTip,
    this.canGoBack = false,
    this.canGoForward = false,
    this.onFirstMove,
    this.onPreviousMove,
    this.onNextMove,
    this.onLastMove,
    this.onPreviousGame,
    this.onNextGame,
    this.trailingActions,
  });

  /// Board tab id used to persist the active right-rail page. Null routes to
  /// the shared scratch slot so freeplay / pre-tab boots still remember the
  /// last-active page across rebuilds.
  final String? tabId;

  /// Optional fixed player scope for profile Build Tree tabs. When present,
  /// the explorer keeps the move table and position-games table restricted to
  /// that player's games while still allowing normal time/rating/result filters.
  final BoardExplorerScope? explorerScope;

  /// The notation widget rendered on page 0. Built by the caller so this
  /// panel doesn't have to know about the desktop board's _Ply / history.
  final Widget notationChild;

  /// Up/Down arrow handling for the Notation tab. Called when the user
  /// presses ↑ / ↓ while the Notation page has focus, so the host can move
  /// the active pointer to the visually adjacent move row.
  final ValueChanged<NotationVerticalDirection>? onNotationVertical;

  /// Left/Right step (+1 / -1). When set, the Notation tab consumes the
  /// horizontal arrows so the highlight cursor stays inside the ladder
  /// instead of bouncing through the outer BoardPane shortcuts.
  final bool Function(int delta)? onNotationStep;

  /// Home key handler for the Notation tab — jumps to the first ply.
  final VoidCallback? onNotationJumpToHead;

  /// End key handler for the Notation tab — jumps to the tip / last ply.
  final VoidCallback? onNotationJumpToTip;

  /// Optional board navigation controls rendered in the bottom strip while
  /// the Explorer is open.
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onFirstMove;
  final VoidCallback? onPreviousMove;
  final VoidCallback? onNextMove;
  final VoidCallback? onLastMove;
  final VoidCallback? onPreviousGame;
  final VoidCallback? onNextGame;

  /// Optional compact actions shown on the right side of the top tab strip.
  /// Used by the desktop board to keep Save / Play-from-here / Info visible
  /// without consuming a separate board chrome row.
  final Widget? trailingActions;

  final String currentFen;
  final String startingFen;

  /// UCI moves played from `startingFen` up to (and including) the ply at
  /// the user's current cursor. Used by the explorer for deep aggregation
  /// past the indexed opening window.
  final List<String> lineUcis;

  /// Board-side cursor inside the transient game-continuation preview. The
  /// games tables use this to show which inline notation move is currently
  /// displayed while Space-driven autoplay is running.
  final int previewLineStep;

  /// True while the board is advancing a game-continuation preview by timer.
  final bool previewLineAutoplay;

  /// Called when the user activates a move row in the Explorer move table.
  /// The string is raw UCI ("e2e4", "e7e8q"); the caller applies it to the
  /// active board.
  final void Function(String uci) onPlayUciMove;

  /// Called for the global "play top engine move" shortcut while focus is
  /// inside any right-rail tab. Handling it here keeps Space reliable even
  /// when nested tab focus nodes would otherwise stop shortcut bubbling.
  final VoidCallback? onPlayEngineMove;

  /// Called when a game-table inline continuation should be inserted into
  /// the current notation tree. The list is the continuation prefix from
  /// the current board position through the focused inline move, plus a
  /// compact source-game label for notation comments.
  final ValueChanged<ExplorerContinuationInsertion>? onPlayUciLine;

  /// Called while keyboard/mouse focus moves over an Explorer candidate move.
  /// The board pane uses this to preview the resulting position without
  /// committing the move to the notation tree.
  final void Function(String uci)? onPreviewUciMove;

  /// Called while keyboard/mouse focus moves over an Explorer game row.
  /// The board pane animates this continuation from the current position,
  /// advancing ply-by-ply until the supplied line is exhausted.
  final PreviewUciLineCallback? onPreviewUciLine;

  /// Clears any transient Explorer move preview.
  final VoidCallback? onClearPreviewUciMove;

  @override
  ConsumerState<NotationOpeningPanel> createState() =>
      _NotationOpeningPanelState();
}

class _NotationOpeningPanelState extends ConsumerState<NotationOpeningPanel> {
  // One FocusScopeNode per page so the focus state of each tab survives
  // a switch. When the user flicks back to the Explorer tab, the last
  // focused row is restored automatically without an extra request.
  final List<FocusScopeNode> _pageScopes = List<FocusScopeNode>.generate(
    3,
    (i) => FocusScopeNode(debugLabel: 'right-rail-page-$i'),
    growable: false,
  );
  final FocusNode _notationFocusNode = FocusNode(debugLabel: 'notation-page');
  late int _page = _readStoredPage();
  bool _buildExplorerPage = false;
  int _pageRestoreToken = 0;

  String get _storeKey => widget.tabId ?? '__none__';

  int _readStoredPage() {
    final raw = ref.read(rightRailActivePageProvider(_storeKey));
    return raw.clamp(0, 2);
  }

  void _writeStoredPage(int page) {
    ref.read(rightRailActivePageProvider(_storeKey).notifier).state = page
        .clamp(0, 2);
  }

  @override
  void initState() {
    super.initState();
    _rememberBuiltPage(_page);
  }

  void _rememberBuiltPage(int page) {
    if (page > 0) _buildExplorerPage = true;
  }

  void _setCurrentPage(int page) {
    _page = page.clamp(0, 2);
    _rememberBuiltPage(_page);
  }

  @override
  void didUpdateWidget(covariant NotationOpeningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final positionChanged =
        _positionKey(oldWidget.currentFen) != _positionKey(widget.currentFen) ||
        _positionKey(oldWidget.startingFen) !=
            _positionKey(widget.startingFen) ||
        !_listEquals(oldWidget.lineUcis, widget.lineUcis);
    // Tab id changed → hop to the page that was active for the new board
    // tab (or 0 if it hasn't been visited before). Without this the panel
    // would carry over `_page` from the previously-shown board tab.
    if (oldWidget.tabId != widget.tabId) {
      final stored = _readStoredPage();
      if (stored != _page) {
        setState(() => _setCurrentPage(stored));
        _focusActivePage();
      }
    } else if (positionChanged) {
      // A board move rebuilds this right rail. Keep whichever right-rail page
      // currently owns the keyboard instead of letting focus fall back to the
      // notation page's default scope. When the user is on Explorer or Games
      // (page 1/2), lock the page over the next few frames so the rebuild
      // storm triggered by board state, focus restore, and async pumps cannot
      // accidentally flip the tab back to Notation; this mirrors the safety
      // that explorer-move clicks already get via `_playUciMoveAndKeepActivePage`.
      if (_page != 0) {
        _restorePageAfterMutation(_page);
      } else {
        _writeStoredPage(_page);
        _focusActivePage();
      }
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _notationFocusNode.dispose();
    for (final scope in _pageScopes) {
      scope.dispose();
    }
    super.dispose();
  }

  void _focusActivePage() {
    final node = _page == 0 ? _notationFocusNode : _pageScopes[1];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      node.requestFocus();
    });
  }

  void _ensurePageActive(int page, {bool force = false}) {
    final next = page.clamp(0, 2);
    final pageChanged = _page != next;
    if (pageChanged) {
      setState(() => _setCurrentPage(next));
    }
    _writeStoredPage(next);
    _focusActivePage();
  }

  void _activateNotation() => _ensurePageActive(0);

  void _keepExplorerActive() => _ensurePageActive(1);

  void _keepGamesActive() => _ensurePageActive(2);

  void _cancelPageRestoreLock() {
    _pageRestoreToken++;
  }

  void _restorePageAfterMutation(int page) {
    final next = page.clamp(0, 2);
    final token = ++_pageRestoreToken;

    void restore() {
      if (!mounted || token != _pageRestoreToken) return;
      _ensurePageActive(next, force: true);
    }

    void restoreAfterFrames(int frames) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        restore();
        if (!mounted || token != _pageRestoreToken) return;
        if (frames > 1) {
          restoreAfterFrames(frames - 1);
          return;
        }
      });
    }

    restore();
    restoreAfterFrames(3);
  }

  void _playUciMoveAndKeepActivePage(String uci) {
    final pageBeforePlay = _page;
    widget.onPlayUciMove(uci);
    if (!mounted) return;
    _restorePageAfterMutation(pageBeforePlay);
  }

  void _insertUciLineAndKeepActivePage(
    ExplorerContinuationInsertion insertion,
  ) {
    final pageBeforeInsert = _page;
    widget.onPlayUciLine?.call(insertion);
    if (!mounted) return;
    // Inserting a continuation mutates the board/notation state, but it should
    // not override the right-rail page the user explicitly selected. Keep the
    // active tab stable; the user can switch to Notation manually when desired.
    _restorePageAfterMutation(pageBeforeInsert);
  }

  void _go(int page, {bool persist = true}) {
    if (page == _page) return;
    _cancelPageRestoreLock();
    setState(() => _setCurrentPage(page));
    if (persist) _writeStoredPage(page);
    _focusActivePage();
  }

  void _goRelative(int delta) {
    final next = (_page + delta).clamp(0, 2);
    _go(next);
  }

  KeyEventResult _handleRailKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space && !_hasAnyModifierPressed()) {
      if (widget.onPlayEngineMove == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) widget.onPlayEngineMove!.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && !_hasAnyModifierPressed()) {
      if (event is KeyDownEvent) {
        if ((_buildExplorerPage || _page > 0) && _page > 0) {
          _go(0);
        } else {
          _go(1);
        }
      }
      return KeyEventResult.handled;
    }
    final hasModifier = _hasAnyModifierPressed();
    // Bare ←/→ must step notation on every right-rail page, never switch the
    // top-level tab. Inner Explorer/Games Focus normally handles these first
    // (table-row navigation, game-continuation step) and returns `handled`,
    // so this branch only fires when their Focus isn't the leaf — without it
    // the event would bubble to the global Shortcuts map where a remapped or
    // chord-matching activator could flip the rail tab back to Notation.
    if (!hasModifier) {
      if (key == LogicalKeyboardKey.arrowRight) {
        widget.onNotationStep?.call(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        widget.onNotationStep?.call(-1);
        return KeyEventResult.handled;
      }
    }
    if (hasModifier) {
      if (_isRightRailNextTabChord(event)) {
        _goRelative(1);
        return KeyEventResult.handled;
      }
      if (_isRightRailPreviousTabChord(event)) {
        _goRelative(-1);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _showGamesForMove(String uci) {
    setState(() {
      _setCurrentPage(2);
    });
    _writeStoredPage(2);
    _focusActivePage();
  }

  static String _positionKey(String fen) =>
      fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

  static bool _isInitialPositionFen(String fen) =>
      _positionKey(fen) == _positionKey(Chess.initial.fen);

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(rightRailActivePageProvider(_storeKey), (previous, next) {
      final page = next.clamp(0, 2);
      if (page != _page) _go(page, persist: false);
    });
    final explorerVisible = _buildExplorerPage || _page > 0;
    final buildExplorerPage = explorerVisible;
    final notationPane = FocusScope(
      node: _pageScopes[0],
      child: _NotationKeyboardArea(
        active: _page == 0,
        focusNode: _notationFocusNode,
        onActivate: _activateNotation,
        onVertical: widget.onNotationVertical,
        onStep: widget.onNotationStep,
        onJumpToHead: widget.onNotationJumpToHead,
        onJumpToTip: widget.onNotationJumpToTip,
        child: widget.notationChild,
      ),
    );
    final explorerPane = FocusScope(
      node: _pageScopes[1],
      child:
          buildExplorerPage
              ? _OpeningExplorerPage(
                active: explorerVisible,
                activeSection: _page,
                currentFen: widget.currentFen,
                startingFen: widget.startingFen,
                lineUcis: widget.lineUcis,
                previewLineStep: widget.previewLineStep,
                previewLineAutoplay: widget.previewLineAutoplay,
                onPlayUciMove: _playUciMoveAndKeepActivePage,
                onPlayUciLine:
                    widget.onPlayUciLine == null
                        ? null
                        : _insertUciLineAndKeepActivePage,
                onPreviewUciMove: widget.onPreviewUciMove,
                onPreviewUciLine: widget.onPreviewUciLine,
                onClearPreviewUciMove: widget.onClearPreviewUciMove,
                onShowGames: _showGamesForMove,
                onNotationStep: widget.onNotationStep,
                onKeepExplorerActive: _keepExplorerActive,
                onKeepGamesActive: _keepGamesActive,
                explorerScope: widget.explorerScope,
                exactFenSearch: !_isInitialPositionFen(widget.startingFen),
              )
              : const ColoredBox(color: kBlack2Color),
    );
    final buildTreeScoped = widget.explorerScope != null;
    return Focus(
      onKeyEvent: _handleRailKey,
      child: Container(
        color: kBlack2Color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child:
                  explorerVisible
                      ? ResizableSplitView(
                        axis: Axis.vertical,
                        storageKey:
                            buildTreeScoped
                                ? 'desktop.board.right-rail.notation-explorer-stack.build-tree.v1'
                                : 'desktop.board.right-rail.notation-explorer-stack.v1',
                        gutterThickness: 6,
                        children: [
                          SplitChild(
                            minSize: 150,
                            initialWeight: 0.42,
                            initialCollapsed: buildTreeScoped,
                            label: 'Notation',
                            collapsedIcon: Icons.format_list_numbered_rounded,
                            child: notationPane,
                          ),
                          SplitChild(
                            minSize: 220,
                            initialWeight: 0.58,
                            label: 'Explorer',
                            collapsedIcon: Icons.menu_book_outlined,
                            child: explorerPane,
                          ),
                        ],
                      )
                      : notationPane,
            ),
            _SegmentBar(
              explorerOpen: explorerVisible,
              onToggleExplorer: () {
                if (explorerVisible) {
                  setState(() {
                    _buildExplorerPage = false;
                    _setCurrentPage(0);
                  });
                  _writeStoredPage(0);
                  _focusActivePage();
                } else {
                  _go(1);
                }
              },
              explorerScope: widget.explorerScope,
              canGoBack: widget.canGoBack,
              canGoForward: widget.canGoForward,
              onFirstMove: widget.onFirstMove,
              onPreviousMove: widget.onPreviousMove,
              onNextMove: widget.onNextMove,
              onLastMove: widget.onLastMove,
              onPreviousGame: widget.onPreviousGame,
              onNextGame: widget.onNextGame,
              trailingActions: widget.trailingActions,
            ),
          ],
        ),
      ),
    );
  }
}

bool _isRightRailNextTabChord(KeyEvent event) {
  return debugIsRightRailNextTabChord(
    key: event.logicalKey,
    character: event.character,
    isMac: Platform.isMacOS,
    ctrl: _isControlPressed(),
    alt: _isAltPressed(),
    shift: HardwareKeyboard.instance.isShiftPressed,
    meta: _isMetaPressed(),
  );
}

bool _isRightRailPreviousTabChord(KeyEvent event) {
  return debugIsRightRailPreviousTabChord(
    key: event.logicalKey,
    character: event.character,
    isMac: Platform.isMacOS,
    ctrl: _isControlPressed(),
    alt: _isAltPressed(),
    shift: HardwareKeyboard.instance.isShiftPressed,
    meta: _isMetaPressed(),
  );
}

@visibleForTesting
bool debugIsRightRailNextTabChord({
  required LogicalKeyboardKey key,
  required bool isMac,
  String? character,
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
}) {
  if (alt && !ctrl && !meta && !shift) {
    return key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown;
  }
  if (shift && !ctrl && !alt && !meta) {
    return key == LogicalKeyboardKey.arrowDown;
  }
  final primary = isMac ? (meta && !ctrl) : (ctrl && !meta);
  if (!primary || alt) return false;
  return key == LogicalKeyboardKey.greater ||
      key == LogicalKeyboardKey.period ||
      key == LogicalKeyboardKey.arrowRight ||
      character == '>';
}

@visibleForTesting
bool debugIsRightRailPreviousTabChord({
  required LogicalKeyboardKey key,
  required bool isMac,
  String? character,
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
}) {
  if (alt && !ctrl && !meta && !shift) {
    return key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp;
  }
  if (shift && !ctrl && !alt && !meta) {
    return key == LogicalKeyboardKey.arrowUp;
  }
  final primary = isMac ? (meta && !ctrl) : (ctrl && !meta);
  if (!primary || alt) return false;
  return key == LogicalKeyboardKey.less ||
      key == LogicalKeyboardKey.comma ||
      key == LogicalKeyboardKey.arrowLeft ||
      character == '<';
}

class _SegmentBar extends ConsumerWidget {
  const _SegmentBar({
    required this.explorerOpen,
    required this.onToggleExplorer,
    required this.explorerScope,
    required this.canGoBack,
    required this.canGoForward,
    this.onFirstMove,
    this.onPreviousMove,
    this.onNextMove,
    this.onLastMove,
    this.onPreviousGame,
    this.onNextGame,
    this.trailingActions,
  });

  final bool explorerOpen;
  final VoidCallback onToggleExplorer;
  final BoardExplorerScope? explorerScope;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onFirstMove;
  final VoidCallback? onPreviousMove;
  final VoidCallback? onNextMove;
  final VoidCallback? onLastMove;
  final VoidCallback? onPreviousGame;
  final VoidCallback? onNextGame;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scopedPlayer = explorerScope?.player;
    final treeState =
        scopedPlayer == null
            ? null
            : ref.watch(playerOpeningTreeProvider(scopedPlayer.id));
    final hasNavigationControls =
        onFirstMove != null ||
        onPreviousMove != null ||
        onNextMove != null ||
        onLastMove != null ||
        onPreviousGame != null ||
        onNextGame != null;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border(top: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          _RailIconButton(
            icon: Icons.menu_book_outlined,
            tooltip: explorerOpen ? 'Hide Explorer' : 'Open Explorer',
            selected: explorerOpen,
            onTap: onToggleExplorer,
          ),
          if (explorerOpen) ...[
            const SizedBox(width: 8),
            ExplorerFiltersPopoverButton(
              compact: true,
              scopedPlayer: scopedPlayer,
            ),
          ],
          if (treeState != null) ...[
            const SizedBox(width: 8),
            PlayerOpeningTreeProgressChip(
              state: treeState,
              maxWidth: 230,
              onRetry:
                  () =>
                      ref
                          .read(
                            playerOpeningTreeProvider(
                              scopedPlayer!.id,
                            ).notifier,
                          )
                          .retry(),
            ),
          ],
          if (hasNavigationControls)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _ExplorerNavigationCluster(
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onFirstMove: onFirstMove,
                    onPreviousMove: onPreviousMove,
                    onNextMove: onNextMove,
                    onLastMove: onLastMove,
                    onPreviousGame: onPreviousGame,
                    onNextGame: onNextGame,
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          if (trailingActions != null) ...[
            if (hasNavigationControls) const SizedBox(width: 8),
            trailingActions!,
          ],
        ],
      ),
    );
  }
}

class _ExplorerNavigationCluster extends StatelessWidget {
  const _ExplorerNavigationCluster({
    required this.canGoBack,
    required this.canGoForward,
    this.onFirstMove,
    this.onPreviousMove,
    this.onNextMove,
    this.onLastMove,
    this.onPreviousGame,
    this.onNextGame,
  });

  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onFirstMove;
  final VoidCallback? onPreviousMove;
  final VoidCallback? onNextMove;
  final VoidCallback? onLastMove;
  final VoidCallback? onPreviousGame;
  final VoidCallback? onNextGame;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onPreviousGame != null) ...[
          _RailIconButton(
            icon: Icons.keyboard_double_arrow_left_rounded,
            tooltip: 'Previous game',
            onTap: onPreviousGame!,
          ),
          const SizedBox(width: 4),
        ],
        if (onFirstMove != null) ...[
          _RailIconButton(
            icon: Icons.first_page_rounded,
            tooltip: 'First move',
            enabled: canGoBack,
            onTap: onFirstMove!,
          ),
          const SizedBox(width: 4),
        ],
        if (onPreviousMove != null) ...[
          _RailIconButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous move',
            enabled: canGoBack,
            onTap: onPreviousMove!,
          ),
          const SizedBox(width: 4),
        ],
        if (onNextMove != null) ...[
          _RailIconButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next move',
            enabled: canGoForward,
            onTap: onNextMove!,
          ),
          const SizedBox(width: 4),
        ],
        if (onLastMove != null) ...[
          _RailIconButton(
            icon: Icons.last_page_rounded,
            tooltip: 'Last move',
            enabled: canGoForward,
            onTap: onLastMove!,
          ),
          const SizedBox(width: 4),
        ],
        if (onNextGame != null)
          _RailIconButton(
            icon: Icons.keyboard_double_arrow_right_rounded,
            tooltip: 'Next game',
            onTap: onNextGame!,
          ),
      ],
    );
  }
}

class _RailIconButton extends StatefulWidget {
  const _RailIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;
  final bool enabled;

  @override
  State<_RailIconButton> createState() => _RailIconButtonState();
}

class _RailIconButtonState extends State<_RailIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && (widget.selected || _hovered);
    return DesktopTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor:
            widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
        onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  active
                      ? kPrimaryColor.withValues(alpha: 0.16)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    widget.selected
                        ? kPrimaryColor.withValues(alpha: 0.55)
                        : Colors.transparent,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color:
                  widget.enabled
                      ? (widget.selected ? kPrimaryColor : kWhiteColor70)
                      : kLightGreyColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Page 1 — in-game explorer. Pumps the board's current position + UCI line
/// into `gamebaseExplorerProvider`, then renders the games table beside an
/// inline notation pane. The notation side gets the larger default width so
/// SAN tokens, comments, and variation markers do not collapse on common
/// right-rail sizes.
class _OpeningExplorerPage extends ConsumerStatefulWidget {
  const _OpeningExplorerPage({
    required this.active,
    required this.activeSection,
    required this.currentFen,
    required this.startingFen,
    required this.lineUcis,
    required this.previewLineStep,
    required this.previewLineAutoplay,
    required this.onPlayUciMove,
    required this.onPlayUciLine,
    required this.onPreviewUciMove,
    required this.onPreviewUciLine,
    required this.onClearPreviewUciMove,
    required this.onShowGames,
    required this.onNotationStep,
    required this.onKeepExplorerActive,
    required this.onKeepGamesActive,
    required this.explorerScope,
    this.exactFenSearch = false,
  });

  final String currentFen;
  final String startingFen;
  final List<String> lineUcis;
  final bool active;
  final int activeSection;
  final int previewLineStep;
  final bool previewLineAutoplay;
  final void Function(String uci) onPlayUciMove;
  final ValueChanged<ExplorerContinuationInsertion>? onPlayUciLine;
  final void Function(String uci)? onPreviewUciMove;
  final PreviewUciLineCallback? onPreviewUciLine;
  final VoidCallback? onClearPreviewUciMove;
  final void Function(String uci) onShowGames;
  final bool Function(int delta)? onNotationStep;
  final VoidCallback onKeepExplorerActive;
  final VoidCallback onKeepGamesActive;
  final BoardExplorerScope? explorerScope;
  final bool exactFenSearch;

  @override
  ConsumerState<_OpeningExplorerPage> createState() =>
      _OpeningExplorerPageState();
}

class _OpeningExplorerPageState extends ConsumerState<_OpeningExplorerPage>
    with AutomaticKeepAliveClientMixin<_OpeningExplorerPage> {
  String _lastSyncedKey = '';
  final FocusNode _focusNode = FocusNode(debugLabel: 'opening-explorer-page');
  late final DesktopPositionGamesTableController _gamesController =
      DesktopPositionGamesTableController()
        ..addListener(_onGamesControllerChanged);
  int _moveCount = 0;
  List<MoveAggregate> _sortedAggs = const <MoveAggregate>[];
  _ExplorerTableFocus _activeTable = _ExplorerTableFocus.moves;
  int _focusedMoveIndex = -1;
  int _focusedGameIndex = -1;
  int _focusedGameMoveIndex = -1;
  bool _focusedGameAutoplaying = false;
  bool _pendingGamesFocus = false;
  bool _gamesControllerReconcileScheduled = false;

  @override
  bool get wantKeepAlive => true;

  void _syncProvider({bool force = false}) {
    if (!widget.active) return;
    // Same shape mobile uses: starting FEN + line of UCIs up to cursor.
    // Sanitise here too (the provider also sanitises) so our cache key
    // matches what the provider stores.
    final sanitised = widget.lineUcis
        .map((m) => m.trim().toLowerCase())
        .where((m) => RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$').hasMatch(m))
        .toList(growable: false);
    final scopeKey = widget.explorerScope?.identityKey ?? '';
    final key = '${widget.currentFen}|${sanitised.join(' ')}|$scopeKey';
    if (!force && key == _lastSyncedKey) return;
    _lastSyncedKey = key;
    // Defer to next microtask so we don't notify a provider during build.
    Future.microtask(() {
      if (!mounted || !widget.active) return;
      final notifier = ref.read(gamebaseExplorerProvider.notifier);
      final scope = widget.explorerScope;
      final appliedScopeKey = ref.read(appliedBoardExplorerScopeKeyProvider);
      final scopedFilters = boardExplorerFiltersForScope(
        scope: scope,
        currentFilters: ref.read(gamebaseExplorerProvider).filters,
        appliedScopeKey: appliedScopeKey,
      );
      if (scopedFilters != null) {
        notifier.updateFilters(scopedFilters);
      }
      ref.read(appliedBoardExplorerScopeKeyProvider.notifier).state =
          scope?.identityKey;
      notifier.setPositionWithMoves(
        widget.currentFen,
        sanitised,
        startingFen: widget.startingFen,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _syncProvider();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.active && widget.activeSection > 0) _keepExplorerFocus();
    });
  }

  void _focusRequestedSection({bool requestFocus = true}) {
    if (!widget.active) return;
    if (widget.activeSection == 2) {
      _focusGamesPane(requestFocus: requestFocus);
    } else if (widget.activeSection == 1) {
      _focusMovesPane(requestFocus: requestFocus);
    }
  }

  @override
  void didUpdateWidget(covariant _OpeningExplorerPage old) {
    super.didUpdateWidget(old);
    if (!old.active && widget.active) {
      _syncProvider(force: true);
      _focusRequestedSection(requestFocus: false);
    } else if (old.activeSection != widget.activeSection && widget.active) {
      _focusRequestedSection(requestFocus: false);
    }
    final oldScopeKey = old.explorerScope?.identityKey;
    final nextScopeKey = widget.explorerScope?.identityKey;
    if (old.currentFen != widget.currentFen ||
        old.startingFen != widget.startingFen ||
        !_listEquals(old.lineUcis, widget.lineUcis) ||
        oldScopeKey != nextScopeKey) {
      widget.onClearPreviewUciMove?.call();
      _pendingGamesFocus = false;
      _activeTable = _ExplorerTableFocus.moves;
      _focusedMoveIndex = -1;
      _focusedGameIndex = -1;
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
      _moveCount = 0;
      _gamesController.select(null);
      _syncProvider();
      if (widget.active && widget.activeSection > 0) {
        _keepExplorerFocusAfterFrame();
      }
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    widget.onClearPreviewUciMove?.call();
    _gamesController
      ..removeListener(_onGamesControllerChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onGamesControllerChanged() {
    if (!mounted) return;
    if (_gamesControllerReconcileScheduled) return;
    _gamesControllerReconcileScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamesControllerReconcileScheduled = false;
      if (!mounted) return;
      _reconcileGamesController();
    });
  }

  void _reconcileGamesController() {
    if (_pendingGamesFocus && _gamesController.rowCount > 0) {
      _pendingGamesFocus = false;
      _focusGamesRow(0);
      return;
    }
    if (_focusedGameIndex >= _gamesController.rowCount) {
      setState(() {
        _focusedGameIndex = -1;
        _focusedGameMoveIndex = -1;
        _focusedGameAutoplaying = false;
      });
      _gamesController.select(null);
    } else if (_activeTable == _ExplorerTableFocus.games) {
      _syncGamesSelection(_focusedGameIndex);
      setState(() {});
    }
  }

  void _requestExplorerFocus() {
    if (!widget.active) return;
    _focusNode.requestFocus();
  }

  void _keepExplorerFocus() {
    if (!mounted || !widget.active) return;
    if (_activeTable == _ExplorerTableFocus.games) {
      widget.onKeepGamesActive();
    } else {
      widget.onKeepExplorerActive();
    }
    _requestExplorerFocus();
  }

  void _keepExplorerFocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      _keepExplorerFocus();
    });
  }

  void _activateExplorerMove(String uci) {
    _keepExplorerFocus();
    widget.onClearPreviewUciMove?.call();
    widget.onPlayUciMove(uci);
    _keepExplorerFocusAfterFrame();
  }

  void _stepNotationBack() {
    widget.onNotationStep?.call(-1);
    _keepExplorerFocus();
  }

  void _previewGameLine(List<String> ucis, {bool autoplay = true, int? step}) {
    if (_activeTable != _ExplorerTableFocus.games || ucis.isEmpty) {
      widget.onClearPreviewUciMove?.call();
      return;
    }
    widget.onPreviewUciLine?.call(ucis, autoplay: autoplay, step: step);
  }

  void _focusMovesPane({int? index, bool requestFocus = true}) {
    _pendingGamesFocus = false;
    final hadFocus = _focusedMoveIndex >= 0;
    final next =
        index ?? (hadFocus ? _focusedMoveIndex : (_moveCount > 0 ? 0 : -1));
    setState(() {
      _activeTable = _ExplorerTableFocus.moves;
      _focusedMoveIndex = next.clamp(-1, _moveCount - 1).toInt();
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
    _gamesController.select(null, clearPreview: false);
    if (requestFocus) _keepExplorerFocus();
  }

  void _focusGamesPane({int? index, bool requestFocus = true}) {
    widget.onClearPreviewUciMove?.call();
    if (_gamesController.rowCount <= 0) {
      _pendingGamesFocus = true;
      setState(() {
        _activeTable = _ExplorerTableFocus.games;
        _focusedGameIndex = -1;
        _focusedGameMoveIndex = -1;
        _focusedGameAutoplaying = false;
      });
      _gamesController.select(null, clearPreview: false);
      if (requestFocus) _keepExplorerFocus();
      return;
    }
    final next = index ?? (_focusedGameIndex >= 0 ? _focusedGameIndex : 0);
    setState(() {
      _activeTable = _ExplorerTableFocus.games;
      _focusedGameIndex = next.clamp(0, _gamesController.rowCount - 1).toInt();
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
    _syncGamesSelection(_focusedGameIndex);
    if (requestFocus) _keepExplorerFocus();
  }

  void _focusGamesRow(int next) {
    _focusGamesPane(index: next < 0 ? -1 : next);
  }

  void _setFocusedMoveIndex(int next) {
    if (next == _focusedMoveIndex &&
        _activeTable == _ExplorerTableFocus.moves) {
      _gamesController.select(null, clearPreview: false);
      return;
    }
    setState(() {
      _activeTable = _ExplorerTableFocus.moves;
      _focusedMoveIndex = next;
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
    _gamesController.select(null, clearPreview: false);
  }

  void _setFocusedGameIndex(int next) {
    widget.onClearPreviewUciMove?.call();
    if (next == _focusedGameIndex &&
        _activeTable == _ExplorerTableFocus.games) {
      _syncGamesSelection(next);
      return;
    }
    setState(() {
      _activeTable = _ExplorerTableFocus.games;
      _focusedGameIndex = next;
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
    _syncGamesSelection(next);
  }

  void _moveFocusedGameRow(int delta, {bool keepInlineMoveFocus = false}) {
    final total = _gamesController.rowCount;
    if (total <= 0) return;
    final base = _focusedGameIndex < 0 ? 0 : _focusedGameIndex;
    final next = (base + delta).clamp(0, total - 1).toInt();

    if (!keepInlineMoveFocus || _focusedGameMoveIndex < 0) {
      _setFocusedGameIndex(next);
      return;
    }

    if (next == _focusedGameIndex) {
      _syncGamesSelection(next);
      return;
    }

    final line = _gamesController.continuationAt(next);
    final nextMoveIndex = line.isEmpty ? -1 : 0;
    setState(() {
      _activeTable = _ExplorerTableFocus.games;
      _focusedGameIndex = next;
      _focusedGameMoveIndex = nextMoveIndex;
      _focusedGameAutoplaying = false;
    });

    final id = _gamesController.rowIdAt(next);
    if (id == null || id.isEmpty) {
      _gamesController.select(null);
      return;
    }
    _gamesController.select(
      id,
      preview: nextMoveIndex >= 0,
      autoplay: false,
      step: nextMoveIndex >= 0 ? nextMoveIndex : null,
    );
    if (nextMoveIndex < 0) widget.onClearPreviewUciMove?.call();
  }

  void _setFocusedGameIndexFromMouse(int next) {
    if (next == _focusedGameIndex &&
        _activeTable == _ExplorerTableFocus.games &&
        _focusedGameMoveIndex < 0) {
      return;
    }
    setState(() {
      _activeTable = _ExplorerTableFocus.games;
      _focusedGameIndex = next;
      _focusedGameMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
  }

  void _activateFocusedGameMoveFromPointer(int index, int step) {
    setState(() {
      _activeTable = _ExplorerTableFocus.games;
      _focusedGameIndex = index;
      _focusedGameMoveIndex = step;
      _focusedGameAutoplaying = false;
    });
    _keepExplorerFocus();
  }

  void _syncGamesSelection(int index) {
    if (_activeTable != _ExplorerTableFocus.games || index < 0) {
      _gamesController.select(null);
      return;
    }
    final id = _gamesController.rowIdAt(index);
    _gamesController.select(id == null || id.isEmpty ? null : id);
  }

  List<String> _focusedGameLine() {
    if (_focusedGameIndex < 0) return const <String>[];
    return _gamesController.continuationAt(_focusedGameIndex);
  }

  void _previewFocusedGame({required bool autoplay, int? step}) {
    if (_focusedGameIndex < 0) return;
    _gamesController.previewSelected(autoplay: autoplay, step: step);
  }

  int? _activeGameContinuationStep() {
    if (_activeTable != _ExplorerTableFocus.games || _focusedGameIndex < 0) {
      return null;
    }
    if (_focusedGameMoveIndex >= 0) return _focusedGameMoveIndex;
    if (_focusedGameAutoplaying && widget.previewLineAutoplay) {
      return widget.previewLineStep;
    }
    return null;
  }

  List<String> _activeGameContinuationPrefix() {
    final step = _activeGameContinuationStep();
    if (step == null || step < 0 || _focusedGameIndex < 0) {
      return const <String>[];
    }
    final line = _focusedGameLine();
    if (line.isEmpty) return const <String>[];
    final target = step.clamp(0, line.length - 1).toInt();
    return List<String>.unmodifiable(line.take(target + 1));
  }

  Future<void> _activateFocusedGameSelection() async {
    if (_focusedGameIndex < 0) return;
    final step = _activeGameContinuationStep();
    if (step == null) {
      _gamesController.openSelected(focus: true);
      return;
    }

    final prefix = _activeGameContinuationPrefix();
    if (prefix.isEmpty || widget.onPlayUciLine == null) {
      _gamesController.openSelected(focus: true, continuationStep: step);
      return;
    }

    final picked = await showGameContinuationActionChooser(
      context: context,
      previewLine: _formatUciContinuationLine(widget.currentFen, prefix),
      plyCount: prefix.length,
      canInsertMoves: true,
      targetContext: context,
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case GameContinuationAction.insertMoves:
        widget.onPlayUciLine?.call(
          ExplorerContinuationInsertion(
            ucis: prefix,
            sourceLabel: _gamesController.sourceLabelAt(_focusedGameIndex),
          ),
        );
        return;
      case GameContinuationAction.openGame:
        _gamesController.openSelected(focus: true, continuationStep: step);
        return;
    }
  }

  KeyEventResult _enterFocusedGameMove() {
    if (_activeTable != _ExplorerTableFocus.games || _focusedGameIndex < 0) {
      // Consume so the bare ←/→ doesn't bubble to the outer BoardPane
      // shortcuts and trigger prev/next move on the notation cursor.
      return KeyEventResult.handled;
    }
    final line = _focusedGameLine();
    if (line.isEmpty) return KeyEventResult.handled;
    final next =
        _focusedGameMoveIndex < 0
            ? 0
            : (_focusedGameMoveIndex + 1).clamp(0, line.length - 1).toInt();
    setState(() {
      _focusedGameMoveIndex = next;
      _focusedGameAutoplaying = false;
    });
    _previewFocusedGame(autoplay: false, step: next);
    return KeyEventResult.handled;
  }

  KeyEventResult _leaveOrStepBackFocusedGameMove() {
    if (_activeTable != _ExplorerTableFocus.games) {
      return KeyEventResult.handled;
    }
    if (_focusedGameMoveIndex > 0) {
      final next = _focusedGameMoveIndex - 1;
      setState(() {
        _focusedGameMoveIndex = next;
        _focusedGameAutoplaying = false;
      });
      _previewFocusedGame(autoplay: false, step: next);
      return KeyEventResult.handled;
    }
    if (_focusedGameMoveIndex == 0) {
      setState(() {
        _focusedGameMoveIndex = -1;
        _focusedGameAutoplaying = false;
      });
      widget.onClearPreviewUciMove?.call();
      return KeyEventResult.handled;
    }
    _stepNotationBack();
    return KeyEventResult.handled;
  }

  void _updateMoveCount(int nextMoveCount) {
    if (nextMoveCount == _moveCount) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      var nextFocusedMoveIndex = _focusedMoveIndex;
      if (nextFocusedMoveIndex >= nextMoveCount) nextFocusedMoveIndex = -1;
      // Default-select the first row when the table loads with no prior user
      // focus. This is a visual highlight only; board state changes require
      // explicit activation.
      final autoDefaultedToFirst =
          _activeTable == _ExplorerTableFocus.moves &&
          nextFocusedMoveIndex < 0 &&
          nextMoveCount > 0;
      if (autoDefaultedToFirst) {
        nextFocusedMoveIndex = 0;
      }
      setState(() {
        _moveCount = nextMoveCount;
        _focusedMoveIndex = nextFocusedMoveIndex;
      });
      if (_activeTable != _ExplorerTableFocus.games) {
        _gamesController.select(null, clearPreview: false);
      }
    });
  }

  void _switchTable(int delta) {
    if (delta > 0) {
      _focusGamesPane();
    } else if (delta < 0) {
      if (_activeTable == _ExplorerTableFocus.moves) {
        _keepExplorerFocus();
        return;
      }
      _focusMovesPane();
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.active) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final aggs =
        _sortedAggs.isNotEmpty
            ? _sortedAggs
            : ref.read(gamebaseExplorerProvider).moveAggregates;
    final shortcuts =
        ref.read(keyboardShortcutsProvider).valueOrNull ??
        BoardShortcutMap(defaultBoardShortcuts());
    final key = event.logicalKey;
    final hasModifier = _hasAnyModifierPressed();

    if (!hasModifier && key == LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (!hasModifier &&
        _activeTable == _ExplorerTableFocus.moves &&
        key == LogicalKeyboardKey.arrowRight) {
      final index =
          _focusedMoveIndex >= 0 ? _focusedMoveIndex : (aggs.isEmpty ? -1 : 0);
      if (index >= 0 && index < aggs.length) {
        _activateExplorerMove(aggs[index].uci);
      }
      return KeyEventResult.handled;
    }
    if (!hasModifier &&
        _activeTable == _ExplorerTableFocus.moves &&
        key == LogicalKeyboardKey.arrowLeft) {
      _stepNotationBack();
      return KeyEventResult.handled;
    }
    if (!hasModifier &&
        _activeTable == _ExplorerTableFocus.games &&
        key == LogicalKeyboardKey.arrowRight) {
      return _enterFocusedGameMove();
    }
    if (!hasModifier &&
        _activeTable == _ExplorerTableFocus.games &&
        key == LogicalKeyboardKey.arrowLeft) {
      return _leaveOrStepBackFocusedGameMove();
    }

    // Shift+←/→ belongs specifically to the two-table Explorer surface
    // (moves ⇄ games). Keep it local here instead of exposing it as a
    // generic/customizable right-rail shortcut that can be confused with
    // board or tab navigation.
    if (_isExplorerTableSwitchChord(event, forward: true) ||
        _matchesAction(event, shortcuts, BoardActionKey.rightRailNextTable) ||
        (key == LogicalKeyboardKey.tab &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _switchTable(1);
      return KeyEventResult.handled;
    }
    if (_isExplorerTableSwitchChord(event, forward: false) ||
        _matchesAction(
          event,
          shortcuts,
          BoardActionKey.rightRailPreviousTable,
        ) ||
        (key == LogicalKeyboardKey.tab &&
            HardwareKeyboard.instance.isShiftPressed)) {
      _switchTable(-1);
      return KeyEventResult.handled;
    }
    if (hasModifier) {
      return KeyEventResult.ignored;
    }
    // Bare ←/→ inside the Explorer tab must stay inside the tab. Moves-table
    // arrows and games-table arrows were handled above; this catches any
    // remaining boundary key so it does not bubble to the outer board layer.
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _focusGamesPane(index: 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _focusMovesPane(index: _moveCount > 0 ? 0 : -1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focusedGameMoveIndex >= 0) {
        _moveFocusedGameRow(1, keepInlineMoveFocus: true);
        return KeyEventResult.handled;
      }
      if (_activeTable == _ExplorerTableFocus.moves) {
        if (_moveCount <= 0) return KeyEventResult.handled;
        final next =
            (_focusedMoveIndex < 0 ? 0 : _focusedMoveIndex + 1)
                .clamp(0, _moveCount - 1)
                .toInt();
        _setFocusedMoveIndex(next);
        return KeyEventResult.handled;
      }
      if (_gamesController.rowCount <= 0) return KeyEventResult.handled;
      _moveFocusedGameRow(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_focusedGameMoveIndex >= 0) {
        _moveFocusedGameRow(-1, keepInlineMoveFocus: true);
        return KeyEventResult.handled;
      }
      if (_activeTable == _ExplorerTableFocus.moves) {
        if (_moveCount <= 0) return KeyEventResult.handled;
        final next = _focusedMoveIndex <= 0 ? 0 : _focusedMoveIndex - 1;
        _setFocusedMoveIndex(next);
        return KeyEventResult.handled;
      }
      if (_gamesController.rowCount <= 0) return KeyEventResult.handled;
      _moveFocusedGameRow(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      if (_activeTable == _ExplorerTableFocus.moves) {
        _setFocusedMoveIndex(_moveCount > 0 ? 0 : -1);
      } else {
        _setFocusedGameIndex(_gamesController.rowCount > 0 ? 0 : -1);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_activeTable == _ExplorerTableFocus.moves) {
        _setFocusedMoveIndex(_moveCount > 0 ? _moveCount - 1 : -1);
      } else {
        _setFocusedGameIndex(
          _gamesController.rowCount > 0 ? _gamesController.rowCount - 1 : -1,
        );
      }
      return KeyEventResult.handled;
    }
    if (_matchesAction(
          event,
          shortcuts,
          BoardActionKey.rightRailActivateSelection,
        ) ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_activeTable == _ExplorerTableFocus.moves) {
        if (_focusedMoveIndex >= 0 && _focusedMoveIndex < aggs.length) {
          _activateExplorerMove(aggs[_focusedMoveIndex].uci);
        }
      } else if (_focusedGameIndex >= 0 &&
          (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter)) {
        unawaited(_activateFocusedGameSelection());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.active) return const SizedBox.expand();
    final activeContinuationStep = _activeGameContinuationStep();
    final movesPanel = DesktopOpeningExplorer(
      compactColumns: true,
      showHeader: false,
      enableRowHover: false,
      shrinkWrap: false,
      focusedMoveIndex:
          _activeTable == _ExplorerTableFocus.moves &&
                  _focusedMoveIndex >= 0 &&
                  _focusedMoveIndex < _moveCount
              ? _focusedMoveIndex
              : null,
      onFocusMoveIndex: (i) {
        _setFocusedMoveIndex(i);
        _keepExplorerFocus();
      },
      moveCountCallback: _updateMoveCount,
      sortedAggregatesCallback: (next) => _sortedAggs = next,
      onMove: _activateExplorerMove,
      onShowGames: widget.onShowGames,
    );
    final gamesPanel = DesktopPositionGamesTable(
      fen: widget.currentFen,
      moves: widget.lineUcis,
      exactFenSearch: widget.exactFenSearch,
      active: widget.active,
      controller: _gamesController,
      referenceLayout: true,
      activeContinuationStep: activeContinuationStep,
      activeContinuationAutoplay:
          activeContinuationStep != null &&
          _focusedGameAutoplaying &&
          widget.previewLineAutoplay,
      onFocusRowIndex: (i) {
        _setFocusedGameIndexFromMouse(i);
        _keepExplorerFocus();
      },
      onActivateContinuationStep: _activateFocusedGameMoveFromPointer,
      onPreviewContinuation: _previewGameLine,
    );
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active && widget.activeSection > 0,
      onKeyEvent: _handleKey,
      child: Listener(
        // Listener sees pointer-down on descendants regardless of nested
        // GestureDetectors' HitTestBehavior. Row taps use opaque hit-test,
        // which prevents the surrounding GestureDetector from running; without
        // this Listener, focus would stay on the outer board pane and ← would
        // bubble to the global prevMove shortcut instead of `_handleKey`.
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (!widget.active) return;
          _focusNode.requestFocus();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Click into empty panel space keeps focus local without activating
          // notation mode. A notation move click activates that mode explicitly.
          onTap: () => _focusNode.requestFocus(),
          child: ColoredBox(
            color: kBlack2Color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ResizableSplitView(
                    axis: Axis.vertical,
                    // Explorer now stacks the move tree above the matching
                    // games table so notation can stay visible above it,
                    // matching the reference-board mental model.
                    storageKey: 'desktop.board.right-rail.explorer.stack.v1',
                    gutterThickness: 6,
                    children: [
                      SplitChild(
                        label: 'Moves',
                        collapsedIcon: Icons.menu_book_outlined,
                        minSize: 120,
                        initialWeight: 0.42,
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (_) {
                            if (!widget.active) return;
                            _focusMovesPane();
                          },
                          child: movesPanel,
                        ),
                      ),
                      SplitChild(
                        label: 'Games',
                        collapsedIcon: Icons.list_alt_rounded,
                        minSize: 160,
                        initialWeight: 0.58,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => _focusGamesPane(),
                          child: gamesPanel,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ExplorerTableFocus { moves, games }

/// True for a bare `Shift+→` (forward) or `Shift+←` (backward) chord — the
/// Explorer's local Moves ⇄ Games focus switch. Excludes Ctrl/Alt/Meta so it
/// never collides with board/tab navigation chords that also use the arrows.
bool _isExplorerTableSwitchChord(KeyEvent event, {required bool forward}) {
  if (event.logicalKey !=
      (forward
          ? LogicalKeyboardKey.arrowRight
          : LogicalKeyboardKey.arrowLeft)) {
    return false;
  }
  return HardwareKeyboard.instance.isShiftPressed &&
      !_isControlPressed() &&
      !_isAltPressed() &&
      !_isMetaPressed();
}

bool _matchesAction(
  KeyEvent event,
  BoardShortcutMap shortcuts,
  BoardActionKey action,
) {
  for (final chord in shortcuts.chordsFor(action)) {
    if (_matchesChord(event, chord)) return true;
  }
  return false;
}

bool _matchesChord(KeyEvent event, KeyChord chord) {
  if (event.logicalKey.keyId != chord.keyId) return false;
  final ctrl = _isControlPressed();
  final alt = _isAltPressed();
  final shift = HardwareKeyboard.instance.isShiftPressed;
  final meta = _isMetaPressed();
  final effectiveCtrl =
      chord.crossPlatform
          ? chord.ctrl || (chord.meta && !Platform.isMacOS)
          : chord.ctrl;
  final effectiveMeta =
      chord.crossPlatform ? chord.meta && Platform.isMacOS : chord.meta;
  return ctrl == effectiveCtrl &&
      alt == chord.alt &&
      shift == chord.shift &&
      meta == effectiveMeta;
}

bool _isControlPressed() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  return pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight) ||
      pressed.contains(LogicalKeyboardKey.control);
}

bool _isAltPressed() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  return pressed.contains(LogicalKeyboardKey.altLeft) ||
      pressed.contains(LogicalKeyboardKey.altRight) ||
      pressed.contains(LogicalKeyboardKey.alt);
}

bool _isMetaPressed() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  return pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight) ||
      pressed.contains(LogicalKeyboardKey.meta);
}

bool _hasAnyModifierPressed() =>
    _isControlPressed() ||
    _isAltPressed() ||
    _isMetaPressed() ||
    HardwareKeyboard.instance.isShiftPressed;

/// Standalone Games tab (page 2). Wraps [DesktopPositionGamesTable] with a
/// keyboard-driven row cursor so arrow keys highlight rows, Enter opens the
/// selected game, and Home/End jump to the ends. Selection state is owned by
/// a [DesktopPositionGamesTableController] so the table's row decoration and
/// auto-scroll-into-view kick in for free.
class _PositionGamesPage extends ConsumerStatefulWidget {
  const _PositionGamesPage({
    required this.active,
    required this.fen,
    required this.moves,
    required this.previewLineStep,
    required this.previewLineAutoplay,
    required this.exactFenSearch,
    required this.pinnedUci,
    required this.onKeepGamesActive,
    required this.onPlayUciLine,
    required this.onPreviewUciLine,
    required this.onClearPreviewUciMove,
    required this.onNotationStep,
    required this.explorerScope,
  });

  final String fen;
  final List<String> moves;
  final bool active;
  final int previewLineStep;
  final bool previewLineAutoplay;
  final bool exactFenSearch;
  final String? pinnedUci;
  final VoidCallback onKeepGamesActive;
  final ValueChanged<ExplorerContinuationInsertion>? onPlayUciLine;
  final PreviewUciLineCallback? onPreviewUciLine;
  final VoidCallback? onClearPreviewUciMove;
  final bool Function(int delta)? onNotationStep;
  final BoardExplorerScope? explorerScope;

  @override
  ConsumerState<_PositionGamesPage> createState() => _PositionGamesPageState();
}

class _PositionGamesPageState extends ConsumerState<_PositionGamesPage>
    with AutomaticKeepAliveClientMixin<_PositionGamesPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'position-games-page');
  late final DesktopPositionGamesTableController _controller =
      DesktopPositionGamesTableController()..addListener(_onRowsChanged);
  int _focusedIndex = -1;
  int _focusedMoveIndex = -1;
  bool _focusedGameAutoplaying = false;
  bool _reconcileScheduled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.active) _keepGamesFocus();
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onRowsChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PositionGamesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen ||
        !_listEquals(oldWidget.moves, widget.moves) ||
        oldWidget.pinnedUci != widget.pinnedUci ||
        oldWidget.exactFenSearch != widget.exactFenSearch) {
      if (widget.active) _keepGamesFocusAfterFrame();
    }
    if (!oldWidget.active && widget.active) {
      _selectDefaultRowIfNeeded();
      _keepGamesFocusAfterFrame();
    }
  }

  void _keepGamesFocus() {
    if (!mounted || !widget.active) return;
    widget.onKeepGamesActive();
    _focusNode.requestFocus();
  }

  void _keepGamesFocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      _keepGamesFocus();
    });
  }

  void _onRowsChanged() {
    if (!mounted || _reconcileScheduled) return;
    _reconcileScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reconcileScheduled = false;
      if (!mounted) return;
      final total = _controller.rowCount;
      if (total <= 0) {
        if (_focusedIndex < 0 &&
            _focusedMoveIndex < 0 &&
            !_focusedGameAutoplaying) {
          _controller.select(null);
          return;
        }
        setState(() {
          _focusedIndex = -1;
          _focusedMoveIndex = -1;
          _focusedGameAutoplaying = false;
        });
        _controller.select(null);
        return;
      }
      if (_focusedIndex < 0 || _focusedIndex >= total) {
        setState(() {
          _focusedIndex = 0;
          _focusedMoveIndex = -1;
          _focusedGameAutoplaying = false;
        });
        _syncSelection(0);
        return;
      }
      // Re-sync the selection band with our cursor in case the row list
      // shifted out from under us (e.g. pagination merged in new rows).
      _syncSelection(_focusedIndex);
    });
  }

  void _selectDefaultRowIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      if (_focusedIndex >= 0 || _controller.rowCount <= 0) return;
      setState(() {
        _focusedIndex = 0;
        _focusedMoveIndex = -1;
        _focusedGameAutoplaying = false;
      });
      _syncSelection(0);
    });
  }

  void _syncSelection(int index) {
    final id = _controller.rowIdAt(index);
    _controller.select(id == null || id.isEmpty ? null : id);
  }

  void _previewGameLine(List<String> ucis, {bool autoplay = true, int? step}) {
    if (ucis.isEmpty) {
      widget.onClearPreviewUciMove?.call();
      return;
    }
    widget.onPreviewUciLine?.call(ucis, autoplay: autoplay, step: step);
  }

  void _stepNotationBack() {
    widget.onNotationStep?.call(-1);
    _keepGamesFocus();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _setFocusedIndex(int next) {
    if (next == _focusedIndex) return;
    widget.onClearPreviewUciMove?.call();
    setState(() {
      _focusedIndex = next;
      _focusedMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
    if (next < 0) {
      _controller.select(null);
    } else {
      _syncSelection(next);
    }
  }

  void _moveFocusedRow(int delta, {bool preserveMoveFocus = false}) {
    final total = _controller.rowCount;
    if (total <= 0) return;
    final base = _focusedIndex < 0 ? 0 : _focusedIndex;
    final next = (base + delta).clamp(0, total - 1).toInt();

    if (!preserveMoveFocus || _focusedMoveIndex < 0) {
      _setFocusedIndex(next);
      return;
    }

    if (next == _focusedIndex) {
      _syncSelection(next);
      return;
    }

    final line = _controller.continuationAt(next);
    final nextMoveIndex = line.isEmpty ? -1 : 0;
    setState(() {
      _focusedIndex = next;
      _focusedMoveIndex = nextMoveIndex;
      _focusedGameAutoplaying = false;
    });

    final id = _controller.rowIdAt(next);
    if (id == null || id.isEmpty) {
      _controller.select(null);
      return;
    }
    _controller.select(
      id,
      preview: nextMoveIndex >= 0,
      autoplay: false,
      step: nextMoveIndex >= 0 ? nextMoveIndex : null,
    );
    if (nextMoveIndex < 0) widget.onClearPreviewUciMove?.call();
  }

  void _setFocusedIndexFromMouse(int next) {
    if (next == _focusedIndex && _focusedMoveIndex < 0) return;
    setState(() {
      _focusedIndex = next;
      _focusedMoveIndex = -1;
      _focusedGameAutoplaying = false;
    });
  }

  void _activateFocusedMoveFromPointer(int index, int step) {
    setState(() {
      _focusedIndex = index;
      _focusedMoveIndex = step;
      _focusedGameAutoplaying = false;
    });
    _keepGamesFocus();
  }

  List<String> _focusedLine() {
    if (_focusedIndex < 0) return const <String>[];
    return _controller.continuationAt(_focusedIndex);
  }

  void _previewFocusedGame({required bool autoplay, int? step}) {
    if (_focusedIndex < 0) return;
    _controller.previewSelected(autoplay: autoplay, step: step);
  }

  int? _activeContinuationStep() {
    if (_focusedIndex < 0) return null;
    if (_focusedMoveIndex >= 0) return _focusedMoveIndex;
    if (_focusedGameAutoplaying && widget.previewLineAutoplay) {
      return widget.previewLineStep;
    }
    return null;
  }

  List<String> _activeContinuationPrefix() {
    final step = _activeContinuationStep();
    if (step == null || step < 0 || _focusedIndex < 0) {
      return const <String>[];
    }
    final line = _focusedLine();
    if (line.isEmpty) return const <String>[];
    final target = step.clamp(0, line.length - 1).toInt();
    return List<String>.unmodifiable(line.take(target + 1));
  }

  Future<void> _activateFocusedSelection() async {
    if (_focusedIndex < 0) return;
    final step = _activeContinuationStep();
    if (step == null) {
      _keepGamesFocus();
      _controller.openSelected(focus: true);
      return;
    }

    final prefix = _activeContinuationPrefix();
    if (prefix.isEmpty || widget.onPlayUciLine == null) {
      _keepGamesFocus();
      _controller.openSelected(focus: true, continuationStep: step);
      return;
    }

    final picked = await showGameContinuationActionChooser(
      context: context,
      previewLine: _formatUciContinuationLine(widget.fen, prefix),
      plyCount: prefix.length,
      canInsertMoves: true,
      targetContext: context,
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case GameContinuationAction.insertMoves:
        widget.onPlayUciLine?.call(
          ExplorerContinuationInsertion(
            ucis: prefix,
            sourceLabel: _controller.sourceLabelAt(_focusedIndex),
          ),
        );
        return;
      case GameContinuationAction.openGame:
        _keepGamesFocus();
        _controller.openSelected(focus: true, continuationStep: step);
        return;
    }
  }

  KeyEventResult _enterFocusedMove() {
    // Consume bare ←/→ even with no selection so the outer BoardPane
    // Shortcuts don't fire prev/next move while the Games tab owns focus.
    if (_focusedIndex < 0) return KeyEventResult.handled;
    final line = _focusedLine();
    if (line.isEmpty) return KeyEventResult.handled;
    final next =
        _focusedMoveIndex < 0
            ? 0
            : (_focusedMoveIndex + 1).clamp(0, line.length - 1).toInt();
    setState(() {
      _focusedMoveIndex = next;
      _focusedGameAutoplaying = false;
    });
    _previewFocusedGame(autoplay: false, step: next);
    _keepGamesFocus();
    return KeyEventResult.handled;
  }

  KeyEventResult _leaveOrStepBackFocusedMove() {
    if (_focusedMoveIndex > 0) {
      final next = _focusedMoveIndex - 1;
      setState(() {
        _focusedMoveIndex = next;
        _focusedGameAutoplaying = false;
      });
      _previewFocusedGame(autoplay: false, step: next);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (_focusedMoveIndex == 0) {
      setState(() {
        _focusedMoveIndex = -1;
        _focusedGameAutoplaying = false;
      });
      widget.onClearPreviewUciMove?.call();
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    _stepNotationBack();
    return KeyEventResult.handled;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.active) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shortcuts =
        ref.read(keyboardShortcutsProvider).valueOrNull ??
        BoardShortcutMap(defaultBoardShortcuts());
    final key = event.logicalKey;
    if (_hasAnyModifierPressed()) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return _enterFocusedMove();
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _leaveOrStepBackFocusedMove();
    }
    if (_matchesAction(
          event,
          shortcuts,
          BoardActionKey.rightRailActivateSelection,
        ) ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_focusedIndex < 0) return KeyEventResult.ignored;
      unawaited(_activateFocusedSelection());
      return KeyEventResult.handled;
    }
    final total = _controller.rowCount;
    if (total == 0) return KeyEventResult.ignored;
    if (_focusedMoveIndex >= 0 &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp)) {
      _moveFocusedRow(
        key == LogicalKeyboardKey.arrowDown ? 1 : -1,
        preserveMoveFocus: true,
      );
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocusedRow(1);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocusedRow(-1);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      final base = _focusedIndex < 0 ? 0 : _focusedIndex;
      final next = (base + kDesktopListPageStep).clamp(0, total - 1).toInt();
      _setFocusedIndex(next);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      final base = _focusedIndex < 0 ? 0 : _focusedIndex;
      final next = (base - kDesktopListPageStep).clamp(0, total - 1).toInt();
      _setFocusedIndex(next);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _setFocusedIndex(0);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _setFocusedIndex(total - 1);
      _keepGamesFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final activeContinuationStep = _activeContinuationStep();
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _keepGamesFocus,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DesktopPositionGamesTable(
                fen: widget.fen,
                moves: widget.moves,
                exactFenSearch: widget.exactFenSearch,
                active: widget.active,
                uci: widget.pinnedUci,
                controller: _controller,
                activeContinuationStep: activeContinuationStep,
                activeContinuationAutoplay:
                    activeContinuationStep != null &&
                    _focusedGameAutoplaying &&
                    widget.previewLineAutoplay,
                onFocusRowIndex: (i) {
                  _setFocusedIndexFromMouse(i);
                  _keepGamesFocus();
                },
                onActivateContinuationStep: _activateFocusedMoveFromPointer,
                onPreviewContinuation: _previewGameLine,
              ),
            ),
            ExplorerFilterBar(
              compact: true,
              scopedPlayer: widget.explorerScope?.player,
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper: walk a [PgnGame]/dartchess `Position` chain and emit the UCI
/// move-list from the starting position up to a given ply cursor.
///
/// Lives here (next to the panel that consumes it) so the BoardPane glue
/// stays small.
List<String> uciLineFromPlies({
  required Position startingPosition,
  required List<String> sanMoves, // size = total plies; sanMoves[0] is move #1
  required int playedThroughPly, // inclusive; -1 => empty line
}) {
  if (playedThroughPly < 0) return const <String>[];
  final out = <String>[];
  Position position = startingPosition;
  final upTo = playedThroughPly.clamp(0, sanMoves.length - 1);
  for (var i = 0; i <= upTo; i++) {
    final move = position.parseSan(sanMoves[i]);
    if (move == null) break;
    out.add(move.uci);
    position = position.playUnchecked(move);
  }
  return List<String>.unmodifiable(out);
}

String _formatUciContinuationLine(String fen, List<String> ucis) {
  if (ucis.isEmpty) return 'No moves';
  final parts = fen.trim().split(RegExp(r'\s+'));
  final initialFullMove = parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
  final whiteFirst = parts.length >= 2 ? parts[1] == 'w' : true;

  Position position;
  try {
    position = Chess.fromSetup(
      Setup.parseFen(fen),
      ignoreImpossibleCheck: true,
    );
  } catch (_) {
    return ucis.join(' ');
  }

  final tokens = <String>[];
  var fullMove = initialFullMove;
  var whiteToMove = whiteFirst;
  for (final uci in ucis) {
    final move = Move.parse(uci);
    if (move == null) break;
    late final (Position, String) made;
    try {
      made = position.makeSan(move);
    } catch (_) {
      break;
    }
    final (next, san) = made;
    if (whiteToMove) {
      tokens.add('$fullMove.$san');
    } else if (tokens.isEmpty) {
      tokens.add('$fullMove…$san');
    } else {
      tokens.add(san);
    }
    position = next;
    if (!whiteToMove) fullMove += 1;
    whiteToMove = !whiteToMove;
  }
  return tokens.isEmpty ? ucis.join(' ') : tokens.join(' ');
}

/// Page-0 keyboard host. Wraps the caller-supplied [child] (the notation
/// ladder) in a Focus that owns the arrow-key cursor for the Notation tab,
/// so highlight selection is driven from inside the tab and consumed before
/// the outer BoardPane Shortcuts can re-route the keys elsewhere.
class _NotationKeyboardArea extends StatefulWidget {
  const _NotationKeyboardArea({
    required this.child,
    required this.active,
    required this.focusNode,
    required this.onActivate,
    required this.onVertical,
    required this.onStep,
    required this.onJumpToHead,
    required this.onJumpToTip,
  });

  final Widget child;
  final bool active;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final ValueChanged<NotationVerticalDirection>? onVertical;
  final bool Function(int delta)? onStep;
  final VoidCallback? onJumpToHead;
  final VoidCallback? onJumpToTip;

  @override
  State<_NotationKeyboardArea> createState() => _NotationKeyboardAreaState();
}

class _NotationKeyboardAreaState extends State<_NotationKeyboardArea> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      widget.focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _NotationKeyboardArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active || !widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      widget.focusNode.requestFocus();
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_isRightRailNextTabChord(event)) return KeyEventResult.ignored;
      if (_hasAnyModifierPressed()) return KeyEventResult.handled;
      widget.onStep?.call(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_isRightRailPreviousTabChord(event)) return KeyEventResult.ignored;
      if (_hasAnyModifierPressed()) return KeyEventResult.handled;
      widget.onStep?.call(-1);
      return KeyEventResult.handled;
    }
    if (_hasAnyModifierPressed()) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final cb = widget.onVertical;
      if (cb == null) return KeyEventResult.ignored;
      cb(NotationVerticalDirection.down);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final cb = widget.onVertical;
      if (cb == null) return KeyEventResult.ignored;
      cb(NotationVerticalDirection.up);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      final cb = widget.onJumpToHead;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      final cb = widget.onJumpToTip;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.active,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          widget.onActivate();
          widget.focusNode.requestFocus();
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            widget.onActivate();
            widget.focusNode.requestFocus();
          },
          child: widget.child,
        ),
      ),
    );
  }
}
