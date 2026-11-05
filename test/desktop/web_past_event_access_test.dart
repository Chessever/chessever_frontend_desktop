import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/collections/collection_preview_access_gate.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_event_discovery_gate.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class _Lookup implements DesktopEventAccessLookup {
  bool? past = false;
  bool? current = false;
  GroupBroadcast? event;
  GroupBroadcast? slugEvent;
  String? requestedId;
  int calls = 0;
  int broadcastCalls = 0;
  bool failNextBroadcast = false;
  @override
  Future<bool?> isPast(String eventId) async {
    calls++;
    return past;
  }

  @override
  Future<bool?> isCurrent(String eventId) async => current;
  @override
  Future<GroupBroadcast?> broadcast(String eventOrTourId) async {
    requestedId = eventOrTourId;
    broadcastCalls++;
    if (failNextBroadcast) {
      failNextBroadcast = false;
      throw StateError('Event lookup failed');
    }
    return event;
  }

  @override
  Future<GroupBroadcast?> broadcastBySlug(String slug) async => slugEvent;
}

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();
  void update(SubscriptionState value) => state = value;
}

class _IdleGames extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _IdleGames() : super(const AsyncValue.loading());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 5, 12);
  DesktopEventAccessKey event({
    DateTime? start,
    DateTime? end,
    bool past = false,
  }) => (id: 'event', start: start, end: end, fromPastList: past);

  test('last event day and undated events stay free; grace matches phone', () {
    expect(desktopEventWindowIsPast(end: now, now: now), isFalse);
    expect(
      desktopEventWindowIsPast(
        end: now.subtract(const Duration(days: 1)),
        now: now,
      ),
      isTrue,
    );
    expect(
      desktopEventWindowIsPast(
        start: now.subtract(const Duration(days: 7)),
        now: now,
      ),
      isFalse,
    );
    expect(
      desktopEventWindowIsPast(
        start: now.subtract(const Duration(days: 8)),
        now: now,
      ),
      isTrue,
    );
    expect(desktopEventWindowIsPast(now: now), isFalse);
  });

  test(
    'Past SQL membership wins over live, Current, and future dates',
    () async {
      final lookup =
          _Lookup()
            ..past = true
            ..current = true;
      expect(
        await resolveDesktopEventIsPast(
          lookup: lookup,
          event: event(end: now.add(const Duration(days: 2))),
          liveIds: ['event'],
          now: now,
        ),
        isTrue,
      );
    },
  );

  test('live and Current protect events whose local dates look old', () async {
    final lookup = _Lookup();
    final old = event(end: now.subtract(const Duration(days: 100)));
    expect(
      await resolveDesktopEventIsPast(
        lookup: lookup,
        event: old,
        liveIds: ['event'],
        now: now,
      ),
      isFalse,
    );
    lookup.current = true;
    expect(
      await resolveDesktopEventIsPast(
        lookup: lookup,
        event: old,
        liveIds: [],
        now: now,
      ),
      isFalse,
    );
    lookup.current = false;
    expect(
      await resolveDesktopEventIsPast(
        lookup: lookup,
        event: old,
        liveIds: [],
        now: now,
      ),
      isTrue,
    );
    lookup.current = null;
    expect(
      await resolveDesktopEventIsPast(
        lookup: lookup,
        event: old,
        liveIds: [],
        now: now,
      ),
      isFalse,
    );
  });

  test(
    'Past list hint and missing-date canonical metadata are respected',
    () async {
      final lookup = _Lookup();
      expect(
        await resolveDesktopEventIsPast(
          lookup: lookup,
          event: event(past: true),
          liveIds: [],
          now: now,
        ),
        isTrue,
      );
      lookup.event = GroupBroadcast(
        id: 'event',
        createdAt: now,
        name: 'Event',
        search: [],
        dateEnd: now.subtract(const Duration(days: 2)),
      );
      expect(
        await resolveDesktopEventIsPast(
          lookup: lookup,
          event: event(),
          liveIds: [],
          now: now,
        ),
        isTrue,
      );
    },
  );

  ProviderContainer containerFor(
    _Lookup lookup, {
    _Subscription? subscription,
    bool enabled = true,
  }) => ProviderContainer(
    overrides: [
      desktopPastEventAccessEnabledProvider.overrideWithValue(enabled),
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
        (_) => subscription ?? _Subscription(SubscriptionState()),
      ),
      desktopEntitlementProvider.overrideWithValue(
        DesktopEntitlementSnapshot.guest,
      ),
    ],
  );

  for (final settled in ['premium', 'free', 'error']) {
    test(
      'game-link admission waits for $settled membership without a transient dialog',
      () async {
        final subscription = _Subscription(SubscriptionState(isLoading: true));
        final container = containerFor(_Lookup(), subscription: subscription);
        addTearDown(container.dispose);
        final presented = <DesktopAccess>[];
        addTearDown(
          registerDesktopPaywallPresenter(container, (
            decision, {
            context,
            resume,
            required surface,
          }) async {
            presented.add(decision.outcome);
            return false;
          }),
        );
        var completed = false;
        final admitted = requireDesktopAction(
          container,
          desktopPastEventOpenContext,
          surface: 'game_link',
        ).then((value) {
          completed = true;
          return value;
        });
        await Future<void>.delayed(Duration.zero);
        expect(presented, isEmpty);
        expect(completed, isFalse);
        subscription.update(
          SubscriptionState(
            isSubscribed: settled == 'premium',
            error: settled == 'error' ? 'Unavailable' : null,
          ),
        );
        expect(await admitted, settled == 'premium');
        expect(presented, switch (settled) {
          'premium' => <DesktopAccess>[],
          'free' => [DesktopAccess.premiumRequired],
          _ => [DesktopAccess.temporarilyUnavailable],
        });
      },
    );
  }

  testWidgets('stalled membership reaches the existing checking flow once', (
    tester,
  ) async {
    final subscription = _Subscription(SubscriptionState(isLoading: true));
    final container = containerFor(_Lookup(), subscription: subscription);
    addTearDown(container.dispose);
    final presented = <DesktopAccess>[];
    addTearDown(
      registerDesktopPaywallPresenter(container, (
        decision, {
        context,
        resume,
        required surface,
      }) async {
        presented.add(decision.outcome);
        return false;
      }),
    );
    final admitted = requireDesktopAction(
      container,
      desktopPastEventOpenContext,
      surface: 'game_link',
    );
    await tester.pump(const Duration(seconds: 7));
    expect(presented, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(await admitted, isFalse);
    expect(presented, [DesktopAccess.checking]);
  });

  testWidgets(
    'deep-link classification is ready on the first board frame and survives PGN refresh',
    (tester) async {
      final lookup =
          _Lookup()
            ..past = true
            ..event = GroupBroadcast(
              id: 'archive-event',
              createdAt: now,
              name: 'Archive',
              search: [],
            );
      final subscription = _Subscription(SubscriptionState(isSubscribed: true));
      final container = containerFor(lookup, subscription: subscription);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      final game = _game();
      final resolving = resolveDesktopGameEventAccess(
        container,
        game: game,
        access: const DesktopAccessContext(
          feature: DesktopFeature.broadcast,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.deepLink,
        ),
      );
      await tester.pump();
      await tester.pump();
      final access = await resolving;
      expect(access.feature, DesktopFeature.eventDiscovery);
      final classifiedCalls = lookup.calls;
      final args = BoardTabGameArgs(
        gameId: game.gameId,
        pgn: '1. e4 e5 *',
        label: 'Shared game',
        whiteName: 'White',
        blackName: 'Black',
        sourceGame: game,
        accessContext: access,
      );
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'board': args,
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DesktopBoardAccessGate(
              tabId: 'board',
              child: Text('Advanced board'),
            ),
          ),
        ),
      );
      expect(find.text('Advanced board'), findsOneWidget);
      expect(find.text('Checking your membership'), findsNothing);
      expect(lookup.calls, classifiedCalls);
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'board': args.copyWith(
          pgn: '1. e4 e5 2. Nf3 *',
          sourceGame: game.copyWith(pgn: '1. e4 e5 2. Nf3 *'),
        ),
      };
      await tester.pump();
      expect(find.text('Advanced board'), findsOneWidget);
      expect(find.text('Checking your membership'), findsNothing);
      expect(lookup.calls, classifiedCalls);
      subscription.update(SubscriptionState());
      expect(readDesktopAccess(container.read, access).isAllowed, isFalse);
      await tester.pumpAndSettle();
      expect(find.text('Advanced board'), findsNothing);
      expect(lookup.calls, classifiedCalls);
    },
  );

  test(
    'failed event classification is retried and never cached as access',
    () async {
      final lookup = _Lookup()..failNextBroadcast = true;
      final container = containerFor(lookup);
      addTearDown(container.dispose);
      const access = DesktopAccessContext(
        feature: DesktopFeature.broadcast,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.deepLink,
      );
      await expectLater(
        resolveDesktopGameEventAccess(container, game: _game(), access: access),
        throwsStateError,
      );
      await container.pump();
      final resolved = await resolveDesktopGameEventAccess(
        container,
        game: _game(),
        access: access,
      );
      expect(resolved.feature, DesktopFeature.broadcast);
      expect(lookup.broadcastCalls, 2);
    },
  );

  test(
    'game classification uses its own event and preserves source gates',
    () async {
      final lookup =
          _Lookup()
            ..past = true
            ..event = GroupBroadcast(
              id: 'event',
              createdAt: now,
              name: 'Event',
              search: [],
            );
      final container = containerFor(lookup);
      addTearDown(container.dispose);
      const base = DesktopAccessContext(
        feature: DesktopFeature.playerProfile,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.playerProfile,
      );
      final resolved = await resolveDesktopGameEventAccess(
        container,
        game: _game(),
        access: base,
        eventBroadcastId: 'unrelated-current-event',
      );
      expect(lookup.requestedId, _game().tourId);
      expect(resolved.feature, DesktopFeature.eventDiscovery);
      expect(resolved.origin, DesktopDiscoveryOrigin.broadcast);
      final favorites = base.copyWith(
        feature: DesktopFeature.favorites,
        origin: DesktopDiscoveryOrigin.favorites,
      );
      expect(
        await resolveDesktopGameEventAccess(
          container,
          game: _game(),
          access: favorites,
        ),
        favorites,
      );
    },
  );

  test(
    'unknown broadcast remains free, unresolved archive remains paid',
    () async {
      final container = containerFor(_Lookup());
      addTearDown(container.dispose);
      const base = DesktopAccessContext(
        feature: DesktopFeature.playerProfile,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.playerProfile,
      );
      expect(
        (await resolveDesktopGameEventAccess(
          container,
          game: _game(),
          access: base,
        )).feature,
        DesktopFeature.broadcast,
      );
      expect(
        (await resolveDesktopGameEventAccess(
          container,
          game: _game().copyWith(source: GameSource.gamebase),
          access: base,
        )).feature,
        DesktopFeature.eventDiscovery,
      );
    },
  );

  test(
    'public historical collections keep their no-export provenance',
    () async {
      final container = containerFor(_Lookup());
      addTearDown(container.dispose);
      const access = DesktopAccessContext(
        feature: DesktopFeature.collection,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.collection,
      );
      final old = await resolveDesktopGameEventAccess(
        container,
        game: _game().copyWith(
          source: GameSource.savedAnalysis,
          gameDay: DateTime(1953),
        ),
        access: access,
      );
      expect(old.feature, DesktopFeature.eventDiscovery);
      expect(old.isCollectionContent, isTrue);
      final current = await resolveDesktopGameEventAccess(
        container,
        game: _game().copyWith(
          source: GameSource.savedAnalysis,
          gameDay: DateTime.now(),
        ),
        access: access,
      );
      expect(current.feature, DesktopFeature.collection);
      expect(current.isCollectionContent, isTrue);
    },
  );

  test('a reused event name cannot admit an old archive edition', () async {
    final lookup =
        _Lookup()
          ..current = true
          ..slugEvent = GroupBroadcast(
            id: 'current-event',
            createdAt: now,
            name: 'Annual event',
            search: [],
            dateStart: now,
            dateEnd: now,
          );
    final container = containerFor(lookup);
    addTearDown(container.dispose);
    const access = DesktopAccessContext(
      feature: DesktopFeature.playerProfile,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.playerProfile,
    );
    final old = await resolveDesktopGameEventAccess(
      container,
      game: _game().copyWith(
        source: GameSource.gamebase,
        gameDay: DateTime(1953),
      ),
      access: access,
    );
    expect(old.feature, DesktopFeature.eventDiscovery);
    final current = await resolveDesktopGameEventAccess(
      container,
      game: _game().copyWith(source: GameSource.gamebase, gameDay: now),
      access: access,
    );
    expect(current.feature, DesktopFeature.broadcast);
  });

  test('native event access does not query or gate an event open', () async {
    final lookup = _Lookup()..past = true;
    final container = containerFor(lookup, enabled: false);
    addTearDown(container.dispose);
    expect(
      await requireDesktopPastEventAccess(container, event(past: true)),
      isTrue,
    );
    expect(lookup.calls, 0);
  });

  testWidgets(
    'historical collection preview never builds protected notation before Premium',
    (tester) async {
      final subscription = _Subscription(SubscriptionState());
      final container = containerFor(_Lookup(), subscription: subscription);
      addTearDown(container.dispose);
      final row = SavedAnalysis(
        id: 'public-old',
        userId: '',
        title: 'Published game',
        chessGame: ChessGame.fromPgn(
          'public-old',
          '[Date "1953.01.01"]\n\n1. e4 e5 *',
        ),
        analysisState: const {},
        variationComments: const {},
        lastViewedPosition: 0,
        tags: const [],
        isFavorite: false,
        createdAt: now,
        updatedAt: now,
      );
      var builds = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: CollectionPreviewAccessGate(
              row: row,
              builder: (_) {
                builds++;
                return const Text('Protected notation');
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Protected notation'), findsNothing);
      expect(builds, 0);
      subscription.update(SubscriptionState(isSubscribed: true));
      await tester.pump();
      expect(find.text('Protected notation'), findsOneWidget);
    },
  );

  for (final retained in ['clean', 'draft', 'saved']) {
    testWidgets(
      'web protected $retained board rechecks expired admission safely',
      (tester) async {
        final subscription = _Subscription(
          SubscriptionState(isSubscribed: true),
        );
        final container = containerFor(_Lookup(), subscription: subscription);
        addTearDown(container.dispose);
        const args = BoardTabGameArgs(
          pgn: '1. e4 e5 *',
          label: 'Archive',
          whiteName: 'White',
          blackName: 'Black',
          accessContext: desktopPastEventOpenContext,
        );
        container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
          'board': args,
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: DesktopBoardAccessGate(
                tabId: 'board',
                child: Text('Protected board'),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Protected board'), findsOneWidget);
        if (retained != 'clean') {
          container.read(boardPaneSessionByTabIdProvider.notifier).state = {
            'board': BoardPaneSession(
              game: ChessGame.fromPgn('board', args.pgn),
              pointer: const [],
              pgnHeaders: const {},
              flipped: false,
              loadedFrom: null,
              lastAppliedPgn: args.pgn,
              lastAppliedGameId: null,
              lastAppliedInitialFenKey: null,
              dirtySinceLoad: retained == 'draft',
              hasCommittedSave: retained == 'saved',
              hasUnseenMoves: false,
              undoStack: const [],
            ),
          };
        }
        subscription.update(SubscriptionState());
        await tester.pump();
        expect(
          find.text('Protected board'),
          retained == 'clean' ? findsNothing : findsOneWidget,
        );
        expect(
          container.read(boardTabGameArgsByTabIdProvider)['board'],
          same(args),
        );
      },
    );
  }

  testWidgets('denied historical rail navigation retains the active board', (
    tester,
  ) async {
    final lookup =
        _Lookup()
          ..past = true
          ..event = GroupBroadcast(
            id: 'old-event',
            createdAt: now,
            name: 'Old event',
            search: [],
          );
    final container = containerFor(lookup);
    addTearDown(container.dispose);
    const initial = BoardTabGameArgs(
      gameId: 'current-game',
      pgn: '1. e4 e5 *',
      label: 'Current game',
      whiteName: 'Current White',
      blackName: 'Current Black',
      tournamentTitle: 'Mixed games',
      gameListSelectedId: 'current-game',
      accessContext: DesktopAccessContext(
        feature: DesktopFeature.broadcast,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.broadcast,
      ),
      eventGames: [
        TournamentGameSummary(
          id: 'old-game',
          tourId: 'old-tour',
          name: 'Old game',
          whitePlayer: 'Archive White',
          blackPlayer: 'Archive Black',
          hasPgn: true,
          pgn: '1. d4 d5 *',
        ),
      ],
    );
    container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
      'tournaments-default': initial,
    };
    var prompts = 0;
    addTearDown(
      registerDesktopPaywallPresenter(container, (
        decision, {
        context,
        resume,
        required surface,
      }) async {
        prompts++;
        return false;
      }),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SizedBox(
            width: EventGamesTable.width,
            child: const EventGamesTable(tabId: 'tournaments-default'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Archive Black'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Archive Black'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(prompts, 1);
    expect(
      container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'],
      same(initial),
    );
  });

  testWidgets('web Past list browses freely without reading membership', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        desktopPastEventAccessEnabledProvider.overrideWithValue(true),
        subscriptionProvider.overrideWith(
          (_) => throw StateError('must not read'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopEventDiscoveryGate(
            category: GroupEventCategory.past,
            builder: (_) => const Text('Past events'),
          ),
        ),
      ),
    );
    expect(find.text('Past events'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'past activation cancels without navigating, then resumes after verified purchase',
    (tester) async {
      final lookup = _Lookup()..past = true;
      final subscription = _Subscription(SubscriptionState());
      final container = containerFor(lookup, subscription: subscription);
      addTearDown(container.dispose);
      var prompts = 0;
      var purchase = false;
      addTearDown(
        registerDesktopPaywallPresenter(container, (
          decision, {
          context,
          resume,
          required surface,
        }) async {
          prompts++;
          expect(decision.outcome, DesktopAccess.premiumRequired);
          if (purchase) {
            subscription.update(SubscriptionState(isSubscribed: true));
          }
          return purchase;
        }),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder:
                  (context, ref, _) => TextButton(
                    onPressed:
                        () => setActiveTournament(
                          ref,
                          GroupEventCardModel(
                            id: 'event',
                            title: 'Archived event',
                            dates: '',
                            maxAvgElo: 0,
                            timeUntilStart: '',
                            tourEventCategory: TourEventCategory.completed,
                            timeControl: '',
                            startDate: null,
                            endDate: null,
                          ),
                          fromPastList: true,
                        ),
                    child: const Text('Open'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(
        container.read(desktopTabsProvider).active?.kind,
        TabKind.tournaments,
      );
      purchase = true;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(prompts, 2);
      expect(
        container.read(desktopTabsProvider).active?.kind,
        TabKind.tournamentDetail,
      );
      expect(
        container.read(tournamentByTabIdProvider).values.single.title,
        'Archived event',
      );
    },
  );
}

GamesTourModel _game() => GamesTourModel(
  gameId: 'game',
  whitePlayer: PlayerCard(
    name: 'White',
    federation: '',
    title: '',
    rating: 0,
    countryCode: '',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Black',
    federation: '',
    title: '',
    rating: 0,
    countryCode: '',
    team: null,
  ),
  whiteTimeDisplay: '',
  blackTimeDisplay: '',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.unknown,
  roundId: 'round',
  tourId: 'tour',
);
