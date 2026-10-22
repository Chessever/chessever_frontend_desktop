import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';

/// Apple purchases use the same account identifier and entitlement as mobile.
/// The SDK key is public; store credentials remain in RevenueCat.
class MacAppStoreBilling {
  MacAppStoreBilling._();

  static final instance = MacAppStoreBilling._();
  static const entitlementIdentifier = 'Chessever Subscription';
  static const _sdkKey = 'appl_LnkzXSulGlLFVgausTnOomRVPLR';

  bool _configured = false;
  String? _account;
  Future<void> _tail = Future<void>.value();

  // Identity changes and store operations share one queue. A purchase cannot
  // race a logIn for another account, and a stale result cannot grant access.
  Future<T> _forAccount<T>(
    Future<T> Function() operation, {
    bool requirePermanentAccount = false,
  }) {
    final user = Supabase.instance.client.auth.currentUser;
    if (!isMacAppStore) {
      return Future<T>.error(StateError('Apple billing is unavailable here.'));
    }
    if (user == null || (requirePermanentAccount && user.isAnonymous)) {
      return Future<T>.error(StateError('Sign in before making a purchase.'));
    }
    final account = user.id;
    final result = _tail.then((_) async {
      void checkIdentity() {
        if (Supabase.instance.client.auth.currentUser?.id != account) {
          throw StateError('Your account changed. Please try again.');
        }
      }

      checkIdentity();
      if (!_configured) {
        await Purchases.configure(
          PurchasesConfiguration(_sdkKey)..appUserID = account,
        );
        _configured = true;
        _account = account;
      } else if (_account != account) {
        await Purchases.logIn(account);
        _account = account;
      }
      checkIdentity();
      final value = await operation();
      checkIdentity();
      return value;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<Package>> packages() => _forAccount(() async {
    final offerings = await Purchases.getOfferings();
    final offering = offerings.all['rc_chessever_premium'];
    final monthly = offering?.monthly;
    final annual = offering?.annual;
    if (monthly == null || annual == null) {
      throw StateError('App Store plans are unavailable. Please try again.');
    }
    return [monthly, annual];
  });

  Future<CustomerInfo> purchase(Package package) => _forAccount(
    () async =>
        (await Purchases.purchase(
          PurchaseParams.package(package),
        )).customerInfo,
    requirePermanentAccount: true,
  );

  Future<CustomerInfo> restore() =>
      _forAccount(Purchases.restorePurchases, requirePermanentAccount: true);

  Future<EntitlementSnapshot?> currentEntitlement({
    bool forceSessionRefresh = false,
  }) async {
    final account = Supabase.instance.client.auth.currentUser?.id;
    if (!isMacAppStore || account == null) {
      throw StateError('Sign in to check your subscription.');
    }
    final result = await resolveEntitlement(
      backend:
          () => DesktopBillingService.instance.currentEntitlement(
            forceSessionRefresh: forceSessionRefresh,
          ),
      receipt:
          () => _forAccount(() async {
            if (forceSessionRefresh) {
              await Purchases.invalidateCustomerInfoCache();
            }
            return snapshotFrom(await Purchases.getCustomerInfo());
          }),
    );
    if (Supabase.instance.client.auth.currentUser?.id != account) {
      throw StateError('Your account changed. Please try again.');
    }
    return result;
  }

  /// Online access shares the web/mobile authority, including Stripe and
  /// promotional grants. The SDK remains available during a backend outage.
  static Future<EntitlementSnapshot?> resolveEntitlement({
    required Future<EntitlementSnapshot?> Function() backend,
    required Future<EntitlementSnapshot?> Function() receipt,
  }) async {
    try {
      final current = await backend();
      if (current != null) return current;
    } on DesktopBillingAuthException {
      rethrow;
    } catch (_) {
      // A failed lookup is unknown, so retain the verified store fallback.
    }
    return receipt();
  }

  static EntitlementSnapshot snapshotFrom(CustomerInfo info) {
    final entitlement = info.entitlements.all[entitlementIdentifier];
    if (entitlement == null) {
      return const EntitlementSnapshot(isActive: false);
    }
    return EntitlementSnapshot(
      isActive: entitlement.isActive,
      expiresAt:
          entitlement.expirationDate == null
              ? null
              : DateTime.tryParse(entitlement.expirationDate!),
      willRenew: entitlement.willRenew,
      provider: switch (entitlement.store) {
        Store.appStore || Store.macAppStore => 'apple',
        Store.playStore => 'google',
        Store.stripe => 'stripe',
        _ => 'revenuecat',
      },
      productId: entitlement.productIdentifier,
      inBillingGracePeriod:
          entitlement.isActive && entitlement.billingIssueDetectedAt != null,
    );
  }
}
