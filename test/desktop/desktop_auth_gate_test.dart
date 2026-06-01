import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_auth_gate.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  group('desktop subscription gate loading policy', () {
    test('blocks while entitlement has no subscribed snapshot yet', () {
      final state = SubscriptionState(isLoading: true);

      expect(shouldShowDesktopSubscriptionGateLoading(state), isTrue);
    });

    test('keeps shell mounted during subscribed entitlement refresh', () {
      final state = SubscriptionState(isSubscribed: true, isLoading: true);

      expect(shouldShowDesktopSubscriptionGateLoading(state), isFalse);
    });
  });
  group('desktop offline access grace', () {
    final now = DateTime(2026, 5, 28, 12);

    test('allows an active cached entitlement inside the 14 day window', () {
      final verifiedAt = now.subtract(const Duration(days: 13, hours: 23));

      expect(
        DesktopOfflineAccessCache.isOfflineAccessAllowed(
          isActive: true,
          verifiedAtMs: verifiedAt.millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
    });

    test('requires the user to reconnect after the 14 day window', () {
      final verifiedAt = now.subtract(const Duration(days: 15));

      expect(
        DesktopOfflineAccessCache.isOfflineAccessAllowed(
          isActive: true,
          verifiedAtMs: verifiedAt.millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('does not allow offline access without a previously active check', () {
      expect(
        DesktopOfflineAccessCache.isOfflineAccessAllowed(
          isActive: false,
          verifiedAtMs: now.millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
      expect(
        DesktopOfflineAccessCache.isOfflineAccessAllowed(
          isActive: true,
          verifiedAtMs: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('classifies common offline refresh failures', () {
      expect(
        isLikelyOfflineAuthRefreshFailure(TimeoutException('refresh')),
        isTrue,
      );
      expect(
        isLikelyOfflineAuthRefreshFailure(Exception('Failed host lookup')),
        isTrue,
      );
      expect(
        isLikelyOfflineAuthRefreshFailure(Exception('invalid refresh token')),
        isFalse,
      );
    });
  });
}
