import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/library_import_buffer.dart';
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
    this.suggestedFolderId,
  });

  /// Opens the create-folder dialog. Routed through the pane so the call
  /// site can decide whether to lock the parent (when invoked from inside
  /// a folder context).
  final VoidCallback onNewFolder;

  /// Opens picked PGN files as a persistent local database. This action must
  /// not stage games in the temporary Library import preview.
  final VoidCallback onImportPgnFiles;

  /// When set, pasted games are pre-routed to this folder in the
  /// save-to-folder dialog (used when toolbar actions are invoked while
  /// a folder is selected in the sidebar).
  final String? suggestedFolderId;

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
          _IconAction(
            tooltip: 'New folder — create a folder or database',
            icon: Icons.create_new_folder_rounded,
            accent: const Color(0xFF60A5FA),
            onPress: onNewFolder,
          ),
          const SizedBox(width: 6),
          _IconAction(
            tooltip: 'Import PGN file — pick .pgn files from disk',
            icon: Icons.file_upload_rounded,
            accent: const Color(0xFFFBBF24),
            onPress: onImportPgnFiles,
          ),
          const SizedBox(width: 6),
          _IconAction(
            tooltip: 'Paste PGN from clipboard',
            icon: Icons.content_paste_go_rounded,
            accent: const Color(0xFF34D399),
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
    required this.icon,
    required this.accent,
    required this.onPress,
  });

  final String tooltip;
  final IconData icon;
  final Color accent;
  final VoidCallback onPress;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        _hovered
            ? widget.accent.withValues(alpha: 0.70)
            : const Color(0xFF3F3F46);
    final background =
        _pressed
            ? widget.accent.withValues(alpha: 0.22)
            : (_hovered
                ? widget.accent.withValues(alpha: 0.14)
                : const Color(0xFF18181B));
    final iconColor = _hovered ? widget.accent : const Color(0xFFE4E4E7);
    return DesktopTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            width: 34,
            height: 34,
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
            child: Icon(widget.icon, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}
