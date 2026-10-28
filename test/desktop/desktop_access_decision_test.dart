import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  final now = DateTime(2026, 9, 10, 12);
  final free = SubscriptionState();
  final premium = SubscriptionState(
    isSubscribed: true,
    expirationDate: now.add(const Duration(days: 30)),
  );
  final checking = SubscriptionState(isLoading: true);
  final unknown = SubscriptionState(error: 'timeout');

  const member = DesktopEntitlementSnapshot(accountId: 'acct-a', generation: 1);
  const guest = DesktopEntitlementSnapshot.guest;
  const anonymous = DesktopEntitlementSnapshot(
    accountId: 'anon-1',
    isAnonymous: true,
  );

  DesktopAccessDecision decide(
    DesktopAccessContext context, {
    SubscriptionState? sub,
    DesktopEntitlementSnapshot entitlement = member,
    DesktopUsage? usage,
  }) => evaluateDesktopAccess(
    context: context,
    subscription: sub ?? free,
    entitlement: usage == null ? entitlement : entitlement.withUsage(usage),
    now: now,
  );

  const broadcastOpen = DesktopAccessContext(
    feature: DesktopFeature.broadcast,
    action: DesktopAction.openContent,
    origin: DesktopDiscoveryOrigin.broadcast,
  );
  const gamebaseOpen = DesktopAccessContext(
    feature: DesktopFeature.gamebase,
    action: DesktopAction.openContent,
    origin: DesktopDiscoveryOrigin.gamebase,
  );
  const saveGame = DesktopAccessContext(
    feature: DesktopFeature.ownedDocument,
    action: DesktopAction.save,
    origin: DesktopDiscoveryOrigin.broadcast,
  );

  Iterable<DesktopAccessContext> everyRequest({
    int? plies,
    DateTime? date,
    int filters = 0,
  }) sync* {
    for (final feature in DesktopFeature.values) {
      for (final action in DesktopAction.values) {
        for (final origin in DesktopDiscoveryOrigin.values) {
          yield DesktopAccessContext(
            feature: feature,
            action: action,
            origin: origin,
            playedPlies: plies,
            contentDate: date,
            filterCriteriaCount: filters,
          );
        }
      }
    }
  }

  group('outcome matrix', () {
    test('allowed: free content on the free tier', () {
      final decision = decide(broadcastOpen);
      expect(decision.outcome, DesktopAccess.allowed);
      expect(decision.reason, DesktopAccessReason.allowedFree);
    });

    test('allowed: paid content for a member', () {
      final decision = decide(gamebaseOpen, sub: premium);
      expect(decision.outcome, DesktopAccess.allowed);
      expect(decision.reason, DesktopAccessReason.allowedPremium);
    });

    test('checking: entitlement in flight with nothing known', () {
      final decision = decide(gamebaseOpen, sub: checking);
      expect(decision.outcome, DesktopAccess.checking);
      expect(decision.reason, DesktopAccessReason.entitlementChecking);
      expect(decision.mayOfferPurchase, isFalse);
    });

    test('checking on top of a still-valid entitlement keeps working', () {
      final refreshing = SubscriptionState(
        isSubscribed: true,
        isLoading: true,
        expirationDate: now.add(const Duration(days: 1)),
      );
      expect(
        decide(gamebaseOpen, sub: refreshing).outcome,
        DesktopAccess.allowed,
      );
    });

    test('accountRequired: purchase and Botvinnik without an account', () {
      final purchase = decide(
        const DesktopAccessContext(
          feature: DesktopFeature.purchase,
          action: DesktopAction.acquireSource,
          origin: DesktopDiscoveryOrigin.deepLink,
        ),
        entitlement: guest,
      );
      expect(purchase.outcome, DesktopAccess.accountRequired);
      expect(purchase.reason, DesktopAccessReason.accountRequiredForPurchase);

      final botvinnik = decide(
        const DesktopAccessContext(
          feature: DesktopFeature.botvinnik,
          action: DesktopAction.view,
          origin: DesktopDiscoveryOrigin.deepLink,
        ),
        entitlement: anonymous,
      );
      expect(botvinnik.outcome, DesktopAccess.accountRequired);
      expect(botvinnik.reason, DesktopAccessReason.accountRequiredForBotvinnik);
    });

    test('a permanent account may purchase and enter Botvinnik', () {
      for (final feature in [DesktopFeature.purchase, DesktopFeature.botvinnik]) {
        final decision = decide(
          DesktopAccessContext(
            feature: feature,
            action: DesktopAction.view,
            origin: DesktopDiscoveryOrigin.deepLink,
          ),
        );
        expect(decision.outcome, DesktopAccess.allowed);
        expect(decision.reason, DesktopAccessReason.allowedAccountPresent);
      }
    });

    test('premiumRequired: paid content with a known free entitlement', () {
      final decision = decide(gamebaseOpen);
      expect(decision.outcome, DesktopAccess.premiumRequired);
      expect(decision.reason, DesktopAccessReason.premiumPaidSource);
      expect(decision.mayOfferPurchase, isTrue);
    });

    test('quotaExceeded: carries the used/limit pair', () {
      final decision = decide(
        saveGame,
        usage: const DesktopUsage(cloudSavedGames: 10),
      );
      expect(decision.outcome, DesktopAccess.quotaExceeded);
      expect(decision.reason, DesktopAccessReason.quotaCloudSavedGames);
      expect(
        decision.capacity,
        const DesktopQuotaCapacity(
          quota: DesktopQuota.cloudSavedGames,
          used: 10,
          limit: 10,
          requested: 1,
        ),
      );
      expect(decision.capacity!.remaining, 0);
    });

    test('temporarilyUnavailable: paid content with an unknown entitlement',
        () {
      final decision = decide(gamebaseOpen, sub: unknown);
      expect(decision.outcome, DesktopAccess.temporarilyUnavailable);
      expect(decision.reason, DesktopAccessReason.entitlementUnknown);
      expect(decision.mayOfferPurchase, isFalse);
    });

    test('reason codes are unique and stable', () {
      final codes = DesktopAccessReason.values.map((r) => r.code).toSet();
      expect(codes.length, DesktopAccessReason.values.length);
      expect(DesktopAccessReason.quotaCloudSavedGames.code,
          'quota_cloud_saved_games');
      expect(DesktopAccessReason.entitlementUnknown.code,
          'entitlement_unknown');
    });
  });

  group('unknown entitlement never unlocks and never upsells', () {
    const overLimit = DesktopUsage(
      favoritePlayers: 9,
      cloudDatabases: 9,
      cloudSavedGames: 99,
      gameReportsOnUtcDay: 5,
    );
    final stale = now.subtract(const Duration(days: 30));

    test('error: no request anywhere produces a purchase prompt', () {
      for (final context in everyRequest(plies: 40, date: stale, filters: 3)) {
        final decision = decide(context, sub: unknown, usage: overLimit);
        expect(
          decision.mayOfferPurchase,
          isFalse,
          reason: '$context -> $decision',
        );
      }
    });

    test('error: no paid request is allowed without the offline grace', () {
      for (final context in everyRequest(plies: 40, date: stale, filters: 3)) {
        final decision = decide(context, sub: unknown, usage: overLimit);
        final asFree = decide(context, sub: free, usage: overLimit);
        if (!asFree.isAllowed) {
          expect(decision.isAllowed, isFalse, reason: '$context');
        }
      }
    });

    test('loading: no request anywhere produces a purchase prompt', () {
      for (final context in everyRequest(plies: 40, date: stale, filters: 3)) {
        final decision = decide(context, sub: checking, usage: overLimit);
        expect(
          decision.mayOfferPurchase,
          isFalse,
          reason: '$context -> $decision',
        );
      }
    });

    test('quota over the free limit with an unknown entitlement is Retry', () {
      final decision = decide(
        saveGame,
        sub: unknown,
        usage: const DesktopUsage(cloudSavedGames: 10),
      );
      expect(decision.outcome, DesktopAccess.temporarilyUnavailable);
      expect(decision.capacity!.used, 10);
    });

    test('quota within the free limit proceeds while membership is unknown',
        () {
      final decision = decide(
        saveGame,
        sub: unknown,
        usage: const DesktopUsage(cloudSavedGames: 3),
      );
      expect(decision.outcome, DesktopAccess.allowed);
      expect(decision.reason, DesktopAccessReason.allowedWithinFreeQuota);
    });

    test('quota over the free limit while checking waits, no upsell', () {
      expect(
        decide(
          saveGame,
          sub: checking,
          usage: const DesktopUsage(cloudSavedGames: 10),
        ).outcome,
        DesktopAccess.checking,
      );
    });

    test('unmeasured usage is Retry, never a free pass', () {
      final decision = decide(saveGame);
      expect(decision.outcome, DesktopAccess.temporarilyUnavailable);
      expect(decision.reason, DesktopAccessReason.usageUnknown);
    });
  });

  group('guests get the free tier', () {
    const zeroUsage = DesktopUsage(
      favoritePlayers: 0,
      cloudDatabases: 0,
      cloudSavedGames: 0,
      gameReportsOnUtcDay: 0,
    );

    test('accountRequired appears only for purchase and Botvinnik', () {
      for (final identity in [guest, anonymous]) {
        for (final context in everyRequest(plies: 4, date: now)) {
          final decision = decide(
            context,
            entitlement: identity,
            usage: zeroUsage,
          );
          final accountBound =
              (context.feature == DesktopFeature.purchase ||
                  context.feature == DesktopFeature.botvinnik) &&
              !desktopNeverGatedActions.contains(context.action);
          expect(
            decision.outcome == DesktopAccess.accountRequired,
            accountBound,
            reason: '$context -> $decision',
          );
        }
      }
    });

    test('saving, favouriting, creating databases and reports need no account',
        () {
      final requests = [
        saveGame,
        const DesktopAccessContext(
          feature: DesktopFeature.favorites,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.playerProfile,
        ),
        const DesktopAccessContext(
          feature: DesktopFeature.ownedDocument,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.ownedDocument,
        ),
        const DesktopAccessContext(
          feature: DesktopFeature.gameReport,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.broadcast,
        ),
        broadcastOpen,
        const DesktopAccessContext(
          feature: DesktopFeature.openingExplorer,
          action: DesktopAction.fetchPgn,
          origin: DesktopDiscoveryOrigin.broadcast,
          playedPlies: 20,
        ),
      ];
      for (final context in requests) {
        final decision = decide(context, entitlement: guest, usage: zeroUsage);
        expect(decision.outcome, DesktopAccess.allowed, reason: '$context');
      }
    });

    test('a guest asking for paid content is shown Premium, not sign-in', () {
      expect(
        decide(gamebaseOpen, entitlement: guest).outcome,
        DesktopAccess.premiumRequired,
      );
    });
  });

  group('quotas at limit - 1, limit, limit + 1', () {
    void expectLadder(
      DesktopAccessContext context,
      DesktopUsage Function(int used) usage,
      int limit,
      DesktopAccessReason exceeded,
    ) {
      final under = decide(context, usage: usage(limit - 1));
      expect(under.outcome, DesktopAccess.allowed);
      expect(under.reason, DesktopAccessReason.allowedWithinFreeQuota);
      expect(under.capacity!.remaining, 1);

      final at = decide(context, usage: usage(limit));
      expect(at.outcome, DesktopAccess.quotaExceeded);
      expect(at.reason, exceeded);
      expect(at.capacity!.used, limit);
      expect(at.capacity!.limit, limit);

      final over = decide(context, usage: usage(limit + 1));
      expect(over.outcome, DesktopAccess.quotaExceeded);
      expect(over.capacity!.remaining, 0);

      final premiumOver = decide(context, sub: premium, usage: usage(limit + 1));
      expect(premiumOver.outcome, DesktopAccess.allowed);
    }

    test('favourite players (3)', () {
      expectLadder(
        const DesktopAccessContext(
          feature: DesktopFeature.favorites,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.playerProfile,
        ),
        (used) => DesktopUsage(favoritePlayers: used),
        3,
        DesktopAccessReason.quotaFavoritePlayers,
      );
    });

    test('cloud databases (3)', () {
      expectLadder(
        const DesktopAccessContext(
          feature: DesktopFeature.ownedDocument,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.ownedDocument,
        ),
        (used) => DesktopUsage(cloudDatabases: used),
        3,
        DesktopAccessReason.quotaCloudDatabases,
      );
    });

    test('cloud saved games (10)', () {
      expectLadder(
        saveGame,
        (used) => DesktopUsage(cloudSavedGames: used),
        10,
        DesktopAccessReason.quotaCloudSavedGames,
      );
    });

    test('bulk saves count every destination copy', () {
      // Two games into two databases is four copies.
      final fits = decide(
        saveGame.copyWith(additions: 3),
        usage: const DesktopUsage(cloudSavedGames: 7),
      );
      expect(fits.outcome, DesktopAccess.allowed);
      expect(fits.capacity!.requested, 3);

      final overflows = decide(
        saveGame.copyWith(additions: 4),
        usage: const DesktopUsage(cloudSavedGames: 7),
      );
      expect(overflows.outcome, DesktopAccess.quotaExceeded);
      expect(overflows.capacity!.requested, 4);
    });

    test('over the limit after a downgrade: read, edit, export, remove', () {
      const usage = DesktopUsage(cloudSavedGames: 14, favoritePlayers: 7);
      final edit = decide(saveGame.copyWith(additions: 0), usage: usage);
      expect(edit.outcome, DesktopAccess.allowed);
      expect(edit.reason, DesktopAccessReason.allowedNoNewSlot);

      for (final action in [
        DesktopAction.view,
        DesktopAction.openContent,
        DesktopAction.export,
        DesktopAction.copy,
        DesktopAction.share,
        DesktopAction.edit,
        DesktopAction.remove,
      ]) {
        expect(
          decide(saveGame.copyWith(action: action), usage: usage).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }

      final unfavourite = decide(
        const DesktopAccessContext(
          feature: DesktopFeature.favorites,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.favorites,
          additions: 0,
        ),
        usage: usage,
      );
      expect(unfavourite.outcome, DesktopAccess.allowed);
    });

    test('favourite events are unlimited', () {
      expect(
        decide(
          const DesktopAccessContext(
            feature: DesktopFeature.favorites,
            action: DesktopAction.create,
            origin: DesktopDiscoveryOrigin.broadcast,
            quota: DesktopQuota.none,
          ),
          usage: const DesktopUsage(favoritePlayers: 3),
        ).outcome,
        DesktopAccess.allowed,
      );
    });

    test('Likes are excluded from the saved-game and database quotas', () {
      const full = DesktopUsage(cloudSavedGames: 10, cloudDatabases: 3);
      for (final action in [
        DesktopAction.create,
        DesktopAction.tag,
        DesktopAction.remove,
        DesktopAction.edit,
      ]) {
        final decision = decide(
          DesktopAccessContext(
            feature: DesktopFeature.likes,
            action: action,
            origin: DesktopDiscoveryOrigin.likes,
            ownedDocument: true,
            retainedSaveId: 'like-1',
            contentDate: now,
            quota: DesktopQuota.cloudSavedGames,
          ),
          usage: full,
        );
        expect(decision.outcome, DesktopAccess.allowed, reason: action.name);
        expect(decision.capacity, isNull);
      }
    });

    test('moving a like into a regular database is charged as a save', () {
      final move = decide(
        DesktopAccessContext(
          feature: DesktopFeature.likes,
          action: DesktopAction.save,
          origin: DesktopDiscoveryOrigin.likes,
          contentDate: now,
        ),
        usage: const DesktopUsage(cloudSavedGames: 10),
      );
      expect(move.outcome, DesktopAccess.quotaExceeded);
      expect(move.reason, DesktopAccessReason.quotaCloudSavedGames);
    });

    test('folders are excluded from the database count', () {
      expect(
        decide(
          const DesktopAccessContext(
            feature: DesktopFeature.ownedDocument,
            action: DesktopAction.create,
            origin: DesktopDiscoveryOrigin.ownedDocument,
            quota: DesktopQuota.none,
          ),
          usage: const DesktopUsage(cloudDatabases: 3),
        ).outcome,
        DesktopAccess.allowed,
      );
    });

    test('followed shared books and TWIC are not owned databases', () {
      const full = DesktopUsage(cloudDatabases: 3);
      final follow = decide(
        const DesktopAccessContext(
          feature: DesktopFeature.sharedBook,
          action: DesktopAction.acquireSource,
          origin: DesktopDiscoveryOrigin.sharedBook,
        ),
        usage: full,
      );
      expect(follow.outcome, DesktopAccess.allowed);
      expect(follow.capacity, isNull);

      final twic = decide(
        const DesktopAccessContext(
          feature: DesktopFeature.twic,
          action: DesktopAction.view,
          origin: DesktopDiscoveryOrigin.twic,
        ),
        usage: full,
      );
      expect(twic.outcome, DesktopAccess.allowed);
      expect(twic.capacity, isNull);
    });

    test('game reports: one new fingerprint per UTC day', () {
      const report = DesktopAccessContext(
        feature: DesktopFeature.gameReport,
        action: DesktopAction.create,
        origin: DesktopDiscoveryOrigin.broadcast,
      );
      expect(
        decide(report, usage: const DesktopUsage(gameReportsOnUtcDay: 0))
            .outcome,
        DesktopAccess.allowed,
      );
      final spent = decide(
        report,
        usage: const DesktopUsage(gameReportsOnUtcDay: 1),
      );
      expect(spent.outcome, DesktopAccess.quotaExceeded);
      expect(spent.reason, DesktopAccessReason.quotaGameReportsPerUtcDay);

      final repeat = decide(
        report,
        usage: const DesktopUsage(
          gameReportsOnUtcDay: 1,
          existingReportForRequestedGame: true,
        ),
      );
      expect(repeat.outcome, DesktopAccess.allowed);
      expect(repeat.reason, DesktopAccessReason.allowedNoNewSlot);

      expect(
        decide(
          report,
          sub: premium,
          usage: const DesktopUsage(gameReportsOnUtcDay: 9),
        ).outcome,
        DesktopAccess.allowed,
      );
    });
  });

  group('ownership does not grant paid-source fetching', () {
    const ownedCopy = DesktopAccessContext(
      feature: DesktopFeature.ownedDocument,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.gamebase,
      ownedDocument: true,
      retainedSaveId: 'save-1',
    );

    test('the retained copy of a paid-source game is free to use', () {
      final opened = decide(ownedCopy);
      expect(opened.outcome, DesktopAccess.allowed);
      expect(opened.reason, DesktopAccessReason.allowedOwnedDocument);
      for (final action in [
        DesktopAction.view,
        DesktopAction.copy,
        DesktopAction.share,
        DesktopAction.export,
      ]) {
        expect(
          decide(ownedCopy.copyWith(action: action)).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
      expect(
        decide(
          ownedCopy.copyWith(action: DesktopAction.save, additions: 0),
        ).outcome,
        DesktopAccess.allowed,
      );
    });

    test('owning a copied document does not unlock the next paid game', () {
      for (final action in desktopSourceReachingActions) {
        final decision = decide(ownedCopy.copyWith(action: action));
        expect(
          decision.outcome,
          DesktopAccess.premiumRequired,
          reason: action.name,
        );
        expect(decision.reason, DesktopAccessReason.premiumPaidSource);
      }

      // The next game in the source is a fresh request with no retained row.
      final nextGame = decide(
        ownedCopy.copyWith(
          feature: DesktopFeature.gamebase,
          clearRetainedSaveId: true,
        ),
      );
      expect(nextGame.outcome, DesktopAccess.premiumRequired);

      // An ownership flag without the retained row it applies to is nothing.
      expect(
        decide(ownedCopy.copyWith(clearRetainedSaveId: true)).outcome,
        DesktopAccess.premiumRequired,
      );
      expect(
        decide(ownedCopy.copyWith(action: DesktopAction.fetchPgn), sub: premium)
            .outcome,
        DesktopAccess.allowed,
      );
    });
  });

  group('provenance decides, not game identity', () {
    const paidOrigins = [
      DesktopDiscoveryOrigin.countrymen,
      DesktopDiscoveryOrigin.smartCollection,
      DesktopDiscoveryOrigin.playerProfile,
    ];

    test('the same game is free through an ordinary broadcast', () {
      expect(decide(broadcastOpen).outcome, DesktopAccess.allowed);
      expect(
        decide(broadcastOpen.copyWith(action: DesktopAction.fetchPgn)).outcome,
        DesktopAccess.allowed,
      );
    });

    test('and gated through Countrymen, a smart collection or a profile', () {
      const surfaces = {
        DesktopDiscoveryOrigin.countrymen: DesktopFeature.countrymen,
        DesktopDiscoveryOrigin.smartCollection: DesktopFeature.smartCollection,
        DesktopDiscoveryOrigin.playerProfile: DesktopFeature.playerProfile,
      };
      for (final origin in paidOrigins) {
        final decision = decide(
          DesktopAccessContext(
            feature: surfaces[origin]!,
            action: DesktopAction.openContent,
            origin: origin,
          ),
        );
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: origin.name);
      }
    });

    test('a gated game carried onto an ordinary board stays gated', () {
      for (final origin in paidOrigins) {
        expect(
          decide(broadcastOpen.copyWith(origin: origin)).outcome,
          DesktopAccess.premiumRequired,
          reason: origin.name,
        );
      }
    });

    test('browsing a gated surface stays free, and members open it', () {
      for (final origin in paidOrigins) {
        final context = broadcastOpen.copyWith(origin: origin);
        expect(
          decide(context.copyWith(action: DesktopAction.view)).outcome,
          DesktopAccess.allowed,
        );
        expect(decide(context, sub: premium).outcome, DesktopAccess.allowed);
      }
    });
  });

  group('opening explorer', () {
    const stats = DesktopAccessContext(
      feature: DesktopFeature.openingExplorer,
      action: DesktopAction.fetchPgn,
      origin: DesktopDiscoveryOrigin.broadcast,
    );

    test('statistics are free through ply 20 inclusive', () {
      expect(decide(stats.copyWith(playedPlies: 19)).outcome,
          DesktopAccess.allowed);
      expect(decide(stats.copyWith(playedPlies: 20)).outcome,
          DesktopAccess.allowed);
      final deeper = decide(stats.copyWith(playedPlies: 21));
      expect(deeper.outcome, DesktopAccess.premiumRequired);
      expect(deeper.reason, DesktopAccessReason.premiumExplorerDepth);
    });

    test('interactive navigation goes through the ply check', () {
      final navigate = stats.copyWith(action: DesktopAction.previewNavigate);
      expect(decide(navigate.copyWith(playedPlies: 19)).outcome,
          DesktopAccess.allowed);
      expect(decide(navigate.copyWith(playedPlies: 20)).outcome,
          DesktopAccess.allowed);
      expect(decide(navigate.copyWith(playedPlies: 21)).reason,
          DesktopAccessReason.premiumExplorerDepth);
    });

    test('general filters are free; player scope and exact position are not',
        () {
      final general = decide(
        stats.copyWith(
          action: DesktopAction.filter,
          playedPlies: 10,
          filterCriteriaCount: 4,
        ),
      );
      expect(general.outcome, DesktopAccess.allowed);
      expect(
        decide(
          stats.copyWith(
            action: DesktopAction.filter,
            playedPlies: 25,
            filterCriteriaCount: 1,
          ),
        ).reason,
        DesktopAccessReason.premiumExplorerDepth,
      );

      final scoped = decide(stats.copyWith(playedPlies: 4, playerScoped: true));
      expect(scoped.outcome, DesktopAccess.premiumRequired);
      expect(scoped.reason, DesktopAccessReason.premiumExplorerPlayerScope);

      // Player-profile opening exploration is player-scoped explorer work.
      expect(
        decide(
          const DesktopAccessContext(
            feature: DesktopFeature.openingExplorer,
            action: DesktopAction.previewNavigate,
            origin: DesktopDiscoveryOrigin.playerProfile,
            playedPlies: 2,
            playerScoped: true,
          ),
        ).reason,
        DesktopAccessReason.premiumExplorerPlayerScope,
      );

      final exact = decide(
        stats.copyWith(playedPlies: 4, action: DesktopAction.acquireSource),
      );
      expect(exact.reason, DesktopAccessReason.premiumExplorerExactPosition);
    });

    test('rendering the panel never gates; unknown depth is Retry', () {
      expect(
        decide(stats.copyWith(action: DesktopAction.view, playedPlies: 60))
            .outcome,
        DesktopAccess.allowed,
      );
      final unknownDepth = decide(stats);
      expect(unknownDepth.outcome, DesktopAccess.temporarilyUnavailable);
      expect(unknownDepth.reason, DesktopAccessReason.explorerDepthUnknown);
      expect(decide(stats, sub: premium).outcome, DesktopAccess.allowed);
    });

    test('personal board and FEN editing is free', () {
      expect(
        decide(
          const DesktopAccessContext(
            feature: DesktopFeature.localFiles,
            action: DesktopAction.insertMove,
            origin: DesktopDiscoveryOrigin.localFile,
            playedPlies: 80,
          ),
        ).outcome,
        DesktopAccess.allowed,
      );
    });
  });

  group('Prepare and player profiles', () {
    const prepare = DesktopAccessContext(
      feature: DesktopFeature.prepare,
      action: DesktopAction.view,
      origin: DesktopDiscoveryOrigin.playerProfile,
    );

    test('Prepare is not a blanket paywall: retained work stays free', () {
      for (final action in [
        DesktopAction.view,
        DesktopAction.openContent,
        DesktopAction.previewNavigate,
        DesktopAction.sort,
        DesktopAction.filter,
        DesktopAction.edit,
        DesktopAction.export,
        DesktopAction.copy,
        DesktopAction.remove,
        DesktopAction.cancel,
        DesktopAction.tag,
      ]) {
        expect(
          decide(prepare.copyWith(action: action)).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
    });

    test('Prepare targets, sources and computed analysis are Premium', () {
      const premiumActions = {
        DesktopAction.create: DesktopAccessReason.premiumPrepareTarget,
        DesktopAction.acquireSource: DesktopAccessReason.premiumPrepareSource,
        DesktopAction.fetchPgn: DesktopAccessReason.premiumPrepareSource,
        DesktopAction.recompute: DesktopAccessReason.premiumPrepareComputed,
      };
      premiumActions.forEach((action, reason) {
        final decision = decide(prepare.copyWith(action: action));
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: action.name);
        expect(decision.reason, reason);
        expect(
          decide(prepare.copyWith(action: action), sub: premium).outcome,
          DesktopAccess.allowed,
        );
        expect(
          decide(prepare.copyWith(action: action), sub: unknown).outcome,
          DesktopAccess.temporarilyUnavailable,
        );
      });
    });

    test('profiles: one criterion free, two combined Premium, bulk Premium',
        () {
      const profile = DesktopAccessContext(
        feature: DesktopFeature.playerProfile,
        action: DesktopAction.filter,
        origin: DesktopDiscoveryOrigin.playerProfile,
      );
      expect(decide(profile.copyWith(filterCriteriaCount: 1)).outcome,
          DesktopAccess.allowed);
      expect(
        decide(profile.copyWith(filterCriteriaCount: 2)).reason,
        DesktopAccessReason.premiumProfileFilterCombination,
      );
      expect(
        decide(profile.copyWith(action: DesktopAction.bulkSelect)).reason,
        DesktopAccessReason.premiumProfileBulkOperation,
      );
      expect(decide(profile.copyWith(action: DesktopAction.sort)).outcome,
          DesktopAccess.allowed);
    });
  });

  group('likes window', () {
    const like = DesktopAccessContext(
      feature: DesktopFeature.likes,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.likes,
    );

    test('day 6 free, day 7 Premium, members unrestricted', () {
      expect(
        decide(like.copyWith(contentDate: DateTime(2026, 9, 4, 9))).outcome,
        DesktopAccess.allowed,
      );
      final old = like.copyWith(contentDate: DateTime(2026, 9, 3, 23, 59));
      expect(decide(old).reason, DesktopAccessReason.premiumLikesOutsideWindow);
      expect(decide(old, sub: premium).outcome, DesktopAccess.allowed);
    });

    test('an unknown like date is Retry for free users, fine for members', () {
      expect(decide(like).reason, DesktopAccessReason.contentDateUnknown);
      expect(decide(like, sub: premium).outcome, DesktopAccess.allowed);
      expect(
        decide(like.copyWith(action: DesktopAction.view)).outcome,
        DesktopAccess.allowed,
      );
    });
  });

  group('offline verification grace', () {
    DesktopEntitlementSnapshot graced({
      String account = 'acct-a',
      Duration age = const Duration(days: 13),
      DateTime? expiry,
      bool wasActive = true,
      bool billingGrace = false,
    }) => member.copyWith(
      offline: DesktopOfflineVerification(
        accountId: account,
        verifiedAt: now.subtract(age),
        wasActive: wasActive,
        knownExpiry: expiry ?? now.add(const Duration(days: 5)),
        inBillingGracePeriod: billingGrace,
      ),
    );

    test('a verified member keeps Premium within 14 days offline', () {
      final decision = decide(gamebaseOpen, sub: unknown, entitlement: graced());
      expect(decision.outcome, DesktopAccess.allowed);
      expect(decision.reason, DesktopAccessReason.allowedOfflineGrace);
    });

    test('bound to the same account', () {
      expect(
        decide(
          gamebaseOpen,
          sub: unknown,
          entitlement: graced().copyWith(accountId: 'acct-b'),
        ).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
      expect(
        decide(
          gamebaseOpen,
          sub: unknown,
          entitlement: graced().copyWith(clearAccountId: true),
        ).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
    });

    test('bounded by 14 days and by the known expiry', () {
      expect(
        decide(
          gamebaseOpen,
          sub: unknown,
          entitlement: graced(age: const Duration(days: 15)),
        ).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
      expect(
        decide(
          gamebaseOpen,
          sub: unknown,
          entitlement: graced(expiry: now.subtract(const Duration(minutes: 1))),
        ).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
      expect(
        decide(
          gamebaseOpen,
          sub: unknown,
          entitlement: graced(
            expiry: now.subtract(const Duration(days: 2)),
            billingGrace: true,
          ),
        ).outcome,
        DesktopAccess.allowed,
      );
    });

    test('an authoritative inactive result overrides the grace', () {
      expect(
        decide(gamebaseOpen, sub: unknown, entitlement: graced(wasActive: false))
            .outcome,
        DesktopAccess.temporarilyUnavailable,
      );
      expect(
        decide(gamebaseOpen, sub: free, entitlement: graced()).outcome,
        DesktopAccess.premiumRequired,
      );
    });

    test('personal documents need no verification at all', () {
      for (final context in [
        const DesktopAccessContext(
          feature: DesktopFeature.localFiles,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.localFile,
        ),
        const DesktopAccessContext(
          feature: DesktopFeature.ownedDocument,
          action: DesktopAction.export,
          origin: DesktopDiscoveryOrigin.ownedDocument,
          ownedDocument: true,
          retainedSaveId: 'save-9',
        ),
      ]) {
        expect(
          decide(context, sub: unknown, entitlement: guest).outcome,
          DesktopAccess.allowed,
        );
      }
    });
  });

  group('stale contexts', () {
    final stamped = member.stamp(gamebaseOpen);

    test('stamping captures account and generation', () {
      expect(stamped.accountId, 'acct-a');
      expect(stamped.entitlementGeneration, 1);
      expect(guest.stamp(gamebaseOpen).accountId, isNull);
    });

    test('a response evaluated after logout is rejected', () {
      final afterLogout = decide(
        stamped,
        sub: premium,
        entitlement: const DesktopEntitlementSnapshot(generation: 2),
      );
      expect(afterLogout.isStale, isTrue);
      expect(afterLogout.outcome, DesktopAccess.temporarilyUnavailable);
      expect(afterLogout.mayOfferPurchase, isFalse);
    });

    test('an account switch or newer generation is rejected', () {
      for (final later in const [
        DesktopEntitlementSnapshot(accountId: 'acct-b', generation: 2),
        DesktopEntitlementSnapshot(accountId: 'acct-a', generation: 2),
      ]) {
        expect(
          decide(stamped, sub: premium, entitlement: later).isStale,
          isTrue,
        );
      }
      expect(decide(stamped, sub: premium).outcome, DesktopAccess.allowed);
    });

    test('an unstamped context is never considered stale', () {
      expect(
        decide(gamebaseOpen, entitlement: const DesktopEntitlementSnapshot(
          accountId: 'acct-z',
          generation: 9,
        )).isStale,
        isFalse,
      );
    });
  });

  group('locked content actions', () {
    test('interactive preview navigation is gated on every paid origin', () {
      for (final origin in const [
        DesktopDiscoveryOrigin.gamebase,
        DesktopDiscoveryOrigin.twic,
        DesktopDiscoveryOrigin.countrymen,
        DesktopDiscoveryOrigin.smartCollection,
        DesktopDiscoveryOrigin.playerProfile,
      ]) {
        final navigate = decide(
          broadcastOpen.copyWith(
            action: DesktopAction.previewNavigate,
            origin: origin,
          ),
        );
        expect(navigate.outcome, DesktopAccess.premiumRequired,
            reason: origin.name);
        expect(
          decide(
            broadcastOpen.copyWith(action: DesktopAction.view, origin: origin),
          ).outcome,
          DesktopAccess.allowed,
          reason: '${origin.name} static preview',
        );
      }
      expect(
        decide(gamebaseOpen.copyWith(action: DesktopAction.previewNavigate))
            .outcome,
        DesktopAccess.premiumRequired,
      );
      expect(
        decide(broadcastOpen.copyWith(action: DesktopAction.previewNavigate))
            .outcome,
        DesktopAccess.allowed,
      );
    });

    test('remove, cancel and tag are never gated anywhere', () {
      for (final context in everyRequest(plies: 90, filters: 5)) {
        if (!desktopNeverGatedActions.contains(context.action)) continue;
        for (final sub in [free, unknown, checking]) {
          final decision = decide(
            context.copyWith(
              ownedDocument: true,
              retainedSaveId: 'row',
              contentDate: now.subtract(const Duration(days: 400)),
            ),
            sub: sub,
            entitlement: guest,
          );
          expect(decision.outcome, DesktopAccess.allowed, reason: '$context');
          expect(decision.reason, DesktopAccessReason.allowedDataStewardship);
        }
      }
    });
  });

  group('engine tournaments', () {
    const tournament = DesktopAccessContext(
      feature: DesktopFeature.engineTournament,
      action: DesktopAction.view,
      origin: DesktopDiscoveryOrigin.ownedDocument,
    );

    test('create, restart and resume are Premium', () {
      for (final action in [DesktopAction.create, DesktopAction.recompute]) {
        final decision = decide(tournament.copyWith(action: action));
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: action.name);
        expect(decision.reason, DesktopAccessReason.premiumEngineTournament);
      }
    });

    test('viewing and exporting results and stopping a run are free', () {
      for (final action in [
        DesktopAction.view,
        DesktopAction.openContent,
        DesktopAction.export,
        DesktopAction.cancel,
      ]) {
        expect(
          decide(tournament.copyWith(action: action)).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
    });
  });

  group('opening trees', () {
    const tree = DesktopAccessContext(
      feature: DesktopFeature.openingTree,
      action: DesktopAction.view,
      origin: DesktopDiscoveryOrigin.localFile,
      ownedDocument: true,
      retainedSaveId: 'tree-1',
    );

    test('build and rebuild are Premium, even for an owned local tree', () {
      final build = decide(tree.copyWith(action: DesktopAction.recompute));
      expect(build.outcome, DesktopAccess.premiumRequired);
      expect(build.reason, DesktopAccessReason.premiumOpeningTreeBuild);
    });

    test('interactive exploration is Premium', () {
      for (final action in [
        DesktopAction.previewNavigate,
        DesktopAction.openContent,
      ]) {
        final decision = decide(tree.copyWith(action: action));
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: action.name);
        expect(decision.reason, DesktopAccessReason.premiumOpeningTreeExplore);
      }
    });

    test('files and existing work stay free', () {
      for (final action in [
        DesktopAction.view,
        DesktopAction.remove,
        DesktopAction.export,
      ]) {
        expect(
          decide(tree.copyWith(action: action)).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
    });
  });

  group('miniatures', () {
    const miniature = DesktopAccessContext(
      feature: DesktopFeature.miniatures,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.miniatures,
    );

    test('content is free only when the game is dated today', () {
      expect(
        decide(miniature.copyWith(contentDate: DateTime.utc(2026, 9, 10)))
            .outcome,
        DesktopAccess.allowed,
      );
      for (final date in [
        DateTime.utc(2026, 9, 9),
        DateTime.utc(2026, 9, 11),
      ]) {
        final decision = decide(miniature.copyWith(contentDate: date));
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: '$date');
        expect(decision.reason, DesktopAccessReason.premiumMiniatureNotToday);
      }
    });

    test('an undated miniature is Premium, not Retry', () {
      final undated = decide(miniature);
      expect(undated.outcome, DesktopAccess.premiumRequired);
      expect(undated.reason, DesktopAccessReason.premiumMiniatureNotToday);
      // An unknown entitlement still never shows a purchase prompt.
      expect(
        decide(miniature, sub: unknown).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
      expect(decide(miniature, sub: premium).outcome, DesktopAccess.allowed);
    });

    test('browsing, sorting and filtering metadata is free', () {
      for (final action in [
        DesktopAction.view,
        DesktopAction.sort,
        DesktopAction.filter,
      ]) {
        expect(
          decide(miniature.copyWith(action: action)).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
    });

    test('preview navigation on an old miniature is gated, also on a board',
        () {
      final old = miniature.copyWith(
        action: DesktopAction.previewNavigate,
        contentDate: DateTime.utc(2026, 8, 1),
      );
      expect(decide(old).outcome, DesktopAccess.premiumRequired);
      expect(
        decide(old.copyWith(feature: DesktopFeature.broadcast)).reason,
        DesktopAccessReason.premiumMiniatureNotToday,
      );
    });
  });

  group('structured filters and sorts', () {
    const ownedDatabase = DesktopAccessContext(
      feature: DesktopFeature.ownedDocument,
      action: DesktopAction.filter,
      origin: DesktopDiscoveryOrigin.ownedDocument,
      ownedDocument: true,
      retainedSaveId: 'db-1',
    );

    test('owned cloud databases gate structured filters and sorts', () {
      final filtered = decide(ownedDatabase.copyWith(filterCriteriaCount: 1));
      expect(filtered.outcome, DesktopAccess.premiumRequired);
      expect(filtered.reason, DesktopAccessReason.premiumStructuredFilter);

      final sorted = decide(ownedDatabase.copyWith(action: DesktopAction.sort));
      expect(sorted.outcome, DesktopAccess.premiumRequired);
      expect(sorted.reason, DesktopAccessReason.premiumStructuredSort);

      expect(
        decide(ownedDatabase.copyWith(filterCriteriaCount: 1), sub: premium)
            .outcome,
        DesktopAccess.allowed,
      );
    });

    test('text search (no structured criteria) and tags stay free', () {
      expect(decide(ownedDatabase).outcome, DesktopAccess.allowed);
      expect(
        decide(ownedDatabase.copyWith(action: DesktopAction.tag)).outcome,
        DesktopAccess.allowed,
      );
    });

    test('shared books follow the same filter and sort rules', () {
      const book = DesktopAccessContext(
        feature: DesktopFeature.sharedBook,
        action: DesktopAction.filter,
        origin: DesktopDiscoveryOrigin.sharedBook,
      );
      expect(decide(book).outcome, DesktopAccess.allowed);
      expect(
        decide(book.copyWith(filterCriteriaCount: 2)).reason,
        DesktopAccessReason.premiumStructuredFilter,
      );
      expect(
        decide(book.copyWith(action: DesktopAction.sort)).reason,
        DesktopAccessReason.premiumStructuredSort,
      );
    });

    test('local files: single-key sort free, multi-key and filters gated', () {
      const local = DesktopAccessContext(
        feature: DesktopFeature.localFiles,
        action: DesktopAction.sort,
        origin: DesktopDiscoveryOrigin.localFile,
        ownedDocument: true,
        retainedSaveId: 'file.pgn',
      );
      expect(decide(local.copyWith(sortKeyCount: 1)).outcome,
          DesktopAccess.allowed);
      expect(
        decide(local.copyWith(sortKeyCount: 2)).reason,
        DesktopAccessReason.premiumMultiKeySort,
      );
      expect(
        decide(local.copyWith(action: DesktopAction.filter)).outcome,
        DesktopAccess.allowed,
      );
      expect(
        decide(
          local.copyWith(action: DesktopAction.filter, filterCriteriaCount: 1),
        ).reason,
        DesktopAccessReason.premiumStructuredFilter,
      );
      expect(
        decide(local.copyWith(action: DesktopAction.acquireSource)).reason,
        DesktopAccessReason.premiumLocalPositionQuery,
      );
    });

    test('local files have no capacity limits', () {
      for (final action in [
        DesktopAction.save,
        DesktopAction.create,
        DesktopAction.edit,
        DesktopAction.insertMove,
        DesktopAction.openContent,
      ]) {
        final decision = decide(
          DesktopAccessContext(
            feature: DesktopFeature.localFiles,
            action: action,
            origin: DesktopDiscoveryOrigin.localFile,
            additions: 500,
          ),
        );
        expect(decision.outcome, DesktopAccess.allowed, reason: action.name);
        expect(decision.capacity, isNull);
      }
    });
  });

  group('likes are decided by the window, not by owning the row', () {
    final oldLike = DesktopAccessContext(
      feature: DesktopFeature.likes,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.likes,
      ownedDocument: true,
      retainedSaveId: 'like-7',
      contentDate: DateTime(2026, 8, 1),
    );

    test('an owned like row outside the window is still gated', () {
      for (final action in [
        DesktopAction.openContent,
        DesktopAction.previewNavigate,
        DesktopAction.fetchPgn,
        DesktopAction.insertMove,
        DesktopAction.edit,
        DesktopAction.copy,
        DesktopAction.share,
        DesktopAction.export,
        DesktopAction.save,
      ]) {
        final decision = decide(oldLike.copyWith(action: action));
        expect(decision.outcome, DesktopAccess.premiumRequired,
            reason: action.name);
        expect(decision.reason, DesktopAccessReason.premiumLikesOutsideWindow);
      }
    });

    test('tag, remove, sort, filter and view of an old like are free', () {
      for (final action in [
        DesktopAction.tag,
        DesktopAction.remove,
        DesktopAction.sort,
        DesktopAction.filter,
        DesktopAction.view,
      ]) {
        expect(
          decide(
            oldLike.copyWith(
              action: action,
              filterCriteriaCount: 3,
              sortKeyCount: 3,
            ),
          ).outcome,
          DesktopAccess.allowed,
          reason: action.name,
        );
      }
    });

    test('a liked game opened on a board keeps the Likes window', () {
      expect(
        decide(oldLike.copyWith(feature: DesktopFeature.broadcast)).reason,
        DesktopAccessReason.premiumLikesOutsideWindow,
      );
    });
  });
}
