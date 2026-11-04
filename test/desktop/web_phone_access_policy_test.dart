import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  final today = DateTime(2026, 11, 5, 12);
  DesktopAccessDecision decide(
    DesktopAccessContext context, {
    SubscriptionState? subscription,
    bool web = true,
  }) => evaluateDesktopAccess(
    context: context,
    subscription: subscription ?? SubscriptionState(),
    entitlement: DesktopEntitlementSnapshot.guest,
    now: today,
    isWebApp: web,
  );

  for (final feature in [DesktopFeature.likes, DesktopFeature.communityLikes]) {
    final origin =
        feature == DesktopFeature.likes
            ? DesktopDiscoveryOrigin.likes
            : DesktopDiscoveryOrigin.communityLikes;
    group('phone parity: ${feature.name}', () {
      for (final action in [
        DesktopAction.openContent,
        DesktopAction.previewNavigate,
        DesktopAction.fetchPgn,
        DesktopAction.copy,
        DesktopAction.share,
        DesktopAction.save,
      ]) {
        test(
          '${action.name} is paid even for today and a retained like row',
          () {
            final request = DesktopAccessContext(
              feature: feature,
              action: action,
              origin: origin,
              contentDate: today,
              ownedDocument: true,
              retainedSaveId: 'like-row',
            );
            expect(decide(request).outcome, DesktopAccess.premiumRequired);
            expect(
              decide(
                request,
                subscription: SubscriptionState(isSubscribed: true),
              ).isAllowed,
              isTrue,
            );
            expect(
              decide(
                request,
                subscription: SubscriptionState(error: 'offline'),
              ).outcome,
              DesktopAccess.temporarilyUnavailable,
            );
            expect(
              decide(
                request,
                subscription: SubscriptionState(isLoading: true),
              ).outcome,
              DesktopAccess.checking,
            );
          },
        );
      }
      for (final action in [
        DesktopAction.view,
        DesktopAction.sort,
        DesktopAction.filter,
        DesktopAction.remove,
        DesktopAction.tag,
      ]) {
        test('${action.name} remains free during an outage', () {
          expect(
            decide(
              DesktopAccessContext(
                feature: feature,
                action: action,
                origin: origin,
              ),
              subscription: SubscriptionState(error: 'offline'),
            ).isAllowed,
            isTrue,
          );
        });
      }
      test('native today window is preserved', () {
        expect(
          decide(
            DesktopAccessContext(
              feature: feature,
              action: DesktopAction.openContent,
              origin: origin,
              contentDate: today,
            ),
            web: false,
          ).isAllowed,
          isTrue,
        );
      });
    });
  }

  for (final action in [
    DesktopAction.view,
    DesktopAction.create,
    DesktopAction.recompute,
  ]) {
    test('every web report ${action.name} needs Premium, including cached', () {
      final request = DesktopAccessContext(
        feature: DesktopFeature.gameReport,
        action: action,
        origin: DesktopDiscoveryOrigin.ownedDocument,
        ownedDocument: true,
        retainedSaveId: 'saved',
        quota: DesktopQuota.none,
      );
      expect(decide(request).reason, DesktopAccessReason.premiumGameReport);
      expect(
        decide(
          request,
          subscription: SubscriptionState(isSubscribed: true),
        ).isAllowed,
        isTrue,
      );
    });
  }

  test('free prep setup and downloads, paid statistics and games', () {
    for (final action in [
      DesktopAction.create,
      DesktopAction.acquireSource,
      DesktopAction.fetchPgn,
      DesktopAction.view,
      DesktopAction.remove,
      DesktopAction.export,
    ]) {
      expect(
        decide(
          DesktopAccessContext(
            feature: DesktopFeature.prepare,
            action: action,
            origin: DesktopDiscoveryOrigin.localFile,
          ),
        ).isAllowed,
        isTrue,
        reason: action.name,
      );
    }
    for (final action in [
      DesktopAction.recompute,
      DesktopAction.openContent,
      DesktopAction.previewNavigate,
    ]) {
      expect(
        decide(
          DesktopAccessContext(
            feature: DesktopFeature.prepare,
            action: action,
            origin: DesktopDiscoveryOrigin.localFile,
          ),
        ).outcome,
        DesktopAccess.premiumRequired,
        reason: action.name,
      );
    }
  });

  test('current player-profile game is free; archive context is paid', () {
    const current = DesktopAccessContext(
      feature: DesktopFeature.playerProfile,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.playerProfile,
    );
    expect(decide(current).isAllowed, isTrue);
    expect(
      decide(current.copyWith(feature: DesktopFeature.eventDiscovery)).outcome,
      DesktopAccess.premiumRequired,
    );
    expect(
      decide(
        current.copyWith(action: DesktopAction.filter, filterCriteriaCount: 2),
      ).outcome,
      DesktopAccess.premiumRequired,
    );
    expect(
      decide(current.copyWith(action: DesktopAction.bulkSelect)).outcome,
      DesktopAccess.premiumRequired,
    );
  });
}
