import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Forui-styled "3-dot" menu surfaced on the desktop board.
///
/// Mirrors the mobile chess board's app-bar overflow menu (Board Settings,
/// Share Game, Copy PGN/FEN) — adapted to the keyboard+mouse idiom of the
/// desktop port. Each item dispatches to the BoardPane via the supplied
/// callbacks; this widget is purely chrome.
class BoardActionsPopover extends StatefulWidget {
  const BoardActionsPopover({
    super.key,
    required this.onCopyPgn,
    required this.onCopyFen,
    required this.onSavePgn,
    required this.onOpenBoardSettings,
    required this.onShareGame,
    required this.canCopyOrSavePgn,
  });

  /// Copies the active game's PGN to the system clipboard.
  final VoidCallback onCopyPgn;

  /// Copies the board's current FEN to the system clipboard.
  final VoidCallback onCopyFen;

  /// Writes the active game's PGN to a `.pgn` file on disk (Save dialog).
  final VoidCallback onSavePgn;

  /// Opens the Board Settings tab — same target as the link in the
  /// SettingsPane "More settings" card.
  final VoidCallback onOpenBoardSettings;

  /// Opens the desktop share dialog (image, GIF, link, PGN).
  final VoidCallback onShareGame;

  /// Disables Copy/Save PGN when the tree is empty (e.g. no game has
  /// been loaded yet — the freeplay-from-empty board state).
  final bool canCopyOrSavePgn;

  @override
  State<BoardActionsPopover> createState() => _BoardActionsPopoverState();
}

class _BoardActionsPopoverState extends State<BoardActionsPopover>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder:
            (context, _) => _MenuBody(
              onSelect: (action) {
                _controller.toggle();
                // Defer the callback so the popover unmounts cleanly before
                // the action runs.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  switch (action) {
                    case _BoardAction.share:
                      widget.onShareGame();
                    case _BoardAction.copy:
                      widget.onCopyPgn();
                    case _BoardAction.copyFen:
                      widget.onCopyFen();
                    case _BoardAction.save:
                      widget.onSavePgn();
                    case _BoardAction.boardSettings:
                      widget.onOpenBoardSettings();
                  }
                });
              },
              canCopyOrSavePgn: widget.canCopyOrSavePgn,
            ),
        child: DesktopTooltip(
          message: 'More actions',
          child: FButton.icon(
            onPress: _controller.toggle,
            child: const Icon(
              Icons.more_horiz_rounded,
              color: kWhiteColor70,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

enum _BoardAction { share, copy, copyFen, save, boardSettings }

class _MenuBody extends ConsumerWidget {
  const _MenuBody({required this.onSelect, required this.canCopyOrSavePgn});

  final ValueChanged<_BoardAction> onSelect;
  final bool canCopyOrSavePgn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pull the user's live bindings so the shortcut hint next to each
    // entry stays accurate when chords are remapped in Settings.
    final shortcuts =
        ref.watch(keyboardShortcutsProvider).valueOrNull ??
        BoardShortcutMap(defaultBoardShortcuts());

    String? hintFor(BoardActionKey action) {
      final chords = shortcuts.chordsFor(action);
      if (chords.isEmpty) return null;
      return chords.first.label;
    }

    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuItem(
            icon: Icons.share_rounded,
            label: 'Share Game',
            onTap: () => onSelect(_BoardAction.share),
          ),
          const _Divider(),
          _MenuItem(
            icon: Icons.copy_rounded,
            label: 'Copy PGN',
            shortcut: hintFor(BoardActionKey.copyPgn),
            enabled: canCopyOrSavePgn,
            onTap: () => onSelect(_BoardAction.copy),
          ),
          _MenuItem(
            icon: Icons.content_paste_go_rounded,
            label: 'Copy FEN',
            onTap: () => onSelect(_BoardAction.copyFen),
          ),
          _MenuItem(
            icon: Icons.save_alt_rounded,
            label: 'Save PGN to file…',
            shortcut: hintFor(BoardActionKey.savePgnFile),
            enabled: canCopyOrSavePgn,
            onTap: () => onSelect(_BoardAction.save),
          ),
          const _Divider(),
          _MenuItem(
            icon: Icons.dashboard_customize_outlined,
            label: 'Board settings',
            shortcut: hintFor(BoardActionKey.openBoardSettings),
            onTap: () => onSelect(_BoardAction.boardSettings),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.shortcut,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String? shortcut;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled;
    final fg =
        disabled
            ? kLightGreyColor.withValues(alpha: 0.55)
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg = (disabled || !_hovered) ? Colors.transparent : kBlack3Color;
    final iconColor =
        disabled ? kLightGreyColor.withValues(alpha: 0.45) : kWhiteColor70;

    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: bg,
      child: Row(
        children: [
          Icon(widget.icon, size: 14, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (widget.shortcut != null) ...[
            const SizedBox(width: 12),
            Text(
              widget.shortcut!,
              style: TextStyle(
                color:
                    disabled
                        ? kLightGreyColor.withValues(alpha: 0.45)
                        : kLightGreyColor,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );

    if (disabled) return child;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: child,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: kDividerColor,
    );
  }
}

/// Confirmation dialog for the destructive "Reset edits" action.
///
/// Lists which categories of user edits will be wiped (variations, drawn
/// shapes, move-quality marks) so the user knows exactly what disappears
/// before they confirm. Returns `true` on confirm; `null`/`false` cancels.
Future<bool> showResetEditsConfirmation(
  BuildContext context, {
  required bool hasVariations,
  required bool hasShapes,
  required bool hasNags,
}) async {
  final bullets = <String>[
    if (hasVariations) 'Sub-variations you added to this game',
    if (hasShapes) 'Arrows and circles drawn on the board',
    if (hasNags) 'Move-quality marks (!, ?, !!, ??, !?, ?!) you applied',
  ];
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder:
        (ctx) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: Container(
              width: 400,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.restart_alt_rounded,
                        color: Color(0xFFEB5757),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Reset all edits?',
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This will wipe the following from this game:',
                    style: TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final b in bullets)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 4,
                        top: 2,
                        bottom: 2,
                      ),
                      child: Text(
                        '•  $b',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'The mainline and broadcaster-authored variations stay '
                    'untouched. This action cannot be undone.',
                    style: TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesktopDialogButton(
                        label: 'Cancel',
                        onPress: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: 'Reset',
                        tone: DesktopDialogButtonTone.danger,
                        onPress: () => Navigator.of(ctx).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  );
  return confirmed == true;
}
