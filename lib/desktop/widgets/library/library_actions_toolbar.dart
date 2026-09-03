import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/library_import_buffer.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/utils/pgn_multi_parser.dart';

/// Compact forui action bar that lives on the right side of a folder
/// header in the Library pane. Surfaces the import / new-folder / tools
/// actions that mobile reaches through a bottom sheet, adapted to the
/// desktop idiom: icon-only buttons with tooltips, keyboard-friendly,
/// no haptics.
///
/// Exposes its callbacks instead of triggering navigation directly so the
/// pane wiring (which folder is currently selected, which dialog to show
/// for "New folder") stays in `library_pane.dart`.
class LibraryActionsToolbar extends ConsumerWidget {
  const LibraryActionsToolbar({
    super.key,
    required this.onNewFolder,
    required this.onImportPgnFiles,
    this.onNewDatabase,
    this.newFolderTooltip = 'New folder',
    this.disabledNewFolderTooltip,
    this.suggestedFolderId,
    this.buttonSize = 34,
    this.iconSize = 17,
    this.spacing = 6,
    this.hitSize,
    this.showLabels = false,
    this.showNewFolderAction = true,
    this.showImportAction = true,
  });

  /// Opens the create-folder dialog. Routed through the pane so the call
  /// site can decide whether to lock the parent (when invoked from inside
  /// a folder context).
  final VoidCallback? onNewFolder;

  /// Creates a cloud database. Local databases enter through Import PGN.
  final VoidCallback? onNewDatabase;

  /// Tooltip shown for the create-folder action while it is enabled.
  final String newFolderTooltip;

  /// Tooltip shown for the create-folder action while it is disabled.
  final String? disabledNewFolderTooltip;

  /// Opens picked PGN files as a persistent local database. This action must
  /// not stage games in the temporary Library import preview.
  final VoidCallback onImportPgnFiles;

  /// When set, pasted games are pre-routed to this folder in the
  /// save-to-folder dialog (used when toolbar actions are invoked while
  /// a folder is selected in the sidebar).
  final String? suggestedFolderId;

  /// Visible square size for each icon button.
  final double buttonSize;

  /// Icon size inside each action button.
  final double iconSize;

  /// Horizontal gap between action buttons.
  final double spacing;

  /// Optional pointer target size. When larger than [buttonSize], the
  /// visible button stays compact while the hit area remains comfortable.
  final double? hitSize;

  /// Uses visible labels for the primary Library Home actions.
  final bool showLabels;
  final bool showNewFolderAction;
  final bool showImportAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> handlePasteClipboard() async {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboard?.text?.trim();
      if (text == null || text.isEmpty) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Clipboard is empty — copy a PGN first.',
          error: true,
        );
        return;
      }
      final parsed = await parsePgnsToChessGamesAsync(text);
      if (parsed.isEmpty) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Clipboard does not contain a valid PGN.',
          error: true,
        );
        return;
      }
      ref
          .read(libraryImportBufferProvider.notifier)
          .accept(
            games: parsed.map((e) => e.chessGame).toList(),
            sourceLabel: 'clipboard',
            suggestedFolderId: suggestedFolderId,
          );
    }

    return FTheme(
      data: FThemes.zinc.dark,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showImportAction) ...[
            _IconAction(
              tooltip: 'Import PGN file — pick .pgn files from disk',
              label: showLabels ? 'Import PGN' : null,
              icon: Icons.file_upload_rounded,
              accent: const Color(0xFFFBBF24),
              buttonSize: buttonSize,
              iconSize: iconSize,
              hitSize: hitSize,
              onPress: onImportPgnFiles,
            ),
            SizedBox(width: spacing),
          ],
          if (showNewFolderAction) ...[
            _IconAction(
              tooltip:
                  onNewFolder == null
                      ? disabledNewFolderTooltip ?? newFolderTooltip
                      : newFolderTooltip,
              label: showLabels ? 'New folder' : null,
              icon: Icons.create_new_folder_rounded,
              accent: const Color(0xFF60A5FA),
              buttonSize: buttonSize,
              iconSize: iconSize,
              hitSize: hitSize,
              onPress: onNewFolder,
            ),
            SizedBox(width: spacing),
          ],
          if (onNewDatabase != null) ...[
            _IconAction(
              tooltip: 'Create a cloud database',
              label: showLabels ? 'New database' : null,
              icon: Icons.add_rounded,
              accent: const Color(0xFF38BDF8),
              buttonSize: buttonSize,
              iconSize: iconSize,
              hitSize: hitSize,
              emphasized: true,
              onPress: onNewDatabase,
            ),
            SizedBox(width: spacing),
          ],
          _IconAction(
            tooltip: 'Paste PGN from clipboard',
            icon: Icons.content_paste_go_rounded,
            accent: const Color(0xFF34D399),
            buttonSize: buttonSize,
            iconSize: iconSize,
            hitSize: hitSize,
            onPress: handlePasteClipboard,
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.tooltip,
    this.label,
    required this.icon,
    required this.accent,
    required this.buttonSize,
    required this.iconSize,
    this.hitSize,
    required this.onPress,
    this.emphasized = false,
  });

  final String tooltip;
  final String? label;
  final IconData icon;
  final Color accent;
  final double buttonSize;
  final double iconSize;
  final double? hitSize;
  final VoidCallback? onPress;
  final bool emphasized;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction>
    with DeferredPointerStateMixin<_IconAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final borderColor =
        enabled
            ? (widget.emphasized
                ? widget.accent.withValues(alpha: _hovered ? 0.85 : 0.55)
                : _hovered
                ? widget.accent.withValues(alpha: 0.70)
                : const Color(0xFF3F3F46))
            : const Color(0xFF27272A);
    final background =
        !enabled
            ? const Color(0xFF141416)
            : (_pressed
                ? widget.accent.withValues(alpha: 0.22)
                : (_hovered
                    ? widget.accent.withValues(alpha: 0.14)
                    : widget.emphasized
                    ? widget.accent.withValues(alpha: 0.10)
                    : const Color(0xFF18181B)));
    final iconColor =
        !enabled
            ? const Color(0xFF71717A)
            : (_hovered ? widget.accent : const Color(0xFFE4E4E7));
    final effectiveHitSize =
        widget.hitSize == null || widget.hitSize! < widget.buttonSize
            ? widget.buttonSize
            : widget.hitSize!;
    return DesktopTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter:
            enabled
                ? (_) => setStateAfterPointerEvent(() => _hovered = true)
                : null,
        onExit:
            (_) => setStateAfterPointerEvent(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          onTapDown:
              enabled
                  ? (_) => setStateAfterPointerEvent(() => _pressed = true)
                  : null,
          onTapUp:
              enabled
                  ? (_) => setStateAfterPointerEvent(() => _pressed = false)
                  : null,
          onTapCancel: () => setStateAfterPointerEvent(() => _pressed = false),
          child: SizedBox(
            height: effectiveHitSize,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                constraints: BoxConstraints(minWidth: widget.buttonSize),
                height: widget.buttonSize,
                padding:
                    widget.label == null
                        ? EdgeInsets.zero
                        : const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                  boxShadow:
                      _hovered
                          ? [
                            BoxShadow(
                              color: widget.accent.withValues(alpha: 0.18),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ]
                          : null,
                ),
                child:
                    widget.label == null
                        ? Icon(
                          widget.icon,
                          size: widget.iconSize,
                          color: iconColor,
                        )
                        : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.icon,
                              size: widget.iconSize,
                              color: iconColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              widget.label!,
                              style: TextStyle(
                                color: iconColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
