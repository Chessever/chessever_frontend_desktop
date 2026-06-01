import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';

enum _BoardContextAction {
  share,
  copyPgn,
  copyFen,
  saveGameToLibrary,
  savePgn,
  playFromHere,
  positionSetup,
  boardSettings,
}

/// Show the board context menu anchored at [position] in screen coordinates.
Future<void> showBoardContextMenu(
  WidgetRef ref,
  BuildContext context, {
  required Offset position,
  required VoidCallback onShareGame,
  required VoidCallback onCopyPgn,
  required VoidCallback onCopyFen,
  required VoidCallback onSavePgn,
  required VoidCallback onSaveGameToLibrary,
  required VoidCallback onOpenBoardSettings,
  required VoidCallback onOpenPositionSetup,
  required bool canCopyOrSavePgn,
  VoidCallback? onPlayFromHere,
}) async {
  final shortcuts =
      ref.read(keyboardShortcutsProvider).valueOrNull ??
      BoardShortcutMap(defaultBoardShortcuts());

  String? hintFor(BoardActionKey action) {
    final chords = shortcuts.chordsFor(action);
    if (chords.isEmpty) return null;
    return chords.first.label;
  }

  final selected = await showDesktopContextMenu<_BoardContextAction>(
    context: context,
    position: position,
    width: 232,
    entries: [
      const DesktopContextMenuItem(
        value: _BoardContextAction.share,
        icon: Icons.share_rounded,
        label: 'Share Game',
      ),
      const DesktopContextMenuDivider(),
      DesktopContextMenuItem(
        value: _BoardContextAction.copyPgn,
        icon: Icons.copy_rounded,
        label: 'Copy PGN',
        shortcut: hintFor(BoardActionKey.copyPgn),
        enabled: canCopyOrSavePgn,
      ),
      const DesktopContextMenuItem(
        value: _BoardContextAction.copyFen,
        icon: Icons.content_paste_go_rounded,
        label: 'Copy FEN',
      ),
      DesktopContextMenuItem(
        value: _BoardContextAction.saveGameToLibrary,
        icon: Icons.library_add_outlined,
        label: 'Save game to library…',
        shortcut: hintFor(BoardActionKey.saveGameToLibrary),
        enabled: canCopyOrSavePgn,
      ),
      DesktopContextMenuItem(
        value: _BoardContextAction.savePgn,
        icon: Icons.save_alt_rounded,
        label: 'Save PGN to file...',
        shortcut: hintFor(BoardActionKey.savePgnFile),
        enabled: canCopyOrSavePgn,
      ),
      const DesktopContextMenuDivider(),
      DesktopContextMenuItem(
        value: _BoardContextAction.playFromHere,
        icon: Icons.sports_esports_outlined,
        label: 'Play from here…',
        enabled: onPlayFromHere != null,
      ),
      const DesktopContextMenuDivider(),
      DesktopContextMenuItem(
        value: _BoardContextAction.positionSetup,
        icon: Icons.edit_location_alt_outlined,
        label: 'Position setup',
        shortcut: hintFor(BoardActionKey.openPositionSetup),
      ),
      DesktopContextMenuItem(
        value: _BoardContextAction.boardSettings,
        icon: Icons.dashboard_customize_outlined,
        label: 'Board settings',
        shortcut: hintFor(BoardActionKey.openBoardSettings),
      ),
    ],
  );
  if (selected == null || !context.mounted) return;

  switch (selected) {
    case _BoardContextAction.share:
      onShareGame();
    case _BoardContextAction.copyPgn:
      onCopyPgn();
    case _BoardContextAction.copyFen:
      onCopyFen();
    case _BoardContextAction.saveGameToLibrary:
      onSaveGameToLibrary();
    case _BoardContextAction.savePgn:
      onSavePgn();
    case _BoardContextAction.playFromHere:
      onPlayFromHere?.call();
    case _BoardContextAction.positionSetup:
      onOpenPositionSetup();
    case _BoardContextAction.boardSettings:
      onOpenBoardSettings();
  }
}
