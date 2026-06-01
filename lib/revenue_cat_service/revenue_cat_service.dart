import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Result of a purchase attempt
class PurchaseAttemptResult {
  final bool success;
  final bool wasCancelled;
  final String? errorMessage;

  const PurchaseAttemptResult({
    required this.success,
    this.wasCancelled = false,
    this.errorMessage,
  });

  factory PurchaseAttemptResult.success() =>
      const PurchaseAttemptResult(success: true);

  factory PurchaseAttemptResult.cancelled() =>
      const PurchaseAttemptResult(success: false, wasCancelled: true);

  factory PurchaseAttemptResult.error(String message) =>
      PurchaseAttemptResult(success: false, errorMessage: message);
}

enum PackageType { unknown, monthly, annual }

enum PeriodUnit { unknown, day, week, month, year }

class BillingPeriod {
  const BillingPeriod({required this.value, required this.unit});

  final int value;
  final PeriodUnit unit;
}

class SubscriptionPhase {
  const SubscriptionPhase({this.billingPeriod});

  final BillingPeriod? billingPeriod;
}

class SubscriptionOption {
  const SubscriptionOption({this.freePhase});

  final SubscriptionPhase? freePhase;
}

class IntroductoryPrice {
  const IntroductoryPrice({
    required this.price,
    required this.periodNumberOfUnits,
    required this.periodUnit,
  });

  final double price;
  final int periodNumberOfUnits;
  final PeriodUnit periodUnit;
}

class StoreProduct {
  const StoreProduct({
    required this.identifier,
    required this.price,
    required this.priceString,
    this.title = '',
    this.description = '',
    this.currencyCode = '',
    this.introductoryPrice,
    this.defaultOption,
  });

  final String identifier;
  final double price;
  final String priceString;
  final String title;
  final String description;
  final String currencyCode;
  final IntroductoryPrice? introductoryPrice;
  final SubscriptionOption? defaultOption;
}

class Package {
  const Package({required this.packageType, required this.storeProduct});

  final PackageType packageType;
  final StoreProduct storeProduct;
}

class EntitlementInfo {
  const EntitlementInfo({
    this.expirationDate,
    this.willRenew = false,
    this.productIdentifier,
  });

  final String? expirationDate;
  final bool willRenew;
  final String? productIdentifier;
}

class EntitlementInfos {
  const EntitlementInfos({this.active = const {}});

  final Map<String, EntitlementInfo> active;
}

class CustomerInfo {
  const CustomerInfo({
    this.originalAppUserId = '',
    this.entitlements = const EntitlementInfos(),
    this.managementURL,
  });

  final String originalAppUserId;
  final EntitlementInfos entitlements;
  final String? managementURL;
}

/// Compatibility facade kept while desktop billing moves to Stripe.
///
/// The native purchases SDK has been removed from this desktop repository. The
/// app should never invoke an App Store / Play Store purchase API on macOS or
/// Windows. Desktop gates stay open until the Stripe-backed licensing path is
/// implemented.
class RevenueCatService {
  static final RevenueCatService _instance = RevenueCatService._internal();
  factory RevenueCatService() => _instance;
  RevenueCatService._internal();

  /// The legacy entitlement identifier kept for state migration and callsites.
  static const String premiumEntitlement = 'Chessever Subscription';

  /// Callback to be invoked on app resume to sync subscription state.
  /// Set by SubscriptionNotifier to ensure state is updated after sync.
  Future<void> Function()? onAppResumeCallback;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> logIn(String userId) async {}

  Future<void> logOut() async {}

  /// Check if user has active premium subscription
  Future<bool> isSubscribed() async {
    return _isDesktop;
  }

  /// Get current customer info
  Future<CustomerInfo?> getCustomerInfo() async {
    return null;
  }

  /// Get available products/packages
  Future<List<Package>> getProducts() async {
    return const [];
  }

  /// Purchase subscription with proper error handling
  Future<PurchaseAttemptResult> purchaseSubscription(Package package) async {
    return PurchaseAttemptResult.error(
      'Subscriptions are not available in this build.',
    );
  }

  /// Restore purchases
  Future<bool> restorePurchases() async {
    return _isDesktop;
  }

  /// Refresh the local subscription state.
  /// Call this at critical points: app foreground, app startup, after auth changes.
  Future<CustomerInfo?> syncPurchases() async {
    return null;
  }

  /// Set up listener for customer info changes
  void setCustomerInfoListener(void Function(CustomerInfo) listener) {}

  Future<void> presentCodeRedemptionSheet() async {}

  Future<void> tagRedemptionAttempt({
    required String source,
    String? code,
    Map<String, String>? affiliateContext,
  }) async {}
}
