import 'dart:async';

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

  /// Reconcile the just-completed store transaction with the shared authority.
  /// The endpoint already refreshes RevenueCat for inactive/store accounts.
  /// A fresh SDK result only tells us to wait for propagation; it cannot
  /// override a backend revocation or grant persistent offline access itself.
  Future<EntitlementSnapshot?> reconcileStoreTransaction({
    required String accountId,
    required bool expectActive,
  }) {
    if (!isMacAppStore) {
      return Future.error(StateError('Apple billing is unavailable here.'));
    }
    return reconcileTransaction(
      backend: () => DesktopBillingService.instance.currentEntitlement(),
      isCurrentAccount:
          () =>
              Supabase.instance.client.auth.currentUser?.id == accountId &&
              Supabase.instance.client.auth.currentUser?.isAnonymous == false,
      expectActive: expectActive,
    );
  }

  /// Bounded post-transaction polling, independent of cached SDK customer info.
  /// Identity is checked before and after every network request and pause.
  static Future<EntitlementSnapshot?> reconcileTransaction({
    required Future<EntitlementSnapshot?> Function() backend,
    required bool Function() isCurrentAccount,
    required bool expectActive,
    Future<void> Function(Duration)? pause,
  }) async {
    final elapsed = Stopwatch()..start();
    const budget = Duration(seconds: 30);
    EntitlementSnapshot? latest;
    Object? lastError;
    StackTrace? lastStack;
    void checkIdentity() {
      if (!isCurrentAccount()) {
        throw StateError('Your account changed. Please try again.');
      }
    }

    final attempts = expectActive ? 6 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      checkIdentity();
      final remaining = budget - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        latest = await backend().timeout(remaining);
        lastError = null;
      } on DesktopBillingAuthException {
        rethrow;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
      }
      checkIdentity();
      if (latest?.isActive == true || !expectActive) break;
      if (attempt + 1 == attempts ||
          budget - elapsed.elapsed <= const Duration(seconds: 2)) {
        break;
      }
      await (pause ?? Future<void>.delayed)(const Duration(seconds: 2));
    }
    checkIdentity();
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack!);
    }
    return latest;
  }

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
