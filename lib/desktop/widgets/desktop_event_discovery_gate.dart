import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_event_discovery_access.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/providers/group_event_category.dart';

/// Keeps Past unmounted until admission; the Events tab strip remains
/// available so a guest can always switch back to For You or Current.
class DesktopEventDiscoveryGate extends ConsumerWidget {
  const DesktopEventDiscoveryGate({
    super.key,
    required this.category,
    required this.builder,
  });

  final GroupEventCategory category;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decision = ref.watch(desktopEventDiscoveryAccessProvider(category));
    if (decision.isAllowed) return builder(context);
    return DesktopAccessLockedSurface(
      decision: decision,
      accessContext: desktopEventDiscoveryContext(category),
      surface: 'events_${category.name}',
    );
  }
}
