import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/billing/mac_app_store_billing.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

const _a = DesktopAccountIdentity(id: 'acct-a');
const _b = DesktopAccountIdentity(id: 'acct-b');

class _Backend {
  DesktopAccountIdentity? account = _a;
  final auth = StreamController<DesktopAccountIdentity?>.broadcast();
  final requests = <Completer<EntitlementSnapshot?>>[];
  DesktopOfflineVerification stored = DesktopOfflineVerification.none;
  final recordedAccounts = <String?>[];
  int signOuts = 0;
  DateTime clock = DateTime(2026, 9, 10, 12);
  Duration maxTimerDelay = desktopMaxTimerDelay;

  DesktopSubscriptionDependencies deps() => DesktopSubscriptionDependencies(
    maxTimerDelay: maxTimerDelay,
    isBackendAvailable: () => true,
    currentAccount: () => account,
    authChanges: () => auth.stream,
    fetchEntitlement: ({required bool forceSessionRefresh}) {
      final request = Completer<EntitlementSnapshot?>();
      requests.add(request);
      return request.future;
    },
    readOfflineVerification: () async => stored,
    recordEntitlement:
        ({
          required bool isActive,
          String? accountId,
          DateTime? expiresAt,
          bool inBillingGracePeriod = false,
          DateTime? verifiedAt,
        }) async {
          recordedAccounts.add(accountId);
          stored = DesktopOfflineVerification(
            accountId: accountId,
            verifiedAt: verifiedAt,
            wasActive: isActive,
            knownExpiry: expiresAt,
            inBillingGracePeriod: inBillingGracePeriod,
          );
        },
    signOut: () async {
      signOuts++;
      switchTo(null);
    },
    now: () => clock,
    refreshPeriod: const Duration(hours: 6),
  );

  void switchTo(DesktopAccountIdentity? next) {
    account = next;
    auth.add(next);
  }

  DesktopOfflineVerification verifiedFor(
    String accountId, {
    Duration age = const Duration(days: 3),
    Duration? expiresIn = const Duration(days: 20),
  }) => DesktopOfflineVerification(
    accountId: accountId,
    verifiedAt: clock.subtract(age),
    wasActive: true,
    knownExpiry: expiresIn == null ? null : clock.add(expiresIn),
  );
}

EntitlementSnapshot _active(DateTime now, {Duration term = const Duration(days: 30)}) =>
    EntitlementSnapshot(isActive: true, expiresAt: now.add(term), willRenew: true);

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Backend backend;
  late DesktopSubscriptionNotifier notifier;
  DesktopSubscriptionNotifier? started;

  DesktopSubscriptionNotifier start() => started = notifier =
      DesktopSubscriptionNotifier(dependencies: backend.deps());

  setUp(() {
    backend = _Backend();
    started = null;
  });
  tearDown(() async {
    final current = started;
    if (current != null && current.mounted) current.dispose();
    await backend.auth.close();
  });

  test('a stale response after logout is rejected', () async {
    start();
    await _settle();
    expect(backend.requests, hasLength(1));

    backend.switchTo(null);
    await _settle();
    expect(notifier.generation, 1);
    expect(notifier.state.isSubscribed, isFalse);

    backend.requests.first.complete(_active(backend.clock));
    await _settle();

    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.state.error, isNull);
    expect(backend.recordedAccounts, isEmpty);
    expect(notifier.entitlementSnapshot.accountId, isNull);
  });

  test('a late response from the previous account cannot land after a switch',
      () async {
    start();
    await _settle();

    backend.switchTo(_b);
    await _settle();
    // The switch starts a fresh request instead of joining the stale one.
    expect(backend.requests, hasLength(2));

    backend.requests[0].complete(_active(backend.clock));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);

    backend.requests[1].complete(const EntitlementSnapshot(isActive: false));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.state.isLoading, isFalse);
    expect(backend.recordedAccounts, ['acct-b']);
    expect(notifier.entitlementSnapshot.accountId, 'acct-b');
  });

  test('an active mobile or web purchase is Premium and recorded for the account',
      () async {
    start();
    await _settle();
    backend.requests.first.complete(_active(backend.clock));
    await _settle();

    expect(notifier.state.isSubscribed, isTrue);
    expect(desktopPremiumAccess(notifier.state, now: backend.clock),
        DesktopAccess.allowed);
    expect(backend.stored.accountId, 'acct-a');
    expect(backend.stored.wasActive, isTrue);
    expect(notifier.entitlementSnapshot.offline.accountId, 'acct-a');
  });

  test('concurrent refreshes coalesce into one request', () async {
    start();
    // The initial fetch is already in flight; both callers join it.
    final first = notifier.refreshFromBackend();
    final second = notifier.refreshFromBackend();
    expect(identical(first, second), isTrue);
    await _settle();
    expect(backend.requests, hasLength(1));
    backend.requests.first.complete(_active(backend.clock));
    await _settle();
  });

  test(
    'confirmed Apple purchase unlocks access after webhook lag and supersedes an old inactive poll',
    () async {
      start();
      await _settle();
      final beforePurchase = backend.requests.first;
      var reconciliations = 0;
      final confirmed = _active(backend.clock);
      final result = await notifier.refreshAfterStoreTransaction(
        accountId: 'acct-a',
        reconcile:
            () => MacAppStoreBilling.reconcileTransaction(
              backend:
                  () async =>
                      ++reconciliations < 3
                          ? const EntitlementSnapshot(isActive: false)
                          : confirmed,
              isCurrentAccount: () => backend.account?.id == 'acct-a',
              expectActive: true,
              pause: (_) async {},
            ),
      );
      expect(result, same(confirmed));
      expect(reconciliations, 3);
      expect(notifier.state.isSubscribed, isTrue);
      expect(
        desktopPremiumAccess(notifier.state, now: backend.clock),
        DesktopAccess.allowed,
      );
      expect(backend.stored.wasActive, isTrue);

      beforePurchase.complete(const EntitlementSnapshot(isActive: false));
      await _settle();
      expect(notifier.state.isSubscribed, isTrue);
      expect(backend.stored.wasActive, isTrue);

      unawaited(notifier.refreshFromBackend());
      await _settle();
      backend.requests.last.complete(
        const EntitlementSnapshot(isActive: false),
      );
      await _settle();
      expect(notifier.state.isSubscribed, isFalse);
      expect(backend.stored.wasActive, isFalse);
    },
  );

  test(
    'Apple reconciliation cannot grant another account or write its offline record',
    () async {
      start();
      await _settle();
      final pending = Completer<EntitlementSnapshot?>();
      final result = notifier.refreshAfterStoreTransaction(
        accountId: 'acct-a',
        reconcile: () => pending.future,
      );
      backend.switchTo(_b);
      await _settle();
      pending.complete(_active(backend.clock));
      expect(await result, isNull);
      expect(notifier.state.isSubscribed, isFalse);
      expect(backend.recordedAccounts, isEmpty);
      expect(notifier.entitlementSnapshot.accountId, 'acct-b');
    },
  );

  test('a verified member keeps Premium through a network failure', () async {
    backend.stored = backend.verifiedFor('acct-a');
    start();
    await _settle();
    backend.requests.first.completeError(Exception('Failed host lookup'));
    await _settle();

    expect(notifier.state.isSubscribed, isTrue);
    expect(notifier.state.error, isNull);
    expect(notifier.isOfflineGraceActive, isTrue);
    expect(backend.signOuts, 0);
  });

  test('the offline grace is bound to the account that was verified',
      () async {
    backend
      ..stored = backend.verifiedFor('acct-a')
      ..account = _b;
    start();
    await _settle();
    backend.requests.first.completeError(Exception('Failed host lookup'));
    await _settle();

    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.state.error, isNotNull);
    expect(
      desktopPremiumAccess(notifier.state, now: backend.clock),
      DesktopAccess.temporarilyUnavailable,
    );
  });

  test('the offline grace ends at the known entitlement expiry', () async {
    backend.stored = backend.verifiedFor(
      'acct-a',
      expiresIn: const Duration(hours: -1),
    );
    start();
    await _settle();
    backend.requests.first.completeError(TimeoutException('entitlement'));
    await _settle();

    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.isOfflineGraceActive, isFalse);
  });

  test('the offline grace ends after 14 days', () async {
    backend.stored = backend.verifiedFor(
      'acct-a',
      age: const Duration(days: 15),
    );
    start();
    await _settle();
    backend.requests.first.completeError(TimeoutException('entitlement'));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
  });

  test('an authoritative inactive result overrides the grace immediately',
      () async {
    backend.stored = backend.verifiedFor('acct-a');
    start();
    await _settle();
    backend.requests.first.complete(const EntitlementSnapshot(isActive: false));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
    expect(backend.stored.wasActive, isFalse);

    unawaited(notifier.refreshFromBackend());
    await _settle();
    backend.requests.last.completeError(Exception('connection refused'));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.isOfflineGraceActive, isFalse);
  });

  test('a sign-in failure without grace signs out; with grace it does not',
      () async {
    start();
    await _settle();
    backend.requests.first.completeError(
      const DesktopBillingAuthException('expired'),
    );
    await _settle();
    expect(backend.signOuts, 1);
    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.entitlementSnapshot.accountId, isNull);

    notifier.dispose();
    await backend.auth.close();
    backend = _Backend()..stored = _Backend().verifiedFor('acct-a');
    start();
    await _settle();
    backend.requests.first.completeError(
      const DesktopBillingAuthException('expired'),
    );
    await _settle();
    expect(backend.signOuts, 0);
    expect(notifier.state.isSubscribed, isTrue);
  });

  test('cancellation through expiry, then access stops at the exact instant',
      () async {
    start();
    await _settle();
    backend.requests.first.complete(
      EntitlementSnapshot(
        isActive: true,
        willRenew: false,
        expiresAt: backend.clock.add(const Duration(milliseconds: 40)),
      ),
    );
    await _settle();
    expect(notifier.state.isSubscribed, isTrue);
    expect(notifier.state.willRenew, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.state.isLoading, isTrue);
    expect(backend.requests, hasLength(2));
  });

  test('the expiry timer never asks a browser for more than 2^31-1 ms', () {
    // setTimeout overflows past this and fires at once (app.chessever.com
    // looped on "Checking your membership" for annual members).
    expect(
      desktopMaxTimerDelay.inMilliseconds,
      lessThanOrEqualTo(0x7FFFFFFF),
    );
  });

  test('a far expiry is waited out in steps, without refetching', () async {
    backend.maxTimerDelay = const Duration(milliseconds: 20);
    start();
    await _settle();
    final expiry = backend.clock.add(const Duration(days: 365));
    backend.requests.first.complete(
      EntitlementSnapshot(isActive: true, willRenew: true, expiresAt: expiry),
    );
    await _settle();

    // Several steps elapse; each re-measures and re-arms, none refetches.
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await _settle();
    expect(notifier.state.isSubscribed, isTrue);
    expect(notifier.state.isLoading, isFalse);
    expect(backend.requests, hasLength(1));

    // Once the expiry is within a step, access stops at the instant.
    backend.clock = expiry;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
    expect(notifier.state.isLoading, isTrue);
    expect(backend.requests, hasLength(2));
  });

  test('billing grace is Premium past the term; a lapsed term is not',
      () async {
    start();
    await _settle();
    backend.requests.first.complete(
      EntitlementSnapshot(
        isActive: true,
        status: 'past_due',
        inBillingGracePeriod: true,
        expiresAt: backend.clock.subtract(const Duration(days: 2)),
      ),
    );
    await _settle();
    expect(notifier.state.isSubscribed, isTrue);
    expect(notifier.state.inBillingGracePeriod, isTrue);

    unawaited(notifier.refreshFromBackend());
    await _settle();
    backend.requests.last.complete(
      EntitlementSnapshot(
        isActive: true,
        expiresAt: backend.clock.subtract(const Duration(seconds: 1)),
      ),
    );
    await _settle();
    expect(notifier.state.isSubscribed, isFalse);
  });

  test('an anonymous identity is a guest and bumps the generation', () async {
    start();
    await _settle();
    backend.switchTo(const DesktopAccountIdentity(id: 'anon', isAnonymous: true));
    await _settle();
    final snapshot = notifier.entitlementSnapshot;
    expect(snapshot.generation, 1);
    expect(snapshot.isAnonymous, isTrue);
    expect(snapshot.hasPermanentAccount, isFalse);
  });

  test('responses arriving after dispose are ignored', () async {
    start();
    await _settle();
    notifier.dispose();
    backend.requests.first.complete(_active(backend.clock));
    await _settle();
    expect(backend.recordedAccounts, isEmpty);
  });

  test('legacy offline records without an account grant nothing', () {
    final legacy = DesktopOfflineAccessCache.offlineVerificationFromRecord(
      isActive: true,
      verifiedAtMs: backend.clock.millisecondsSinceEpoch,
      accountId: null,
      expiresAtMs: null,
    );
    expect(
      legacy.grantsPremium(currentAccountId: 'acct-a', now: backend.clock),
      isFalse,
    );
  });

  test('a background re-check keeps a known free result, never checking',
      () async {
    start();
    await _settle();
    backend.requests.first.complete(const EntitlementSnapshot(isActive: false));
    await _settle();
    expect(notifier.state.isLoading, isFalse);
    expect(desktopPremiumAccess(notifier.state), DesktopAccess.premiumRequired);

    final published = <SubscriptionState>[];
    final removeListener = notifier.addListener(
      published.add,
      fireImmediately: false,
    );
    addTearDown(removeListener);

    // The periodic poll and Retry both land here.
    unawaited(notifier.refreshFromBackend());
    await _settle();
    expect(backend.requests, hasLength(2));
    expect(published, isEmpty, reason: 'a known denial must not blink');
    expect(desktopPremiumAccess(notifier.state), DesktopAccess.premiumRequired);

    // A purchase made elsewhere still unlocks as soon as the response lands.
    backend.requests.last.complete(_active(backend.clock));
    await _settle();
    expect(desktopPremiumAccess(notifier.state, now: backend.clock),
        DesktopAccess.allowed);
  });

  test('a re-check after a failed lookup shows checking, never Premium',
      () async {
    start();
    await _settle();
    backend.requests.first.completeError(Exception('offline'));
    await _settle();
    expect(
      desktopPremiumAccess(notifier.state),
      DesktopAccess.temporarilyUnavailable,
    );

    unawaited(notifier.refreshFromBackend());
    await _settle();
    expect(notifier.state.isLoading, isTrue);
    expect(desktopPremiumAccess(notifier.state), DesktopAccess.checking);
    expect(notifier.state.isSubscribed, isFalse);

    backend.requests.last.complete(const EntitlementSnapshot(isActive: false));
    await _settle();
    expect(desktopPremiumAccess(notifier.state), DesktopAccess.premiumRequired);
  });

  test('providers expose the lifecycle to access decisions', () async {
    final container = ProviderContainer(
      overrides: [
        subscriptionProvider.overrideWith(
          (ref) => start(),
        ),
      ],
    );
    addTearDown(container.dispose);
    const paid = DesktopAccessContext(
      feature: DesktopFeature.gamebase,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.gamebase,
    );
    final sub = container.listen(desktopAccessDecisionProvider(paid), (previous, next) {});
    addTearDown(sub.close);

    expect(sub.read().outcome, DesktopAccess.checking);
    await _settle();
    backend.requests.first.complete(_active(DateTime.now()));
    await _settle();
    expect(sub.read().outcome, DesktopAccess.allowed);
    expect(container.read(desktopEntitlementProvider).accountId, 'acct-a');

    backend.switchTo(null);
    await _settle();
    expect(sub.read().outcome, DesktopAccess.premiumRequired);
    expect(container.read(desktopEntitlementProvider).generation, 1);
  });
}
