import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

import 'desktop_dialog_button.dart';

/// Desktop feedback primitive.
///
/// Keep transient desktop feedback on forui toasts instead of the mobile
/// Material feedback pattern, which feels wrong in the desktop shell.
///
/// [actionLabel] + [onAction] attach one explicit action to the toast (for
/// example `Refresh` after a local database failed to open). A toast with an
/// action stays up long enough to be clicked and dismisses itself when the
/// action runs.
void showDesktopToast(
  BuildContext context,
  String message, {
  bool error = false,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (!context.mounted) return;

  final label = actionLabel?.trim() ?? '';
  final action = onAction;
  final hasAction = label.isNotEmpty && action != null;

  try {
    showFToast(
      context: context,
      alignment: FToastAlignment.bottomRight,
      duration: duration ?? Duration(seconds: hasAction ? 8 : 2),
      icon: Icon(
        error ? Icons.error_outline_rounded : Icons.check_circle_outline,
        color: error ? kRedColor : kPrimaryColor,
        size: 18,
      ),
      title: Text(message),
      suffixBuilder:
          hasAction
              ? (context, entry) => DesktopDialogButton(
                label: label,
                tone: DesktopDialogButtonTone.ghost,
                onPress: () {
                  entry.dismiss();
                  action();
                },
              )
              : null,
      style:
          error
              ? (style) => style.copyWith(
                decoration: style.decoration.copyWith(
                  border: Border.all(color: kRedColor.withValues(alpha: 0.62)),
                ),
              )
              : null,
    );
  } on FlutterError catch (e) {
    if (kDebugMode) {
      debugPrint('showDesktopToast skipped: ${e.message}');
    }
  }
}
