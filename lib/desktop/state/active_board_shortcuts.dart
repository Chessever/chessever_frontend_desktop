import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';

/// Live keyboard dispatcher registered by the currently mounted Board pane.
///
/// Board state is intentionally local to `BoardPane`, but shell-level
/// shortcuts need a way to reach the active board even when focus sits in the
/// tab strip, side list, or another chrome widget inside the shell.
class ActiveBoardShortcutDispatcher {
  const ActiveBoardShortcutDispatcher({
    required this.tabId,
    required this.invoke,
  });

  final String tabId;
  final bool Function(BoardActionKey action) invoke;
}

final activeBoardShortcutDispatcherProvider =
    StateProvider<ActiveBoardShortcutDispatcher?>((_) => null);
