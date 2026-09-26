import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';

enum BoardSaveScope { currentGame, wholePgnFile }

/// Choose the amount of a local PGN to save before opening the usual
/// destination dialog. Dismissing the dialog cancels the save.
Future<BoardSaveScope?> showBoardSaveScopeDialog(BuildContext context) {
  return showDesktopDialog<BoardSaveScope>(
    context,
    builder:
        (dialogContext) => Center(
          child: Container(
            width: 460,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDividerColor),
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    () => Navigator.of(dialogContext).pop(),
                const SingleActivator(LogicalKeyboardKey.digit1):
                    () => Navigator.of(
                      dialogContext,
                    ).pop(BoardSaveScope.currentGame),
                const SingleActivator(LogicalKeyboardKey.digit2):
                    () => Navigator.of(
                      dialogContext,
                    ).pop(BoardSaveScope.wholePgnFile),
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'What would you like to save?',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Save the selected game, including your edits, or all games '
                      'from the original PGN file.',
                      style: TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    DesktopDialogButton(
                      label: 'Just this game',
                      tone: DesktopDialogButtonTone.primary,
                      fillWidth: true,
                      onPress:
                          () => Navigator.of(
                            dialogContext,
                          ).pop(BoardSaveScope.currentGame),
                    ),
                    const SizedBox(height: 8),
                    DesktopDialogButton(
                      label: 'Whole PGN file',
                      fillWidth: true,
                      onPress:
                          () => Navigator.of(
                            dialogContext,
                          ).pop(BoardSaveScope.wholePgnFile),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: DesktopDialogButton(
                        label: 'Cancel',
                        onPress: () => Navigator.of(dialogContext).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
  );
}
