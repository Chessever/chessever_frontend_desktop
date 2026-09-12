import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/library_utils.dart';

void main() {
  final now = DateTime(2026, 9, 10, 12);

  group('free tier constants', () {
    test('match the caps shared with mobile so limits follow the user', () {
      expect(desktopFreeFavoritePlayers, kFreeFavoriteLimit);
      expect(desktopFreeCloudDatabases, kFreeBookCreationLimit);
      expect(desktopFreeCloudSavedGames, kFreeSavedGamesLimit);
      expect(
        desktopOfflineVerificationGrace,
        DesktopOfflineAccessCache.defaultGracePeriod,
      );
    });

    test('pin the spec values', () {
      expect(desktopFreeFavoritePlayers, 3);
      expect(desktopFreeCloudDatabases, 3);
      expect(desktopFreeCloudSavedGames, 10);
      expect(desktopFreeExplorerPlies, 20);
      expect(desktopFreeGameReportsPerUtcDay, 1);
      expect(desktopFreeLikesWindowDays, 7);
      expect(desktopOfflineVerificationGrace, const Duration(days: 14));
    });
  });

  group('explorer boundary', () {
    // Regression for the off-by-one in the earlier attempt, which allowed
    // only 19 plies (`playedPlies + 1 <= 20`). 20 played plies is Black's
    // 10th move and is free; ply 21 is Premium.
    test('plies 19 and 20 are free, 21 is Premium', () {
      expect(desktopExplorerPositionIsFree(19), isTrue);
      expect(desktopExplorerPositionIsFree(20), isTrue);
      expect(desktopExplorerPositionIsFree(21), isFalse);
    });

    test('start position is free and negative plies are rejected', () {
      expect(desktopExplorerPositionIsFree(0), isTrue);
      expect(desktopExplorerPositionIsFree(-1), isFalse);
    });

    test('composition: filters and exact position are Premium', () {
      const free = DesktopAccess.premiumRequired;
      expect(
        desktopExplorerAccess(free, playedPlies: 20),
        DesktopAccess.allowed,
      );
      expect(
        desktopExplorerAccess(free, playedPlies: 21),
        DesktopAccess.premiumRequired,
      );
      expect(
        desktopExplorerAccess(free, playedPlies: 4, playerFilters: true),
        DesktopAccess.premiumRequired,
      );
      expect(
        desktopExplorerAccess(free, playedPlies: 4, remoteExactPosition: true),
        DesktopAccess.premiumRequired,
      );
      expect(
        desktopExplorerAccess(free, playedPlies: 60, personalPosition: true),
        DesktopAccess.allowed,
      );
      expect(
        desktopExplorerAccess(DesktopAccess.allowed, playedPlies: 60),
        DesktopAccess.allowed,
      );
    });

    test('a free position is not blocked by a loading or failed lookup', () {
      expect(
        desktopExplorerAccess(DesktopAccess.checking, playedPlies: 10),
        DesktopAccess.allowed,
      );
      expect(
        desktopExplorerAccess(
          DesktopAccess.temporarilyUnavailable,
          playedPlies: 10,
        ),
        DesktopAccess.allowed,
      );
      expect(
        desktopExplorerAccess(
          DesktopAccess.temporarilyUnavailable,
          playedPlies: 21,
        ),
        DesktopAccess.temporarilyUnavailable,
      );
    });
  });

  group('quota fit', () {
    test('limit - 1, limit, limit + 1', () {
      expect(desktopQuotaFits(9, 1, 10), isTrue);
      expect(desktopQuotaFits(10, 1, 10), isFalse);
      expect(desktopQuotaFits(11, 1, 10), isFalse);
    });

    test('bulk additions count every copy', () {
      expect(desktopQuotaFits(7, 3, 10), isTrue);
      expect(desktopQuotaFits(7, 4, 10), isFalse);
    });

    test('zero additions always fit, even over the limit after downgrade', () {
      expect(desktopQuotaFits(14, 0, 10), isTrue);
      expect(desktopQuotaFits(0, 0, 10), isTrue);
    });

    test('negative input never fits', () {
      expect(desktopQuotaFits(-1, 1, 10), isFalse);
      expect(desktopQuotaFits(1, -1, 10), isFalse);
    });
  });

  group('raw premium signal', () {
    test('loading is checking, never premium or upsell', () {
      expect(
        desktopPremiumAccess(SubscriptionState(isLoading: true), now: now),
        DesktopAccess.checking,
      );
    });

    test('an error is temporarily unavailable, never premiumRequired', () {
      expect(
        desktopPremiumAccess(SubscriptionState(error: 'timeout'), now: now),
        DesktopAccess.temporarilyUnavailable,
      );
      expect(
        desktopPremiumAccess(
          SubscriptionState(isSubscribed: true, error: 'offline'),
          now: now,
        ),
        DesktopAccess.temporarilyUnavailable,
      );
    });

    test('known free is premiumRequired', () {
      expect(
        desktopPremiumAccess(SubscriptionState(), now: now),
        DesktopAccess.premiumRequired,
      );
    });

    test('trial and active purchase are allowed', () {
      expect(
        desktopPremiumAccess(
          SubscriptionState(
            isSubscribed: true,
            expirationDate: now.add(const Duration(days: 3)),
          ),
          now: now,
        ),
        DesktopAccess.allowed,
      );
      expect(
        desktopPremiumAccess(SubscriptionState(isSubscribed: true), now: now),
        DesktopAccess.allowed,
      );
    });

    test('cancelled stays Premium through expiry; the boundary is exclusive',
        () {
      final cancelled = SubscriptionState(
        isSubscribed: true,
        willRenew: false,
        expirationDate: now.add(const Duration(seconds: 1)),
      );
      expect(desktopPremiumAccess(cancelled, now: now), DesktopAccess.allowed);
      expect(
        desktopPremiumAccess(
          SubscriptionState(isSubscribed: true, expirationDate: now),
          now: now,
        ),
        DesktopAccess.premiumRequired,
      );
    });

    test('billing grace outlives the term timestamp', () {
      expect(
        desktopPremiumAccess(
          SubscriptionState(
            isSubscribed: true,
            inBillingGracePeriod: true,
            expirationDate: now.subtract(const Duration(days: 2)),
          ),
          now: now,
        ),
        DesktopAccess.allowed,
      );
    });

    test('admitted work continues through a routine refresh only', () {
      expect(
        desktopCanContinuePremiumWork(
          SubscriptionState(
            isSubscribed: true,
            isLoading: true,
            expirationDate: now.add(const Duration(days: 1)),
          ),
          now: now,
        ),
        isTrue,
      );
      expect(
        desktopCanContinuePremiumWork(
          SubscriptionState(isSubscribed: true, error: 'offline'),
          now: now,
        ),
        isFalse,
      );
      expect(
        desktopCanContinuePremiumWork(
          SubscriptionState(isSubscribed: true, expirationDate: now),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('likes window uses local calendar days', () {
    test('day 6 is free, day 7 is Premium', () {
      final today = DateTime(2026, 5, 20, 15);
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 5, 14, 9), now: today),
        isTrue,
      );
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 5, 13, 23, 59), now: today),
        isFalse,
      );
      expect(desktopLikeIsInFreeWindow(today, now: today), isTrue);
    });

    test('rolls over at local midnight, not at a 24 hour mark', () {
      final liked = DateTime(2026, 5, 13, 0, 0);
      expect(
        desktopLikeIsInFreeWindow(liked, now: DateTime(2026, 5, 19, 23, 59)),
        isTrue,
      );
      expect(
        desktopLikeIsInFreeWindow(liked, now: DateTime(2026, 5, 20, 0, 0)),
        isFalse,
      );
      // Minutes before midnight six days ago is still inside after midnight.
      expect(
        desktopLikeIsInFreeWindow(
          DateTime(2026, 5, 14, 23, 50),
          now: DateTime(2026, 5, 20, 0, 10),
        ),
        isTrue,
      );
    });

    test('is not 168 hours', () {
      // 166 elapsed hours, but seven calendar days back: Premium.
      final now = DateTime(2026, 5, 20, 8);
      final liked = DateTime(2026, 5, 13, 10);
      expect(now.difference(liked) < const Duration(hours: 168), isTrue);
      expect(desktopLikeIsInFreeWindow(liked, now: now), isFalse);
    });

    // Run this file with `TZ=America/New_York flutter test --no-pub
    // test/desktop/desktop_access_policy_test.dart` to exercise a real DST
    // transition. The assertions hold in any zone; only a DST zone makes the
    // naive-Duration comparison below diverge, and the test checks that it
    // does whenever the zone actually shifts.
    test('across the US DST end the window still starts at local midnight',
        () {
      // 2026-11-01 02:00 EDT -> 01:00 EST: that local day is 25 hours long.
      final now = DateTime(2026, 11, 7, 12);
      final start = desktopFreeLikesWindowStart(now);
      expect(start, DateTime(2026, 11, 1));
      expect(start.hour, 0);

      // A like at 00:30 on the first day of the window is inside it.
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 11, 1, 0, 30), now: now),
        isTrue,
      );
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 10, 31, 23, 30), now: now),
        isFalse,
      );

      final zoneShifts =
          DateTime(2026, 11, 1).timeZoneOffset !=
          DateTime(2026, 11, 2).timeZoneOffset;
      final naive = DateTime(2026, 11, 7).subtract(const Duration(days: 6));
      if (zoneShifts) {
        // Elapsed-time subtraction lands at 01:00 and would drop the 00:30
        // like; calendar arithmetic does not.
        expect(naive.hour, isNot(0));
        expect(naive.isAfter(DateTime(2026, 11, 1, 0, 30)), isTrue);
      } else {
        expect(naive, start);
      }
    });

    test('across the US DST start the window still starts at local midnight',
        () {
      // 2026-03-08 02:00 EST -> 03:00 EDT: that local day is 23 hours long.
      final now = DateTime(2026, 3, 14, 0, 30);
      final start = desktopFreeLikesWindowStart(now);
      expect(start, DateTime(2026, 3, 8));
      expect(start.hour, 0);
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 3, 7, 23, 30), now: now),
        isFalse,
      );
      expect(
        desktopLikeIsInFreeWindow(DateTime(2026, 3, 8, 0, 5), now: now),
        isTrue,
      );
      final zoneShifts =
          DateTime(2026, 3, 8).timeZoneOffset !=
          DateTime(2026, 3, 9).timeZoneOffset;
      if (zoneShifts) {
        final naive = DateTime(2026, 3, 14).subtract(const Duration(days: 6));
        expect(naive.hour, isNot(0));
      }
    });

    test('a future-dated like from clock skew is not charged', () {
      expect(
        desktopLikeIsInFreeWindow(
          DateTime(2026, 5, 21, 1),
          now: DateTime(2026, 5, 20, 23),
        ),
        isTrue,
      );
    });
  });

  group('miniatures are free only when dated today', () {
    final now = DateTime(2026, 11, 10, 15);

    test('today free; yesterday, tomorrow and undated gated', () {
      expect(
        desktopMiniatureIsInFreeWindow(DateTime.utc(2026, 11, 10), now: now),
        isTrue,
      );
      expect(
        desktopMiniatureIsInFreeWindow(DateTime.utc(2026, 11, 9), now: now),
        isFalse,
      );
      // Mobile accepts future dates; desktop gates them.
      expect(
        desktopMiniatureIsInFreeWindow(DateTime.utc(2026, 11, 11), now: now),
        isFalse,
      );
      expect(desktopMiniatureIsInFreeWindow(null, now: now), isFalse);
    });

    test('mixed frame: UTC game day against LOCAL today, near local midnight',
        () {
      // Local 23:30 on Nov 10. In America/New_York that instant is already
      // 04:30Z on Nov 11, yet "today" is still the local Nov 10.
      final lateNight = DateTime(2026, 11, 10, 23, 30);
      expect(
        desktopMiniatureIsInFreeWindow(
          DateTime.utc(2026, 11, 10, 23),
          now: lateNight,
        ),
        isTrue,
      );
      expect(
        desktopMiniatureIsInFreeWindow(
          DateTime.utc(2026, 11, 11, 0, 30),
          now: lateNight,
        ),
        isFalse,
      );

      // A game stored as a LOCAL 22:00 timestamp is judged by its UTC day,
      // which west of UTC is already tomorrow (gated) and east of UTC is
      // still today (free).
      final localEvening = DateTime(2026, 11, 10, 22);
      final utcDay = localEvening.toUtc().day;
      expect(
        desktopMiniatureIsInFreeWindow(localEvening, now: lateNight),
        utcDay == 10,
      );
      if (localEvening.timeZoneOffset == const Duration(hours: -5)) {
        expect(
          desktopMiniatureIsInFreeWindow(localEvening, now: lateNight),
          isFalse,
        );
      }
    });
  });
}
