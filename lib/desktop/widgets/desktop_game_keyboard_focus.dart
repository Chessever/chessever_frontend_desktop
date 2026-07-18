import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

const int kDesktopGameKeyboardDefaultPageStride = 8;

@visibleForTesting
int nextDesktopGameKeyboardIndex({
  required int currentIndex,
  required int itemCount,
  required LogicalKeyboardKey key,
  int pageStride = kDesktopGameKeyboardDefaultPageStride,
  int columnCount = 1,
}) {
  if (itemCount <= 0) return -1;
  final hasSelection = currentIndex >= 0;
  final safeCurrent =
      hasSelection ? currentIndex.clamp(0, itemCount - 1).toInt() : 0;
  final safePageStride = math.max(1, pageStride);
  // ArrowUp/ArrowDown walk whole rows in a multi-column grid; ArrowLeft/Right
  // still step one card. `columnCount == 1` degrades to the old flat-list
  // behavior (vertical lists, single-column tables), so callers that don't
  // know their column count keep working unchanged.
  final safeColumns = math.max(1, columnCount);

  // ArrowRight moves one card forward (wraps into the next row at a row edge).
  if (key == LogicalKeyboardKey.arrowRight) {
    if (!hasSelection) return 0;
    return math.min(itemCount - 1, safeCurrent + 1);
  }
  // ArrowLeft moves one card back (wraps into the previous row at a row edge).
  if (key == LogicalKeyboardKey.arrowLeft) {
    if (!hasSelection) return 0;
    return math.max(0, safeCurrent - 1);
  }
  // ArrowDown drops a full row; clamp onto the last card so a partial final
  // row is still reachable instead of trapping focus on the last full row.
  if (key == LogicalKeyboardKey.arrowDown) {
    if (!hasSelection) return 0;
    return math.min(itemCount - 1, safeCurrent + safeColumns);
  }
  // ArrowUp climbs a full row; clamp onto the first card.
  if (key == LogicalKeyboardKey.arrowUp) {
    if (!hasSelection) return 0;
    return math.max(0, safeCurrent - safeColumns);
  }
  if (key == LogicalKeyboardKey.pageDown) {
    if (!hasSelection) return 0;
    return math.min(itemCount - 1, safeCurrent + safePageStride);
  }
  if (key == LogicalKeyboardKey.pageUp) {
    if (!hasSelection) return 0;
    return math.max(0, safeCurrent - safePageStride);
  }
  if (key == LogicalKeyboardKey.home) return 0;
  if (key == LogicalKeyboardKey.end) return itemCount - 1;
  return safeCurrent;
}

/// Keyboard focus/selection host for desktop game feeds.
///
/// It gives every games screen the same behavior:
/// - first visible game is selected when the screen opens or filters change
/// - ArrowDown/ArrowRight move forward
/// - ArrowUp/ArrowLeft move backward
/// - PageDown/PageUp jump by roughly a page-sized stride
/// - Enter opens the highlighted game when [onActivateGame] is supplied
///
/// Selection-state lookups are keyed by `gameId`. Hit-test/scroll-into-view
/// keys are issued via [DesktopGameKeyboardFocusBuilder.keyForGame]: every
/// non-selected item gets a unique [ValueKey] (so duplicate game ids across
/// rounds/match-cards do not collide), and only the *currently selected* item
/// receives the singleton [GlobalKey] used to drive `Scrollable.ensureVisible`.
class DesktopGameKeyboardFocus extends StatefulWidget {
  const DesktopGameKeyboardFocus({
    super.key,
    required this.scopeId,
    required this.games,
    required this.builder,
    this.pageStride = kDesktopGameKeyboardDefaultPageStride,
    this.onActivateGame,
    this.ensureInitialSelectionVisible = true,
    this.resolveColumnCount,
    this.scrollController,
  });

  final String scopeId;
  final List<GamesTourModel> games;
  final int pageStride;
  final ValueChanged<GamesTourModel>? onActivateGame;
  final bool ensureInitialSelectionVisible;
  final ScrollController? scrollController;

  /// Live column count of the grid that renders [games], read at key-press
  /// time so ArrowUp/ArrowDown can travel whole rows. Return `1` (or leave
  /// null) for single-column lists. Panes whose grid is responsive can point
  /// this at a mutable field they update from the grid's own layout pass, so
  /// the row stride always matches what's on screen.
  final int Function()? resolveColumnCount;
  final Widget Function(
    BuildContext context,
    String? selectedGameId,
    void Function(String gameId) selectGame,
    Key Function(String gameId) keyForGame,
  )
  builder;

  @override
  State<DesktopGameKeyboardFocus> createState() =>
      _DesktopGameKeyboardFocusState();
}

class _DesktopGameKeyboardFocusState extends State<DesktopGameKeyboardFocus> {
  late final FocusNode _focusNode;
  // Singleton global key reused for whichever item is currently selected.
  // Only the selected row mounts under this key, so we never trigger the
  // "duplicate GlobalKey in widget tree" assertion even when knockout or
  // match-card layouts render the same gameId in multiple subtrees.
  final GlobalKey _selectedItemKey = GlobalKey(
    debugLabel: 'desktop-keyboard-selected',
  );
  String? _selectedGameId;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'desktop-game-keyboard-${widget.scopeId}',
    );
    _syncSelectionWithGames();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Initial autofocus only — never steal focus from another input that
      // a higher-level pane (search field, etc.) may have already claimed.
      if (_canClaimFocus()) {
        _focusNode.requestFocus();
      }
      if (widget.ensureInitialSelectionVisible) {
        _ensureSelectedVisible();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // PersistentIndexedStack wraps inactive tabs in TickerMode+ExcludeFocus,
    // which strips our focus when the tab is hidden. Watch the TickerMode
    // notifier so we can re-claim keyboard focus when the tab is shown again
    // — nothing else restores it.
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_handleTickerModeChanged);
      _tickerMode = notifier..addListener(_handleTickerModeChanged);
    }
  }

  void _handleTickerModeChanged() {
    if (_tickerMode?.value.enabled != true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_canClaimFocus()) {
        _focusNode.requestFocus();
      }
    });
  }

  /// Whether grabbing keyboard focus would steal it from something that
  /// meaningfully owns it.
  ///
  /// Claimable states: nothing focused, focus parked on an ancestor (the
  /// shell's autofocused FocusableActionDetector or a scope), or focus stuck
  /// on a node inside a hidden tab (ExcludeFocus flips its canRequestFocus to
  /// false before the pending unfocus is applied). A focused sibling — a
  /// search field, a dialog — keeps focus.
  bool _canClaimFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _focusNode) return true;
    if (!primary.canRequestFocus) return true;
    return _focusNode.ancestors.contains(primary);
  }

  @override
  void didUpdateWidget(covariant DesktopGameKeyboardFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scopeChanged = oldWidget.scopeId != widget.scopeId;
    final gamesChanged = !_sameGameIds(oldWidget.games, widget.games);
    if (!scopeChanged && !gamesChanged) return;

    _syncSelectionWithGames();
    final hadFocus = _focusNode.hasFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only re-claim focus when we already owned it (the games list was
      // active when the rebuild happened). Filtering the list because the
      // user is typing into a search field above us must not yank focus
      // back into the games list mid-keystroke.
      if (scopeChanged || hadFocus) {
        _focusNode.requestFocus();
      }
      if (widget.ensureInitialSelectionVisible) {
        _ensureSelectedVisible();
      }
    });
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_handleTickerModeChanged);
    _focusNode.dispose();
    super.dispose();
  }

  Key _keyForGame(String gameId) {
    if (gameId == _selectedGameId) return _selectedItemKey;
    return ValueKey<String>('desktop-keyboard-item:${widget.scopeId}:$gameId');
  }

  void _syncSelectionWithGames() {
    final games = widget.games;
    if (games.isEmpty) {
      _selectedGameId = null;
      return;
    }
    final selected = _selectedGameId;
    if (selected == null || !games.any((game) => game.gameId == selected)) {
      _selectedGameId = games.first.gameId;
    }
  }

  void _selectGame(
    String gameId, {
    bool ensureVisible = false,
    LogicalKeyboardKey? navigationKey,
    ScrollPositionAlignmentPolicy alignment =
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  }) {
    if (_selectedGameId == gameId) {
      _focusNode.requestFocus();
      if (ensureVisible) {
        _ensureSelectedVisible(
          alignment: alignment,
          navigationKey: navigationKey,
          expectedGameId: gameId,
        );
      }
      return;
    }
    setState(() => _selectedGameId = gameId);
    _focusNode.requestFocus();
    if (ensureVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _ensureSelectedVisible(
            alignment: alignment,
            navigationKey: navigationKey,
            expectedGameId: gameId,
          );
        }
      });
    }
  }

  bool _hasNavigationModifier() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.control) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.meta) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.alt) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isNavigationKey =
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    final isActivationKey =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;

    if (!isNavigationKey && !isActivationKey) return KeyEventResult.ignored;

    // Modifier-held key events belong to global shortcuts (Cmd/Ctrl+Enter,
    // Cmd+End, Alt+Arrow, etc). Let them bubble.
    if (_hasNavigationModifier()) return KeyEventResult.ignored;

    if (isActivationKey) {
      final game = _selectedGame();
      if (game == null || widget.onActivateGame == null) {
        return KeyEventResult.ignored;
      }
      widget.onActivateGame!(game);
      return KeyEventResult.handled;
    }

    final games = widget.games;
    if (games.isEmpty) return KeyEventResult.ignored;
    final currentIndex = games.indexWhere(
      (game) => game.gameId == _selectedGameId,
    );
    final columnCount = math.max(1, widget.resolveColumnCount?.call() ?? 1);
    final nextIndex = nextDesktopGameKeyboardIndex(
      currentIndex: currentIndex,
      itemCount: games.length,
      key: key,
      pageStride: widget.pageStride,
      columnCount: columnCount,
    );
    if (nextIndex < 0 || nextIndex >= games.length) {
      return KeyEventResult.ignored;
    }
    _selectGame(
      games[nextIndex].gameId,
      ensureVisible: true,
      navigationKey: key,
      // Backward moves (up/left/pageUp/home) must reveal the target at the
      // viewport's leading edge — keepVisibleAtEnd refuses to scroll backward
      // (it clamps `target` to the current offset), so an upward step would
      // otherwise never move the scroll position.
      alignment:
          _isBackwardNavigation(key)
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    return KeyEventResult.handled;
  }

  bool _isBackwardNavigation(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home;
  }

  GamesTourModel? _selectedGame() {
    final selected = _selectedGameId;
    if (selected == null) return null;
    for (final game in widget.games) {
      if (game.gameId == selected) return game;
    }
    return null;
  }

  void _ensureSelectedVisible({
    ScrollPositionAlignmentPolicy alignment =
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    LogicalKeyboardKey? navigationKey,
    String? expectedGameId,
  }) {
    // A second key press can supersede a lazy-scroll callback that was queued
    // for the previous selection. Never let that stale callback move the
    // viewport away from the currently selected game.
    if (expectedGameId != null && _selectedGameId != expectedGameId) return;
    final context = _selectedItemKey.currentContext;
    if (context == null) {
      // Lazy slivers intentionally do not mount cards outside their viewport.
      // Move their owning scroll position toward the keyboard destination so
      // the selected card is created, then perform the precise ensureVisible
      // pass on the following frame. Eagerly retaining every GlobalKey target
      // would defeat the realtime lifecycle bounds this host is designed for.
      final controller = widget.scrollController;
      if (navigationKey == null ||
          controller == null ||
          !controller.hasClients ||
          controller.positions.length != 1) {
        return;
      }
      final position = controller.position;
      final target =
          navigationKey == LogicalKeyboardKey.home
              ? position.minScrollExtent
              : navigationKey == LogicalKeyboardKey.end
              ? position.maxScrollExtent
              : (position.pixels +
                      (_isBackwardNavigation(navigationKey) ? -1 : 1) *
                          position.viewportDimension *
                          0.8)
                  .clamp(position.minScrollExtent, position.maxScrollExtent)
                  .toDouble();
      if (target != position.pixels) {
        controller.jumpTo(target);
      } else {
        // Reaching an extent without mounting the key means there is nowhere
        // else to search. This also bounds the retry chain without imposing a
        // fixed attempt cap that would break very large broadcasts.
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ensureSelectedVisible(
          alignment: alignment,
          navigationKey: navigationKey,
          expectedGameId: expectedGameId,
        );
      });
      return;
    }
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignmentPolicy: alignment,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      // No `autofocus: true` here — initState's post-frame guard claims focus
      // only when nothing else owns it. autofocus runs unconditionally on
      // every rebuild and would re-steal focus from sibling inputs.
      canRequestFocus: true,
      onKeyEvent: _handleKey,
      child: widget.builder(context, _selectedGameId, _selectGame, _keyForGame),
    );
  }
}

class DesktopGameKeyboardItem extends StatelessWidget {
  const DesktopGameKeyboardItem({
    super.key,
    required this.itemKey,
    required this.gameId,
    required this.onSelect,
    required this.child,
  });

  final Key itemKey;
  final String gameId;
  final ValueChanged<String> onSelect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: itemKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onSelect(gameId),
        child: child,
      ),
    );
  }
}

bool _sameGameIds(List<GamesTourModel> a, List<GamesTourModel> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].gameId != b[i].gameId) return false;
  }
  return true;
}
