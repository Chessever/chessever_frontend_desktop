import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// The identity the entitlement lifecycle is bound to.
class DesktopAccountIdentity {
  const DesktopAccountIdentity({required this.id, this.isAnonymous = false});

  final String id;

  /// A Supabase anonymous (guest) user. Guests get the full free tier; only
  /// purchasing and Botvinnik need a permanent account.
  final bool isAnonymous;
}

/// Signature of [DesktopOfflineAccessCache.recordEntitlement].
typedef DesktopRecordEntitlement =
    Future<void> Function({
      required bool isActive,
      String? accountId,
      DateTime? expiresAt,
      bool inBillingGracePeriod,
      DateTime? verifiedAt,
    });

/// Everything [DesktopSubscriptionNotifier] reaches outside itself for.
///
/// Injected so the lifecycle (generation reset, stale-response rejection,
/// offline grace, expiry) is testable without Supabase or the network.
class DesktopSubscriptionDependencies {
  const DesktopSubscriptionDependencies({
    required this.isBackendAvailable,
    required this.currentAccount,
    required this.authChanges,
    required this.fetchEntitlement,
    required this.readOfflineVerification,
    required this.recordEntitlement,
    required this.signOut,
    this.now = DateTime.now,
    this.refreshPeriod = const Duration(minutes: 5),
  });

  /// Production wiring: Supabase auth, the `entitlement` edge function and the
  /// shared-preferences offline record.
  factory DesktopSubscriptionDependencies.live() {
    DesktopAccountIdentity? identityOf(User? user) => user == null
        ? null
        : DesktopAccountIdentity(id: user.id, isAnonymous: user.isAnonymous);
    return DesktopSubscriptionDependencies(
      isBackendAvailable: () => DesktopSupabaseInit.isInitialized,
      currentAccount: () =>
          identityOf(Supabase.instance.client.auth.currentUser),
      authChanges: () => Supabase.instance.client.auth.onAuthStateChange.map(
        (event) => identityOf(event.session?.user),
      ),
      fetchEntitlement: ({required bool forceSessionRefresh}) =>
          DesktopBillingService.instance.currentEntitlement(
            forceSessionRefresh: forceSessionRefresh,
          ),
      readOfflineVerification: DesktopOfflineAccessCache.readOfflineVerification,
      recordEntitlement: DesktopOfflineAccessCache.recordEntitlement,
      signOut: () => Supabase.instance.client.auth.signOut(),
    );
  }

  final bool Function() isBackendAvailable;
  final DesktopAccountIdentity? Function() currentAccount;
  final Stream<DesktopAccountIdentity?> Function() authChanges;
  final Future<EntitlementSnapshot?> Function({
    required bool forceSessionRefresh,
  })
  fetchEntitlement;
  final Future<DesktopOfflineVerification> Function() readOfflineVerification;
  final DesktopRecordEntitlement recordEntitlement;
  final Future<void> Function() signOut;
  final DateTime Function() now;
  final Duration refreshPeriod;
}

/// Desktop-side override of [subscriptionProvider].
///
/// The source of truth is the Supabase `entitlement` edge function (backed by
/// `public.subscriptions`), which already reflects purchases made on mobile
/// or the web, trials, cancellation-through-expiry and billing grace. This
/// notifier polls it on account changes, on a timer, at the exact expiry
/// instant, and on demand (the `chessever://billing/success` deep link).
///
/// Lifecycle guarantees:
/// * Every fetch captures the account and a generation counter. Nothing is
///   published unless both still match (`_owns`), so a late response from a
///   previous account can never land after logout or an account switch.
/// * An account change resets state, bumps the generation and drops the
///   in-flight request.
/// * While the backend is unreachable, a Premium verification recorded for
///   THIS account within the last 14 days, and before the known entitlement
///   expiry, keeps Premium working (offline grace). An authoritative online
///   inactive result overwrites that record immediately.
/// * Timers are cancelled on dispose.
///
/// Extends [SubscriptionNotifier] through `.stub()` so none of the RevenueCat
/// listeners (which would crash without `purchases_flutter`) are wired.
class DesktopSubscriptionNotifier extends SubscriptionNotifier {
  /// Last-constructed instance, for callers outside the widget tree (the
  /// billing deep-link listener) that need to trigger a refresh.
  static DesktopSubscriptionNotifier? current;

  DesktopSubscriptionNotifier({DesktopSubscriptionDependencies? dependencies})
    : _deps = dependencies ?? DesktopSubscriptionDependencies.live(),
      super.stub(SubscriptionState(isLoading: true)) {
    current = this;
    _wire();
  }

  final DesktopSubscriptionDependencies _deps;

  Timer? _refreshTimer;
  Timer? _expiryTimer;
  StreamSubscription<DesktopAccountIdentity?>? _authSub;
  Future<EntitlementSnapshot?>? _refreshFuture;
  String? _accountId;
  bool _isAnonymous = false;
  int _generation = 0;
  DesktopOfflineVerification _offline = DesktopOfflineVerification.none;
  bool _offlineGraceActive = false;

  static const _unreachableMessage =
      'Membership could not be verified. Check your connection and retry.';

  /// Entitlement generation; bumped on every account change.
  int get generation => _generation;

  /// True while Premium is being honoured from the offline verification
  /// rather than a live check. UI may say so; it is not an error.
  bool get isOfflineGraceActive => _offlineGraceActive;

  /// Account-bound facts for `evaluateDesktopAccess`. Usage is not measured
  /// here; quota guards measure it at admission time and attach it with
  /// [DesktopEntitlementSnapshot.withUsage].
  DesktopEntitlementSnapshot get entitlementSnapshot =>
      DesktopEntitlementSnapshot(
        accountId: _accountId,
        isAnonymous: _isAnonymous,
        generation: _generation,
        offline: _offline,
      );

  void _wire() {
    // The debug desktop shell may start without backend configuration, and
    // Riverpod can still instantiate this override. Never touch Supabase
    // until it is initialised.
    if (!_deps.isBackendAvailable()) {
      state = SubscriptionState(
        error: 'Supabase is unavailable in this desktop session.',
      );
      return;
    }

    final identity = _deps.currentAccount();
    _accountId = identity?.id;
    _isAnonymous = identity?.isAnonymous ?? false;
    _authSub = _deps.authChanges().listen(_onAuthChange);
    _refreshTimer = Timer.periodic(_deps.refreshPeriod, (_) {
      unawaited(refreshFromBackend());
    });
    unawaited(_loadOfflineVerification(_generation, _accountId));
    unawaited(refreshFromBackend(forceSessionRefresh: true));
  }

  void _onAuthChange(DesktopAccountIdentity? identity) {
    final account = identity?.id;
    if (account == _accountId) {
      _isAnonymous = identity?.isAnonymous ?? _isAnonymous;
      return;
    }
    if (kDebugMode) debugPrint('[desktop-sub] account changed; resetting');
    _accountId = account;
    _isAnonymous = identity?.isAnonymous ?? false;
    _generation++;
    _refreshFuture = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _offlineGraceActive = false;
    _offline = DesktopOfflineVerification.none;
    state = SubscriptionState(isLoading: account != null);
    unawaited(_loadOfflineVerification(_generation, account));
    unawaited(refreshFromBackend(forceSessionRefresh: true));
  }

  @override
  Future<void> refresh() async {
    await refreshFromBackend();
  }

  @override
  Future<void> syncAndRefresh() async {
    await refreshFromBackend();
  }

  /// Fetch the latest entitlement and publish it. Concurrent calls coalesce;
  /// an account change starts a fresh request instead of joining a stale one.
  Future<EntitlementSnapshot?> refreshFromBackend({
    bool forceSessionRefresh = false,
  }) {
    if (!mounted || !_deps.isBackendAvailable()) {
      return Future<EntitlementSnapshot?>.value();
    }
    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;
    final future = _fetch(_generation, _accountId, forceSessionRefresh);
    _refreshFuture = future;
    return future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
  }

  bool _owns(int generation, String? account) =>
      mounted &&
      generation == _generation &&
      account == _accountId &&
      _deps.currentAccount()?.id == account;

  Future<void> _loadOfflineVerification(int generation, String? account) async {
    if (account == null) return;
    try {
      final record = await _deps.readOfflineVerification();
      // A fetch may already have recorded a fresher verification.
      if (_owns(generation, account) && _offline.verifiedAt == null) {
        _offline = record;
      }
    } catch (_) {
      // No record is the safe default: it grants nothing.
    }
  }

  Future<EntitlementSnapshot?> _fetch(
    int generation,
    String? account,
    bool forceSessionRefresh,
  ) async {
    if (!_owns(generation, account)) return null;
    if (account == null) {
      // Signed out: a known, entitlement-free guest. Not an error.
      _offlineGraceActive = false;
      state = SubscriptionState();
      return null;
    }
    state = state.copyWith(isLoading: true);
    try {
      final ent = await _deps.fetchEntitlement(
        forceSessionRefresh: forceSessionRefresh,
      );
      if (!_owns(generation, account)) return null;
      if (ent == null) {
        await _publishUnverified(
          generation,
          account,
          'Sign in to sync your ChessEver Premium membership.',
        );
        return null;
      }
      await _publishVerified(generation, account, ent);
      return _owns(generation, account) ? ent : null;
    } on DesktopBillingAuthException catch (e) {
      if (kDebugMode) debugPrint('[desktop-sub] auth refresh failed: $e');
      if (!_owns(generation, account)) return null;
      if (await _tryOfflineGrace(generation, account)) return null;
      try {
        await _deps.signOut();
      } catch (_) {}
      // Signing out fires an account change, which already reset state.
      if (_owns(generation, account)) {
        state = SubscriptionState(
          error: 'Your sign-in expired. Sign in again to sync Premium.',
        );
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[desktop-sub] refresh failed: $e');
      if (!_owns(generation, account)) return null;
      await _publishUnverified(generation, account, _unreachableMessage);
      return null;
    }
  }

  Future<void> _publishVerified(
    int generation,
    String account,
    EntitlementSnapshot ent,
  ) async {
    final now = _deps.now();
    final expiry = ent.expiresAt;
    final lapsed =
        !ent.inBillingGracePeriod && expiry != null && !expiry.isAfter(now);
    final active = ent.isActive && !lapsed;

    _offlineGraceActive = false;
    _offline = DesktopOfflineVerification(
      accountId: account,
      verifiedAt: now,
      wasActive: active,
      knownExpiry: expiry,
      inBillingGracePeriod: ent.inBillingGracePeriod,
    );
    state = SubscriptionState(
      isSubscribed: active,
      expirationDate: expiry,
      willRenew: ent.willRenew,
      provider: ent.provider,
      inBillingGracePeriod: ent.inBillingGracePeriod,
    );
    _armExpiry(
      generation,
      account,
      active && !ent.inBillingGracePeriod ? expiry : null,
    );

    try {
      await _deps.recordEntitlement(
        isActive: active,
        accountId: account,
        expiresAt: expiry,
        inBillingGracePeriod: ent.inBillingGracePeriod,
        verifiedAt: now,
      );
    } catch (e) {
      // The in-memory record already reflects this result; persisting it is
      // best-effort and only affects a later offline launch.
      if (kDebugMode) debugPrint('[desktop-sub] record failed: $e');
    }
  }

  /// The live entitlement could not be read. Honour the offline grace if this
  /// account has one, otherwise publish an honest "could not verify" state:
  /// not subscribed, with an error, which the access policy reads as
  /// temporarily unavailable (Retry) rather than as a lapsed membership.
  Future<void> _publishUnverified(
    int generation,
    String account,
    String message,
  ) async {
    if (await _tryOfflineGrace(generation, account)) return;
    if (!_owns(generation, account)) return;
    _offlineGraceActive = false;
    _armExpiry(generation, account, null);
    state = SubscriptionState(error: message);
  }

  /// Returns true when nothing further should be published: either the grace
  /// applied, or the request went stale while the record was being read.
  Future<bool> _tryOfflineGrace(int generation, String account) async {
    var record = _offline;
    if (record.accountId != account || record.verifiedAt == null) {
      try {
        record = await _deps.readOfflineVerification();
      } catch (_) {
        record = DesktopOfflineVerification.none;
      }
      if (!_owns(generation, account)) return true;
      _offline = record;
    }
    final now = _deps.now();
    if (!record.grantsPremium(currentAccountId: account, now: now)) {
      return false;
    }
    _offlineGraceActive = true;
    state = SubscriptionState(
      isSubscribed: true,
      expirationDate: record.knownExpiry,
      inBillingGracePeriod: record.inBillingGracePeriod,
    );
    final graceEnd = record.verifiedAt!.add(record.window);
    final expiry = record.knownExpiry;
    _armExpiry(
      generation,
      account,
      !record.inBillingGracePeriod && expiry != null && expiry.isBefore(graceEnd)
          ? expiry
          : graceEnd,
    );
    return true;
  }

  /// Arms a one-shot timer at [endsAt] so access stops at the exact instant,
  /// not at the next poll.
  void _armExpiry(int generation, String account, DateTime? endsAt) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (endsAt == null) return;
    final delay = endsAt.difference(_deps.now());
    _expiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (!_owns(generation, account)) return;
      _offlineGraceActive = false;
      state = SubscriptionState(isLoading: true);
      unawaited(refreshFromBackend());
    });
  }

  @visibleForTesting
  Future<EntitlementSnapshot?>? get inFlightRefresh => _refreshFuture;

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

/// Riverpod override that swaps the mobile RevenueCat-driven notifier for
/// the desktop one. Wired into [ProviderScope] in `desktop_main.dart`.
final Override desktopSubscriptionOverride = subscriptionProvider.overrideWith(
  (ref) => DesktopSubscriptionNotifier(),
);
