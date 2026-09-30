import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';

const desktopPlayAccessContext = DesktopAccessContext(
  feature: DesktopFeature.play,
  action: DesktopAction.create,
  origin: DesktopDiscoveryOrigin.ownedDocument,
);

/// Call at the actual start boundary, including seeded/rematch entry points.
/// Never closes an existing session or mutates a user's game on denial.
bool admitDesktopPlay(WidgetRef ref) {
  final decision = readDesktopAccess(ref.read, desktopPlayAccessContext);
  if (decision.isAllowed) return true;
  if (ref.context.mounted) {
    unawaited(
      showDesktopPaywall(
        ref.context,
        decision,
        accessContext: desktopPlayAccessContext,
        surface: 'play_start',
      ),
    );
  }
  return false;
}
