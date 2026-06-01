import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/library_quick_import.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart'
    show looksLikeLocalChessFile;
import 'package:chessever/theme/app_theme.dart';

/// Two visual modes for [FolderDropTarget]:
/// * [row] — slim ring used over folder rail entries.
/// * [body] — full-height overlay with a centered hint card, used over the
///   games listview body inside the active folder pane.
enum FolderDropStyle { row, body }

/// Inherited handle passed down so nested drop targets can claim a drop and
/// have the pane-level outer [DropTarget] back off via [LibraryDropArbiter].
class LibraryDropArbiterScope extends InheritedWidget {
  const LibraryDropArbiterScope({
    super.key,
    required this.arbiter,
    required super.child,
  });

  final LibraryDropArbiter arbiter;

  static LibraryDropArbiter? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<LibraryDropArbiterScope>();
    final widget = element?.widget as LibraryDropArbiterScope?;
    return widget?.arbiter;
  }

  @override
  bool updateShouldNotify(LibraryDropArbiterScope oldWidget) =>
      oldWidget.arbiter != arbiter;
}

/// Wraps [child] so external drag-drop of chess files lands directly on a
/// specific library folder. Disabled folders (subscribed / TWIC) still
/// render the child but flash a red affordance and refuse the drop so the
/// constraint is visible without surprising the user.
///
/// On a successful drop the arbiter (when present) is marked so the outer
/// [LocalChessDropZone] can skip its open-as-local fallback.
class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({
    super.key,
    required this.enabled,
    required this.folderName,
    required this.onAcceptPaths,
    required this.child,
    this.style = FolderDropStyle.row,
  });

  /// `false` for subscribed folders and TWIC — the drop is still consumed
  /// (so it doesn't fall through to the outer local-open) but the import is
  /// skipped and a read-only message replaces the green affordance.
  final bool enabled;
  final String folderName;
  final Future<void> Function(List<String> paths) onAcceptPaths;
  final Widget child;
  final FolderDropStyle style;

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final arbiter = LibraryDropArbiterScope.maybeOf(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) async {
        setState(() => _hovering = false);
        final paths = details.files
            .map((f) => f.path)
            .where(
              (p) => p.trim().isNotEmpty && looksLikeLocalChessFile(p),
            )
            .toList(growable: false);
        if (paths.isEmpty) return;
        // Claim before the async work so the outer's microtask-deferred
        // arbitration always sees the flag set.
        arbiter?.claim();
        if (!widget.enabled) return;
        await widget.onAcceptPaths(paths);
      },
      child: _wrap(widget.child),
    );
  }

  Widget _wrap(Widget child) {
    if (!_hovering) return child;
    final accent = widget.enabled ? kPrimaryColor : kRedColor;
    final radius = widget.style == FolderDropStyle.row ? 6.0 : 10.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              margin: widget.style == FolderDropStyle.row
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 1)
                  : const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: accent.withValues(alpha: 0.70),
                  width: 1.5,
                ),
              ),
              child: widget.style == FolderDropStyle.body
                  ? Center(
                      child: _BodyHint(
                        folderName: widget.folderName,
                        enabled: widget.enabled,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _BodyHint extends StatelessWidget {
  const _BodyHint({required this.folderName, required this.enabled});
  final String folderName;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = enabled ? kPrimaryColor : kRedColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled
                ? Icons.library_add_outlined
                : Icons.lock_outline_rounded,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 10),
          Text(
            enabled
                ? 'Drop to import into "$folderName"'
                : '"$folderName" is read-only',
            style: TextStyle(
              color: enabled ? kWhiteColor : kRedColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
