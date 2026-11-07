import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/providers/group_event_category.dart';

DesktopAccessContext desktopEventDiscoveryContext(
  GroupEventCategory category,
) => DesktopAccessContext(
  feature:
      category == GroupEventCategory.past
          ? DesktopFeature.eventDiscovery
          : DesktopFeature.broadcast,
  action: DesktopAction.view,
  origin: DesktopDiscoveryOrigin.broadcast,
);

/// Event discovery never waits for membership. Archived game admission is
/// checked when opening a game, after the user has browsed the event.
final desktopEventDiscoveryAccessProvider = Provider.autoDispose
    .family<DesktopAccessDecision, GroupEventCategory>((ref, category) {
      return const DesktopAccessDecision(
        DesktopAccess.allowed,
        DesktopAccessReason.allowedFree,
      );
    });
