/// Riverpod wrappers over the pure desktop access policy.
///
/// These are the extension points the feature surfaces plug into. The policy
/// itself stays in pure functions (`evaluateDesktopAccess`) so it can be
/// tested without a container.
library;

import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// The raw Premium signal. Prefer [desktopAccessDecisionProvider] for a
/// specific request: this one knows nothing about provenance, quotas or the
/// offline grace.
final desktopPremiumAccessProvider = Provider<DesktopAccess>(
  (ref) => desktopPremiumAccess(ref.watch(subscriptionProvider)),
);

/// Account, generation and offline verification for the current identity.
///
/// Usage counters are left unmeasured. A quota guard measures them with a
/// fresh COUNT at admission time and evaluates
/// `evaluateDesktopAccess(entitlement: snapshot.withUsage(...))`, then
/// re-reads this provider after the await and discards the result if the
/// account or generation moved.
final desktopEntitlementProvider = Provider<DesktopEntitlementSnapshot>((ref) {
  ref.watch(subscriptionProvider);
  final notifier = ref.watch(subscriptionProvider.notifier);
  if (notifier is DesktopSubscriptionNotifier) {
    return notifier.entitlementSnapshot;
  }
  return DesktopEntitlementSnapshot.guest;
});

/// Reactive decision for one request context. Rebuilds whenever the
/// membership or identity changes, including at the exact expiry instant
/// (the subscription notifier publishes then).
///
/// Safe for rendering: evaluating a locked surface never opens a paywall.
/// Quota-bearing contexts resolve to `usageUnknown` here by design; see
/// [desktopEntitlementProvider] for how guards attach measured usage.
final desktopAccessDecisionProvider = Provider.autoDispose
    .family<DesktopAccessDecision, DesktopAccessContext>(
      (ref, context) => evaluateDesktopAccess(
        context: context,
        subscription: ref.watch(subscriptionProvider),
        entitlement: ref.watch(desktopEntitlementProvider),
      ),
    );
