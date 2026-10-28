import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Runs a widget test as a verified Premium member.
///
/// For tests whose subject IS a Premium feature (database position games,
/// opening-tree exploration, player tree builds). Free-tier behaviour is
/// covered by `desktop_access_gates_test.dart`.
List<Override> get desktopPremiumTestOverrides => [
  subscriptionProvider.overrideWith(
    (ref) => SubscriptionNotifier.stub(
      SubscriptionState(
        isSubscribed: true,
        expirationDate: DateTime.now().add(const Duration(days: 365)),
      ),
    ),
  ),
  desktopEntitlementProvider.overrideWithValue(
    const DesktopEntitlementSnapshot(accountId: 'test-member', generation: 1),
  ),
];
