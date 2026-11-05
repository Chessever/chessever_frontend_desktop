import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';

/// A first-invoice quote verified by the checkout service. The existing
/// recurring monthly price remains the renewal price.
class WebIntroOffer {
  const WebIntroOffer({
    required this.renewalAmountCents,
    this.requiresSignIn = false,
  });

  static const id = 'web_first_month_99_v1';
  static const amountCents = 99;
  final int renewalAmountCents;

  /// A verified offer may be shown conditionally to an authenticated guest,
  /// but only a permanent account can establish purchase eligibility.
  final bool requiresSignIn;

  static WebIntroOffer? fromJson(
    Object? value, {
    bool allowSignInOffer = false,
  }) {
    if (value is! Map ||
        value['id'] != id ||
        value['eligible'] is! bool ||
        (value['eligible'] != true && !allowSignInOffer) ||
        value['amount_cents'] != amountCents ||
        value['currency'] != 'usd' ||
        value['interval'] != 'month') {
      return null;
    }
    final renewal = value['renewal_amount_cents'];
    if (renewal is! int || renewal <= amountCents) return null;
    return WebIntroOffer(
      renewalAmountCents: renewal,
      requiresSignIn: allowSignInOffer,
    );
  }

  bool matches({required String currency, required double monthlyAmount}) =>
      currency.toLowerCase() == 'usd' &&
      (monthlyAmount * 100).round() == renewalAmountCents;
}

/// Account-scoped and pessimistic: an unknown/failed quote never advertises
/// a discount. An authenticated guest may see the verified offer with explicit
/// sign-in and first-subscriber conditions; a rejected member never does.
final webIntroOfferProvider = FutureProvider.autoDispose
    .family<WebIntroOffer?, int>((ref, tier) {
      final account = ref.watch(desktopAccountIdentityProvider);
      if (!account.isSignedIn || account.staleSession) return null;
      return DesktopBillingService.instance.fetchWebIntroOffer(tier);
    });
