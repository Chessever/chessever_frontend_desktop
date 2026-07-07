import 'package:flutter/material.dart';

import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:motor/motor.dart';

/// Compact "open / build local opening tree" control that sits in the local
/// database toolbar, just above the board.
///
/// Styled to match the desktop sidebar buttons (`_SidebarItem`) rather than a
/// stock forui button: a rounded-8 pill with a transparent→[kBlack3Color]
/// hover fill, a spring micro-nudge on hover/press, and — when the tree is
/// built and ready to open — the same [kPrimaryColor]-tinted "primary action"
/// treatment a selected sidebar item gets. Build / retry stay neutral.
class LocalTreeActionButton extends StatefulWidget {
  const LocalTreeActionButton({
    super.key,
    this.progress,
    this.onOpen,
    this.onBuild,
  });

  final LocalChessTreeBuildProgress? progress;
  final VoidCallback? onOpen;
  final VoidCallback? onBuild;

  @override
  State<LocalTreeActionButton> createState() => _LocalTreeActionButtonState();
}

class _LocalTreeActionButtonState extends State<LocalTreeActionButton>
    with DeferredPointerStateMixin<LocalTreeActionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final isBuilding = progress?.isActive == true && widget.onOpen == null;
    final isFailed = progress?.phase == LocalChessTreeBuildPhase.failed;
    // "Tree is built and ready to open" is the primary call to action — it
    // wears the accent, the way a selected sidebar item does.
    final isPrimary = widget.onOpen != null;
    final onPress = widget.onOpen ?? (isBuilding ? null : widget.onBuild);
    final enabled = onPress != null;

    final label =
        widget.onOpen != null
            ? 'Tree'
            : isBuilding
            ? 'Tree ${progress!.percent}%'
            : isFailed
            ? 'Retry Tree'
            : 'Build Tree';
    final icon =
        isFailed ? Icons.restart_alt_rounded : Icons.account_tree_outlined;

    // Foreground / background mirror the sidebar item state machine.
    final Color fg;
    final Color bg;
    final Border? border;
    if (!enabled && !isBuilding) {
      fg = kLightGreyColor;
      bg = Colors.transparent;
      border = Border.all(color: kDividerColor);
    } else if (isPrimary) {
      fg = kPrimaryColor;
      bg = kPrimaryColor.withValues(alpha: _hovered ? 0.16 : 0.10);
      border = Border.all(color: kPrimaryColor.withValues(alpha: 0.35));
    } else {
      fg = _hovered ? kWhiteColor : kWhiteColor70;
      bg = _hovered ? kBlack3Color : Colors.transparent;
      border = Border.all(
        color: _hovered ? kWhiteColor.withValues(alpha: 0.10) : kDividerColor,
      );
    }

    // Same spring nudge as the sidebar: content reaches toward the cursor on
    // hover, dips back on press; the pill itself stays put.
    final nudgeX = _pressed ? -1.0 : (_hovered ? 2.0 : 0.0);

    final pill = Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border,
      ),
      child: SingleMotionBuilder(
        value: nudgeX,
        motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
        builder:
            (context, x, child) =>
                Transform.translate(offset: Offset(x, 0), child: child),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isBuilding)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value:
                      progress!.fraction > 0 && progress.fraction < 1
                          ? progress.fraction
                          : null,
                  valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
                  backgroundColor: kDividerColor,
                ),
              )
            else
              Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );

    return DesktopTooltip(
      message: _tooltipText(
        progress: progress,
        onOpen: widget.onOpen,
        onBuild: widget.onBuild,
        isBuilding: isBuilding,
        isFailed: isFailed,
      ),
      child: CursorAware(
        mode: CursorMode.hover,
        enabled: enabled,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit:
              (_) => setStateAfterPointerEvent(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPress,
            onTapDown:
                enabled
                    ? (_) => setStateAfterPointerEvent(() => _pressed = true)
                    : null,
            onTapUp:
                enabled
                    ? (_) => setStateAfterPointerEvent(() => _pressed = false)
                    : null,
            onTapCancel:
                enabled
                    ? () => setStateAfterPointerEvent(() => _pressed = false)
                    : null,
            child: pill,
          ),
        ),
      ),
    );
  }
}

String _tooltipText({
  required LocalChessTreeBuildProgress? progress,
  required VoidCallback? onOpen,
  required VoidCallback? onBuild,
  required bool isBuilding,
  required bool isFailed,
}) {
  if (onOpen != null) return 'Open this database tree in the board explorer';
  if (isBuilding) return progress?.message ?? 'Building local opening tree';
  if (isFailed) {
    final error = progress?.error?.trim();
    if (error != null && error.isNotEmpty) return 'Tree rebuild failed: $error';
    return 'Tree rebuild failed. Click to start over.';
  }
  if (onBuild != null) return 'Build this local opening tree on demand';
  return 'No local tree is available for this database yet';
}
