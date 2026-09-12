import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:flutter/widgets.dart';

/// Offers a guest the desktop sign-in (Google or Apple).
///
/// Returns `true` when the window ends up acting for a permanent,
/// non-anonymous account, including when it already was one.
Future<bool> showAuthUpgradeSheet({required BuildContext context}) {
  return showDesktopAccountSignIn(
    context,
    surface: 'auth_upgrade',
    title: 'Sign in',
    message:
        'A free account keeps your favourites, databases and analysis safe '
        'on every device.',
  );
}

/// Guests are ordinary free accounts, so nothing a free user can do is
/// blocked here. This matches mobile, where this guard also always allows.
/// The account requirements that do exist (purchasing, Botvinnik) are
/// enforced at those entry points instead.
///
/// Kept async so existing call sites stay unchanged.
Future<bool> requireFullAuthGuard(BuildContext context) async => true;
