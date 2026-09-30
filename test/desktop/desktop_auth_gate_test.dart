import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_auth_gate.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';

void main() {
  group('desktop auth gate routing', () {
    test('guests and free users reach the shell with no entitlement check', () {
      for (final bootstrap in DesktopGuestBootstrap.values) {
        expect(
          resolveDesktopAuthGateView(
            restoring: false,
            hasSession: true,
            bootstrap: bootstrap,
          ),
          DesktopAuthGateView.shell,
        );
      }
    });

    test('restoring and an in-flight guest bootstrap show loading', () {
      expect(
        resolveDesktopAuthGateView(
          restoring: true,
          hasSession: true,
          bootstrap: DesktopGuestBootstrap.idle,
        ),
        DesktopAuthGateView.loading,
      );
      expect(
        resolveDesktopAuthGateView(
          restoring: false,
          hasSession: false,
          bootstrap: DesktopGuestBootstrap.inFlight,
        ),
        DesktopAuthGateView.loading,
      );
    });

    test('no session without a pending guest shows the welcome screen', () {
      expect(
        resolveDesktopAuthGateView(
          restoring: false,
          hasSession: false,
          bootstrap: DesktopGuestBootstrap.failed,
        ),
        DesktopAuthGateView.welcome,
      );
    });

    test('creates a guest on launch but never a second one', () {
      expect(
        shouldBootstrapDesktopGuest(
          hasSession: false,
          hasCurrentUser: false,
          signedOutThisRun: false,
          bootstrap: DesktopGuestBootstrap.idle,
        ),
        isTrue,
      );
      expect(
        shouldBootstrapDesktopGuest(
          hasSession: false,
          hasCurrentUser: true,
          signedOutThisRun: false,
          bootstrap: DesktopGuestBootstrap.idle,
        ),
        isFalse,
      );
      expect(
        shouldBootstrapDesktopGuest(
          hasSession: false,
          hasCurrentUser: false,
          signedOutThisRun: false,
          bootstrap: DesktopGuestBootstrap.inFlight,
        ),
        isFalse,
      );
    });

    test('an explicit sign-out does not silently mint a guest', () {
      expect(
        shouldBootstrapDesktopGuest(
          hasSession: false,
          hasCurrentUser: false,
          signedOutThisRun: true,
          bootstrap: DesktopGuestBootstrap.idle,
        ),
        isFalse,
      );
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
