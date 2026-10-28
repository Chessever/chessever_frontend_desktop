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
  openInNewWindow,
  share,
  copyShareLink,
  gameInfo,
  copyPgn,
  selectAll,
  pasteGames,
  saveToCloud,
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
    this.canPaste = true,
    this.onContextMenuOpening,
    this.useLongPress = true,
  });

  final SavedAnalysis analysis;
  final ValueChanged<LibraryGameAction> onAction;
  final Widget child;

  /// `false` for analyses inside subscribed folders — the user does not own
  /// them so the delete entry is disabled to make the constraint visible.
  final bool canDelete;

  /// `false` for subscribed or system databases, which must not accept a
  /// clipboard import from a row context menu.
  final bool canPaste;

  /// Invoked just before opening the menu. List surfaces use this to select an
  /// unselected row while preserving an existing multi-selection when the
  /// clicked row is already part of it.
  final VoidCallback? onContextMenuOpening;

  /// Disable when the wrapped widget already owns long-press for another
  /// gesture (e.g. the games table reserves it for drag-to-tab spawning),
  /// so right-click stays the only path to the menu.
  final bool useLongPress;

  Future<void> _open(BuildContext context, Offset globalPos) async {
    onContextMenuOpening?.call();
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
        const DesktopContextMenuItem(
          value: LibraryGameAction.openInNewWindow,
          icon: Icons.open_in_new_rounded,
          label: 'Open in new window',
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
        const DesktopContextMenuItem(
          value: LibraryGameAction.selectAll,
          icon: Icons.select_all_rounded,
          label: 'Select all',
        ),
        if (canPaste)
          const DesktopContextMenuItem(
            value: LibraryGameAction.pasteGames,
            icon: Icons.content_paste_rounded,
            label: 'Paste games',
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

/// Right-click menu for a game row inside a **cloud** database — the desktop
/// database-workspace table and its Library-Home preview.
///
/// The subset is what is semantically valid for a saved game that already lives
/// in the cloud:
///
/// * **Game info** — the stored PGN header set.
/// * **Copy PGN** — clipboard export (selection aware at the call site).
/// * **Paste games** — clipboard import into this database [writable] only; a
///   followed/subscribed book is read-only.
/// * **Save To Cloud** — writes *another* copy into a chosen cloud database the
///   account owns, so it stays available even for a followed book: the copy
///   never touches the source and the save dialog only lists writable
///   destinations.
/// * **Delete game** — destructive, [writable] only.
///
/// Board-only and local-file actions (open in board/new tab/window, share,
/// copy FEN, export to disk) stay out of this table menu: those rows are already
/// library records and the surrounding pane previews them in place.
@visibleForTesting
List<DesktopContextMenuEntry<LibraryGameAction>> cloudDatabaseGameMenuEntries({
  required bool writable,
}) => [
  const DesktopContextMenuItem(
    value: LibraryGameAction.gameInfo,
    icon: Icons.info_outline_rounded,
    label: 'Game info',
  ),
  const DesktopContextMenuItem(
    value: LibraryGameAction.copyPgn,
    icon: Icons.content_copy_rounded,
    label: 'Copy PGN',
  ),
  DesktopContextMenuItem(
    value: LibraryGameAction.pasteGames,
    icon: Icons.content_paste_rounded,
    label: 'Paste games',
    enabled: writable,
  ),
  const DesktopContextMenuItem(
    value: LibraryGameAction.saveToCloud,
    icon: Icons.library_add_outlined,
    label: 'Save To Cloud',
  ),
  const DesktopContextMenuDivider(),
  DesktopContextMenuItem(
    value: LibraryGameAction.delete,
    icon: Icons.delete_outline_rounded,
    label: 'Delete game',
    destructive: true,
    enabled: writable,
  ),
];

/// Shows [cloudDatabaseGameMenuEntries] at [position]. Returns the chosen
/// action, or `null` when the user dismissed the menu.
Future<LibraryGameAction?> showCloudDatabaseGameContextMenu({
  required BuildContext context,
  required Offset position,
  required bool writable,
}) => showDesktopContextMenu<LibraryGameAction>(
  context: context,
  position: position,
  width: 248,
  entries: cloudDatabaseGameMenuEntries(writable: writable),
);

/// Wraps a cloud database game row in the right-click region for
/// [cloudDatabaseGameMenuEntries]. The row's own tap/double-tap gestures keep
/// primary-button ownership; this only claims secondary taps.
class LibraryCloudGameRowMenu extends StatelessWidget {
  const LibraryCloudGameRowMenu({
    super.key,
    required this.writable,
    required this.onAction,
    required this.child,
    this.onContextMenuOpening,
  });

  final bool writable;
  final ValueChanged<LibraryGameAction> onAction;

  /// Invoked just before the menu opens so the surface can select this row
  /// without discarding an existing multi-selection.
  final VoidCallback? onContextMenuOpening;

  final Widget child;

  Future<void> _open(BuildContext context, Offset globalPosition) async {
    onContextMenuOpening?.call();
    final action = await showCloudDatabaseGameContextMenu(
      context: context,
      position: globalPosition,
      writable: writable,
    );
    if (action == null || !context.mounted) return;
    onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _open(context, details.globalPosition),
      child: child,
    );
  }
}
