import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

/// Logical actions a cloud folder/database can dispatch from its right-click
/// menu. Library Home membership is non-destructive and remains separate from
/// cloud deletion.
enum LibraryFolderAction {
  showOnLibraryHome,
  removeFromLibraryHome,
  rename,
  newDatabase,
  exportPgn,
  delete,
}

enum _LibraryFolderPinAction { pin, unpin }

/// Opens the same actions menu the folder rows use, anchored at a global
/// offset (the bottom-left of an overflow button, etc.). Lets the right-pane
/// header reuse the rail's right-click menu instead of duplicating the list.
void showLibraryFolderActionsMenu({
  required BuildContext context,
  required Offset anchor,
  required LibraryFolder folder,
  required ValueChanged<LibraryFolderAction> onAction,
  bool canCreateDatabase = true,
  bool hasGames = true,
  bool includeLibraryHomeAction = true,
  bool isShownOnLibraryHome = false,
  bool isPinned = false,
  ValueChanged<bool>? onPinnedChanged,
}) {
  unawaited(
    _showFolderMenu(
      context: context,
      anchor: anchor,
      folder: folder,
      canCreateDatabase: canCreateDatabase,
      hasGames: hasGames,
      includeLibraryHomeAction: includeLibraryHomeAction,
      isShownOnLibraryHome: isShownOnLibraryHome,
      isPinned: isPinned,
      onPinnedChanged: onPinnedChanged,
      onAction: onAction,
    ),
  );
}

/// Wraps [child] in a region that opens a forui-styled context menu on
/// right-click (or long press for trackpad users). The menu items adapt to the
/// cloud item's mutability and Library Home membership.
class LibraryFolderContextMenu extends StatelessWidget {
  const LibraryFolderContextMenu({
    super.key,
    required this.folder,
    required this.onAction,
    required this.child,
    this.canCreateDatabase = true,
    this.hasGames = true,
    this.includeLibraryHomeAction = true,
    this.isShownOnLibraryHome = false,
    this.isPinned = false,
    this.onPinnedChanged,
  });

  final LibraryFolder folder;
  final ValueChanged<LibraryFolderAction> onAction;
  final Widget child;

  /// Whether this folder can contain a directly nested database.
  final bool canCreateDatabase;

  /// Disables the export entry when the item has no games.
  final bool hasGames;

  /// Shows the non-destructive Library Home membership action.
  final bool includeLibraryHomeAction;

  /// Whether this cloud item currently appears on Library Home.
  final bool isShownOnLibraryHome;

  /// Whether this folder/database is pinned on Library Home.
  final bool isPinned;

  /// Adds a Pin/Unpin action when supplied for a Home-managed item.
  final ValueChanged<bool>? onPinnedChanged;

  Future<void> _open(BuildContext context, Offset globalPos) {
    return _showFolderMenu(
      context: context,
      anchor: globalPos,
      folder: folder,
      canCreateDatabase: canCreateDatabase,
      hasGames: hasGames,
      includeLibraryHomeAction: includeLibraryHomeAction,
      isShownOnLibraryHome: isShownOnLibraryHome,
      isPinned: isPinned,
      onPinnedChanged: onPinnedChanged,
      onAction: onAction,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _open(context, details.globalPosition),
      onLongPressStart: (details) => _open(context, details.globalPosition),
      child: child,
    );
  }
}

Future<void> _showFolderMenu({
  required BuildContext context,
  required Offset anchor,
  required LibraryFolder folder,
  required ValueChanged<LibraryFolderAction> onAction,
  required bool canCreateDatabase,
  required bool hasGames,
  required bool includeLibraryHomeAction,
  required bool isShownOnLibraryHome,
  required bool isPinned,
  required ValueChanged<bool>? onPinnedChanged,
}) async {
  final isSubscribed = folder.isSubscribed;
  final canRenameOrDelete = !isSubscribed && !folder.isPermanentLibraryFolder;
  final canChangePin =
      onPinnedChanged != null && !folder.isPermanentLibraryFolder;
  final action = await showDesktopContextMenu<Object>(
    context: context,
    position: anchor,
    width: 252,
    entries: [
      if (canChangePin) ...[
        DesktopContextMenuItem(
          value:
              isPinned
                  ? _LibraryFolderPinAction.unpin
                  : _LibraryFolderPinAction.pin,
          icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          label: isPinned ? 'Unpin folder' : 'Pin folder',
        ),
        const DesktopContextMenuDivider(),
      ],
      if (!isSubscribed && includeLibraryHomeAction) ...[
        DesktopContextMenuItem(
          value:
              isShownOnLibraryHome
                  ? LibraryFolderAction.removeFromLibraryHome
                  : LibraryFolderAction.showOnLibraryHome,
          icon:
              isShownOnLibraryHome
                  ? Icons.remove_circle_outline_rounded
                  : Icons.add_circle_outline_rounded,
          label:
              isShownOnLibraryHome
                  ? 'Remove from Library Home'
                  : 'Show on Library Home',
        ),
        const DesktopContextMenuDivider(),
      ],
      DesktopContextMenuItem(
        value: LibraryFolderAction.exportPgn,
        icon: Icons.save_alt_rounded,
        label: 'Export as PGN...',
        enabled: hasGames,
      ),
      if (!isSubscribed) ...[
        const DesktopContextMenuDivider(),
        if (canCreateDatabase)
          const DesktopContextMenuItem(
            value: LibraryFolderAction.newDatabase,
            icon: Icons.storage_rounded,
            label: 'New database...',
          ),
        if (canRenameOrDelete) ...[
          const DesktopContextMenuItem(
            value: LibraryFolderAction.rename,
            icon: Icons.edit_outlined,
            label: 'Rename...',
          ),
          const DesktopContextMenuDivider(),
          const DesktopContextMenuItem(
            value: LibraryFolderAction.delete,
            icon: Icons.cloud_off_outlined,
            label: 'Delete from Cloud',
            destructive: true,
          ),
        ],
      ],
    ],
  );
  if (action == null || !context.mounted) return;
  if (action is _LibraryFolderPinAction) {
    onPinnedChanged?.call(action == _LibraryFolderPinAction.pin);
    return;
  }
  if (action is LibraryFolderAction) onAction(action);
}
