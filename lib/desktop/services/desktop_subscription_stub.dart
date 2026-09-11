import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Server-backed cross-device entitlement. Unknown/offline never grants new
/// Premium work. Authentication and personal-file recovery remain independent.
class DesktopSubscriptionNotifier extends SubscriptionNotifier {
  static DesktopSubscriptionNotifier? current;
  DesktopSubscriptionNotifier()
    : super.stub(SubscriptionState(isLoading: true)) {
    current = this;
    _wire();
  }

  Timer? _refreshTimer;
  Timer? _expiryTimer;
  StreamSubscription<AuthState>? _authSub;
  Future<EntitlementSnapshot?>? _refreshFuture;
  String? _accountId;
  int _generation = 0;

  void _wire() {
    if (!DesktopSupabaseInit.isInitialized) {
      state = SubscriptionState(error: 'Membership service is unavailable.');
      return;
    }
    _accountId = Supabase.instance.client.auth.currentUser?.id;
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      final account = event.session?.user.id;
      if (account != _accountId) {
        _accountId = account;
        _generation++;
        _refreshFuture = null;
        _expiryTimer?.cancel();
        state = SubscriptionState(isLoading: account != null);
        unawaited(refreshFromBackend());
      }
    });
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(refreshFromBackend());
    });
    unawaited(refreshFromBackend());
  }

  @override
  Future<void> refresh() async {
    await refreshFromBackend();
  }

  @override
  Future<void> syncAndRefresh() async {
    await refreshFromBackend();
  }

  Future<EntitlementSnapshot?> refreshFromBackend({
    bool forceSessionRefresh = false,
  }) {
    if (!mounted || !DesktopSupabaseInit.isInitialized) {
      return Future.value(null);
    }
    final active = _refreshFuture;
    if (active != null) return active;
    final generation = _generation;
    final account = _accountId;
    final future = _fetch(generation, account, forceSessionRefresh);
    _refreshFuture = future;
    return future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
  }

  bool _owns(int generation, String? account) =>
      mounted &&
      generation == _generation &&
      account == _accountId &&
      Supabase.instance.client.auth.currentUser?.id == account;

  Future<EntitlementSnapshot?> _fetch(
    int generation,
    String? account,
    bool force,
  ) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      if (account == null) {
        if (_owns(generation, account)) state = SubscriptionState();
        return null;
      }
      final ent = await DesktopBillingService.instance.currentEntitlement(
        forceSessionRefresh: force,
      );
      if (!_owns(generation, account)) return null;
      if (ent == null) {
        state = SubscriptionState(error: 'Sign in to verify membership.');
        return null;
      }
      final expired =
          !ent.inBillingGracePeriod &&
          ent.expiresAt != null &&
          !ent.expiresAt!.isAfter(DateTime.now());
      state = SubscriptionState(
        isSubscribed: ent.isActive && !expired,
        expirationDate: ent.expiresAt,
        willRenew: ent.willRenew,
        provider: ent.provider,
        inBillingGracePeriod: ent.inBillingGracePeriod,
      );
      _expiryTimer?.cancel();
      if (state.isSubscribed &&
          !ent.inBillingGracePeriod &&
          ent.expiresAt != null) {
        _expiryTimer = Timer(ent.expiresAt!.difference(DateTime.now()), () {
          if (!_owns(generation, account)) return;
          state = state.copyWith(isSubscribed: false);
          unawaited(refreshFromBackend());
        });
      }
      // This cache permits recovery of an authenticated shell, not entitlement.
      await DesktopOfflineAccessCache.recordEntitlement(
        isActive: state.isSubscribed,
      );
      return _owns(generation, account) ? ent : null;
    } catch (_) {
      if (!_owns(generation, account)) return null;
      state = state.copyWith(
        isLoading: false,
        error:
            'Membership could not be verified. Check your connection and retry.',
      );
      return null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _refreshTimer?.cancel();
    _expiryTimer?.cancel();
    unawaited(_authSub?.cancel());
    if (identical(current, this)) current = null;
    super.dispose();
  }
}

final Override desktopSubscriptionOverride = subscriptionProvider.overrideWith(
  (ref) => DesktopSubscriptionNotifier(),
);
