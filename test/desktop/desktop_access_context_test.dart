import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  final full = DesktopAccessContext(
    feature: DesktopFeature.countrymen,
    action: DesktopAction.openContent,
    origin: DesktopDiscoveryOrigin.countrymen,
    ownedDocument: true,
    retainedSaveId: 'save-42',
    contentDate: DateTime(2026, 9, 1, 18, 30),
    playedPlies: 17,
    filterCriteriaCount: 2,
    sortKeyCount: 2,
    playerScoped: true,
    accountId: 'acct-a',
    entitlementGeneration: 4,
    quota: DesktopQuota.cloudSavedGames,
    additions: 3,
  );

  group('value semantics', () {
    test('equal fields are equal with equal hash codes', () {
      final copy = full.copyWith();
      expect(copy, full);
      expect(copy.hashCode, full.hashCode);
      expect(full.copyWith(playedPlies: 18), isNot(full));
      expect(full.copyWith(origin: DesktopDiscoveryOrigin.broadcast),
          isNot(full));
      expect(full.copyWith(sortKeyCount: 1), isNot(full));
      expect(full.copyWith(playerScoped: false), isNot(full));
      expect(full.copyWith(playerScoped: false).hashCode,
          isNot(full.hashCode));
      expect(full.toString(), contains('sortKeys: 2'));
      expect(full.toString(), contains('playerScoped: true'));
    });

    test('copyWith can clear nullable identity fields', () {
      final cleared = full.copyWith(
        clearRetainedSaveId: true,
        clearAccountId: true,
      );
      expect(cleared.retainedSaveId, isNull);
      expect(cleared.accountId, isNull);
    });
  });

  group('JSON', () {
    test('round-trips every field through an encoded string', () {
      final decoded = DesktopAccessContext.fromJson(
        jsonDecode(jsonEncode(full.toJson())) as Map<String, Object?>,
      );
      expect(decoded, full);
      expect(decoded.contentDate!.isUtc, isFalse);
    });

    test('round-trips a minimal context and UTC dates', () {
      final minimal = DesktopAccessContext(
        feature: DesktopFeature.likes,
        action: DesktopAction.view,
        origin: DesktopDiscoveryOrigin.likes,
        contentDate: DateTime.utc(2026, 9, 1),
      );
      expect(DesktopAccessContext.fromJson(minimal.toJson()), minimal);
      expect(
        DesktopAccessContext.fromJson(minimal.toJson()).entitlementGeneration,
        desktopUnassertedGeneration,
      );
    });

    test('an unrecognised payload decodes as a paid source, never as free',
        () {
      final decoded = DesktopAccessContext.fromJson(const {
        'feature': 'somethingFromANewerBuild',
        'action': 'teleport',
        'origin': null,
        'quota': 'mystery',
        'additions': -5,
        'filterCriteriaCount': -1,
      });
      expect(decoded.feature, DesktopFeature.gamebase);
      expect(decoded.origin, DesktopDiscoveryOrigin.gamebase);
      expect(decoded.action, DesktopAction.openContent);
      expect(decoded.quota, DesktopQuota.cloudSavedGames);
      expect(decoded.additions, 1);
      expect(decoded.filterCriteriaCount, 0);
      expect(decoded.sortKeyCount, 0);
      expect(decoded.playerScoped, isFalse);

      final decision = evaluateDesktopAccess(
        context: decoded,
        subscription: SubscriptionState(),
        entitlement: DesktopEntitlementSnapshot.guest,
        now: DateTime(2026, 9, 10),
      );
      expect(decision.outcome, DesktopAccess.premiumRequired);
    });

    test('a restored Countrymen board stays gated after the round trip', () {
      const tab = DesktopAccessContext(
        feature: DesktopFeature.broadcast,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.countrymen,
      );
      final restored = DesktopAccessContext.fromJson(
        jsonDecode(jsonEncode(tab.toJson())) as Map<String, Object?>,
      );
      final decision = evaluateDesktopAccess(
        context: restored,
        subscription: SubscriptionState(),
        entitlement: DesktopEntitlementSnapshot.guest,
        now: DateTime(2026, 9, 10),
      );
      expect(decision.outcome, DesktopAccess.premiumRequired);
      expect(decision.reason, DesktopAccessReason.premiumPaidSource);
    });
  });

  group('effective quota errs toward charging', () {
    DesktopQuota quotaOf(
      DesktopFeature feature,
      DesktopAction action, {
      DesktopQuota? explicit,
    }) => DesktopAccessContext(
      feature: feature,
      action: action,
      origin: DesktopDiscoveryOrigin.ownedDocument,
      quota: explicit,
    ).effectiveQuota;

    test('implied allowances', () {
      expect(
        quotaOf(DesktopFeature.ownedDocument, DesktopAction.save),
        DesktopQuota.cloudSavedGames,
      );
      expect(
        quotaOf(DesktopFeature.ownedDocument, DesktopAction.create),
        DesktopQuota.cloudDatabases,
      );
      expect(
        quotaOf(DesktopFeature.favorites, DesktopAction.create),
        DesktopQuota.favoritePlayers,
      );
      expect(
        quotaOf(DesktopFeature.gameReport, DesktopAction.create),
        DesktopQuota.gameReportsPerUtcDay,
      );
      expect(
        quotaOf(DesktopFeature.broadcast, DesktopAction.save),
        DesktopQuota.cloudSavedGames,
      );
      expect(
        quotaOf(DesktopFeature.ownedDocument, DesktopAction.export),
        DesktopQuota.none,
      );
    });

    test('exemptions must be explicit', () {
      expect(
        quotaOf(
          DesktopFeature.ownedDocument,
          DesktopAction.create,
          explicit: DesktopQuota.none,
        ),
        DesktopQuota.none,
      );
    });

    test('the Likes collection itself never spends an allowance', () {
      for (final action in [
        DesktopAction.create,
        DesktopAction.tag,
        DesktopAction.remove,
        DesktopAction.edit,
      ]) {
        expect(
          quotaOf(
            DesktopFeature.likes,
            action,
            explicit: DesktopQuota.cloudSavedGames,
          ),
          DesktopQuota.none,
          reason: action.name,
        );
      }
    });

    test('moving a like into a regular database is a charged save', () {
      expect(
        quotaOf(DesktopFeature.likes, DesktopAction.save),
        DesktopQuota.cloudSavedGames,
      );
    });

    test('local files, edits and never-gated actions spend nothing', () {
      expect(
        quotaOf(DesktopFeature.localFiles, DesktopAction.save),
        DesktopQuota.none,
      );
      expect(
        quotaOf(
          DesktopFeature.localFiles,
          DesktopAction.create,
          explicit: DesktopQuota.cloudDatabases,
        ),
        DesktopQuota.none,
      );
      for (final action in [
        DesktopAction.edit,
        ...desktopNeverGatedActions,
      ]) {
        expect(
          quotaOf(
            DesktopFeature.ownedDocument,
            action,
            explicit: DesktopQuota.cloudSavedGames,
          ),
          DesktopQuota.none,
          reason: action.name,
        );
      }
    });
  });

  group('ownership scope', () {
    test('covers the retained row but never an action reaching the origin',
        () {
      const owned = DesktopAccessContext(
        feature: DesktopFeature.ownedDocument,
        action: DesktopAction.export,
        origin: DesktopDiscoveryOrigin.gamebase,
        ownedDocument: true,
        retainedSaveId: 'save-1',
      );
      expect(owned.ownershipCovers, isTrue);
      for (final action in desktopSourceReachingActions) {
        expect(owned.copyWith(action: action).ownershipCovers, isFalse);
      }
      expect(
        owned.copyWith(clearRetainedSaveId: true).ownershipCovers,
        isFalse,
      );
    });
  });
}
