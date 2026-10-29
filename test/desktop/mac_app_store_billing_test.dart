import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'package:chessever/desktop/services/billing/mac_app_store_billing.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';

CustomerInfo customerWith(EntitlementInfo entitlement) => CustomerInfo(
  EntitlementInfos(
    {entitlement.identifier: entitlement},
    {if (entitlement.isActive) entitlement.identifier: entitlement},
  ),
  const {},
  const [],
  const [],
  const [],
  '2026-10-01T00:00:00Z',
  'account-a',
  const {},
  '2026-10-19T00:00:00Z',
);

EntitlementInfo premium({
  bool active = true,
  bool renews = true,
  String? billingIssue,
  String identifier = MacAppStoreBilling.entitlementIdentifier,
}) => EntitlementInfo(
  identifier,
  active,
  renews,
  '2026-10-01T00:00:00Z',
  '2026-10-01T00:00:00Z',
  'rc_chessever_monthly',
  false,
  store: Store.macAppStore,
  expirationDate: '2026-11-01T00:00:00Z',
  billingIssueDetectedAt: billingIssue,
);

void main() {
  group('post-transaction server reconciliation', () {
    const inactive = EntitlementSnapshot(isActive: false);
    const active = EntitlementSnapshot(isActive: true, provider: 'apple');

    test('a successful purchase waits through backend/webhook lag', () async {
      var requests = 0;
      final pauses = <Duration>[];
      final result = await MacAppStoreBilling.reconcileTransaction(
        backend: () async => ++requests < 3 ? inactive : active,
        isCurrentAccount: () => true,
        expectActive: true,
        pause: (duration) async => pauses.add(duration),
      );
      expect(result, same(active));
      expect(requests, 3);
      expect(pauses, [const Duration(seconds: 2), const Duration(seconds: 2)]);
    });

    test(
      'a backend revocation remains inactive after bounded retries',
      () async {
        var requests = 0;
        final result = await MacAppStoreBilling.reconcileTransaction(
          backend: () async {
            requests++;
            return inactive;
          },
          isCurrentAccount: () => true,
          expectActive: true,
          pause: (_) async {},
        );
        expect(result, same(inactive));
        expect(requests, 6);
      },
    );

    test(
      'restore without active store access still checks shared membership once',
      () async {
        var requests = 0;
        final result = await MacAppStoreBilling.reconcileTransaction(
          backend: () async {
            requests++;
            return inactive;
          },
          isCurrentAccount: () => true,
          expectActive: false,
          pause: (_) => throw StateError('must not poll'),
        );
        expect(result, same(inactive));
        expect(requests, 1);
      },
    );

    test('an auth rejection stops polling without SDK fallback', () async {
      var requests = 0;
      await expectLater(
        MacAppStoreBilling.reconcileTransaction(
          backend: () async {
            requests++;
            throw const DesktopBillingAuthException('expired');
          },
          isCurrentAccount: () => true,
          expectActive: true,
          pause: (_) => throw StateError('must not poll'),
        ),
        throwsA(isA<DesktopBillingAuthException>()),
      );
      expect(requests, 1);
    });

    test(
      'a changed account never receives a completed store reconciliation',
      () async {
        var current = true;
        final pending = Completer<EntitlementSnapshot?>();
        final result = MacAppStoreBilling.reconcileTransaction(
          backend: () => pending.future,
          isCurrentAccount: () => current,
          expectActive: true,
          pause: (_) async {},
        );
        final assertion = expectLater(result, throwsStateError);
        current = false;
        pending.complete(active);
        await assertion;
      },
    );

    test(
      'an account change during backoff prevents the next request',
      () async {
        var current = true;
        var requests = 0;
        await expectLater(
          MacAppStoreBilling.reconcileTransaction(
            backend: () async {
              requests++;
              return inactive;
            },
            isCurrentAccount: () => current,
            expectActive: true,
            pause: (_) async => current = false,
          ),
          throwsStateError,
        );
        expect(requests, 1);
      },
    );
  });

  test(
    'lifetime does not renew and expired payment failures are not grace',
    () {
      expect(
        EntitlementSnapshot.fromJson({
          'is_premium': true,
          'interval': 'lifetime',
        }).willRenew,
        isFalse,
      );
      expect(
        EntitlementSnapshot.fromJson({
          'is_premium': false,
          'status': 'past_due',
        }).inBillingGracePeriod,
        isFalse,
      );
    },
  );
  test('a rejected sign-in cannot fall back to cached store access', () async {
    expect(
      MacAppStoreBilling.resolveEntitlement(
        backend: () => throw const DesktopBillingAuthException('expired'),
        receipt: () async => const EntitlementSnapshot(isActive: true),
      ),
      throwsA(isA<DesktopBillingAuthException>()),
    );
  });
  test(
    'Mac honors Stripe and lifetime access through the shared backend',
    () async {
      const paid = EntitlementSnapshot(isActive: true, provider: 'stripe');
      final result = await MacAppStoreBilling.resolveEntitlement(
        backend: () async => paid,
        receipt: () => throw StateError('SDK is unavailable'),
      );
      expect(result, same(paid));
      expect(result?.expiresAt, isNull);
    },
  );

  test('a confirmed revocation overrides stale SDK access', () async {
    const revoked = EntitlementSnapshot(isActive: false, provider: 'stripe');
    final result = await MacAppStoreBilling.resolveEntitlement(
      backend: () async => revoked,
      receipt: () async => const EntitlementSnapshot(isActive: true),
    );
    expect(result, same(revoked));
  });

  test(
    'an unavailable backend falls back to the verified store receipt',
    () async {
      const paid = EntitlementSnapshot(isActive: true, provider: 'apple');
      final result = await MacAppStoreBilling.resolveEntitlement(
        backend: () => throw StateError('offline'),
        receipt: () async => paid,
      );
      expect(result, same(paid));
    },
  );

  test(
    'Mac receipt grants the shared entitlement through its current term',
    () {
      final snapshot = MacAppStoreBilling.snapshotFrom(
        customerWith(premium(renews: false)),
      );
      expect(snapshot.isActive, isTrue);
      expect(snapshot.provider, 'apple');
      expect(snapshot.willRenew, isFalse);
      expect(snapshot.expiresAt, DateTime.utc(2026, 11));
    },
  );

  test('an unrelated active entitlement cannot unlock Premium', () {
    final snapshot = MacAppStoreBilling.snapshotFrom(
      customerWith(premium(identifier: 'unrelated')),
    );
    expect(snapshot.isActive, isFalse);
  });

  test('billing retry is grace only while RevenueCat still grants access', () {
    const issue = '2026-10-19T00:00:00Z';
    expect(
      MacAppStoreBilling.snapshotFrom(
        customerWith(premium(billingIssue: issue)),
      ).inBillingGracePeriod,
      isTrue,
    );
    final lapsed = MacAppStoreBilling.snapshotFrom(
      customerWith(premium(active: false, billingIssue: issue)),
    );
    expect(lapsed.isActive, isFalse);
    expect(lapsed.inBillingGracePeriod, isFalse);
  });
}
