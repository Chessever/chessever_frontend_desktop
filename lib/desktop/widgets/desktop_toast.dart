import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/theme/app_theme.dart';

/// Desktop feedback primitive.
///
/// Keep transient desktop feedback on forui toasts instead of the mobile
/// Material feedback pattern, which feels wrong in the desktop shell.
void showDesktopToast(
  BuildContext context,
  String message, {
  bool error = false,
  Duration duration = const Duration(seconds: 2),
}) {
  if (!context.mounted) return;

  try {
    showFToast(
      context: context,
      alignment: FToastAlignment.bottomRight,
      duration: duration,
      icon: Icon(
        error ? Icons.error_outline_rounded : Icons.check_circle_outline,
        color: error ? kRedColor : kPrimaryColor,
        size: 18,
      ),
      title: Text(message),
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
