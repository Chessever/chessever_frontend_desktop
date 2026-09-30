import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/miniature_game_open.dart';
import 'package:chessever/desktop/services/miniatures_access.dart';
import 'package:chessever/repository/gamebase/miniatures/miniatures_order.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

GamesTourModel _game(
  String id,
  DateTime? date, {
  int white = 0,
  int black = 0,
}) => GamesTourModel(
  gameId: id,
  source: GameSource.gamebase,
  whitePlayer: PlayerCard(
    name: 'White $id',
    federation: '',
    title: '',
    rating: white,
    countryCode: '',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Black $id',
    federation: '',
    title: '',
    rating: black,
    countryCode: '',
    team: null,
  ),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.whiteWins,
  roundId: 'gamebase-miniatures',
  tourId: '',
  lastMoveTime: date,
);

final _free = SubscriptionState();
const _guest = DesktopEntitlementSnapshot.guest;

DesktopAccess _open(
  GamesTourModel game,
  DateTime now, {
  SubscriptionState? subscription,
  DesktopAction action = DesktopAction.openContent,
}) =>
    miniatureGameDecision(
      game,
      action,
      subscription: subscription ?? _free,
      entitlement: _guest,
      now: now,
    ).outcome;

void main() {
  final now = DateTime(2026, 9, 12, 14, 0);

  group('Miniatures today-only rule', () {
    test('today is free; yesterday, future and undated are Premium', () {
      expect(
        _open(_game('t', DateTime.utc(2026, 9, 12)), now),
        DesktopAccess.allowed,
      );
      expect(
        _open(_game('y', DateTime.utc(2026, 9, 11)), now),
        DesktopAccess.premiumRequired,
      );
      // Mobile lets a future date through; the desktop spec gates it.
      expect(
        _open(_game('f', DateTime.utc(2026, 9, 13)), now),
        DesktopAccess.premiumRequired,
      );
      // Undated is Premium, not Retry.
      expect(_open(_game('u', null), now), DesktopAccess.premiumRequired);
    });

    test('game day is UTC while today is local (deliberate mixed frame)', () {
      final justAfterLocalMidnight = DateTime(2026, 9, 12, 0, 5);
      // Stored at UTC midnight of the 12th: today, in every timezone.
      expect(
        _open(_game('a', DateTime.utc(2026, 9, 12)), justAfterLocalMidnight),
        DesktopAccess.allowed,
      );
      // 23:30 UTC on the 11th is already the 12th east of Greenwich, but the
      // game's day is its UTC day, so it stays locked everywhere.
      expect(
        _open(
          _game('b', DateTime.utc(2026, 9, 11, 23, 30)),
          justAfterLocalMidnight,
        ),
        DesktopAccess.premiumRequired,
      );
    });

    test('browsing metadata is free; members open everything', () {
      final old = _game('o', DateTime.utc(2020, 1, 1));
      expect(
        _open(old, now, action: DesktopAction.view),
        DesktopAccess.allowed,
      );
      expect(
        _open(old, now, action: DesktopAction.sort),
        DesktopAccess.allowed,
      );
      expect(
        _open(old, now, subscription: SubscriptionState(isSubscribed: true)),
        DesktopAccess.allowed,
      );
    });

    test('a loading membership is not drawn locked but is not openable', () {
      final old = _game('o', DateTime.utc(2026, 9, 1));
      final loading = SubscriptionState(isLoading: true);
      expect(
        miniatureGameIsLockedAtRest(
          old,
          subscription: loading,
          entitlement: _guest,
          now: now,
        ),
        isFalse,
      );
      expect(
        openableMiniatureGames(
          [old],
          subscription: loading,
          entitlement: _guest,
          now: now,
        ),
        isEmpty,
      );
    });

    test('locked games are excluded from the board game list', () {
      final games = [
        _game('t1', DateTime.utc(2026, 9, 12)),
        _game('y', DateTime.utc(2026, 9, 11)),
        _game('t2', DateTime.utc(2026, 9, 12)),
      ];
      expect(
        openableMiniatureGames(
          games,
          subscription: _free,
          entitlement: _guest,
          now: now,
        ).map((g) => g.gameId),
        ['t1', 't2'],
      );
    });
  });

  group('day sections agree with the rule', () {
    test('a Today section is openable, a Yesterday section is locked', () {
      final groups = buildMiniatureDayGroups([
        _game('a', DateTime.utc(2026, 9, 12)),
        _game('b', DateTime.utc(2026, 9, 11)),
        _game('c', null),
        _game('d', DateTime.utc(2026, 9, 13)),
      ], now: now);
      expect(groups.map((g) => g.key), [
        '2026-09-13',
        '2026-09-12',
        '2026-09-11',
        kMiniatureUnknownDateKey,
      ]);
      for (final group in groups) {
        for (final game in group.games) {
          final locked = miniatureGameIsLockedAtRest(
            game,
            subscription: _free,
            entitlement: _guest,
            now: now,
          );
          expect(locked, group.label != 'Today', reason: group.label);
        }
      }
      expect(groups.last.label, 'Unknown date');
    });

    test('Yesterday stays Yesterday across a daylight-saving change', () {
      final afterDst = DateTime(2026, 3, 9, 0, 30);
      expect(formatMiniatureDayHeader('2026-03-09', now: afterDst), 'Today');
      expect(
        formatMiniatureDayHeader('2026-03-08', now: afterDst),
        'Yesterday',
      );
      expect(
        formatMiniatureDayHeader('2026-03-07', now: afterDst),
        'Saturday, Mar 7, 2026',
      );
    });

    test('gate copy names the rule and the day', () {
      expect(
        miniatureGateBody(_game('y', DateTime.utc(2026, 9, 11)), now: now),
        contains('yesterday'),
      );
      expect(
        miniatureGateTitle(_game('u', null), now: now),
        contains('Undated'),
      );
      expect(
        miniatureGateTitle(_game('f', DateTime.utc(2026, 9, 20)), now: now),
        contains('Future'),
      );
    });
  });
}
