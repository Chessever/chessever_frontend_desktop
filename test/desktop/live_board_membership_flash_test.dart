import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';

/// Slow, network-shaped event lookup: every call costs a frame budget the
/// gate used to spend showing "Checking your membership" over a live board.
class _SlowLookup implements DesktopEventAccessLookup {
  int pastCalls = 0;
  int broadcastCalls = 0;

  @override
  Future<bool?> isPast(String eventId) async {
    pastCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return false;
  }

  @override
  Future<bool?> isCurrent(String eventId) async => false;

  @override
  Future<GroupBroadcast?> broadcast(String eventOrTourId) async {
    broadcastCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return null;
  }

  @override
  Future<GroupBroadcast?> broadcastBySlug(String slug) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return null;
  }
}

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();
}

class _IdleGames extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _IdleGames() : super(const AsyncValue.loading());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const DesktopAccessContext _liveBroadcastAccess = DesktopAccessContext(
  feature: DesktopFeature.broadcast,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.broadcast,
);

GamesTourModel _liveGame({required DateTime lastMoveTime}) => GamesTourModel(
  gameId: 'live-game',
  source: GameSource.supabase,
  whitePlayer: PlayerCard(
    name: 'Carlsen, Magnus',
    federation: 'NOR',
    title: 'GM',
    rating: 2839,
    countryCode: 'NOR',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Nakamura, Hikaru',
    federation: 'USA',
    title: 'GM',
    rating: 2802,
    countryCode: 'USA',
    team: null,
  ),
  whiteTimeDisplay: '0:12',
  blackTimeDisplay: '0:09',
  whiteClockCentiseconds: 1200,
  blackClockCentiseconds: 900,
  whiteClockSeconds: 12,
  blackClockSeconds: 9,
  gameStatus: GameStatus.ongoing,
  roundId: 'round-1',
  tourId: 'tour-1',
  pgn: '1. e4 e5 *',
  fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
  lastMoveTime: lastMoveTime,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerFor(DesktopEventAccessLookup lookup) {
    final container = ProviderContainer(
      overrides: [
        desktopPastEventAccessEnabledProvider.overrideWithValue(true),
        desktopBoardMembershipRecheckEnabledProvider.overrideWithValue(true),
        desktopEventAccessLookupProvider.overrideWithValue(lookup),
        gamesTourProvider.overrideWith((ref, tourId) => _IdleGames()),
        gameUpdatesBatchArrivalStreamProvider.overrideWith(
          (ref, key) => const Stream.empty(),
        ),
        liveGroupBroadcastIdsProvider.overrideWith(
          (_) => Stream.value(<String>[]),
        ),
        gameUpdatesStreamProvider.overrideWith(
          (ref, gameId) => const Stream<Map<String, dynamic>?>.empty(),
        ),
        gameUpdatesBatchStreamProvider.overrideWith(
          (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
        ),
        subscriptionProvider.overrideWith(
          (_) => _Subscription(SubscriptionState()),
        ),
        desktopEntitlementProvider.overrideWithValue(
          DesktopEntitlementSnapshot.guest,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpGate(WidgetTester tester, ProviderContainer container) {
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DesktopBoardAccessGate(
            tabId: 'board',
            child: Text('BOARD CONTENT'),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'a live board is shown at once and never waits on a membership check',
    (tester) async {
      final lookup = _SlowLookup();
      final container = containerFor(lookup);
      final startedAt = DateTime.now();
      final game = _liveGame(lastMoveTime: startedAt);
      final args = BoardTabGameArgs(
        gameId: game.gameId,
        pgn: game.pgn!,
        label: 'Carlsen - Nakamura',
        whiteName: game.whitePlayer.name,
        blackName: game.blackPlayer.name,
        sourceGame: game,
        accessContext: _liveBroadcastAccess,
      );
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'board': args,
      };

      await pumpGate(tester, container);

      // First frame: the live game is on screen, not a membership surface.
      expect(find.text('BOARD CONTENT'), findsOneWidget);
      expect(find.text('Checking your membership'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('BOARD CONTENT'), findsOneWidget);
      expect(find.text('Checking your membership'), findsNothing);
      // A live game is never an archived event: no classification traffic.
      expect(lookup.pastCalls, 0);
      expect(lookup.broadcastCalls, 0);
    },
  );

  testWidgets(
    'live moves keep the board mounted without a membership surface',
    (tester) async {
      final lookup = _SlowLookup();
      final container = containerFor(lookup);
      final startedAt = DateTime.now();
      final game = _liveGame(lastMoveTime: startedAt);
      var args = BoardTabGameArgs(
        gameId: game.gameId,
        pgn: game.pgn!,
        label: 'Carlsen - Nakamura',
        whiteName: game.whitePlayer.name,
        blackName: game.blackPlayer.name,
        sourceGame: game,
        accessContext: _liveBroadcastAccess,
      );
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'board': args,
      };
      await pumpGate(tester, container);
      await tester.pumpAndSettle();
      expect(find.text('BOARD CONTENT'), findsOneWidget);

      for (var move = 1; move <= 3; move++) {
        final tick = game.copyWith(
          pgn: '1. e4 e5 2. Nf3 Nc6 3. Bb5 $move *',
          lastMoveTime: startedAt.add(Duration(seconds: 5 * move)),
        );
        args = args.copyWith(pgn: tick.pgn, sourceGame: tick);
        container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
          'board': args,
        };

        await tester.pump();

        expect(find.text('BOARD CONTENT'), findsOneWidget);
        expect(find.text('Checking your membership'), findsNothing);
      }

      expect(lookup.pastCalls, 0);
      expect(lookup.broadcastCalls, 0);
    },
  );

  test('event classification key ignores sub-day timestamp churn', () {
    final game = _liveGame(lastMoveTime: DateTime(2026, 11, 5, 12));
    expect(
      desktopGameEventKey(game, _liveBroadcastAccess),
      desktopGameEventKey(
        game.copyWith(lastMoveTime: DateTime(2026, 11, 5, 12, 37, 4)),
        _liveBroadcastAccess,
      ),
    );
  });

  group('a live game is never event-classified', () {
    final now = DateTime(2026, 11, 10, 15);

    test('a running game with recent moves stays free', () {
      final game = _liveGame(
        lastMoveTime: now.subtract(const Duration(minutes: 4)),
      );
      expect(desktopGameIsLiveNow(game, now: now), isTrue);
      expect(
        desktopGameNeedsEventClassification(
          _liveBroadcastAccess,
          game,
          now: now,
        ),
        isFalse,
      );
    });

    test('a pre-start board dated today is live, not archived', () {
      final game = _liveGame(
        lastMoveTime: now,
      ).copyWith(clearLastMoveTime: true, dateStart: now);
      expect(desktopGameIsLiveNow(game, now: now), isTrue);
      expect(
        desktopGameNeedsEventClassification(
          _liveBroadcastAccess,
          game,
          now: now,
        ),
        isFalse,
      );
    });

    test('a finished archived game is still classified', () {
      final game = _liveGame(
        lastMoveTime: now.subtract(const Duration(days: 30)),
      ).copyWith(gameStatus: GameStatus.whiteWins, gameDay: DateTime(2026, 9, 1));
      expect(desktopGameIsLiveNow(game, now: now), isFalse);
      expect(
        desktopGameNeedsEventClassification(
          _liveBroadcastAccess,
          game,
          now: now,
        ),
        isTrue,
      );
    });

    test('a stale ongoing row from an archived event is still classified', () {
      final game = _liveGame(
        lastMoveTime: now.subtract(const Duration(days: 8)),
      ).copyWith(dateStart: DateTime(2026, 9, 1));
      expect(desktopGameIsLiveNow(game, now: now), isFalse);
      expect(
        desktopGameNeedsEventClassification(
          _liveBroadcastAccess,
          game,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
