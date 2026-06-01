import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';

/// Logical actions the games table / cards can dispatch from a row's
/// right-click menu. Mirrors the most useful subset of the board view's
/// capabilities (open, share, copy PGN/FEN, export) plus library-only actions
/// (delete) so the user never has to enter the board view to act on a game.
enum LibraryGameAction {
  open,
  openInNewTab,
  share,
  copyShareLink,
  copyPgn,
  copyFen,
  exportPgn,
  delete,
}

/// Wraps [child] in a region that opens a forui-styled context menu on
/// right-click (or long press for trackpad users). Subscribed (read-only)
/// folders gate the destructive action via [canDelete].
class LibraryGameContextMenu extends StatelessWidget {
  const LibraryGameContextMenu({
    super.key,
    required this.analysis,
    required this.onAction,
    required this.child,
    this.canDelete = true,
    this.useLongPress = true,
  });

  final SavedAnalysis analysis;
  final ValueChanged<LibraryGameAction> onAction;
  final Widget child;

  /// `false` for analyses inside subscribed folders — the user does not own
  /// them so the delete entry is disabled to make the constraint visible.
  final bool canDelete;

  /// Disable when the wrapped widget already owns long-press for another
  /// gesture (e.g. the games table reserves it for drag-to-tab spawning),
  /// so right-click stays the only path to the menu.
  final bool useLongPress;

  Future<void> _open(BuildContext context, Offset globalPos) async {
    final shareUrl = buildSavedAnalysisShareUrl(analysis);
    final hasMoves = analysis.chessGame.mainline.isNotEmpty;
    final action = await showDesktopContextMenu<LibraryGameAction>(
      context: context,
      position: globalPos,
      width: 248,
      entries: [
        const DesktopContextMenuItem(
          value: LibraryGameAction.open,
          icon: Icons.open_in_new_rounded,
          label: 'Open in board',
        ),
        const DesktopContextMenuItem(
          value: LibraryGameAction.openInNewTab,
          icon: Icons.tab_outlined,
          label: 'Open in new tab',
        ),
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: LibraryGameAction.share,
          icon: Icons.share_rounded,
          label: 'Share Game',
        ),
        DesktopContextMenuItem(
          value: LibraryGameAction.copyShareLink,
          icon: Icons.copy_rounded,
          label: 'Copy share link',
          enabled: shareUrl != null,
        ),
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: LibraryGameAction.copyPgn,
          icon: Icons.content_copy_rounded,
          label: 'Copy PGN',
        ),
        DesktopContextMenuItem(
          value: LibraryGameAction.copyFen,
          icon: Icons.code_rounded,
          label: hasMoves ? 'Copy final-position FEN' : 'Copy FEN',
        ),
        const DesktopContextMenuItem(
          value: LibraryGameAction.exportPgn,
          icon: Icons.save_alt_rounded,
          label: 'Export as PGN...',
        ),
        const DesktopContextMenuDivider(),
        DesktopContextMenuItem(
          value: LibraryGameAction.delete,
          icon: Icons.delete_outline_rounded,
          label: 'Delete game',
          destructive: true,
          enabled: canDelete,
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _open(context, details.globalPosition),
      onLongPressStart:
          useLongPress
              ? (details) => _open(context, details.globalPosition)
              : null,
      child: child,
    );
  }
}
