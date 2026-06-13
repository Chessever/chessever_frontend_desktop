import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Desktop-side override of [subscriptionProvider].
///
/// On desktop the source of truth for subscription state is the Supabase
/// `entitlement` Edge Function (which reads `public.subscriptions`). This
/// notifier polls it on auth state changes, on a 5-minute timer, and on
/// demand (e.g. when the billing deep link arrives after Stripe Checkout).
///
/// We extend [SubscriptionNotifier] via the `.stub()` constructor so that
/// none of the RevenueCat-specific timers/listeners (which would crash on
/// desktop without `purchases_flutter`) are wired up.
class DesktopSubscriptionNotifier extends SubscriptionNotifier {
  /// Last-constructed instance. Used by [DesktopDeepLinkListener] (which
  /// runs outside the widget tree) to trigger an entitlement refresh after
  /// a `chessever://billing/success` redirect lands.
  static DesktopSubscriptionNotifier? current;

  DesktopSubscriptionNotifier()
    : super.stub(SubscriptionState(isLoading: true)) {
    current = this;
    _wire();
  }

  Timer? _refreshTimer;
  StreamSubscription<AuthState>? _authSub;
  Future<EntitlementSnapshot?>? _refreshFuture;

  static const _refreshPeriod = Duration(minutes: 5);

  void _wire() {
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (kDebugMode) {
        debugPrint(
          '[desktop-sub] auth event ${event.event}; refreshing entitlement',
        );
      }
      // ignore: discarded_futures
      refreshFromBackend(forceSessionRefresh: true);
    });
    _refreshTimer = Timer.periodic(_refreshPeriod, (_) {
      // ignore: discarded_futures
      refreshFromBackend();
    });
    // First fetch.
    // ignore: discarded_futures
    refreshFromBackend(forceSessionRefresh: true);
  }

  /// Fetch the latest entitlement from the backend and update [state].
  /// Coalesces concurrent calls — the deep-link listener and the periodic
  /// timer can both fire at the same moment.
  Future<EntitlementSnapshot?> refreshFromBackend({
    bool forceSessionRefresh = false,
  }) {
    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;

    final future = _refreshFromBackend(
      forceSessionRefresh: forceSessionRefresh,
    );
    _refreshFuture = future;
    return future.whenComplete(() {
      if (identical(_refreshFuture, future)) {
        _refreshFuture = null;
      }
    });
  }

  Future<EntitlementSnapshot?> _refreshFromBackend({
    required bool forceSessionRefresh,
  }) async {
    try {
      state = state.copyWith(isLoading: true);
      final ent = await DesktopBillingService.instance.currentEntitlement(
        forceSessionRefresh: forceSessionRefresh,
      );
      if (ent == null) {
        state = SubscriptionState(
          isSubscribed: false,
          isLoading: false,
          error: 'Sign in to sync your ChessEver Premium membership.',
        );
        return null;
      }
      await DesktopOfflineAccessCache.recordEntitlement(isActive: ent.isActive);
      state = SubscriptionState(
        isSubscribed: ent.isActive,
        isLoading: false,
        expirationDate: ent.expiresAt,
        willRenew: ent.willRenew,
        provider: ent.provider,
        inBillingGracePeriod: ent.inBillingGracePeriod,
      );
      return ent;
    } on DesktopBillingAuthException catch (e) {
      if (kDebugMode) debugPrint('[desktop-sub] auth refresh failed: $e');
      if (await DesktopOfflineAccessCache.canUseOfflineAccess()) {
        state = state.copyWith(
          isSubscribed: true,
          isLoading: false,
          error:
              'Offline mode — Premium will be verified when internet returns.',
        );
        return null;
      }
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
      state = SubscriptionState(
        isSubscribed: false,
        isLoading: false,
        error: 'Your sign-in expired. Sign in again to sync Premium.',
      );
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[desktop-sub] refresh failed: $e');
      if (await DesktopOfflineAccessCache.canUseOfflineAccess()) {
        state = state.copyWith(
          isSubscribed: true,
          isLoading: false,
          error:
              'Offline mode — Premium will be verified when internet returns.',
        );
        return null;
      }
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _authSub?.cancel();
    if (identical(current, this)) current = null;
    super.dispose();
  }
}

/// Riverpod override that swaps the mobile RevenueCat-driven notifier for
/// the desktop one. Wired into [ProviderScope] in `desktop_main.dart`.
final Override desktopSubscriptionOverride = subscriptionProvider.overrideWith(
  (ref) => DesktopSubscriptionNotifier(),
);
