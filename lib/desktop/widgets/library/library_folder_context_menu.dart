import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

/// Logical actions a folder row can dispatch from its right-click menu.
/// Mirrors the icon set the mobile folder header surfaces in
/// `folder_contents_screen.dart`.
enum LibraryFolderAction {
  showOnMyDatabases,
  rename,
  newSubfolder,
  exportPgn,
  delete,
}

/// Opens the same actions menu the folder rows use, anchored at a global
/// offset (the bottom-left of an overflow button, etc.). Lets the right-pane
/// header reuse the rail's right-click menu instead of duplicating the
/// item list.
void showLibraryFolderActionsMenu({
  required BuildContext context,
  required Offset anchor,
  required LibraryFolder folder,
  required ValueChanged<LibraryFolderAction> onAction,
  bool canCreateSubfolder = true,
  bool hasGames = true,
}) {
  unawaited(
    _showFolderMenu(
      context: context,
      anchor: anchor,
      folder: folder,
      canCreateSubfolder: canCreateSubfolder,
      hasGames: hasGames,
      onAction: onAction,
    ),
  );
}

/// Wraps [child] in a region that opens a forui-styled context menu on
/// right-click (or long press for trackpad users). The menu items adapt
/// to the folder kind: subscribed (read-only) folders only get Export.
class LibraryFolderContextMenu extends StatelessWidget {
  const LibraryFolderContextMenu({
    super.key,
    required this.folder,
    required this.onAction,
    required this.child,
    this.canCreateSubfolder = true,
    this.hasGames = true,
  });

  final LibraryFolder folder;
  final ValueChanged<LibraryFolderAction> onAction;
  final Widget child;
  final bool canCreateSubfolder;

  /// Disables the export entry when the folder has no direct games.
  final bool hasGames;

  Future<void> _open(BuildContext context, Offset globalPos) {
    return _showFolderMenu(
      context: context,
      anchor: globalPos,
      folder: folder,
      canCreateSubfolder: canCreateSubfolder,
      hasGames: hasGames,
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
  required bool canCreateSubfolder,
  required bool hasGames,
}) async {
  final isSubscribed = folder.isSubscribed;
  final action = await showDesktopContextMenu<LibraryFolderAction>(
    context: context,
    position: anchor,
    width: 236,
    entries: [
      if (!isSubscribed) ...[
        const DesktopContextMenuItem(
          value: LibraryFolderAction.showOnMyDatabases,
          icon: Icons.add_circle_outline_rounded,
          label: 'Show on My Databases',
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
        if (canCreateSubfolder)
          const DesktopContextMenuItem(
            value: LibraryFolderAction.newSubfolder,
            icon: Icons.create_new_folder_outlined,
            label: 'New sub-folder...',
          ),
        const DesktopContextMenuItem(
          value: LibraryFolderAction.rename,
          icon: Icons.edit_outlined,
          label: 'Rename...',
        ),
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: LibraryFolderAction.delete,
          icon: Icons.delete_outline_rounded,
          label: 'Delete folder',
          destructive: true,
        ),
      ],
    ],
  );
  if (action == null || !context.mounted) return;
  onAction(action);
}
