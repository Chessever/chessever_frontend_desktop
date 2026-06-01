/// Subscription billing on desktop is **Stripe Checkout in the browser**.
///
/// Stripe Checkout works on every desktop OS we ship to. The backend owns
/// entitlement updates after Stripe confirms payment.
///
/// End-to-end flow:
///
///   Desktop                         Backend                    Stripe
///   --------                        ---------                  ------
///   1. User clicks Upgrade
///   2. POST /create-checkout
///       (uid, plan, success_url) ─────►
///                                  3. Stripe Checkout Session
///                                     ◄───── (cs_test_...)
///   4. open(checkout_url)
///   5. Pays in browser  ───────────────────────────────────►
///                                                              6. Stripe webhook
///                                                                 ◄───── /webhook
///                                  7. Entitlement set
///   8. App polls /entitlements ◄───
///   9. Paywall UI flips to "Pro"
///
/// `success_url` and `cancel_url` use a deep link that brings the user
/// back to ChessEver (we already register `chessever://` for OneLink on
/// mobile; desktop registers the same scheme).
///
/// The desktop side only needs three things:
///   1. Ask the backend for a Checkout Session URL.
///   2. Open that URL in the user's browser.
///   3. Periodically refresh the user's entitlement state from the backend
///      (or react to a deep-link return, whichever fires first).
///
/// This file is the request/response contract between the desktop and the
/// backend. The actual `dio` POST + polling loop lives in
/// `desktop_billing_service.dart` so the contract is easy to test and the
/// service is easy to swap when we add Mac App Store IAP for sandboxed
/// builds.
library;

import 'package:flutter/foundation.dart';

@immutable
class CheckoutSessionRequest {
  const CheckoutSessionRequest({
    required this.userId,
    required this.priceId,
    required this.successUrl,
    required this.cancelUrl,
  });

  final String userId;

  /// Stripe `price_…` id for the plan being purchased. The backend looks
  /// these up in a denylist + whitelist before creating the session so
  /// the desktop client cannot ask for a price that does not exist or
  /// that the user is not allowed to buy (e.g. region restrictions).
  final String priceId;

  /// `chessever://billing/success?session_id={CHECKOUT_SESSION_ID}` style
  /// URL that returns control to the desktop app on success.
  final String successUrl;

  /// Same shape; loaded when the user cancels the Stripe page.
  final String cancelUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'price_id': priceId,
    'success_url': successUrl,
    'cancel_url': cancelUrl,
  };
}

@immutable
class CheckoutSessionResponse {
  const CheckoutSessionResponse({
    required this.sessionId,
    required this.checkoutUrl,
  });

  final String sessionId;

  /// `https://checkout.stripe.com/...` URL the desktop opens in the user's
  /// default browser.
  final String checkoutUrl;

  factory CheckoutSessionResponse.fromJson(Map<String, dynamic> json) {
    return CheckoutSessionResponse(
      sessionId: json['session_id'] as String,
      checkoutUrl: json['checkout_url'] as String,
    );
  }
}
