import 'dart:math' as math;

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
}) {
  if (itemCount <= 0) return -1;
  final hasSelection = currentIndex >= 0;
  final safeCurrent =
      hasSelection ? currentIndex.clamp(0, itemCount - 1).toInt() : 0;
  final safePageStride = math.max(1, pageStride);

  if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowDown) {
    // When no item is selected, ArrowDown/Right lands on the first item.
    if (!hasSelection) return 0;
    return math.min(itemCount - 1, safeCurrent + 1);
  }
  if (key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowUp) {
    if (!hasSelection) return 0;
    return math.max(0, safeCurrent - 1);
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
  });

  final String scopeId;
  final List<GamesTourModel> games;
  final int pageStride;
  final ValueChanged<GamesTourModel>? onActivateGame;
  final bool ensureInitialSelectionVisible;
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
      if (FocusScope.of(context).focusedChild == null) {
        _focusNode.requestFocus();
      }
      if (widget.ensureInitialSelectionVisible) {
        _ensureSelectedVisible();
      }
    });
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

  void _selectGame(String gameId, {bool ensureVisible = false}) {
    if (_selectedGameId == gameId) {
      _focusNode.requestFocus();
      if (ensureVisible) _ensureSelectedVisible();
      return;
    }
    setState(() => _selectedGameId = gameId);
    _focusNode.requestFocus();
    if (ensureVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSelectedVisible();
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
    final nextIndex = nextDesktopGameKeyboardIndex(
      currentIndex: currentIndex,
      itemCount: games.length,
      key: key,
      pageStride: widget.pageStride,
    );
    if (nextIndex < 0 || nextIndex >= games.length) {
      return KeyEventResult.ignored;
    }
    _selectGame(games[nextIndex].gameId, ensureVisible: true);
    return KeyEventResult.handled;
  }

  GamesTourModel? _selectedGame() {
    final selected = _selectedGameId;
    if (selected == null) return null;
    for (final game in widget.games) {
      if (game.gameId == selected) return game;
    }
    return null;
  }

  void _ensureSelectedVisible() {
    final context = _selectedItemKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
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
