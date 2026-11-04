import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
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

/// For You and Current both show current broadcasts and never wait for
/// membership. Web Past browsing is also free, with admission at event/game
/// opening. Native Past retains its verified-entitlement discovery gate.
final desktopEventDiscoveryAccessProvider = Provider.autoDispose
    .family<DesktopAccessDecision, GroupEventCategory>((ref, category) {
      if (category != GroupEventCategory.past ||
          ref.watch(desktopPastEventAccessEnabledProvider)) {
        return const DesktopAccessDecision(
          DesktopAccess.allowed,
          DesktopAccessReason.allowedFree,
        );
      }
      return ref.watch(
        desktopAccessDecisionProvider(desktopEventDiscoveryContext(category)),
      );
    });
