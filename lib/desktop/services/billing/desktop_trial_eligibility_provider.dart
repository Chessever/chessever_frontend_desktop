import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'desktop_billing_service.dart';

/// Whether the signed-in user may still be offered the free trial.
///
/// Null means "not yet known" (signed out, or the probe has not returned)
/// and reads as eligible for copy purposes — see
/// `DesktopPricing.offersTrial`. Consumers combine this with
/// [desktopTrialEligibilityOverride]: the override wins once a checkout
/// proves the trial is gone, so the paywall corrects itself without waiting
/// for a refetch.
final desktopTrialEligibilityProvider = FutureProvider<bool?>((ref) async {
  return DesktopBillingService.instance.fetchTrialEligibility();
});

/// Local correction after a checkout withholds an advertised trial.
/// Mirrors chessever.com/premium setting `trialEligible` false when the
/// created session grants zero trial days.
final desktopTrialEligibilityOverrideProvider = StateProvider<bool?>(
  (ref) => null,
);

/// Effective eligibility for paywall copy: the local correction when set,
/// otherwise the probed value (null until known).
bool? effectiveTrialEligibility(WidgetRef ref) {
  return ref.watch(desktopTrialEligibilityOverrideProvider) ??
      ref.watch(desktopTrialEligibilityProvider).valueOrNull;
}
