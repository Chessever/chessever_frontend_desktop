import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';

Future<bool> confirmDiscardBoardAnalysis(BuildContext context) async {
  final confirmed = await showDesktopModal<bool>(
    context,
    title: 'Are you sure?',
    maxWidth: 380,
    maxHeight: 230,
    barrierDismissible: true,
    builder:
        (dialogContext) => BoardUnsavedAnalysisDialog(
          onConfirm: () => Navigator.of(dialogContext).pop(true),
          onCancel: () => Navigator.of(dialogContext).pop(false),
        ),
  );
  return confirmed == true;
}

class BoardUnsavedAnalysisDialog extends StatefulWidget {
  const BoardUnsavedAnalysisDialog({
    super.key,
    required this.onConfirm,
    required this.onCancel,
  });

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  State<BoardUnsavedAnalysisDialog> createState() =>
      _BoardUnsavedAnalysisDialogState();
}

class _BoardUnsavedAnalysisDialogState
    extends State<BoardUnsavedAnalysisDialog> {
  final FocusNode _leaveFocusNode = FocusNode(
    debugLabel: 'discard board analysis',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _leaveFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): widget.onConfirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): widget.onConfirm,
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'You have analysis on this game. Are you sure you want to leave? Your analysis will be discarded.',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: 'Stay',
                  onPress: widget.onCancel,
                  tone: DesktopDialogButtonTone.secondary,
                ),
                const SizedBox(width: 10),
                Focus(
                  focusNode: _leaveFocusNode,
                  child: DesktopDialogButton(
                    label: 'Leave',
                    onPress: widget.onConfirm,
                    tone: DesktopDialogButtonTone.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
