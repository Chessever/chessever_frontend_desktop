import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';

/// A first-invoice quote verified by the checkout service. The existing
/// recurring monthly price remains the renewal price.
class WebIntroOffer {
  const WebIntroOffer({required this.renewalAmountCents});

  static const id = 'web_first_month_99_v1';
  static const amountCents = 99;
  final int renewalAmountCents;

  static WebIntroOffer? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] != id ||
        value['eligible'] != true ||
        value['amount_cents'] != amountCents ||
        value['currency'] != 'usd' ||
        value['interval'] != 'month') {
      return null;
    }
    final renewal = value['renewal_amount_cents'];
    if (renewal is! int || renewal <= amountCents) return null;
    return WebIntroOffer(renewalAmountCents: renewal);
  }

  bool matches({required String currency, required double monthlyAmount}) =>
      currency.toLowerCase() == 'usd' &&
      (monthlyAmount * 100).round() == renewalAmountCents;
}

/// Account-scoped and pessimistic: an unknown/failed quote never advertises
/// a discount. Guests see the website's conditional new-subscriber offer.
final webIntroOfferProvider = FutureProvider.autoDispose
    .family<WebIntroOffer?, int>((ref, tier) {
      final account = ref.watch(desktopAccountIdentityProvider);
      if (!account.isPermanent) return null;
      return DesktopBillingService.instance.fetchWebIntroOffer(tier);
    });
