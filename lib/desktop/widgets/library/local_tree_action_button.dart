import 'package:flutter/material.dart';

import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Compact "open / build local opening tree" control that sits in the local
/// database toolbar, just above the board.
///
/// Thin mapper over [DesktopToolbarPillButton]: it translates the build
/// progress state machine into the pill's label / tone / leading, so it stays
/// pixel-identical to every other toolbar pill (e.g. the "Save to cloud"
/// button beside it). When the tree is built and ready to open it wears the
/// [DesktopToolbarPillTone.primary] treatment the way a selected sidebar item
/// does; build / retry / building stay neutral.
class LocalTreeActionButton extends StatelessWidget {
  const LocalTreeActionButton({
    super.key,
    this.progress,
    this.onOpen,
    this.onBuild,
    this.onCancel,
  });

  final LocalChessTreeBuildProgress? progress;
  final VoidCallback? onOpen;
  final VoidCallback? onBuild;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    final isBuilding = progress?.isActive == true && onOpen == null;
    final isFailed = progress?.phase == LocalChessTreeBuildPhase.failed;
    // "Tree is built and ready to open" is the primary call to action — it
    // wears the accent, the way a selected sidebar item does.
    final isPrimary = onOpen != null;
    final onPress = onOpen ?? (isBuilding ? onCancel : onBuild);

    final label =
        onOpen != null
            ? 'Tree'
            : isBuilding
            ? 'Tree ${progress!.percent}%'
            : isFailed
            ? 'Retry Tree'
            : 'Build Tree';
    final icon =
        isFailed ? Icons.restart_alt_rounded : Icons.account_tree_outlined;

    return DesktopToolbarPillButton(
      label: label,
      icon: icon,
      onPress: onPress,
      busy: isBuilding,
      tabularFigures: true,
      tone:
          isPrimary
              ? DesktopToolbarPillTone.primary
              : DesktopToolbarPillTone.neutral,
      leading:
          isBuilding
              ? SizedBox(
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
              : null,
      tooltip: _tooltipText(
        progress: progress,
        onOpen: onOpen,
        onBuild: onBuild,
        onCancel: onCancel,
        isBuilding: isBuilding,
        isFailed: isFailed,
      ),
    );
  }
}

String _tooltipText({
  required LocalChessTreeBuildProgress? progress,
  required VoidCallback? onOpen,
  required VoidCallback? onBuild,
  required VoidCallback? onCancel,
  required bool isBuilding,
  required bool isFailed,
}) {
  if (onOpen != null) return 'Open this database tree in the board explorer';
  if (isBuilding) {
    final message = progress?.message ?? 'Building local opening tree';
    final stop = onCancel == null ? '' : ' Click to stop the build.';
    return '$message$stop';
  }
  if (isFailed) {
    final error = progress?.error?.trim();
    if (error != null && error.isNotEmpty) return 'Tree rebuild failed: $error';
    return 'Tree rebuild failed. Click to start over.';
  }
  if (onBuild != null) return 'Build this local opening tree on demand';
  return 'No local tree is available for this database yet';
}
