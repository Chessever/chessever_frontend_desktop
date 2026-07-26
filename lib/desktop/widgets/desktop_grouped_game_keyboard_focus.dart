import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class DesktopGameKeyboardGroup {
  const DesktopGameKeyboardGroup({
    required this.id,
    required this.games,
    this.expanded = true,
  });

  final String id;
  final List<GamesTourModel> games;
  final bool expanded;
}

class DesktopGroupedGameSelection {
  const DesktopGroupedGameSelection.group(this.groupId) : gameId = null;

  const DesktopGroupedGameSelection.game(this.groupId, this.gameId);

  final String groupId;
  final String? gameId;

  bool get isGroup => gameId == null;
  bool get isGame => gameId != null;
}

typedef DesktopGroupedGameKeyboardFocusBuilder =
    Widget Function(
      BuildContext context,
      DesktopGroupedGameSelection? selection,
      void Function(String groupId) selectGroup,
      void Function(String groupId, String gameId) selectGame,
      Key Function(String groupId) keyForGroup,
      Key Function(String groupId, String gameId) keyForGame,
    );

/// Keyboard host for feeds made of a selectable group header followed by games.
///
/// Up/Down follows the visual hierarchy: header -> board rows -> next header.
/// Left/Right always moves exactly one board and never crosses a group boundary.
/// Enter activates the highlighted header or game.
class DesktopGroupedGameKeyboardFocus extends StatefulWidget {
  const DesktopGroupedGameKeyboardFocus({
    super.key,
    required this.scopeId,
    required this.groups,
    required this.builder,
    required this.onActivateGame,
    this.onActivateGroup,
    this.resolveColumnCount,
    this.scrollController,
    this.pageGroupStride = 4,
    this.ensureInitialSelectionVisible = false,
  });

  final String scopeId;
  final List<DesktopGameKeyboardGroup> groups;
  final DesktopGroupedGameKeyboardFocusBuilder builder;
  final ValueChanged<GamesTourModel> onActivateGame;
  final ValueChanged<String>? onActivateGroup;
  final int Function(String groupId)? resolveColumnCount;
  final ScrollController? scrollController;
  final int pageGroupStride;
  final bool ensureInitialSelectionVisible;

  @override
  State<DesktopGroupedGameKeyboardFocus> createState() =>
      _DesktopGroupedGameKeyboardFocusState();
}

class _DesktopGroupedGameKeyboardFocusState
    extends State<DesktopGroupedGameKeyboardFocus> {
  late final FocusNode _focusNode;
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  DesktopGroupedGameSelection? _selection;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'desktop-grouped-game-keyboard-${widget.scopeId}',
    );
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _syncSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_canClaimFocus()) _focusNode.requestFocus();
      if (widget.ensureInitialSelectionVisible) _ensureSelectedVisible();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_handleTickerModeChanged);
      _tickerMode = notifier..addListener(_handleTickerModeChanged);
    }
  }

  void _handleTickerModeChanged() {
    if (_tickerMode?.value.enabled != true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canClaimFocus()) _focusNode.requestFocus();
    });
  }

  bool _canClaimFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _focusNode) return true;
    if (!primary.canRequestFocus || _focusNode.ancestors.contains(primary)) {
      return true;
    }
    final primaryContext = primary.context;
    if (primaryContext != null) {
      final ownsEditableText =
          primaryContext.widget is EditableText ||
          primaryContext.findAncestorWidgetOfExactType<EditableText>() != null;
      if (ownsEditableText) return false;
      final primaryRoute = ModalRoute.of(primaryContext);
      final gamesRoute = ModalRoute.of(context);
      if (primaryRoute != null &&
          gamesRoute != null &&
          primaryRoute != gamesRoute) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(covariant DesktopGroupedGameKeyboardFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scopeId == widget.scopeId &&
        _sameGroups(oldWidget.groups, widget.groups)) {
      return;
    }
    final ownedPrimaryFocus = _focusNode.hasPrimaryFocus;
    _syncSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (oldWidget.scopeId != widget.scopeId || ownedPrimaryFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_handleTickerModeChanged);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncSelection() {
    if (widget.groups.isEmpty) {
      _selection = null;
      return;
    }
    final current = _selection;
    if (current == null) {
      _selection = DesktopGroupedGameSelection.group(widget.groups.first.id);
      return;
    }
    final group = _groupById(current.groupId);
    if (group == null) {
      _selection = DesktopGroupedGameSelection.group(widget.groups.first.id);
      return;
    }
    if (current.isGame &&
        (!group.expanded ||
            !group.games.any((game) => game.gameId == current.gameId))) {
      _selection = DesktopGroupedGameSelection.group(group.id);
    }
  }

  DesktopGameKeyboardGroup? _groupById(String groupId) {
    for (final group in widget.groups) {
      if (group.id == groupId) return group;
    }
    return null;
  }

  GlobalKey _keyForGroup(String groupId) {
    final identity = '${widget.scopeId}\u0000group\u0000$groupId';
    return _itemKeys.putIfAbsent(
      identity,
      () => GlobalKey(
        debugLabel: 'desktop-grouped-keyboard:${widget.scopeId}:group:$groupId',
      ),
    );
  }

  GlobalKey _keyForGame(String groupId, String gameId) {
    final identity = '${widget.scopeId}\u0000game\u0000$groupId\u0000$gameId';
    return _itemKeys.putIfAbsent(
      identity,
      () => GlobalKey(
        debugLabel:
            'desktop-grouped-keyboard:${widget.scopeId}:game:$groupId:$gameId',
      ),
    );
  }

  void _select(
    DesktopGroupedGameSelection selection, {
    bool ensureVisible = false,
    LogicalKeyboardKey? navigationKey,
  }) {
    final unchanged =
        _selection?.groupId == selection.groupId &&
        _selection?.gameId == selection.gameId;
    if (!unchanged) setState(() => _selection = selection);
    _focusNode.requestFocus();
    if (ensureVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ensureSelectedVisible(
          navigationKey: navigationKey,
          expected: selection,
        );
      });
    }
  }

  void _selectGroup(String groupId) {
    _select(DesktopGroupedGameSelection.group(groupId));
  }

  void _selectGame(String groupId, String gameId) {
    _select(DesktopGroupedGameSelection.game(groupId, gameId));
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

  bool _isNavigationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
  }

  /// Keeps grouped event navigation authoritative when focus is temporarily
  /// parked on the pane's generic scroll wrapper or another non-editable
  /// control. Without this guard, Up/Down occasionally scroll pixels instead
  /// of advancing the highlighted round or board.
  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted ||
        !TickerMode.valuesOf(context).enabled ||
        _focusNode.hasFocus ||
        _hasNavigationModifier() ||
        !_isNavigationKey(event.logicalKey)) {
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final primaryContext = FocusManager.instance.primaryFocus?.context;
    if (primaryContext != null) {
      final ownsEditableText =
          primaryContext.widget is EditableText ||
          primaryContext.findAncestorWidgetOfExactType<EditableText>() != null;
      if (ownsEditableText) return false;

      final primaryRoute = ModalRoute.of(primaryContext);
      final gamesRoute = ModalRoute.of(context);
      if (primaryRoute != null &&
          gamesRoute != null &&
          primaryRoute != gamesRoute) {
        return false;
      }
    }

    return _handleKey(_focusNode, event) == KeyEventResult.handled;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (_hasNavigationModifier()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isActivation =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final isNavigation = _isNavigationKey(key);
    if (!isActivation && !isNavigation) return KeyEventResult.ignored;
    // Selection moves once per physical key press. Consume repeat events so
    // they cannot bubble to an ancestor pixel scroller and separate the
    // viewport from the highlighted group or board.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (isActivation) {
      final selection = _selection;
      if (selection == null) return KeyEventResult.ignored;
      if (selection.isGroup) {
        final callback = widget.onActivateGroup;
        if (callback == null) return KeyEventResult.ignored;
        callback(selection.groupId);
      } else {
        final group = _groupById(selection.groupId);
        final game = group?.games.cast<GamesTourModel?>().firstWhere(
          (candidate) => candidate?.gameId == selection.gameId,
          orElse: () => null,
        );
        if (game == null) return KeyEventResult.ignored;
        widget.onActivateGame(game);
      }
      return KeyEventResult.handled;
    }

    final next = _nextSelection(key);
    if (next == null) return KeyEventResult.ignored;
    _select(next, ensureVisible: true, navigationKey: key);
    return KeyEventResult.handled;
  }

  DesktopGroupedGameSelection? _nextSelection(LogicalKeyboardKey key) {
    final groups = widget.groups;
    if (groups.isEmpty) return null;
    final current = _selection;
    if (current == null) {
      return DesktopGroupedGameSelection.group(groups.first.id);
    }
    final groupIndex = groups.indexWhere(
      (group) => group.id == current.groupId,
    );
    if (groupIndex < 0) {
      return DesktopGroupedGameSelection.group(groups.first.id);
    }
    final group = groups[groupIndex];

    if (key == LogicalKeyboardKey.home) {
      return DesktopGroupedGameSelection.group(groups.first.id);
    }
    if (key == LogicalKeyboardKey.end) {
      final last = groups.last;
      if (last.expanded && last.games.isNotEmpty) {
        return DesktopGroupedGameSelection.game(
          last.id,
          last.games.last.gameId,
        );
      }
      return DesktopGroupedGameSelection.group(last.id);
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown) {
      final direction = key == LogicalKeyboardKey.pageUp ? -1 : 1;
      final target =
          (groupIndex + direction * math.max(1, widget.pageGroupStride))
              .clamp(0, groups.length - 1)
              .toInt();
      return DesktopGroupedGameSelection.group(groups[target].id);
    }

    if (current.isGroup) {
      if (key == LogicalKeyboardKey.arrowDown) {
        if (group.expanded && group.games.isNotEmpty) {
          return DesktopGroupedGameSelection.game(
            group.id,
            group.games.first.gameId,
          );
        }
        if (groupIndex + 1 < groups.length) {
          return DesktopGroupedGameSelection.group(groups[groupIndex + 1].id);
        }
      }
      if (key == LogicalKeyboardKey.arrowUp && groupIndex > 0) {
        final previous = groups[groupIndex - 1];
        if (previous.expanded && previous.games.isNotEmpty) {
          return DesktopGroupedGameSelection.game(
            previous.id,
            previous.games.last.gameId,
          );
        }
        return DesktopGroupedGameSelection.group(previous.id);
      }
      return current;
    }

    final gameIndex = group.games.indexWhere(
      (game) => game.gameId == current.gameId,
    );
    if (gameIndex < 0) return DesktopGroupedGameSelection.group(group.id);
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (gameIndex > 0) {
        return DesktopGroupedGameSelection.game(
          group.id,
          group.games[gameIndex - 1].gameId,
        );
      }
      return current;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (gameIndex + 1 < group.games.length) {
        return DesktopGroupedGameSelection.game(
          group.id,
          group.games[gameIndex + 1].gameId,
        );
      }
      return current;
    }
    final columns = math.max(1, widget.resolveColumnCount?.call(group.id) ?? 1);
    if (key == LogicalKeyboardKey.arrowUp) {
      final target = gameIndex - columns;
      if (target >= 0) {
        return DesktopGroupedGameSelection.game(
          group.id,
          group.games[target].gameId,
        );
      }
      return DesktopGroupedGameSelection.group(group.id);
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final target = gameIndex + columns;
      if (target < group.games.length) {
        return DesktopGroupedGameSelection.game(
          group.id,
          group.games[target].gameId,
        );
      }
      if (groupIndex + 1 < groups.length) {
        return DesktopGroupedGameSelection.group(groups[groupIndex + 1].id);
      }
    }
    return current;
  }

  void _ensureSelectedVisible({
    LogicalKeyboardKey? navigationKey,
    DesktopGroupedGameSelection? expected,
  }) {
    if (expected != null &&
        (_selection?.groupId != expected.groupId ||
            _selection?.gameId != expected.gameId)) {
      return;
    }
    final selection = expected ?? _selection;
    final selectedContext =
        selection == null
            ? null
            : selection.isGroup
            ? _keyForGroup(selection.groupId).currentContext
            : _keyForGame(selection.groupId, selection.gameId!).currentContext;
    if (selectedContext != null) {
      Scrollable.ensureVisible(
        selectedContext,
        duration: Duration.zero,
        alignmentPolicy:
            _isBackward(navigationKey)
                ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
                : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      return;
    }
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
                    (_isBackward(navigationKey) ? -1 : 1) *
                        position.viewportDimension *
                        0.8)
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble();
    if ((target - position.pixels).abs() < 0.5) return;
    controller.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensureSelectedVisible(
          navigationKey: navigationKey,
          expected: expected,
        );
      }
    });
  }

  bool _isBackward(LogicalKeyboardKey? key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: true,
      onKeyEvent: _handleKey,
      child: widget.builder(
        context,
        _selection,
        _selectGroup,
        _selectGame,
        _keyForGroup,
        _keyForGame,
      ),
    );
  }
}

class DesktopGroupedGameKeyboardHeader extends StatelessWidget {
  const DesktopGroupedGameKeyboardHeader({
    super.key,
    required this.itemKey,
    required this.groupId,
    required this.onSelect,
    required this.child,
  });

  final Key itemKey;
  final String groupId;
  final ValueChanged<String> onSelect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: itemKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onSelect(groupId),
        child: child,
      ),
    );
  }
}

class DesktopGroupedGameKeyboardItem extends StatelessWidget {
  const DesktopGroupedGameKeyboardItem({
    super.key,
    required this.itemKey,
    required this.groupId,
    required this.gameId,
    required this.onSelect,
    required this.child,
  });

  final Key itemKey;
  final String groupId;
  final String gameId;
  final void Function(String groupId, String gameId) onSelect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: itemKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onSelect(groupId, gameId),
        child: child,
      ),
    );
  }
}

bool _sameGroups(
  List<DesktopGameKeyboardGroup> a,
  List<DesktopGameKeyboardGroup> b,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].expanded != b[i].expanded ||
        a[i].games.length != b[i].games.length) {
      return false;
    }
    for (var gameIndex = 0; gameIndex < a[i].games.length; gameIndex++) {
      if (a[i].games[gameIndex].gameId != b[i].games[gameIndex].gameId) {
        return false;
      }
    }
  }
  return true;
}
