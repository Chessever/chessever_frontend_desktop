import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/likes/community_likes_access.dart';
import 'package:chessever/desktop/services/likes/community_likes_link.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

PlayerCard _player(
  String name, {
  int? fideId,
  int rating = 0,
  String title = '',
  String country = '',
}) => PlayerCard(
  name: name,
  federation: country,
  title: title,
  rating: rating,
  countryCode: country,
  fideId: fideId,
  team: null,
);

GamesTourModel _game(String id, PlayerCard white, PlayerCard black) =>
    GamesTourModel(
      gameId: id,
      whitePlayer: white,
      blackPlayer: black,
      whiteTimeDisplay: '--:--',
      blackTimeDisplay: '--:--',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.whiteWins,
      roundId: 'r',
      tourId: 't',
    );

void main() {
  group('CommunityLikesQuery', () {
    // Wednesday.
    final now = DateTime(2026, 9, 23, 15, 30);

    test('periods are calendar windows in local time', () {
      final week = CommunityLikesQuery(CommunityLikesPeriod.week, now);
      expect(week.window.from, DateTime(2026, 9, 21));
      expect(week.window.to, DateTime(2026, 9, 28));
      final month = CommunityLikesQuery(CommunityLikesPeriod.month, now);
      expect(month.window.from, DateTime(2026, 9));
      expect(month.window.to, DateTime(2026, 10));
      final year = CommunityLikesQuery(CommunityLikesPeriod.year, now);
      expect(year.window.to, DateTime(2027));
    });

    test('next stops at the current period; previous at the first day', () {
      final today = CommunityLikesQuery(CommunityLikesPeriod.today, now);
      expect(today.next(now), isNull);
      expect(today.previous!.start, DateTime(2026, 9, 22));
      expect(today.previous!.next(now), today);

      final firstDay = CommunityLikesQuery(
        CommunityLikesPeriod.today,
        kCommunityLikesFirstDay,
      );
      expect(firstDay.previous, isNull);
      // The week holding the first day still opens; the one before does not.
      final firstWeek = CommunityLikesQuery(
        CommunityLikesPeriod.week,
        kCommunityLikesFirstDay,
      );
      expect(firstWeek.previous, isNull);
    });

    test('only the current day is free', () {
      expect(
        CommunityLikesQuery(CommunityLikesPeriod.today, now).isFree(now),
        isTrue,
      );
      expect(
        CommunityLikesQuery(
          CommunityLikesPeriod.today,
          DateTime(2026, 9, 22),
        ).isFree(now),
        isFalse,
      );
      expect(
        CommunityLikesQuery(CommunityLikesPeriod.week, now).isFree(now),
        isFalse,
      );
    });

    test('labels', () {
      String label(CommunityLikesPeriod p, DateTime d) =>
          CommunityLikesQuery(p, d).label(now);
      expect(label(CommunityLikesPeriod.today, now), 'Today');
      expect(
        label(CommunityLikesPeriod.today, DateTime(2026, 9, 22)),
        'Yesterday',
      );
      expect(label(CommunityLikesPeriod.week, now), 'Sep 21–27');
      expect(
        label(CommunityLikesPeriod.week, DateTime(2026, 9, 30)),
        'Sep 28 – Oct 4',
      );
      expect(label(CommunityLikesPeriod.month, now), 'September');
      expect(label(CommunityLikesPeriod.year, now), '2026');
    });
  });

  group('ranking rows', () {
    test('drop single likes, bad rows and duplicates; order is stable', () {
      final rows = parseCommunityLikesRows([
        {'source_game_id': 'b', 'like_count': 5},
        {'source_game_id': 'a', 'like_count': '5'},
        {'source_game_id': 'c', 'like_count': 1},
        {'source_game_id': '', 'like_count': 9},
        {'source_game_id': 'd', 'like_count': 12.0},
        {'source_game_id': 'b', 'like_count': 3},
        'garbage',
      ]);
      expect([for (final r in rows) r.gameId], ['d', 'a', 'b']);
      expect([for (final r in rows) r.likes], [12, 5, 5]);
      expect(parseCommunityLikesRows(null), isEmpty);
    });

    test('an unresolved game keeps its rank empty', () {
      final white = _player('Carlsen', fideId: 1503014);
      final black = _player('Nakamura', fideId: 2016192);
      final entries = assembleCommunityLikesEntries(
        counts: const [
          CommunityLikesCount(gameId: 'x', likes: 9),
          CommunityLikesCount(gameId: 'gone', likes: 7),
          CommunityLikesCount(gameId: 'y', likes: 4),
        ],
        gamesById: {
          'x': _game('x', white, black),
          'y': _game('y', black, white),
        },
        rankOffset: 12,
      );
      expect([for (final e in entries) e.rank], [13, 15]);
    });

    test('players fold by identity and rank by likes', () {
      final carlsen = _player('Carlsen', fideId: 1503014);
      final carlsenRated = _player(
        'Carlsen, M.',
        fideId: 1503014,
        rating: 2830,
        title: 'GM',
      );
      final hikaru = _player('Nakamura', fideId: 2016192);
      final anon = _player('?');
      final entries = [
        CommunityLikesEntry(
          rank: 1,
          likes: 10,
          game: _game('1', carlsen, hikaru),
        ),
        CommunityLikesEntry(
          rank: 2,
          likes: 6,
          game: _game('2', anon, carlsenRated),
        ),
      ];
      final players = aggregateCommunityLikesPlayers(entries);
      expect(players, hasLength(2));
      expect(players.first.player.fideId, 1503014);
      expect(players.first.likes, 16);
      expect(players.first.games, 2);
      expect(players.first.player.rating, 2830);
      expect(players.first.player.title, 'GM');
      expect(players.last.likes, 10);
      expect(communityLikesEntryHasPlayer(entries[1], players.first), isTrue);
      expect(communityLikesEntryHasPlayer(entries[1], players.last), isFalse);
    });

    test('compact counts', () {
      expect(compactLikeCount(999), '999');
      expect(compactLikeCount(1000), '1K');
      expect(compactLikeCount(1250), '1.2K');
      expect(compactLikeCount(12500), '12K');
      expect(communityLikesLabel(1), '1 like');
      expect(communityLikesLabel(2), '2 likes');
    });
  });

  group('access', () {
    final now = DateTime(2026, 9, 10, 12);
    final free = SubscriptionState();
    final premium = SubscriptionState(
      isSubscribed: true,
      expirationDate: now.add(const Duration(days: 30)),
    );
    const member = DesktopEntitlementSnapshot(
      accountId: 'acct-a',
      generation: 1,
    );

    DesktopAccessDecision decide(
      CommunityLikesQuery query, {
      SubscriptionState? sub,
      DesktopAction action = DesktopAction.openContent,
    }) => evaluateDesktopAccess(
      context: communityLikesAccessContext(query, action),
      subscription: sub ?? free,
      entitlement: member,
      now: now,
    );

    test("today's ranking opens free", () {
      final today = CommunityLikesQuery(CommunityLikesPeriod.today, now);
      expect(decide(today).outcome, DesktopAccess.allowed);
      expect(
        communityLikesLockedAtRest(
          today,
          subscription: free,
          entitlement: member,
          now: now,
        ),
        isFalse,
      );
    });

    test('earlier days and longer periods are Premium to open', () {
      for (final query in [
        CommunityLikesQuery(CommunityLikesPeriod.today, DateTime(2026, 9, 9)),
        CommunityLikesQuery(CommunityLikesPeriod.week, now),
        CommunityLikesQuery(CommunityLikesPeriod.month, now),
        CommunityLikesQuery(CommunityLikesPeriod.year, now),
      ]) {
        final decision = decide(query);
        expect(
          decision.outcome,
          DesktopAccess.premiumRequired,
          reason: '$query',
        );
        expect(
          decision.reason,
          DesktopAccessReason.premiumCommunityLikesNotToday,
        );
        expect(decide(query, sub: premium).outcome, DesktopAccess.allowed);
        // Browsing the list itself never needs Premium.
        expect(
          decide(query, action: DesktopAction.view).outcome,
          DesktopAccess.allowed,
        );
      }
    });

    test('provenance keeps the gate on the board', () {
      // A board tab carries the origin with another feature (e.g. a PGN
      // fetch through the game report); the rule still applies.
      final context = DesktopAccessContext(
        feature: DesktopFeature.broadcast,
        action: DesktopAction.fetchPgn,
        origin: DesktopDiscoveryOrigin.communityLikes,
      );
      expect(
        evaluateDesktopAccess(
          context: context,
          subscription: free,
          entitlement: member,
          now: now,
        ).outcome,
        DesktopAccess.premiumRequired,
      );
      final roundTrip = DesktopAccessContext.fromJson(
        communityLikesAccessContext(
          CommunityLikesQuery(CommunityLikesPeriod.today, now),
          DesktopAction.openContent,
        ).toJson(),
      );
      expect(roundTrip.origin, DesktopDiscoveryOrigin.communityLikes);
      expect(roundTrip.contentDate, DateTime(2026, 9, 10));
    });

    test('paywall copy names the rule', () {
      final copy = desktopPaywallCopyFor(
        decide(CommunityLikesQuery(CommunityLikesPeriod.week, now)),
      );
      expect(copy.title, contains('most liked'));
    });
  });

  group('links', () {
    test('parses the phone share link', () {
      final link = parseDesktopIncomingLink(
        Uri.parse(
          'https://chessever.com/app/likes/month?date=2026-08-01&view=players',
        ),
      );
      expect(link?.target, DesktopIncomingLinkTarget.likes);
      expect(
        link?.likes,
        CommunityLikesLink(
          period: CommunityLikesPeriod.month,
          date: DateTime(2026, 8),
          section: CommunityLikesSection.players,
        ),
      );
      expect(
        parseDesktopIncomingLink(
          Uri.parse('https://chessever.com/app/likes'),
        )?.likes,
        const CommunityLikesLink(),
      );
      for (final rejected in [
        'https://chessever.com/app/likes/week/extra',
        'https://chessever.com/app/likes/decade',
        'https://chessever.com/app/likes/week?view=boards',
        'https://chessever.com/app/likes/week?date=2026-02-30',
        'https://chessever.com/app/likes/week?utm=x',
        'https://chessever.com/app/likes?view=players',
      ]) {
        expect(
          parseCommunityLikesLink(Uri.parse(rejected), isWeb: true),
          isNull,
          reason: rejected,
        );
      }
      expect(
        parseCommunityLikesLink(
          Uri.parse('com.chessever.app://likes/today'),
          isWeb: false,
        ),
        const CommunityLikesLink(period: CommunityLikesPeriod.today),
      );
    });

    test('opening a link selects the ranking and the Likes tab', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = DateTime(2026, 9, 23, 9);
      openCommunityLikesLink(
        CommunityLikesLink(
          period: CommunityLikesPeriod.today,
          date: DateTime(2026, 9, 20),
          section: CommunityLikesSection.players,
        ),
        container,
        now: now,
      );
      expect(
        container.read(communityLikesPeriodProvider),
        CommunityLikesPeriod.today,
      );
      expect(container.read(communityLikesDayProvider), DateTime(2026, 9, 20));
      expect(
        container.read(communityLikesSectionProvider),
        CommunityLikesSection.players,
      );
      final tabs = container.read(desktopTabsProvider);
      expect(tabs.tabs.where((t) => t.kind == TabKind.likes), hasLength(1));

      // A future date follows the clock instead.
      openCommunityLikesLink(
        CommunityLikesLink(
          period: CommunityLikesPeriod.week,
          date: DateTime(2027, 1, 1),
        ),
        container,
        now: now,
      );
      expect(container.read(communityLikesDayProvider), isNull);
      expect(
        container
            .read(desktopTabsProvider)
            .tabs
            .where((t) => t.kind == TabKind.likes),
        hasLength(1),
      );
    });
  });
}
