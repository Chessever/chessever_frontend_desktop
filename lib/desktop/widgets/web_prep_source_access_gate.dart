import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/web_prep_access.dart';
import 'package:chessever/desktop/auth/web_prep_source_access.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';

/// Keeps Prep game readers unmounted until membership is verified, including
/// Library previews and restored database tabs. Ordinary local files stay free.
class WebPrepSourceAccessGate extends ConsumerWidget {
  const WebPrepSourceAccessGate({
    super.key,
    required this.path,
    required this.child,
  });

  final String path;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decision = ref.watch(webPrepSourceAccessDecisionProvider(path));
    if (decision == null || decision.isAllowed) return child;
    return DesktopAccessLockedSurface(
      decision: decision,
      accessContext: webPrepContentAccess,
      surface: 'prep_library',
    );
  }
}
