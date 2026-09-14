import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/state/smart_collection_access.dart';
import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/utils/freemium_quota_guard.dart';
import 'package:flutter_test/flutter_test.dart';

FreemiumQuotaResult _spent(
  FreemiumQuotaKind kind, {
  int? used = 10,
  int? limit = 10,
}) => FreemiumQuotaResult(
  kind: kind,
  outcome: FreemiumQuotaOutcome.quotaExceeded,
  reason: 'quota_exceeded',
  requested: 1,
  used: used,
  limit: limit,
  source: FreemiumQuotaSource.server,
);

void main() {
  group('server quota result -> desktop paywall decision', () {
    test('maps each allowance to its quota and reason with capacity', () {
      final expected = {
        FreemiumQuotaKind.savedGames: (
          DesktopQuota.cloudSavedGames,
          DesktopAccessReason.quotaCloudSavedGames,
        ),
        FreemiumQuotaKind.favoritePlayers: (
          DesktopQuota.favoritePlayers,
          DesktopAccessReason.quotaFavoritePlayers,
        ),
        FreemiumQuotaKind.ownedDatabases: (
          DesktopQuota.cloudDatabases,
          DesktopAccessReason.quotaCloudDatabases,
        ),
      };
      for (final entry in expected.entries) {
        final decision = freemiumQuotaDesktopDecision(_spent(entry.key));
        expect(decision.outcome, DesktopAccess.quotaExceeded);
        expect(decision.reason, entry.value.$2);
        expect(decision.capacity?.quota, entry.value.$1);
        expect(decision.capacity?.used, 10);
        expect(decision.capacity?.limit, 10);
        expect(decision.capacity?.requested, 1);
      }
    });

    test('omits capacity when the server did not report usage', () {
      final decision = freemiumQuotaDesktopDecision(
        _spent(FreemiumQuotaKind.savedGames, used: null),
      );
      expect(decision.outcome, DesktopAccess.quotaExceeded);
      expect(decision.capacity, isNull);
    });
  });

  group('smart collection access', () {
    test('maps each content action onto the policy action', () {
      expect(
        smartCollectionAccessContext(
          SmartCollectionContentAction.openGame,
        ).action,
        DesktopAction.openContent,
      );
      expect(
        smartCollectionAccessContext(
          SmartCollectionContentAction.previewNavigate,
        ).action,
        DesktopAction.previewNavigate,
      );
      expect(
        smartCollectionAccessContext(
          SmartCollectionContentAction.gameContextMenu,
        ).action,
        DesktopAction.copy,
      );
    });

    test('provenance decides: gated via the collection, free via broadcast', () {
      const entitlement = DesktopEntitlementSnapshot(
        accountId: 'acct-free',
        generation: 1,
      );
      final viaCollection = smartCollectionAccessContext(
        SmartCollectionContentAction.openGame,
      );
      final gated = evaluateDesktopAccess(
        context: viaCollection,
        subscription: SubscriptionState(),
        entitlement: entitlement,
      );
      expect(gated.outcome, isNot(DesktopAccess.allowed));

      final viaBroadcast = viaCollection.copyWith(
        feature: DesktopFeature.broadcast,
        origin: DesktopDiscoveryOrigin.broadcast,
      );
      final free = evaluateDesktopAccess(
        context: viaBroadcast,
        subscription: SubscriptionState(),
        entitlement: entitlement,
      );
      expect(free.outcome, DesktopAccess.allowed);
    });
  });

  test('Botvinnik upgrade copy names a daily allowance, never unlimited', () {
    final copy = desktopPaywallCopyFor(
      const DesktopAccessDecision(
        DesktopAccess.premiumRequired,
        DesktopAccessReason.premiumBotvinnikAllowance,
      ),
    );
    final text = '${copy.title} ${copy.body}';
    expect(copy.title, contains('Botvinnik'));
    expect(copy.body, contains('daily'));
    expect(text.toLowerCase(), isNot(contains('unlimited')));
    expect(text, isNot(contains('—')));
    expect(RegExp(r'\d').hasMatch(text), isFalse);
  });
}
