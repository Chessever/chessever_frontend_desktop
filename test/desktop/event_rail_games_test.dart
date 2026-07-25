import 'dart:async';
import 'dart:math' as math;

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/event_rail_games.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('production event rail query remains lightweight and deterministic', () {
    final select = eventRailGameSelectColumnsForTesting;

    expect(select, contains('round_schedule:rounds!games_round_id_fkey'));
    expect(select, contains('name,starts_at'));
    expect(select, isNot(contains('\n          pgn,')));
    expect(select, isNot(contains('\n          search,')));
    expect(select, isNot(contains('last_clock_white')));
    expect(select, isNot(contains('last_clock_black')));
    expect(eventRailTourOrderColumnsForTesting, <String>[
      'round_id',
      'board_nr',
      'id',
    ]);
    expect(eventRailRoundOrderColumnsForTesting, <String>['board_nr', 'id']);
    expect(eventRailPageRangeForTesting(limit: 64, offset: 64), (
      from: 64,
      to: 127,
    ));
    expect(
      () => eventRailPageRangeForTesting(limit: 0, offset: 0),
      throwsArgumentError,
    );
    expect(
      () => eventRailPageRangeForTesting(limit: 64, offset: -1),
      throwsArgumentError,
    );
  });

  test('an older conflicting terminal snapshot cannot replace the result', () {
    expect(
      mergeEventGameStatus(
        current: GameStatus.whiteWins,
        incoming: GameStatus.draw,
        currentSnapshotIsNewer: true,
      ),
      GameStatus.whiteWins,
    );
  });

  test('event rail provider identity prefers a stable tour slug', () {
    const first = EventRailGamesProviderKey(
      ownerId: 'board-1',
      eventKey: BoardTabEventGamesKey(
        tourId: 'dole-fragment-a',
        tourSlug: 'dole-open-aix-en-provence-2026',
      ),
    );
    const second = EventRailGamesProviderKey(
      ownerId: 'board-1',
      eventKey: BoardTabEventGamesKey(
        tourId: 'dole-fragment-b',
        tourSlug: 'dole-open-aix-en-provence-2026',
      ),
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });

  test(
    'slug-scoped event rail uses bounded tournament identity queries',
    () async {
      final repository = _FakeGameRepository(
        firstTourPage: <Games>[
          _game(id: 'round-8-game-1', roundId: 'round-8', boardNumber: 1),
        ],
        selectedRoundPage: const <Games>[],
        totalCount: 140,
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      const eventKey = BoardTabEventGamesKey(
        tourId: 'dole-fragment-a',
        tourSlug: 'dole-open-aix-en-provence-2026',
      );
      final provider = eventRailGamesProvider(_providerKey(eventKey));
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      final state = await container.read(provider.future);

      expect(state.totalCount, 140);
      expect(repository.tournamentIdentityPageCalls, <String>[
        'dole-fragment-a|dole-open-aix-en-provence-2026|64|0',
      ]);
      expect(repository.tournamentIdentityCountCalls, <String>[
        'dole-fragment-a|dole-open-aix-en-provence-2026',
      ]);
    },
  );

  test('lightweight rows preserve the canonical round stage name', () {
    final row = Games.fromJson(<String, dynamic>{
      'id': 'game-1',
      'round_id': 'round-1',
      'round_slug': 'round-1',
      'tour_id': 'tour-1',
      'tour_slug': 'tour-1',
      'players': const <Object>[],
      'round_schedule': <String, dynamic>{
        'name': 'Armageddon',
        'starts_at': '2026-07-18T12:00:00.000Z',
      },
    });

    expect(row.roundName, 'Armageddon');
    expect(row.toJson()['round_schedule'], <String, dynamic>{
      'name': 'Armageddon',
      'starts_at': '2026-07-18T12:00:00.000Z',
    });
  });

  test(
    'catalog merges unnamed loaded rounds and keeps no-date rounds upcoming',
    () {
      final loaded = TournamentGameSummary.fromGame(
        _game(id: 'game-1', roundId: 'round-1', boardNumber: 1),
      );
      final projection = eventRailCatalogProjectionForTesting(
        <TournamentGameSummary>[loaded],
        const <EventRailRoundMetadata>[
          EventRailRoundMetadata(
            id: 'round-1',
            name: '',
            startsAt: null,
            createdAt: null,
            ongoing: false,
          ),
          EventRailRoundMetadata(
            id: 'round-2',
            name: 'Round 2',
            startsAt: null,
            createdAt: null,
            ongoing: false,
          ),
        ],
      );

      final unnamed = projection.singleWhere(
        (group) => group.id == 'round-id:round-1',
      );
      expect(unnamed.catalogOnly, isFalse);
      expect(unnamed.gameIds, <String>['game-1']);
      expect(
        projection.where((group) => group.id == 'round-id:round-1'),
        hasLength(1),
      );
      expect(
        projection
            .singleWhere((group) => group.id == 'round-name:round 2')
            .status,
        'upcoming',
      );
    },
  );

  test('named catalog metadata bridges a loaded row without roundName', () {
    final loaded = TournamentGameSummary.fromGame(
      _game(id: 'game-1', roundId: 'round-1', boardNumber: 1),
    );
    final projection = eventRailCatalogProjectionForTesting(
      <TournamentGameSummary>[loaded],
      const <EventRailRoundMetadata>[
        EventRailRoundMetadata(
          id: 'round-1',
          name: 'Quarterfinal',
          startsAt: null,
          createdAt: null,
          ongoing: false,
        ),
      ],
    );

    expect(projection, hasLength(1));
    expect(projection.single.id, 'round-name:quarterfinal');
    expect(projection.single.catalogOnly, isFalse);
    expect(projection.single.gameIds, <String>['game-1']);
  });

  testWidgets('DOLE-shaped catalog loads all rounds by stable slug', (
    tester,
  ) async {
    final repository = _FakeGameRepository(
      firstTourPage: const <Games>[],
      selectedRoundPage: const <Games>[],
      totalCount: 140,
      roundCatalog: <EventRailRoundMetadata>[
        for (var round = 1; round <= 8; round++)
          EventRailRoundMetadata(
            id: 'round-$round',
            name: 'Round $round',
            startsAt: null,
            createdAt: DateTime.utc(2026, 7, round),
            ongoing: false,
          ),
      ],
    );
    const catalogKey = EventRailRoundCatalogKey(
      ownerId: 'test-board-tab',
      tourId: 'dole-fragment-a',
      tourSlug: 'dole-open-aix-en-provence-2026',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(eventRailRoundCatalogProvider(catalogKey));
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(repository.tournamentIdentityCatalogCalls, <String>[
      'dole-fragment-a|dole-open-aix-en-provence-2026',
    ]);
  });

  testWidgets('slow initial catalog request stays single-flight', (
    tester,
  ) async {
    final catalogCompleter = Completer<List<EventRailRoundMetadata>>();
    final repository = _FakeGameRepository(
      firstTourPage: const <Games>[],
      selectedRoundPage: const <Games>[],
      totalCount: 0,
      roundCatalogFuture: catalogCompleter.future,
    );
    const catalogKey = EventRailRoundCatalogKey(
      ownerId: 'test-board-tab',
      tourId: 'tour-1',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(eventRailRoundCatalogProvider(catalogKey));
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(repository.roundCatalogCalls, <String>['tour-1']);

    await tester.pump(const Duration(seconds: 6));
    expect(
      repository.roundCatalogCalls,
      <String>['tour-1'],
      reason: 'The refresh timer must not overlap the initial request.',
    );

    catalogCompleter.complete(const <EventRailRoundMetadata>[]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(repository.roundCatalogCalls, <String>['tour-1', 'tour-1']);
  });

  testWidgets('collapsed Event keepalive starts no REST session', (
    tester,
  ) async {
    final repository = _FakeGameRepository(
      firstTourPage: const <Games>[],
      selectedRoundPage: const <Games>[],
      totalCount: 0,
      roundCatalog: const <EventRailRoundMetadata>[],
    );
    const eventKey = BoardTabEventGamesKey(
      tourId: 'tour-1',
      selectedGameId: 'game-1',
      selectedRoundId: 'round-1',
      selectedBoardNumber: 1,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => const <String, BoardTabGameArgs>{
              'board-1': BoardTabGameArgs(
                gameId: 'game-1',
                pgn: '*',
                label: 'Event game',
                whiteName: 'White',
                blackName: 'Black',
                eventGamesKey: eventKey,
              ),
            },
          ),
        ],
        child: const MaterialApp(
          home: BoardEventNavigationKeepAlive(tabId: 'board-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));

    expect(repository.roundCatalogCalls, isEmpty);
    expect(repository.countCalls, isEmpty);
    expect(repository.tourPageCalls, isEmpty);
    expect(repository.selectedGameCalls, isEmpty);
    expect(repository.roundIdsPageCalls, isEmpty);
  });

  test('hidden catalog refresh cannot publish its stale completion', () async {
    const initial = EventRailRoundMetadata(
      id: 'round-1',
      name: 'Round 1',
      startsAt: null,
      createdAt: null,
      ongoing: true,
    );
    const stale = EventRailRoundMetadata(
      id: 'stale-round',
      name: 'Stale round',
      startsAt: null,
      createdAt: null,
      ongoing: true,
    );
    const fresh = EventRailRoundMetadata(
      id: 'round-2',
      name: 'Round 2',
      startsAt: null,
      createdAt: null,
      ongoing: true,
    );
    final repository = _FakeGameRepository(
      firstTourPage: const <Games>[],
      selectedRoundPage: const <Games>[],
      totalCount: 0,
      roundCatalog: const <EventRailRoundMetadata>[initial],
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    const key = EventRailRoundCatalogKey(
      ownerId: 'test-board-tab',
      tourId: 'tour-1',
    );
    final provider = eventRailRoundCatalogProvider(key);
    final subscription = container
        .listen<AsyncValue<List<EventRailRoundMetadata>>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
    addTearDown(subscription.close);
    expect(
      await container.read(provider.future),
      const <EventRailRoundMetadata>[initial],
    );
    final notifier = container.read(provider.notifier);
    final staleCompleter = Completer<List<EventRailRoundMetadata>>();
    repository.roundCatalogFuture = staleCompleter.future;

    final staleRefresh = notifier.refreshCatalog();
    await Future<void>.delayed(Duration.zero);
    notifier
      ..setForeground(false)
      ..setForeground(true);
    staleCompleter.complete(const <EventRailRoundMetadata>[stale]);
    repository.roundCatalogFuture = Future<List<EventRailRoundMetadata>>.value(
      const <EventRailRoundMetadata>[fresh],
    );
    await staleRefresh;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(provider).requireValue,
      const <EventRailRoundMetadata>[fresh],
    );
  });

  test('round header spanning pages prefers its current render page', () {
    expect(
      eventRailPreferredGroupPageForTesting(
        firstGameOffset: 40,
        gameCount: 80,
        currentPageIndex: 1,
      ),
      1,
    );
    expect(
      eventRailPreferredGroupPageForTesting(
        firstGameOffset: 40,
        gameCount: 80,
        currentPageIndex: 2,
      ),
      0,
    );
  });

  test('hydrated rail-focus target resolves across the 64-row boundary', () {
    final games = List<TournamentGameSummary>.generate(
      65,
      (index) => TournamentGameSummary.fromGame(
        _game(
          id: 'game-$index',
          roundId: 'round-1',
          roundName: 'Round 1',
          boardNumber: index + 1,
        ),
      ),
    );

    expect(
      eventRailHydratedHighlightTargetForTesting(
        games,
        exactTargetGameId: 'game-64',
      ),
      (gameId: 'game-64', pageIndex: 1),
    );
  });

  testWidgets('a selected Source rail does not start the Event session', (
    tester,
  ) async {
    final repository = _FakeGameRepository(
      firstTourPage: <Games>[
        _game(id: 'event-game', roundId: 'round-1', boardNumber: 1),
      ],
      selectedRoundPage: const <Games>[],
      totalCount: 1,
    );
    final source = TournamentGameSummary.fromGame(
      _game(id: 'source-game', roundId: 'round-1', boardNumber: 1),
    );
    final event = TournamentGameSummary.fromGame(
      _game(id: 'event-game', roundId: 'round-1', boardNumber: 1),
    );
    final args = BoardTabGameArgs(
      gameId: source.id,
      pgn: '',
      label: 'Source game',
      whiteName: source.whitePlayer,
      blackName: source.blackPlayer,
      routeTitle: 'Source',
      routeGames: <TournamentGameSummary>[source],
      eventGames: <TournamentGameSummary>[event],
      eventGamesKey: const BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'event-game',
        selectedRoundId: 'round-1',
        selectedBoardNumber: 1,
      ),
      gameListSelectedId: source.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
          gameUpdatesBatchStreamProvider.overrideWith(
            (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
          ),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: EventGamesTable.width,
            height: 700,
            child: EventGamesTable(tabId: 'tournaments-default'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(repository.tourPageCalls, isEmpty);
    expect(repository.roundPageCalls, isEmpty);
    expect(repository.selectedGameCalls, isEmpty);
    expect(repository.countCalls, isEmpty);
    expect(repository.roundCatalogCalls, isEmpty);
  });

  testWidgets('hidden and paused Event rails stop catalog refreshes', (
    tester,
  ) async {
    final repository = _FakeGameRepository(
      firstTourPage: <Games>[
        _game(id: 'event-game', roundId: 'round-1', boardNumber: 1),
      ],
      selectedRoundPage: const <Games>[],
      totalCount: 1,
      roundCatalog: const <EventRailRoundMetadata>[
        EventRailRoundMetadata(
          id: 'round-1',
          name: 'Round 1',
          startsAt: null,
          createdAt: null,
          ongoing: false,
        ),
      ],
    );
    final game = TournamentGameSummary.fromGame(
      repository.firstTourPage.single,
    );
    final args = BoardTabGameArgs(
      gameId: game.id,
      pgn: '',
      label: game.name,
      whiteName: game.whitePlayer,
      blackName: game.blackPlayer,
      tournamentTitle: 'Event',
      eventGames: <TournamentGameSummary>[game],
      eventGamesKey: const BoardTabEventGamesKey(tourId: 'tour-1'),
      gameListSelectedId: game.id,
    );
    final tabs = DesktopTabsNotifier();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopTabsProvider.overrideWith((ref) => tabs),
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
          gameUpdatesBatchStreamProvider.overrideWith(
            (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
          ),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: EventGamesTable.width,
            height: 700,
            child: EventGamesTable(tabId: 'tournaments-default'),
          ),
        ),
      ),
    );
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (repository.roundCatalogCalls.isNotEmpty) break;
    }
    expect(repository.roundCatalogCalls, <String>['tour-1']);

    tabs.open(TabKind.library, title: 'Library', reuseExisting: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(repository.roundCatalogCalls, <String>['tour-1']);

    tabs.activate('tournaments-default');
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (repository.roundCatalogCalls.length == 2) break;
    }
    expect(repository.roundCatalogCalls, <String>['tour-1', 'tour-1']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(repository.roundCatalogCalls, <String>['tour-1', 'tour-1']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (repository.roundCatalogCalls.length == 3) break;
    }
    expect(repository.roundCatalogCalls, <String>[
      'tour-1',
      'tour-1',
      'tour-1',
    ]);
  });

  testWidgets(
    'catalog shows every round without draining tour pages and hydrates on expand',
    (tester) async {
      List<Games> roundGames(
        int round,
        int count, {
        String status = 'not_started',
        DateTime? startsAt,
        int boardOffset = 0,
      }) => List<Games>.generate(
        count,
        (index) => _game(
          id: 'round-$round-board-${boardOffset + index + 1}',
          roundId: 'round-$round',
          roundName: 'Round $round',
          roundStartsAt: startsAt ?? DateTime.utc(2030, 7, round),
          boardNumber: boardOffset + index + 1,
          status: status,
          pgn: status == 'started' ? '1. e4 e5' : null,
        ),
        growable: false,
      );

      final firstPage = <Games>[
        ...roundGames(
          9,
          1,
          status: 'started',
          startsAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        ...roundGames(8, 21),
        ...roundGames(7, 21),
        ...roundGames(1, 21),
      ];
      final secondPage = <Games>[
        ...roundGames(6, 21),
        ...roundGames(5, 21),
        ...roundGames(4, 21),
        ...roundGames(3, 1),
      ];
      final finalPage = <Games>[
        ...roundGames(3, 8, boardOffset: 1),
        ...roundGames(2, 4),
      ];
      final allGames = <Games>[...firstPage, ...secondPage, ...finalPage];
      final selected = TournamentGameSummary.fromGame(firstPage.first);
      final repository = _FakeGameRepository(
        firstTourPage: firstPage,
        selectedRoundPage: firstPage.take(1).toList(growable: false),
        selectedGame: firstPage.first,
        totalCount: 140,
        roundCatalog: <EventRailRoundMetadata>[
          for (var round = 1; round <= 9; round++)
            EventRailRoundMetadata(
              id: 'round-$round',
              name: 'Round $round',
              startsAt:
                  round == 9
                      ? DateTime.utc(2026, 7, 24)
                      : DateTime.utc(2030, 7, round),
              createdAt: DateTime.utc(2026, 7, round),
              ongoing: false,
            ),
        ],
        tourPagesByOffset: <int, List<Games>>{64: secondPage, 128: finalPage},
        allRoundGames: allGames,
      );
      final args = BoardTabGameArgs(
        gameId: selected.id,
        pgn: '',
        label: selected.name,
        whiteName: selected.whitePlayer,
        blackName: selected.blackPlayer,
        tournamentTitle: 'Nine-round event',
        eventGames: <TournamentGameSummary>[selected],
        eventGamesKey: BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: selected.id,
          selectedRoundId: selected.roundId,
          selectedBoardNumber: selected.boardNumber,
        ),
        gameListSelectedId: selected.id,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gameRepositoryProvider.overrideWithValue(repository),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
            ),
            gameUpdatesBatchStreamProvider.overrideWith(
              (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
            ),
          ],
          child: const MaterialApp(
            home: SizedBox(
              width: EventGamesTable.width,
              height: 700,
              child: EventGamesTable(tabId: 'tournaments-default'),
            ),
          ),
        ),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (repository.roundCatalogCalls.isNotEmpty &&
            find.text('Round 2').evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pump();

      expect(repository.tourPageCalls, <_PageCall>[
        const _PageCall(id: 'tour-1', limit: 64, offset: 0),
      ]);
      expect(repository.roundCatalogCalls, <String>['tour-1']);
      for (var round = 1; round <= 9; round++) {
        expect(
          find.text('Round $round'),
          findsOneWidget,
          reason: 'Round $round must remain represented in the event rail.',
        );
      }

      await tester.tap(find.text('Round 2'));
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (repository.roundIdsPageCalls.isNotEmpty) break;
      }

      expect(repository.roundIdsPageCalls, <_RoundIdsPageCall>[
        const _RoundIdsPageCall(
          ids: <String>['round-2'],
          limit: kEventRailGamesPageSize,
          offset: 0,
        ),
      ]);
      expect(repository.tourPageCalls, hasLength(1));

      await tester.tap(find.text('Round 2'));
      await tester.pump();
      await tester.tap(find.text('Round 2'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        repository.roundIdsPageCalls,
        hasLength(1),
        reason: 'A previously hydrated round must reopen from memory.',
      );

      expect(find.text('Page 1 of 2'), findsOneWidget);
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget.runtimeType.toString() == '_EventGameStatusCell',
            )
            .evaluate(),
        hasLength(lessThanOrEqualTo(kEventRailGamesPageSize)),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('event-rail-next-page')),
      );
      await tester.pump();
      expect(find.text('Page 2 of 2'), findsOneWidget);
      for (var round = 1; round <= 9; round++) {
        expect(
          find.text('Round $round'),
          findsOneWidget,
          reason: 'Round $round must remain visible on every row page.',
        );
      }
      await tester.tap(find.text('Round 2'));
      await tester.pump();
      expect(
        find.text('Page 1 of 2'),
        findsOneWidget,
        reason: 'An expanded off-page header must navigate on the first click.',
      );
      expect(
        repository.roundIdsPageCalls,
        hasLength(1),
        reason: 'Navigating to an expanded hydrated round must not refetch it.',
      );
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('keyboard navigation crosses a lazy page without a full fetch', (
    tester,
  ) async {
    final firstPage = List<Games>.generate(
      kEventRailGamesPageSize,
      (index) =>
          _game(id: 'first-$index', roundId: 'round-1', boardNumber: index + 1),
    );
    final secondPage = List<Games>.generate(
      kEventRailGamesPageSize,
      (index) => _game(
        id: 'second-$index',
        roundId: 'round-1',
        boardNumber: index + kEventRailGamesPageSize + 1,
      ),
    );
    final repository = _FakeGameRepository(
      firstTourPage: firstPage,
      selectedRoundPage: const <Games>[],
      totalCount: kEventRailGamesPageSize * 2,
      continuationFuture: Future<List<Games>>.value(secondPage),
    );
    final summaries = <TournamentGameSummary>[
      for (final game in firstPage) TournamentGameSummary.fromGame(game),
    ];
    final selected = summaries.last;
    final args = BoardTabGameArgs(
      gameId: selected.id,
      pgn: '',
      label: selected.name,
      whiteName: selected.whitePlayer,
      blackName: selected.blackPlayer,
      tournamentTitle: 'Huge event',
      eventGames: summaries,
      eventGamesKey: BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: selected.id,
        selectedRoundId: selected.roundId,
        selectedBoardNumber: selected.boardNumber,
      ),
      gameListSelectedId: selected.id,
    );
    WidgetRef? capturedRef;
    BuildContext? capturedContext;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final container = ProviderScope.containerOf(capturedContext!);
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: 'tournaments-default',
        eventKey: args.eventGamesKey!,
      ),
    );
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);

    await navigateActiveEventGame(
      capturedRef!,
      context: capturedContext!,
      delta: 1,
    );
    await tester.pump();

    final opened =
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'];
    expect(opened?.gameId, 'second-0');
    expect(repository.legacyFullTourCalls, 0);
    expect(repository.tourPageCalls, <_PageCall>[
      const _PageCall(id: 'tour-1', limit: 64, offset: 0),
      const _PageCall(id: 'tour-1', limit: 64, offset: 64),
    ]);
  });

  testWidgets('two rapid navigation commands land two games ahead', (
    tester,
  ) async {
    final games = List<Games>.generate(
      3,
      (index) => _game(
        id: 'game-${index + 1}',
        roundId: 'round-1',
        boardNumber: index + 1,
      ),
      growable: false,
    );
    final repository = _FakeGameRepository(
      firstTourPage: games,
      selectedRoundPage: games,
      selectedGame: games.first,
      totalCount: games.length,
    );
    final summaries = games
        .map(TournamentGameSummary.fromGame)
        .toList(growable: false);
    final selected = summaries.first;
    final args = BoardTabGameArgs(
      gameId: selected.id,
      pgn: '',
      label: selected.name,
      whiteName: selected.whitePlayer,
      blackName: selected.blackPlayer,
      tournamentTitle: 'Rapid navigation event',
      eventGames: summaries,
      eventGamesKey: BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: selected.id,
        selectedRoundId: selected.roundId,
        selectedBoardNumber: selected.boardNumber,
      ),
      gameListSelectedId: selected.id,
    );
    WidgetRef? capturedRef;
    BuildContext? capturedContext;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final container = ProviderScope.containerOf(capturedContext!);
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: 'tournaments-default',
        eventKey: args.eventGamesKey!,
      ),
    );
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);

    final firstCommand = navigateActiveEventGame(
      capturedRef!,
      context: capturedContext!,
      delta: 1,
    );
    final secondCommand = navigateActiveEventGame(
      capturedRef!,
      context: capturedContext!,
      delta: 1,
    );
    await Future.wait(<Future<void>>[firstCommand, secondCommand]);
    await tester.pump();

    final opened =
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'];
    expect(opened?.gameId, 'game-3');
    expect(opened?.gameListSelectedId, 'game-3');
    expect(repository.tourPageCalls, <_PageCall>[
      const _PageCall(id: 'tour-1', limit: 64, offset: 0),
    ]);
    expect(repository.roundCatalogCalls, isEmpty);
    expect(repository.legacyFullTourCalls, 0);
  });

  testWidgets('navigation waits for an in-flight continuation page', (
    tester,
  ) async {
    final firstPage = List<Games>.generate(
      kEventRailGamesPageSize,
      (index) =>
          _game(id: 'first-$index', roundId: 'round-1', boardNumber: index + 1),
      growable: false,
    );
    final secondPage = List<Games>.generate(
      kEventRailGamesPageSize,
      (index) => _game(
        id: 'second-$index',
        roundId: 'round-1',
        boardNumber: index + kEventRailGamesPageSize + 1,
      ),
      growable: false,
    );
    final continuation = Completer<List<Games>>();
    final repository = _FakeGameRepository(
      firstTourPage: firstPage,
      selectedRoundPage: firstPage,
      selectedGame: firstPage.last,
      totalCount: firstPage.length + secondPage.length,
      continuationFuture: continuation.future,
    );
    final summaries = firstPage
        .map(TournamentGameSummary.fromGame)
        .toList(growable: false);
    final selected = summaries.last;
    final args = BoardTabGameArgs(
      gameId: selected.id,
      pgn: '',
      label: selected.name,
      whiteName: selected.whitePlayer,
      blackName: selected.blackPlayer,
      tournamentTitle: 'Paginated event',
      eventGames: summaries,
      eventGamesKey: BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: selected.id,
        selectedRoundId: selected.roundId,
        selectedBoardNumber: selected.boardNumber,
      ),
      gameListSelectedId: selected.id,
    );
    WidgetRef? capturedRef;
    BuildContext? capturedContext;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final container = ProviderScope.containerOf(capturedContext!);
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: 'tournaments-default',
        eventKey: args.eventGamesKey!,
      ),
    );
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);

    final pageLoad = container.read(provider.notifier).loadMore();
    var navigationCompleted = false;
    final navigation = navigateActiveEventGame(
      capturedRef!,
      context: capturedContext!,
      delta: 1,
    ).whenComplete(() => navigationCompleted = true);
    await tester.pump();

    expect(navigationCompleted, isFalse);
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)['tournaments-default']
          ?.gameId,
      selected.id,
    );
    expect(container.read(provider).requireValue.isLoadingMore, isTrue);

    continuation.complete(secondPage);
    expect(await pageLoad, isTrue);
    await navigation;
    expect(navigationCompleted, isTrue);
    await tester.pump();

    final opened =
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'];
    expect(opened?.gameId, 'second-0');
    expect(opened?.gameListSelectedId, 'second-0');
    expect(repository.tourPageCalls, <_PageCall>[
      const _PageCall(id: 'tour-1', limit: 64, offset: 0),
      const _PageCall(id: 'tour-1', limit: 64, offset: 64),
    ]);
    expect(repository.legacyFullTourCalls, 0);
  });

  testWidgets('keyboard navigation re-centers a sparse selected-round window', (
    tester,
  ) async {
    final allGames = List<Games>.generate(
      1092,
      (index) => _game(
        id: 'game-${index + 1}',
        roundId: 'round-1',
        boardNumber: index + 1,
      ),
    );
    final initialWindow = allGames.sublist(467, 531);
    final recenteredWindow = allGames.sublist(435, 499);
    final repository = _FakeGameRepository(
      firstTourPage: allGames.take(kEventRailGamesPageSize).toList(),
      selectedRoundPage: initialWindow,
      roundPagesByOffset: <int, List<Games>>{435: recenteredWindow},
      totalCount: allGames.length,
      selectedGame: allGames[499],
    );
    final selected = TournamentGameSummary.fromGame(allGames[499]);
    final args = BoardTabGameArgs(
      gameId: selected.id,
      pgn: '',
      label: selected.name,
      whiteName: selected.whitePlayer,
      blackName: selected.blackPlayer,
      tournamentTitle: 'Huge event',
      eventGames: <TournamentGameSummary>[
        for (final game in <Games>[
          ...allGames.take(kEventRailGamesPageSize),
          ...initialWindow,
        ])
          TournamentGameSummary.fromGame(game),
      ],
      eventGamesKey: BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: selected.id,
        selectedRoundId: selected.roundId,
        selectedBoardNumber: selected.boardNumber,
      ),
      gameListSelectedId: selected.id,
    );
    WidgetRef? capturedRef;
    BuildContext? capturedContext;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repository),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final container = ProviderScope.containerOf(capturedContext!);
    final provider = eventRailGamesProvider(
      EventRailGamesProviderKey(
        ownerId: 'tournaments-default',
        eventKey: args.eventGamesKey!,
      ),
    );
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);

    final boundary = TournamentGameSummary.fromGame(allGames[467]);
    final boundaryKey = BoardTabEventGamesKey(
      tourId: 'tour-1',
      selectedGameId: boundary.id,
      selectedRoundId: boundary.roundId,
      selectedBoardNumber: boundary.boardNumber,
    );
    container.read(boardTabGameArgsByTabIdProvider.notifier).update((tabs) {
      return <String, BoardTabGameArgs>{
        ...tabs,
        'tournaments-default': args.copyWith(
          gameId: boundary.id,
          gameListSelectedId: boundary.id,
          eventGamesKey: boundaryKey,
        ),
      };
    });

    await navigateActiveEventGame(
      capturedRef!,
      context: capturedContext!,
      delta: -1,
    );
    await tester.pump();

    final opened =
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'];
    expect(opened?.gameId, 'game-467');
    expect(repository.legacyFullTourCalls, 0);
    expect(repository.roundPageCalls, <_PageCall>[
      const _PageCall(id: 'round-1', limit: 64, offset: 467),
      const _PageCall(id: 'round-1', limit: 64, offset: 435),
    ]);
  });

  testWidgets(
    'cross-round navigation hydrates lightweight gaps before moving',
    (tester) async {
      final allGames = <Games>[
        for (var round = 1; round <= 6; round++)
          for (var board = 1; board <= 40; board++)
            _game(
              id: 'round-$round-board-$board',
              roundId: 'round-$round',
              roundName: 'Stage ${String.fromCharCode(64 + round)}',
              roundStartsAt: DateTime.utc(
                2026,
                8,
                1,
              ).add(Duration(days: round - 1)),
              boardNumber: board,
            ),
      ];
      final roundFive = allGames
          .where((game) => game.roundId == 'round-5')
          .toList(growable: false);
      final pages = <int, List<Games>>{
        for (
          var offset = kEventRailGamesPageSize;
          offset < allGames.length;
          offset += kEventRailGamesPageSize
        )
          offset: allGames.sublist(
            offset,
            math.min(offset + kEventRailGamesPageSize, allGames.length),
          ),
      };
      final repository = _FakeGameRepository(
        firstTourPage: allGames.take(kEventRailGamesPageSize).toList(),
        selectedRoundPage: roundFive,
        selectedGame: roundFive.first,
        totalCount: allGames.length,
        tourPagesByOffset: pages,
        allRoundGames: allGames,
        roundCatalog: <EventRailRoundMetadata>[
          for (var round = 1; round <= 6; round++)
            EventRailRoundMetadata(
              id: 'round-$round',
              name: 'Stage ${String.fromCharCode(64 + round)}',
              startsAt: DateTime.utc(2026, 8, 1).add(Duration(days: round - 1)),
              createdAt: DateTime.utc(2026, 7, round),
              ongoing: false,
            ),
        ],
      );
      final selected = TournamentGameSummary.fromGame(roundFive.first);
      final args = BoardTabGameArgs(
        gameId: selected.id,
        pgn: '',
        label: selected.name,
        whiteName: selected.whitePlayer,
        blackName: selected.blackPlayer,
        tournamentTitle: 'Six-stage event',
        eventGames: <TournamentGameSummary>[
          for (final game in <Games>[
            ...allGames.take(kEventRailGamesPageSize),
            ...roundFive,
          ])
            TournamentGameSummary.fromGame(game),
        ],
        eventGamesKey: BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: selected.id,
          selectedRoundId: selected.roundId,
          selectedBoardNumber: selected.boardNumber,
        ),
        gameListSelectedId: selected.id,
      );
      WidgetRef? capturedRef;
      BuildContext? capturedContext;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gameRepositoryProvider.overrideWithValue(repository),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                capturedRef = ref;
                capturedContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final container = ProviderScope.containerOf(capturedContext!);
      final provider = eventRailGamesProvider(
        EventRailGamesProviderKey(
          ownerId: 'tournaments-default',
          eventKey: args.eventGamesKey!,
        ),
      );
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(provider.future);

      await navigateActiveEventGame(
        capturedRef!,
        context: capturedContext!,
        delta: -1,
      );
      await tester.pump();

      var opened =
          container.read(
            boardTabGameArgsByTabIdProvider,
          )['tournaments-default'];
      expect(opened?.gameId, 'round-4-board-40');
      expect(repository.legacyFullTourCalls, 0);
      expect(repository.tourPageCalls, <_PageCall>[
        const _PageCall(id: 'tour-1', limit: 64, offset: 0),
      ]);
      expect(repository.roundCatalogCalls, <String>['tour-1']);
      expect(repository.roundIdsPageCalls, <_RoundIdsPageCall>[
        const _RoundIdsPageCall(ids: <String>['round-5'], limit: 64, offset: 0),
        const _RoundIdsPageCall(ids: <String>['round-4'], limit: 64, offset: 0),
      ]);

      final lastRoundFive = TournamentGameSummary.fromGame(roundFive.last);
      final lastRoundFiveKey = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: lastRoundFive.id,
        selectedRoundId: lastRoundFive.roundId,
        selectedBoardNumber: lastRoundFive.boardNumber,
      );
      container.read(boardTabGameArgsByTabIdProvider.notifier).update((tabs) {
        return <String, BoardTabGameArgs>{
          ...tabs,
          'tournaments-default': args.copyWith(
            gameId: lastRoundFive.id,
            gameListSelectedId: lastRoundFive.id,
            eventGamesKey: lastRoundFiveKey,
          ),
        };
      });

      await navigateActiveEventGame(
        capturedRef!,
        context: capturedContext!,
        delta: 1,
      );
      await tester.pump();

      opened =
          container.read(
            boardTabGameArgsByTabIdProvider,
          )['tournaments-default'];
      expect(opened?.gameId, 'round-6-board-1');
      expect(repository.tourPageCalls, hasLength(1));
      expect(repository.roundCatalogCalls, <String>['tour-1', 'tour-1']);
      expect(
        repository.roundIdsPageCalls.last,
        const _RoundIdsPageCall(ids: <String>['round-6'], limit: 64, offset: 0),
      );
    },
  );

  group('eventRailGamesProvider', () {
    test('loads one bounded metadata seed around the selected board', () async {
      final repository = _FakeGameRepository(
        firstTourPage: List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        ),
        selectedRoundPage: List<Games>.generate(kEventRailGamesPageSize, (
          index,
        ) {
          final boardNumber = 118 + index;
          return _game(
            id:
                boardNumber == 150
                    ? 'selected-game'
                    : 'selected-round-$boardNumber',
            roundId: 'selected-round',
            boardNumber: boardNumber,
          );
        }, growable: false),
        totalCount: 128,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(
        tourId: ' tour-1 ',
        selectedGameId: 'selected-game',
        selectedRoundId: ' selected-round ',
        selectedBoardNumber: 150,
      );
      final state = await container.read(
        eventRailGamesProvider(_providerKey(key)).future,
      );

      expect(repository.tourPageCalls, const <_PageCall>[
        _PageCall(id: 'tour-1', limit: 64, offset: 0),
      ]);
      expect(repository.roundPageCalls, const <_PageCall>[
        _PageCall(id: 'selected-round', limit: 64, offset: 117),
      ]);
      expect(repository.countCalls, const <String>['tour-1']);
      expect(repository.selectedGameCalls, const <String>['selected-game']);

      final selected = state.games.singleWhere(
        (game) => game.id == 'selected-game',
      );
      expect(selected.roundId, 'selected-round');
      expect(selected.boardNumber, 150);
      expect(
        state.games.where((game) => game.roundId == 'selected-round'),
        hasLength(kEventRailGamesPageSize),
      );
      expect(
        state.games,
        everyElement(
          isA<dynamic>()
              .having((game) => game.hasPgn, 'hasPgn', isFalse)
              .having((game) => game.pgn, 'pgn', isNull),
        ),
      );
      expect(state.nextOffset, kEventRailGamesPageSize);
      expect(state.totalCount, 128);
      expect(state.hasMore, isTrue);
      expect(state.isLoadingMore, isFalse);
    });

    test(
      'centers duplicate sparse board numbers by selected id rank',
      () async {
        final roundGames = <Games>[
          for (var index = 0; index < 90; index++)
            _game(
              id: 'sparse-${index.toString().padLeft(3, '0')}',
              roundId: 'selected-round',
              boardNumber: (index + 1) * 10,
            ),
          _game(
            id: 'duplicate-a',
            roundId: 'selected-round',
            boardNumber: 1000,
          ),
          _game(
            id: 'duplicate-b',
            roundId: 'selected-round',
            boardNumber: 1000,
          ),
          _game(
            id: 'duplicate-c',
            roundId: 'selected-round',
            boardNumber: 1000,
          ),
          for (var index = 0; index < 20; index++)
            _game(
              id: 'tail-${index.toString().padLeft(3, '0')}',
              roundId: 'selected-round',
              boardNumber: 1010 + index * 10,
            ),
        ]..sort(_compareFakeEventRailRows);
        final selectedIndex = roundGames.indexWhere(
          (game) => game.id == 'duplicate-b',
        );
        final expectedOffset = selectedIndex - kEventRailGamesPageSize ~/ 2;
        final selectedWindow = roundGames.sublist(
          expectedOffset,
          math.min(expectedOffset + kEventRailGamesPageSize, roundGames.length),
        );
        final repository = _FakeGameRepository(
          firstTourPage: const <Games>[],
          selectedRoundPage: selectedWindow,
          selectedGame: roundGames[selectedIndex],
          totalCount: roundGames.length,
          roundPagesByOffset: <int, List<Games>>{
            expectedOffset: selectedWindow,
          },
          allRoundGames: roundGames,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: 'duplicate-b',
          selectedRoundId: 'selected-round',
          selectedBoardNumber: 1000,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        final state = await container.read(provider.future);

        expect(selectedIndex, greaterThan(kEventRailGamesPageSize));
        expect(repository.selectedOffsetCalls, const <_SelectedOffsetCall>[
          _SelectedOffsetCall(
            roundId: 'selected-round',
            selectedGameId: 'duplicate-b',
            selectedBoardNumber: 1000,
          ),
        ]);
        expect(repository.roundPageCalls, <_PageCall>[
          _PageCall(
            id: 'selected-round',
            limit: kEventRailGamesPageSize,
            offset: expectedOffset,
          ),
        ]);
        expect(
          state.games.map((game) => game.id),
          containsAll(<String>['duplicate-a', 'duplicate-b', 'duplicate-c']),
        );
        expect(
          await container.read(provider.notifier).ensureNavigationAdjacency(-1),
          isTrue,
        );
        expect(
          await container.read(provider.notifier).ensureNavigationAdjacency(1),
          isTrue,
        );
      },
    );

    test('centers null board numbers by selected id rank', () async {
      final roundGames = <Games>[
        for (var index = 0; index < 100; index++)
          _game(
            id: 'numbered-${index.toString().padLeft(3, '0')}',
            roundId: 'selected-round',
            boardNumber: (index + 1) * 5,
          ),
        for (var index = 0; index < 10; index++)
          _game(
            id: 'null-${index.toString().padLeft(3, '0')}',
            roundId: 'selected-round',
            boardNumber: null,
          ),
      ]..sort(_compareFakeEventRailRows);
      final selectedIndex = roundGames.indexWhere(
        (game) => game.id == 'null-005',
      );
      final expectedOffset = selectedIndex - kEventRailGamesPageSize ~/ 2;
      final selectedWindow = roundGames.sublist(
        expectedOffset,
        math.min(expectedOffset + kEventRailGamesPageSize, roundGames.length),
      );
      final repository = _FakeGameRepository(
        firstTourPage: const <Games>[],
        selectedRoundPage: selectedWindow,
        selectedGame: roundGames[selectedIndex],
        totalCount: roundGames.length,
        roundPagesByOffset: <int, List<Games>>{expectedOffset: selectedWindow},
        allRoundGames: roundGames,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'null-005',
        selectedRoundId: 'selected-round',
      );
      final provider = eventRailGamesProvider(_providerKey(key));
      final state = await container.read(provider.future);

      expect(selectedIndex, greaterThan(kEventRailGamesPageSize));
      expect(repository.selectedOffsetCalls, const <_SelectedOffsetCall>[
        _SelectedOffsetCall(
          roundId: 'selected-round',
          selectedGameId: 'null-005',
          selectedBoardNumber: null,
        ),
      ]);
      expect(repository.roundPageCalls, <_PageCall>[
        _PageCall(
          id: 'selected-round',
          limit: kEventRailGamesPageSize,
          offset: expectedOffset,
        ),
      ]);
      expect(
        state.games.map((game) => game.id),
        containsAll(<String>['null-004', 'null-005', 'null-006']),
      );
      expect(
        await container.read(provider.notifier).ensureNavigationAdjacency(-1),
        isTrue,
      );
      expect(
        await container.read(provider.notifier).ensureNavigationAdjacency(1),
        isTrue,
      );
    });

    test(
      'one-round stage hydrates its own missing same-round neighbor',
      () async {
        final roundGames = List<Games>.generate(
          kEventRailGamesPageSize + 1,
          (index) => _game(
            id: 'round-game-${(index + 1).toString().padLeft(3, '0')}',
            roundId: 'round-1',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final selected = roundGames[kEventRailGamesPageSize - 1];
        final centeredOffset =
            kEventRailGamesPageSize - 1 - kEventRailGamesPageSize ~/ 2;
        final staleWindow = roundGames.take(kEventRailGamesPageSize).toList();
        final repository = _FakeGameRepository(
          firstTourPage: staleWindow,
          selectedRoundPage: staleWindow,
          selectedGame: selected,
          totalCount: roundGames.length,
          roundPagesByOffset: <int, List<Games>>{centeredOffset: staleWindow},
          allRoundGames: roundGames,
          roundCatalog: <EventRailRoundMetadata>[
            EventRailRoundMetadata(
              id: 'round-1',
              name: 'Round 1',
              startsAt: DateTime.utc(2026, 7, 18),
              createdAt: DateTime.utc(2026, 7, 18),
              ongoing: true,
            ),
          ],
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        final key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: selected.id,
          selectedRoundId: 'round-1',
          selectedBoardNumber: selected.boardNr,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        await container.read(provider.future);

        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          isNot(contains(roundGames.last.id)),
        );
        expect(
          await container.read(provider.notifier).ensureNavigationAdjacency(1),
          isTrue,
        );
        expect(repository.roundIdsPageCalls, const <_RoundIdsPageCall>[
          _RoundIdsPageCall(ids: <String>['round-1'], limit: 64, offset: 1),
        ]);
        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          contains(roundGames.last.id),
        );
      },
    );

    test(
      'publishes no partial initial state in any request completion order',
      () async {
        final tourPage = Completer<List<Games>>();
        final roundPage = Completer<List<Games>>();
        final selectedGame = Completer<Games>();
        final count = Completer<int>();
        final repository = _FakeGameRepository(
          firstTourPage: const <Games>[],
          selectedRoundPage: const <Games>[],
          totalCount: 0,
          initialTourFuture: tourPage.future,
          initialRoundFuture: roundPage.future,
          selectedGameFuture: selectedGame.future,
          countFuture: count.future,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: 'selected-game',
          selectedRoundId: 'selected-round',
          selectedBoardNumber: 7,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        final publishedLengths = <int>[];
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, next) {
            final value = next.valueOrNull;
            if (value != null) publishedLengths.add(value.games.length);
          },
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        final initial = container.read(provider.future);
        await Future<void>.delayed(Duration.zero);

        expect(repository.tourPageCalls, hasLength(1));
        expect(repository.roundPageCalls, hasLength(1));
        expect(repository.selectedGameCalls, <String>['selected-game']);
        expect(repository.countCalls, <String>['tour-1']);
        expect(container.read(provider).isLoading, isTrue);
        expect(publishedLengths, isEmpty);

        count.complete(3);
        await container.pump();
        expect(container.read(provider).isLoading, isTrue);
        expect(publishedLengths, isEmpty);

        selectedGame.complete(
          _game(id: 'selected-game', roundId: 'selected-round', boardNumber: 7),
        );
        await container.pump();
        expect(container.read(provider).isLoading, isTrue);
        expect(publishedLengths, isEmpty);

        tourPage.complete(<Games>[
          _game(id: 'tour-game', roundId: 'round-1', boardNumber: 1),
        ]);
        await container.pump();
        expect(container.read(provider).isLoading, isTrue);
        expect(publishedLengths, isEmpty);

        roundPage.complete(<Games>[
          _game(id: 'round-game', roundId: 'selected-round', boardNumber: 8),
        ]);
        final state = await initial;

        expect(state.games.map((game) => game.id), <String>[
          'selected-game',
          'round-game',
          'tour-game',
        ]);
        expect(state.totalCount, 3);
        expect(publishedLengths, <int>[3]);
      },
    );

    test(
      'keeps an exact sparse selected row outside the board-number window',
      () async {
        final selected = _game(
          id: 'selected-sparse-game',
          roundId: 'selected-round',
          boardNumber: null,
        );
        final repository = _FakeGameRepository(
          firstTourPage: List<Games>.generate(
            kEventRailGamesPageSize,
            (index) => _game(
              id: 'tour-first-$index',
              roundId: 'round-first',
              boardNumber: index + 1,
            ),
            growable: false,
          ),
          selectedRoundPage: List<Games>.generate(
            kEventRailGamesPageSize,
            (index) => _game(
              id: 'sparse-round-$index',
              roundId: 'selected-round',
              boardNumber: index.isEven ? null : 1,
            ),
            growable: false,
          ),
          selectedGame: selected,
          totalCount: 130,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: 'selected-sparse-game',
          selectedRoundId: 'selected-round',
        );
        final state = await container.read(
          eventRailGamesProvider(_providerKey(key)).future,
        );

        expect(repository.selectedGameCalls, <String>['selected-sparse-game']);
        expect(
          state.games.where((game) => game.id == 'selected-sparse-game'),
          hasLength(1),
        );
        expect(
          state.games
              .singleWhere((game) => game.id == 'selected-sparse-game')
              .boardNumber,
          isNull,
        );
      },
    );

    test(
      'coalesces concurrent continuation and publishes the complete page once',
      () async {
        final continuationCompleter = Completer<List<Games>>();
        final firstTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final selectedRoundPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) {
            final boardNumber = 118 + index;
            return _game(
              id:
                  boardNumber == 150
                      ? 'selected-game'
                      : 'selected-round-$boardNumber',
              roundId: 'selected-round',
              boardNumber: boardNumber,
            );
          },
          growable: false,
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstTourPage,
          selectedRoundPage: selectedRoundPage,
          totalCount: 128,
          continuationFuture: continuationCompleter.future,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(
          tourId: ' tour-1 ',
          selectedGameId: 'selected-game',
          selectedRoundId: 'selected-round',
          selectedBoardNumber: 150,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final initial = await container.read(provider.future);
        final publishedGameIds = <List<String>>[];
        final stateSubscription = container
            .listen<AsyncValue<EventRailGamesState>>(provider, (_, next) {
              final value = next.valueOrNull;
              if (value != null) {
                publishedGameIds.add(
                  value.games.map((game) => game.id).toList(growable: false),
                );
              }
            }, fireImmediately: true);
        addTearDown(stateSubscription.close);

        final notifier = container.read(provider.notifier);
        final firstLoadMore = notifier.loadMore();
        final duplicateLoadMore = notifier.loadMore();

        expect(repository.tourPageCalls, const <_PageCall>[
          _PageCall(id: 'tour-1', limit: 64, offset: 0),
          _PageCall(id: 'tour-1', limit: 64, offset: 64),
        ]);
        final pending = container.read(provider).requireValue;
        expect(pending.isLoadingMore, isTrue);
        expect(pending.games, same(initial.games));
        expect(
          pending.games.map((game) => game.id),
          initial.games.map((game) => game.id),
        );
        expect(publishedGameIds.map((ids) => ids.length), <int>[
          initial.games.length,
          initial.games.length,
        ]);

        continuationCompleter.complete(<Games>[
          _game(
            id: 'selected-game',
            roundId: 'selected-round',
            boardNumber: 150,
          ),
          ...List<Games>.generate(
            kEventRailGamesPageSize - 1,
            (index) => _game(
              id: 'tour-second-$index',
              roundId: 'round-second',
              boardNumber: index + 1,
            ),
            growable: false,
          ),
        ]);
        final loadResults = await Future.wait(<Future<bool>>[
          firstLoadMore,
          duplicateLoadMore,
        ]);

        final completed = container.read(provider).requireValue;
        expect(loadResults, <bool>[true, true]);
        final completedIds = completed.games.map((game) => game.id).toList();
        expect(completed.isLoadingMore, isFalse);
        expect(completed.nextOffset, 128);
        expect(completed.totalCount, 128);
        expect(completed.hasMore, isFalse);
        expect(completedIds, hasLength(initial.games.length + 63));
        expect(completedIds.toSet(), hasLength(completedIds.length));
        expect(completedIds.where((id) => id == 'selected-game'), hasLength(1));
        expect(
          completedIds,
          containsAll(
            List<String>.generate(
              kEventRailGamesPageSize - 1,
              (index) => 'tour-second-$index',
            ),
          ),
        );
        expect(publishedGameIds.map((ids) => ids.length), <int>[
          initial.games.length,
          initial.games.length,
          initial.games.length + 63,
        ]);
      },
    );

    test('traverses 1,092 rows without omissions or duplicate ids', () async {
      final allGames = List<Games>.generate(
        1092,
        (index) => _game(
          id: 'huge-$index',
          roundId: 'round-${index ~/ 100}',
          boardNumber: index + 1,
        ),
      );
      final pagesByOffset = <int, List<Games>>{
        for (
          var offset = kEventRailGamesPageSize;
          offset < allGames.length;
          offset += kEventRailGamesPageSize
        )
          offset: allGames.sublist(
            offset,
            math.min(offset + kEventRailGamesPageSize, allGames.length),
          ),
      };
      final repository = _FakeGameRepository(
        firstTourPage: allGames.take(kEventRailGamesPageSize).toList(),
        selectedRoundPage: const <Games>[],
        totalCount: allGames.length,
        tourPagesByOffset: pagesByOffset,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(tourId: 'tour-1');
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);
      while (container.read(provider).requireValue.hasMore) {
        expect(await notifier.loadMore(), isTrue);
      }

      final loaded = container.read(provider).requireValue.games;
      final ids = loaded.map((game) => game.id).toList(growable: false);
      expect(ids, hasLength(1092));
      expect(ids.toSet(), hasLength(1092));
      expect(ids.toSet(), allGames.map((game) => game.id).toSet());
    });

    test('keeps the complete page and reports a failed continuation', () async {
      final continuationCompleter = Completer<List<Games>>();
      final firstTourPage = List<Games>.generate(
        kEventRailGamesPageSize,
        (index) => _game(
          id: 'tour-first-$index',
          roundId: 'round-first',
          boardNumber: index + 1,
        ),
        growable: false,
      );
      final repository = _FakeGameRepository(
        firstTourPage: firstTourPage,
        selectedRoundPage: const <Games>[],
        totalCount: 128,
        continuationFuture: continuationCompleter.future,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(tourId: 'tour-1');
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initial = await container.read(provider.future);
      final load = container.read(provider.notifier).loadMore();
      continuationCompleter.completeError(StateError('page unavailable'));

      expect(await load, isFalse);
      final failed = container.read(provider).requireValue;
      expect(failed.games, same(initial.games));
      expect(failed.nextOffset, initial.nextOffset);
      expect(failed.hasMore, isTrue);
      expect(failed.isLoadingMore, isFalse);
      expect(failed.loadMoreError, contains('page unavailable'));
    });

    test('bounded safety refresh discovers set changes atomically', () async {
      final firstTourPage = List<Games>.generate(
        kEventRailGamesPageSize,
        (index) => _game(
          id: 'tour-first-$index',
          roundId: 'round-first',
          boardNumber: index + 1,
        ),
        growable: false,
      );
      final repository = _FakeGameRepository(
        firstTourPage: firstTourPage,
        selectedRoundPage: const <Games>[],
        totalCount: kEventRailGamesPageSize,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(tourId: 'tour-1');
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initial = await container.read(provider.future);
      expect(initial.hasMore, isFalse);

      repository
        ..firstTourPage = <Games>[
          _game(id: 'new-game', roundId: 'new-round', boardNumber: 1),
          ...firstTourPage.take(kEventRailGamesPageSize - 1),
        ]
        ..totalCount = kEventRailGamesPageSize + 1;
      final publishedIds = <List<String>>[];
      final stateSubscription = container
          .listen<AsyncValue<EventRailGamesState>>(provider, (_, next) {
            final value = next.valueOrNull;
            if (value != null) {
              publishedIds.add(
                value.games.map((game) => game.id).toList(growable: false),
              );
            }
          });
      addTearDown(stateSubscription.close);

      expect(
        await container.read(provider.notifier).refreshLoadedMetadata(),
        isTrue,
      );

      final refreshed = container.read(provider).requireValue;
      expect(refreshed.games.first.id, 'new-game');
      expect(refreshed.games, hasLength(kEventRailGamesPageSize + 1));
      expect(
        refreshed.games.map((game) => game.id),
        contains('tour-first-${kEventRailGamesPageSize - 1}'),
      );
      expect(refreshed.nextOffset, kEventRailGamesPageSize);
      expect(refreshed.totalCount, kEventRailGamesPageSize + 1);
      expect(refreshed.hasMore, isTrue);
      expect(publishedIds, hasLength(1));
      expect(publishedIds.single.first, 'new-game');
      expect(
        await container.read(provider.notifier).refreshLoadedMetadata(),
        isTrue,
      );
      expect(publishedIds, hasLength(1));
      expect(repository.tourPageCalls, const <_PageCall>[
        _PageCall(id: 'tour-1', limit: 64, offset: 0),
        _PageCall(id: 'tour-1', limit: 64, offset: 0),
        _PageCall(id: 'tour-1', limit: 64, offset: 0),
      ]);
    });

    test('metadata refresh cannot regress a known terminal result', () async {
      final repository = _FakeGameRepository(
        firstTourPage: <Games>[
          _game(
            id: 'finished-game',
            roundId: 'round-1',
            boardNumber: 1,
            status: '1-0',
          ),
        ],
        selectedRoundPage: const <Games>[],
        totalCount: 1,
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      const key = BoardTabEventGamesKey(tourId: 'tour-1');
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await container.read(provider.future);
      repository.firstTourPage = <Games>[
        _game(
          id: 'finished-game',
          roundId: 'round-1',
          boardNumber: 1,
          status: 'future-server-value',
        ),
      ];
      expect(
        await container.read(provider.notifier).refreshLoadedMetadata(),
        isTrue,
      );

      expect(
        container.read(provider).requireValue.games.single.status,
        GameStatus.whiteWins,
      );
    });

    test(
      'safety refresh stays bounded after pagination and keeps later pages',
      () async {
        final firstTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final secondTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-second-$index',
            roundId: 'round-second',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstTourPage,
          selectedRoundPage: <Games>[
            _game(
              id: 'selected-game',
              roundId: 'selected-round',
              boardNumber: 150,
            ),
          ],
          totalCount: kEventRailGamesPageSize * 3,
          continuationFuture: Future<List<Games>>.value(secondTourPage),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedRoundId: 'selected-round',
          selectedBoardNumber: 150,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await container.read(provider.future);
        expect(await container.read(provider.notifier).loadMore(), isTrue);
        final paginated = container.read(provider).requireValue;
        expect(paginated.nextOffset, kEventRailGamesPageSize * 2);
        expect(
          paginated.games.map((game) => game.id),
          contains('tour-second-0'),
        );

        repository
          ..tourPageCalls.clear()
          ..roundPageCalls.clear()
          ..countCalls.clear();

        expect(
          await container.read(provider.notifier).refreshLoadedMetadata(),
          isTrue,
        );

        final refreshed = container.read(provider).requireValue;
        expect(repository.tourPageCalls, const <_PageCall>[
          _PageCall(id: 'tour-1', limit: 64, offset: 0),
          _PageCall(id: 'tour-1', limit: 64, offset: 64),
        ]);
        expect(repository.roundPageCalls, const <_PageCall>[
          _PageCall(id: 'selected-round', limit: 64, offset: 117),
        ]);
        expect(repository.countCalls, const <String>['tour-1']);
        expect(refreshed.nextOffset, kEventRailGamesPageSize * 2);
        expect(refreshed.hasMore, isTrue);
        expect(
          refreshed.games.map((game) => game.id),
          contains('tour-second-0'),
        );
      },
    );

    test(
      'count changes reset the cursor before a shifted later page is loaded',
      () async {
        final firstTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final secondTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-second-$index',
            roundId: 'round-second',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstTourPage,
          selectedRoundPage: const <Games>[],
          totalCount: kEventRailGamesPageSize * 3,
          continuationFuture: Future<List<Games>>.value(secondTourPage),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await container.read(provider.future);
        expect(await container.read(provider.notifier).loadMore(), isTrue);
        expect(
          container.read(provider).requireValue.nextOffset,
          kEventRailGamesPageSize * 2,
        );

        repository
          ..totalCount = kEventRailGamesPageSize * 3 + 1
          ..continuationFuture = Future<List<Games>>.value(<Games>[
            _game(
              id: 'new-page-two-game',
              roundId: 'round-second',
              boardNumber: 1,
            ),
            ...secondTourPage.take(kEventRailGamesPageSize - 1),
          ]);

        expect(
          await container.read(provider.notifier).refreshLoadedMetadata(),
          isTrue,
        );
        final reset = container.read(provider).requireValue;
        expect(reset.nextOffset, kEventRailGamesPageSize);
        expect(
          reset.games.map((game) => game.id),
          contains('tour-second-0'),
          reason: 'loaded rows remain represented while the cursor revalidates',
        );
        expect(reset.hasMore, isTrue);

        expect(await container.read(provider.notifier).loadMore(), isTrue);
        final reloaded = container.read(provider).requireValue;
        expect(reloaded.nextOffset, kEventRailGamesPageSize * 2);
        expect(
          reloaded.games.map((game) => game.id),
          contains('new-page-two-game'),
        );
      },
    );

    test(
      'first successful count resets a cursor advanced while count was unknown',
      () async {
        final firstTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final secondTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-second-$index',
            roundId: 'round-second',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstTourPage,
          selectedRoundPage: const <Games>[],
          totalCount: kEventRailGamesPageSize * 2 + 1,
          continuationFuture: Future<List<Games>>.value(secondTourPage),
        )..countError = StateError('count unavailable');
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final initial = await container.read(provider.future);
        expect(initial.totalCount, isNull);
        expect(await container.read(provider.notifier).loadMore(), isTrue);
        expect(
          container.read(provider).requireValue.nextOffset,
          kEventRailGamesPageSize * 2,
        );

        repository.countError = null;
        expect(
          await container.read(provider.notifier).refreshLoadedMetadata(),
          isTrue,
        );

        final reset = container.read(provider).requireValue;
        expect(reset.totalCount, kEventRailGamesPageSize * 2 + 1);
        expect(reset.nextOffset, kEventRailGamesPageSize);
        expect(reset.hasMore, isTrue);
      },
    );

    test(
      'same-count later-page replacement resets stale loaded tail rows',
      () async {
        final firstTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-first-$index',
            roundId: 'round-first',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final secondTourPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'tour-second-$index',
            roundId: 'round-second',
            boardNumber: index + 1,
          ),
          growable: false,
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstTourPage,
          selectedRoundPage: const <Games>[],
          totalCount: kEventRailGamesPageSize * 2,
          continuationFuture: Future<List<Games>>.value(secondTourPage),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await container.read(provider.future);
        expect(await container.read(provider.notifier).loadMore(), isTrue);
        expect(container.read(provider).requireValue.hasMore, isFalse);

        repository.continuationFuture = Future<List<Games>>.value(<Games>[
          _game(
            id: 'replacement-game',
            roundId: 'round-second',
            boardNumber: 1,
          ),
          ...secondTourPage.take(kEventRailGamesPageSize - 1),
        ]);

        expect(
          await container.read(provider.notifier).refreshLoadedMetadata(),
          isTrue,
        );
        final reset = container.read(provider).requireValue;
        expect(reset.nextOffset, kEventRailGamesPageSize);
        expect(reset.hasMore, isTrue);
        expect(
          reset.games.map((game) => game.id),
          isNot(contains('replacement-game')),
        );
        expect(
          reset.games.map((game) => game.id),
          contains('tour-second-63'),
          reason: 'the old tail stays visible until the full page is replaced',
        );

        expect(await container.read(provider.notifier).loadMore(), isTrue);
        final reloadedIds = container
            .read(provider)
            .requireValue
            .games
            .map((game) => game.id);
        expect(reloadedIds, contains('replacement-game'));
        expect(reloadedIds, contains('tour-second-62'));
        expect(reloadedIds, isNot(contains('tour-second-63')));
      },
    );

    test('failed safety refresh preserves the selected-round window', () async {
      final firstTourPage = List<Games>.generate(
        kEventRailGamesPageSize,
        (index) => _game(
          id: 'tour-first-$index',
          roundId: 'round-first',
          boardNumber: index + 1,
        ),
        growable: false,
      );
      final selectedRoundPage = <Games>[
        _game(id: 'selected-game', roundId: 'selected-round', boardNumber: 150),
      ];
      final repository = _FakeGameRepository(
        firstTourPage: firstTourPage,
        selectedRoundPage: selectedRoundPage,
        totalCount: kEventRailGamesPageSize,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      const key = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedRoundId: 'selected-round',
        selectedBoardNumber: 150,
      );
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initial = await container.read(provider.future);
      expect(initial.games.map((game) => game.id), contains('selected-game'));
      repository
        ..roundPageError = StateError('round unavailable')
        ..firstTourPage = <Games>[
          _game(id: 'new-game', roundId: 'new-round', boardNumber: 1),
          ...firstTourPage.take(kEventRailGamesPageSize - 1),
        ];

      expect(
        await container.read(provider.notifier).refreshLoadedMetadata(),
        isFalse,
      );
      expect(container.read(provider).requireValue, same(initial));
    });

    test(
      'does not start the safety timer after initial-load disposal',
      () async {
        final initialCompleter = Completer<List<Games>>();
        final repository = _FakeGameRepository(
          firstTourPage: const <Games>[],
          selectedRoundPage: const <Games>[],
          totalCount: 0,
          initialTourFuture: initialCompleter.future,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        final notifier = container.read(provider.notifier);
        final build = container.read(provider.future);

        subscription.close();
        await container.pump();
        initialCompleter.complete(const <Games>[]);
        await build;

        expect(notifier.safetyRefreshScheduled, isFalse);
      },
    );

    test(
      'pauses periodic REST refresh while its Board tab is hidden',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: <Games>[
            _game(id: 'game-1', roundId: 'round-1', boardNumber: 1),
          ],
          selectedRoundPage: const <Games>[],
          totalCount: 1,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final initial = await container.read(provider.future);
        final notifier = container.read(provider.notifier);
        expect(notifier.safetyRefreshScheduled, isTrue);

        final inFlightPage = Completer<List<Games>>();
        repository.initialTourFuture = inFlightPage.future;
        final inFlightRefresh = notifier.refreshLoadedMetadata();
        await Future<void>.delayed(Duration.zero);
        notifier.setForeground(false);
        expect(notifier.safetyRefreshScheduled, isFalse);
        inFlightPage.complete(<Games>[
          _game(id: 'hidden-new-game', roundId: 'round-2', boardNumber: 1),
        ]);
        expect(await inFlightRefresh, isFalse);
        expect(container.read(provider).requireValue, same(initial));
        expect(await notifier.refreshLoadedMetadata(), isFalse);

        repository.initialTourFuture = Future<List<Games>>.value(
          repository.firstTourPage,
        );
        notifier.setForeground(true);
        expect(notifier.safetyRefreshScheduled, isTrue);
      },
    );

    test(
      'app pause stops REST refresh without discarding retained rail rows',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: <Games>[
            _game(id: 'game-1', roundId: 'round-1', boardNumber: 1),
          ],
          selectedRoundPage: const <Games>[],
          totalCount: 1,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final initial = await container.read(provider.future);
        final notifier = container.read(provider.notifier);
        final lifecycle = container.read(
          liveGameStreamingLifecycleProvider.notifier,
        );
        expect(notifier.safetyRefreshScheduled, isTrue);

        lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.safetyRefreshScheduled, isFalse);
        expect(container.read(provider).requireValue, same(initial));
        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          <String>['game-1'],
        );
        expect(await notifier.refreshLoadedMetadata(), isFalse);

        lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.safetyRefreshScheduled, isTrue);
        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          <String>['game-1'],
        );
      },
    );

    test(
      'keeps duplicate Board tabs independent when one tab is hidden',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: <Games>[
            _game(id: 'game-1', roundId: 'round-1', boardNumber: 1),
          ],
          selectedRoundPage: const <Games>[],
          totalCount: 1,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const eventKey = BoardTabEventGamesKey(tourId: 'tour-1');
        final visibleProvider = eventRailGamesProvider(
          _providerKey(eventKey, ownerId: 'visible-tab'),
        );
        final hiddenProvider = eventRailGamesProvider(
          _providerKey(eventKey, ownerId: 'hidden-tab'),
        );
        final visibleSubscription = container
            .listen<AsyncValue<EventRailGamesState>>(
              visibleProvider,
              (_, __) {},
              fireImmediately: true,
            );
        final hiddenSubscription = container
            .listen<AsyncValue<EventRailGamesState>>(
              hiddenProvider,
              (_, __) {},
              fireImmediately: true,
            );
        addTearDown(visibleSubscription.close);
        addTearDown(hiddenSubscription.close);

        await Future.wait([
          container.read(visibleProvider.future),
          container.read(hiddenProvider.future),
        ]);
        final visibleNotifier = container.read(visibleProvider.notifier);
        final hiddenNotifier = container.read(hiddenProvider.notifier);

        hiddenNotifier.setForeground(false);

        expect(visibleNotifier.safetyRefreshScheduled, isTrue);
        expect(hiddenNotifier.safetyRefreshScheduled, isFalse);
        expect(await hiddenNotifier.refreshLoadedMetadata(), isFalse);
      },
    );

    test(
      'discards a pre-hide refresh and publishes the post-resume refresh',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: <Games>[
            _game(id: 'initial', roundId: 'round-1', boardNumber: 1),
          ],
          selectedRoundPage: const <Games>[],
          totalCount: 1,
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(provider.future);
        final notifier = container.read(provider.notifier);

        final hiddenRequest = Completer<List<Games>>();
        repository.initialTourFuture = hiddenRequest.future;
        final staleRefresh = notifier.refreshLoadedMetadata();
        await Future<void>.delayed(Duration.zero);
        notifier.setForeground(false);

        final resumedRequest = Completer<List<Games>>();
        repository.initialTourFuture = resumedRequest.future;
        notifier.setForeground(true);
        hiddenRequest.complete(<Games>[
          _game(id: 'hidden-stale', roundId: 'round-1', boardNumber: 1),
        ]);
        expect(await staleRefresh, isFalse);
        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          isNot(contains('hidden-stale')),
        );

        resumedRequest.complete(<Games>[
          _game(id: 'resumed-fresh', roundId: 'round-1', boardNumber: 1),
        ]);
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (container.read(provider).requireValue.games.first.id ==
              'resumed-fresh') {
            break;
          }
        }
        expect(
          container.read(provider).requireValue.games.first.id,
          'resumed-fresh',
        );
      },
    );

    test(
      'recovers a failed initial canonical page without losing the seed',
      () async {
        final firstPage = <Games>[
          _game(id: 'recovered', roundId: 'round-1', boardNumber: 1),
        ];
        final repository = _FakeGameRepository(
          firstTourPage: firstPage,
          selectedRoundPage: const <Games>[],
          totalCount: 1,
          initialTourFuture: Future<List<Games>>.error(StateError('offline')),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        final failed = await container.read(provider.future);
        expect(failed.games, isEmpty);
        expect(failed.hasMore, isTrue);
        expect(failed.loadMoreError, contains('offline'));

        repository.initialTourFuture = Future<List<Games>>.value(firstPage);
        final notifier = container.read(provider.notifier);
        notifier.setForeground(false);
        notifier.setForeground(true);
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (container.read(provider).requireValue.loadMoreError == null) {
            break;
          }
        }

        final recovered = container.read(provider).requireValue;
        expect(recovered.games.map((game) => game.id), contains('recovered'));
        expect(recovered.loadMoreError, isNull);
        expect(recovered.hasMore, isFalse);
      },
    );

    test(
      'stops pagination after an empty page despite a stale count',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: List<Games>.generate(
            kEventRailGamesPageSize,
            (index) => _game(
              id: 'tour-first-$index',
              roundId: 'round-first',
              boardNumber: index + 1,
            ),
            growable: false,
          ),
          selectedRoundPage: const <Games>[],
          totalCount: kEventRailGamesPageSize + 1,
          continuationFuture: Future<List<Games>>.value(const <Games>[]),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const key = BoardTabEventGamesKey(tourId: 'tour-1');
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await container.read(provider.future);
        final notifier = container.read(provider.notifier);
        await notifier.loadMore();
        await notifier.loadMore();

        final state = container.read(provider).requireValue;
        expect(state.nextOffset, kEventRailGamesPageSize);
        expect(state.hasMore, isFalse);
        expect(repository.tourPageCalls, const <_PageCall>[
          _PageCall(id: 'tour-1', limit: 64, offset: 0),
          _PageCall(id: 'tour-1', limit: 64, offset: 64),
        ]);
      },
    );

    test('uses value equality for equivalent family keys', () {
      const first = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'game-17',
        selectedRoundId: 'round-2',
        selectedBoardNumber: 17,
      );
      const second = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'game-17',
        selectedRoundId: 'round-2',
        selectedBoardNumber: 17,
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(
        eventRailGamesProvider(_providerKey(first)),
        eventRailGamesProvider(_providerKey(second)),
      );
      expect(
        eventRailGamesProvider(_providerKey(first, ownerId: 'other-tab')),
        isNot(eventRailGamesProvider(_providerKey(second))),
      );
    });

    test(
      'same-slug selection changes retain the event cursor across tour ids',
      () async {
        final firstPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'first-$index',
            roundId: 'round-1',
            boardNumber: index + 1,
          ),
        );
        final secondPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'second-$index',
            roundId: 'round-2',
            boardNumber: index + 1,
          ),
        );
        final repository = _FakeGameRepository(
          firstTourPage: firstPage,
          selectedRoundPage: const <Games>[],
          selectedGame: _game(
            id: 'selected-outside-retained-pages',
            roundId: 'round-3',
            boardNumber: 4,
          ),
          totalCount: kEventRailGamesPageSize * 2,
          continuationFuture: Future<List<Games>>.value(secondPage),
        );
        final container = _container(repository);
        addTearDown(container.dispose);

        const firstSelection = BoardTabEventGamesKey(
          tourId: 'tour-fragment-a',
          tourSlug: 'shared-event',
          selectedGameId: 'first-1',
          selectedRoundId: 'round-1',
          selectedBoardNumber: 2,
        );
        const secondSelection = BoardTabEventGamesKey(
          tourId: 'tour-fragment-b',
          tourSlug: 'shared-event',
          selectedGameId: 'selected-outside-retained-pages',
          selectedRoundId: 'round-3',
          selectedBoardNumber: 4,
        );
        final firstProvider = eventRailGamesProvider(
          _providerKey(firstSelection),
        );
        final secondProvider = eventRailGamesProvider(
          _providerKey(secondSelection),
        );
        expect(secondProvider, firstProvider);
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          firstProvider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(firstProvider.future);
        final notifier = container.read(firstProvider.notifier);
        expect(await notifier.loadMore(), isTrue);

        notifier.updateSelection(secondSelection);
        await container.pump();
        final retained = container.read(secondProvider).requireValue;
        expect(retained.nextOffset, kEventRailGamesPageSize * 2);
        expect(
          retained.games.map((game) => game.id),
          contains('selected-outside-retained-pages'),
        );
        expect(repository.selectedGameCalls, <String>[
          'first-1',
          'selected-outside-retained-pages',
        ]);
        expect(repository.countCalls, hasLength(1));
        expect(repository.tourPageCalls, <_PageCall>[
          const _PageCall(id: 'tour-fragment-a', limit: 64, offset: 0),
          const _PageCall(id: 'tour-fragment-a', limit: 64, offset: 64),
        ]);
      },
    );

    test(
      'selection hydration waits for pagination and preserves its completed page',
      () async {
        final firstPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'first-$index',
            roundId: 'round-1',
            boardNumber: index + 1,
          ),
        );
        final secondPage = List<Games>.generate(
          kEventRailGamesPageSize,
          (index) => _game(
            id: 'second-$index',
            roundId: 'round-2',
            boardNumber: index + 1,
          ),
        );
        final continuation = Completer<List<Games>>();
        final roundHydration = Completer<List<Games>>();
        final selectedHydration = Completer<Games>();
        final repository = _FakeGameRepository(
          firstTourPage: firstPage,
          selectedRoundPage: const <Games>[],
          totalCount: kEventRailGamesPageSize * 2,
          continuationFuture: continuation.future,
        );
        final container = _container(repository);
        addTearDown(container.dispose);
        const initialSelection = BoardTabEventGamesKey(tourId: 'tour-1');
        const nextSelection = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: 'second-3',
          selectedRoundId: 'round-2',
          selectedBoardNumber: 4,
        );
        final provider = eventRailGamesProvider(_providerKey(initialSelection));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(provider.future);
        final notifier = container.read(provider.notifier);

        final pageLoad = notifier.loadMore();
        repository
          ..initialRoundFuture = roundHydration.future
          ..selectedGameFuture = selectedHydration.future;
        notifier.updateSelection(nextSelection);
        await Future<void>.delayed(Duration.zero);
        expect(repository.selectedGameCalls, isEmpty);

        continuation.complete(secondPage);
        expect(await pageLoad, isTrue);
        for (
          var attempt = 0;
          attempt < 10 && repository.selectedGameCalls.isEmpty;
          attempt++
        ) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(repository.selectedGameCalls, <String>['second-3']);

        roundHydration.complete(<Games>[secondPage[3]]);
        selectedHydration.complete(secondPage[3]);
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          if (container
              .read(provider)
              .requireValue
              .games
              .any((game) => game.id == 'second-3')) {
            break;
          }
        }

        final completed = container.read(provider).requireValue;
        expect(completed.nextOffset, kEventRailGamesPageSize * 2);
        expect(completed.isLoadingMore, isFalse);
        expect(completed.games.map((game) => game.id), contains('second-63'));
        expect(completed.games.map((game) => game.id).toSet(), hasLength(128));
      },
    );

    test('round expansion waits for the initial bounded seed', () async {
      final initialPage = Completer<List<Games>>();
      final roundTwo = _game(
        id: 'round-2-board-1',
        roundId: 'round-2',
        boardNumber: 1,
      );
      final repository = _FakeGameRepository(
        firstTourPage: const <Games>[],
        selectedRoundPage: const <Games>[],
        totalCount: 1,
        initialTourFuture: initialPage.future,
        allRoundGames: <Games>[roundTwo],
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      final provider = eventRailGamesProvider(
        _providerKey(const BoardTabEventGamesKey(tourId: 'tour-1')),
      );
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final hydration = container.read(provider.notifier).ensureRoundLoaded(
        const <String>['round-2'],
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.roundIdsPageCalls, isEmpty);

      initialPage.complete(<Games>[
        _game(id: 'round-1-board-1', roundId: 'round-1', boardNumber: 1),
      ]);
      await container.read(provider.future);
      expect(await hydration.timeout(const Duration(seconds: 1)), isTrue);
      expect(
        container.read(provider).requireValue.games.map((game) => game.id),
        contains(roundTwo.id),
      );
    });

    test('three rapid round expansions hydrate in FIFO order', () async {
      final first = Completer<List<Games>>();
      final second = Completer<List<Games>>();
      final third = Completer<List<Games>>();
      final repository = _FakeGameRepository(
        firstTourPage: const <Games>[],
        selectedRoundPage: const <Games>[],
        totalCount: 0,
        roundIdsFuturesByKey: <String, Future<List<Games>>>{
          'round-1': first.future,
          'round-2': second.future,
          'round-3': third.future,
        },
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      final provider = eventRailGamesProvider(
        _providerKey(const BoardTabEventGamesKey(tourId: 'tour-1')),
      );
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);

      final hydrations = <Future<bool>>[
        notifier.ensureRoundLoaded(const <String>['round-1']),
        notifier.ensureRoundLoaded(const <String>['round-2']),
        notifier.ensureRoundLoaded(const <String>['round-3']),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.roundIdsPageCalls.map((call) => call.ids.single),
        <String>['round-1'],
      );

      first.complete(<Games>[
        _game(id: 'one', roundId: 'round-1', boardNumber: 1),
      ]);
      expect(await hydrations[0], isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.roundIdsPageCalls.map((call) => call.ids.single),
        <String>['round-1', 'round-2'],
      );
      second.complete(<Games>[
        _game(id: 'two', roundId: 'round-2', boardNumber: 1),
      ]);
      expect(await hydrations[1], isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.roundIdsPageCalls.map((call) => call.ids.single),
        <String>['round-1', 'round-2', 'round-3'],
      );
      third.complete(<Games>[
        _game(id: 'three', roundId: 'round-3', boardNumber: 1),
      ]);
      expect(await hydrations[2].timeout(const Duration(seconds: 1)), isTrue);
      expect(
        container
            .read(provider)
            .requireValue
            .games
            .map((game) => game.id)
            .toSet(),
        containsAll(<String>['one', 'two', 'three']),
      );
    });

    test(
      'empty round hydration is cached and failed hydration retries',
      () async {
        final repository = _FakeGameRepository(
          firstTourPage: const <Games>[],
          selectedRoundPage: const <Games>[],
          totalCount: 0,
        );
        final container = _container(repository);
        addTearDown(container.dispose);
        final provider = eventRailGamesProvider(
          _providerKey(const BoardTabEventGamesKey(tourId: 'tour-1')),
        );
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(provider.future);
        final notifier = container.read(provider.notifier);

        expect(
          await notifier.ensureRoundLoaded(const <String>['empty-round']),
          isTrue,
        );
        expect(
          await notifier.ensureRoundLoaded(const <String>['empty-round']),
          isTrue,
        );
        expect(repository.roundIdsPageCalls, hasLength(1));

        repository
          ..totalCount = 1
          ..allRoundGames = <Games>[
            _game(
              id: 'newly-published',
              roundId: 'empty-round',
              boardNumber: 1,
            ),
          ];
        expect(await notifier.refreshLoadedMetadata(), isTrue);
        expect(
          await notifier.ensureRoundLoaded(const <String>['empty-round']),
          isTrue,
        );
        expect(repository.roundIdsPageCalls, hasLength(2));
        expect(
          container.read(provider).requireValue.games.map((game) => game.id),
          contains('newly-published'),
        );

        repository.roundIdsPageError = StateError('offline');
        expect(
          await notifier.ensureRoundLoaded(const <String>['retry-round']),
          isFalse,
        );
        repository.roundIdsPageError = null;
        expect(
          await notifier.ensureRoundLoaded(const <String>['retry-round']),
          isTrue,
        );
        expect(repository.roundIdsPageCalls, hasLength(4));
      },
    );
  });

  test('selection change rejects stale navigation hydration', () async {
    final catalogCompleter = Completer<List<EventRailRoundMetadata>>();
    final selected = _game(id: 'selected', roundId: 'round-2', boardNumber: 1);
    final repository = _FakeGameRepository(
      firstTourPage: <Games>[selected],
      selectedRoundPage: <Games>[selected],
      selectedGame: selected,
      totalCount: 1,
      roundCatalogFuture: catalogCompleter.future,
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    const key = BoardTabEventGamesKey(
      tourId: 'tour-1',
      selectedGameId: 'selected',
      selectedRoundId: 'round-2',
      selectedBoardNumber: 1,
    );
    final provider = eventRailGamesProvider(_providerKey(key));
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final navigation = notifier.ensureNavigationAdjacency(-1);
    await Future<void>.delayed(Duration.zero);
    expect(repository.roundCatalogCalls, <String>['tour-1']);
    notifier.updateSelection(
      const BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'replacement',
        selectedRoundId: 'round-3',
        selectedBoardNumber: 1,
      ),
    );
    catalogCompleter.complete(const <EventRailRoundMetadata>[
      EventRailRoundMetadata(
        id: 'round-1',
        name: 'Round 1',
        startsAt: null,
        createdAt: null,
        ongoing: false,
      ),
      EventRailRoundMetadata(
        id: 'round-2',
        name: 'Round 2',
        startsAt: null,
        createdAt: null,
        ongoing: false,
      ),
    ]);

    expect(await navigation, isFalse);
    expect(notifier.navigationTargetGameId, isNull);
    expect(repository.roundIdsPageCalls, isEmpty);
  });

  test('hide and resume rejects stale navigation hydration', () async {
    final catalogCompleter = Completer<List<EventRailRoundMetadata>>();
    final selected = _game(id: 'selected', roundId: 'round-2', boardNumber: 1);
    final repository = _FakeGameRepository(
      firstTourPage: <Games>[selected],
      selectedRoundPage: <Games>[selected],
      selectedGame: selected,
      totalCount: 1,
      roundCatalogFuture: catalogCompleter.future,
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    const key = BoardTabEventGamesKey(
      tourId: 'tour-1',
      selectedGameId: 'selected',
      selectedRoundId: 'round-2',
      selectedBoardNumber: 1,
    );
    final provider = eventRailGamesProvider(_providerKey(key));
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final navigation = notifier.ensureNavigationAdjacency(-1);
    await Future<void>.delayed(Duration.zero);
    notifier
      ..setForeground(false)
      ..setForeground(true);
    catalogCompleter.complete(const <EventRailRoundMetadata>[]);

    expect(await navigation, isFalse);
    expect(notifier.navigationTargetGameId, isNull);
    expect(repository.roundIdsPageCalls, isEmpty);
  });

  test('multi-leg navigation hydrates only the selected matchup', () async {
    final selected = _game(
      id: 'match-a-game-1',
      roundId: 'stage-game-1',
      roundSlug: 'game-1',
      roundName: 'Final',
      boardNumber: 1,
      whiteName: 'Alice',
      blackName: 'Bob',
    );
    final adjacent = _game(
      id: 'match-a-game-2',
      roundId: 'stage-game-2',
      roundSlug: 'game-2',
      roundName: 'Final',
      boardNumber: 1,
      whiteName: 'Bob',
      blackName: 'Alice',
    );
    final repository = _FakeGameRepository(
      firstTourPage: <Games>[selected],
      selectedRoundPage: <Games>[selected],
      selectedGame: selected,
      totalCount: 120,
      roundCatalog: const <EventRailRoundMetadata>[
        EventRailRoundMetadata(
          id: 'stage-game-1',
          name: 'Final',
          startsAt: null,
          createdAt: null,
          ongoing: true,
        ),
        EventRailRoundMetadata(
          id: 'stage-game-2',
          name: 'Final',
          startsAt: null,
          createdAt: null,
          ongoing: true,
        ),
      ],
      allRoundGames: List<Games>.generate(
        120,
        (index) => _game(
          id: 'stage-$index',
          roundId: index.isEven ? 'stage-game-1' : 'stage-game-2',
          roundSlug: index.isEven ? 'game-1' : 'game-2',
          roundName: 'Final',
          boardNumber: index ~/ 2 + 1,
        ),
      ),
      playerGames: <Games>[adjacent, selected],
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    const key = BoardTabEventGamesKey(
      tourId: 'tour-1',
      selectedGameId: 'match-a-game-1',
      selectedRoundId: 'stage-game-1',
      selectedBoardNumber: 1,
    );
    final provider = eventRailGamesProvider(_providerKey(key));
    final subscription = container.listen<AsyncValue<EventRailGamesState>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    expect(await notifier.ensureNavigationAdjacency(1), isTrue);
    expect(notifier.navigationTargetGameId, 'match-a-game-2');
    expect(repository.playerGameCalls, hasLength(1));
    expect(repository.roundIdsPageCalls, isEmpty);
    expect(repository.tourPageCalls, const <_PageCall>[
      _PageCall(id: 'tour-1', limit: 64, offset: 0),
    ]);
  });

  test(
    'navigation queries only the immediate adjacent catalog stage',
    () async {
      final now = DateTime.now();
      final selected = _game(
        id: 'round-4-game',
        roundId: 'round-4',
        boardNumber: 1,
      );
      final laterGame = _game(
        id: 'round-2-game',
        roundId: 'round-2',
        boardNumber: 1,
      );
      final repository = _FakeGameRepository(
        firstTourPage: <Games>[selected],
        selectedRoundPage: <Games>[selected],
        selectedGame: selected,
        totalCount: 2,
        roundCatalog: <EventRailRoundMetadata>[
          EventRailRoundMetadata(
            id: 'round-4',
            name: 'Round 4',
            startsAt: now.subtract(const Duration(hours: 1)),
            createdAt: null,
            ongoing: false,
          ),
          EventRailRoundMetadata(
            id: 'round-3',
            name: 'Round 3',
            startsAt: now.subtract(const Duration(hours: 2)),
            createdAt: null,
            ongoing: false,
          ),
          EventRailRoundMetadata(
            id: 'round-2',
            name: 'Round 2',
            startsAt: now.subtract(const Duration(hours: 3)),
            createdAt: null,
            ongoing: false,
          ),
        ],
        allRoundGames: <Games>[selected, laterGame],
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      const key = BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'round-4-game',
        selectedRoundId: 'round-4',
        selectedBoardNumber: 1,
      );
      final provider = eventRailGamesProvider(_providerKey(key));
      final subscription = container.listen<AsyncValue<EventRailGamesState>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(provider.future);

      final notifier = container.read(provider.notifier);
      expect(await notifier.ensureNavigationAdjacency(1), isFalse);
      expect(notifier.navigationTargetGameId, isNull);
      expect(repository.roundIdsCountCalls, <List<String>>[
        <String>['round-4'],
        <String>['round-3'],
      ]);
      expect(repository.roundIdsPageCalls, const <_RoundIdsPageCall>[
        _RoundIdsPageCall(ids: <String>['round-4'], limit: 64, offset: 0),
      ]);
    },
  );

  for (final delta in <int>[-1, 1]) {
    test(
      'canonical navigation fallback requires an exact target for delta $delta',
      () async {
        final selected = _game(
          id: 'selected-game',
          roundId: 'selected-round',
          boardNumber: 500,
        );
        final canonicalPage = List<Games>.generate(
          64,
          (index) => _game(
            id: 'canonical-$index',
            roundId: 'canonical-round',
            boardNumber: index + 65,
          ),
        );
        final repository = _FakeGameRepository(
          firstTourPage: List<Games>.generate(
            64,
            (index) => _game(
              id: 'seed-$index',
              roundId: 'seed-round',
              boardNumber: index + 1,
            ),
          ),
          selectedRoundPage: <Games>[selected],
          selectedGame: selected,
          totalCount: 192,
          tourPagesByOffset: <int, List<Games>>{64: canonicalPage},
          roundCatalog: const <EventRailRoundMetadata>[],
        );
        final container = _container(repository);
        addTearDown(container.dispose);
        const key = BoardTabEventGamesKey(
          tourId: 'tour-1',
          selectedGameId: 'selected-game',
          selectedRoundId: 'selected-round',
          selectedBoardNumber: 500,
        );
        final provider = eventRailGamesProvider(_providerKey(key));
        final subscription = container.listen<AsyncValue<EventRailGamesState>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(provider.future);

        final notifier = container.read(provider.notifier);
        expect(await notifier.ensureNavigationAdjacency(delta), isFalse);
        expect(notifier.navigationTargetGameId, isNull);
        expect(repository.tourPageCalls, const <_PageCall>[
          _PageCall(id: 'tour-1', limit: 64, offset: 0),
          _PageCall(id: 'tour-1', limit: 64, offset: 64),
        ]);
      },
    );
  }

  test('round catalog recovers and discovers appended rounds', () async {
    final repository = _FakeGameRepository(
      firstTourPage: const <Games>[],
      selectedRoundPage: const <Games>[],
      totalCount: 0,
    )..roundCatalogError = StateError('offline');
    final container = _container(repository);
    addTearDown(container.dispose);
    final provider = eventRailRoundCatalogProvider(
      const EventRailRoundCatalogKey(
        ownerId: 'test-board-tab',
        tourId: 'tour-1',
      ),
    );
    final subscription = container
        .listen<AsyncValue<List<EventRailRoundMetadata>>>(
          provider,
          (_, __) {},
          fireImmediately: true,
        );
    addTearDown(subscription.close);
    await expectLater(container.read(provider.future), throwsStateError);

    repository
      ..roundCatalogError = null
      ..roundCatalog = const <EventRailRoundMetadata>[
        EventRailRoundMetadata(
          id: 'round-1',
          name: 'Round 1',
          startsAt: null,
          createdAt: null,
          ongoing: false,
        ),
      ];
    await container.read(provider.notifier).refreshCatalog();
    expect(container.read(provider).requireValue, hasLength(1));

    repository.roundCatalog = const <EventRailRoundMetadata>[
      EventRailRoundMetadata(
        id: 'round-1',
        name: 'Round 1',
        startsAt: null,
        createdAt: null,
        ongoing: false,
      ),
      EventRailRoundMetadata(
        id: 'round-2',
        name: 'Round 2',
        startsAt: null,
        createdAt: null,
        ongoing: false,
      ),
    ];
    await container.read(provider.notifier).refreshCatalog();
    expect(container.read(provider).requireValue, hasLength(2));

    repository.roundCatalogError = StateError('temporary');
    await container.read(provider.notifier).refreshCatalog();
    expect(container.read(provider).requireValue, hasLength(2));
  });
}

EventRailGamesProviderKey _providerKey(
  BoardTabEventGamesKey eventKey, {
  String ownerId = 'test-board-tab',
}) {
  return EventRailGamesProviderKey(ownerId: ownerId, eventKey: eventKey);
}

ProviderContainer _container(_FakeGameRepository repository) {
  return ProviderContainer(
    overrides: [gameRepositoryProvider.overrideWithValue(repository)],
  );
}

class _FakeGameRepository implements GameRepository {
  _FakeGameRepository({
    required this.firstTourPage,
    required this.selectedRoundPage,
    required this.totalCount,
    this.selectedGame,
    this.initialTourFuture,
    this.initialRoundFuture,
    this.selectedGameFuture,
    this.countFuture,
    this.continuationFuture,
    this.tourPagesByOffset = const <int, List<Games>>{},
    this.roundPagesByOffset = const <int, List<Games>>{},
    this.roundCatalog = const <EventRailRoundMetadata>[],
    this.roundCatalogFuture,
    this.allRoundGames = const <Games>[],
    this.playerGames = const <Games>[],
    this.roundIdsFuturesByKey = const <String, Future<List<Games>>>{},
  });

  List<Games> firstTourPage;
  List<Games> selectedRoundPage;
  Games? selectedGame;
  int totalCount;
  Future<List<Games>>? initialTourFuture;
  Future<List<Games>>? initialRoundFuture;
  Future<Games>? selectedGameFuture;
  Future<int>? countFuture;
  Future<List<Games>>? continuationFuture;
  Map<int, List<Games>> tourPagesByOffset;
  Map<int, List<Games>> roundPagesByOffset;
  List<EventRailRoundMetadata> roundCatalog;
  Future<List<EventRailRoundMetadata>>? roundCatalogFuture;
  List<Games> allRoundGames;
  List<Games> playerGames;
  Map<String, Future<List<Games>>> roundIdsFuturesByKey;
  Object? roundPageError;
  Object? roundCatalogError;
  Object? roundIdsPageError;
  Object? countError;

  final List<_PageCall> tourPageCalls = <_PageCall>[];
  final List<String> tournamentIdentityPageCalls = <String>[];
  final List<String> tournamentIdentityCountCalls = <String>[];
  final List<_PageCall> roundPageCalls = <_PageCall>[];
  final List<String> selectedGameCalls = <String>[];
  final List<String> countCalls = <String>[];
  final List<String> roundCatalogCalls = <String>[];
  final List<String> tournamentIdentityCatalogCalls = <String>[];
  final List<_RoundIdsPageCall> roundIdsPageCalls = <_RoundIdsPageCall>[];
  final List<List<String>> roundIdsCountCalls = <List<String>>[];
  final List<String> playerGameCalls = <String>[];
  final List<_SelectedOffsetCall> selectedOffsetCalls = <_SelectedOffsetCall>[];
  int legacyFullTourCalls = 0;

  @override
  Future<List<Games>> getGamesByTourId(
    String tourId, {
    int? limit,
    int offset = 0,
  }) async {
    legacyFullTourCalls++;
    return const <Games>[];
  }

  @override
  Future<List<Games>> getEventRailGamesByTourId(
    String tourId, {
    required int limit,
    required int offset,
  }) {
    tourPageCalls.add(_PageCall(id: tourId, limit: limit, offset: offset));
    if (offset == 0) {
      return initialTourFuture ?? Future<List<Games>>.value(firstTourPage);
    }
    final continuation = continuationFuture;
    if (offset == kEventRailGamesPageSize && continuation != null) {
      return continuation;
    }
    final page = tourPagesByOffset[offset];
    if (page != null) return Future<List<Games>>.value(page);
    throw StateError('Unexpected tour page offset: $offset');
  }

  @override
  Future<List<Games>> getEventRailGamesByTournamentIdentity({
    required String tourId,
    required String tourSlug,
    required int limit,
    required int offset,
  }) {
    tournamentIdentityPageCalls.add('$tourId|$tourSlug|$limit|$offset');
    return getEventRailGamesByTourId(tourId, limit: limit, offset: offset);
  }

  @override
  Future<List<Games>> getEventRailGamesByRoundId(
    String roundId, {
    required int limit,
    required int offset,
  }) {
    roundPageCalls.add(_PageCall(id: roundId, limit: limit, offset: offset));
    final error = roundPageError;
    if (error != null) return Future<List<Games>>.error(error);
    final page = roundPagesByOffset[offset];
    if (page != null) return Future<List<Games>>.value(page);
    return initialRoundFuture ?? Future<List<Games>>.value(selectedRoundPage);
  }

  @override
  Future<int> countEventRailGamesBeforeSelectedInRound({
    required String roundId,
    required String selectedGameId,
    required int? selectedBoardNumber,
  }) async {
    selectedOffsetCalls.add(
      _SelectedOffsetCall(
        roundId: roundId,
        selectedGameId: selectedGameId,
        selectedBoardNumber: selectedBoardNumber,
      ),
    );
    final completeRound = allRoundGames
      .where((game) => game.roundId == roundId)
      .toList(growable: false)..sort(_compareFakeEventRailRows);
    final exactIndex = completeRound.indexWhere(
      (game) => game.id == selectedGameId,
    );
    if (exactIndex >= 0) return exactIndex;

    // Existing tests that provide only a pre-sliced response keep their
    // historical fixture offset. New rank regressions provide an explicit
    // offset or a complete round and therefore exercise the exact ordering.
    return math.max(0, (selectedBoardNumber ?? 1) - 1);
  }

  @override
  Future<List<EventRailRoundMetadata>> getEventRailRoundsByTourId(
    String tourId,
  ) async {
    roundCatalogCalls.add(tourId);
    final error = roundCatalogError;
    if (error != null) throw error;
    final controlled = roundCatalogFuture;
    if (controlled != null) return controlled;
    return roundCatalog;
  }

  @override
  Future<List<EventRailRoundMetadata>> getEventRailRoundsByTournamentIdentity({
    required String tourId,
    required String tourSlug,
  }) {
    tournamentIdentityCatalogCalls.add('$tourId|$tourSlug');
    return getEventRailRoundsByTourId(tourId);
  }

  @override
  Future<List<Games>> getEventGamesByPlayer({
    required String tourId,
    int? fideId,
    required String playerName,
  }) async {
    playerGameCalls.add('$tourId|$fideId|$playerName');
    return playerGames;
  }

  @override
  Future<int> countEventRailGamesByRoundIds(List<String> roundIds) async {
    roundIdsCountCalls.add(List<String>.of(roundIds));
    final ids = roundIds.toSet();
    return allRoundGames.where((game) => ids.contains(game.roundId)).length;
  }

  @override
  Future<List<Games>> getEventRailGamesByRoundIds(
    List<String> roundIds, {
    required int limit,
    required int offset,
  }) async {
    final ids = roundIds.toSet();
    roundIdsPageCalls.add(
      _RoundIdsPageCall(
        ids: List<String>.of(roundIds),
        limit: limit,
        offset: offset,
      ),
    );
    final error = roundIdsPageError;
    if (error != null) throw error;
    final key = (List<String>.of(roundIds)..sort()).join('|');
    final controlled = roundIdsFuturesByKey[key];
    if (controlled != null) return await controlled;
    final matching = allRoundGames
        .where((game) => ids.contains(game.roundId))
        .toList(growable: false);
    if (offset >= matching.length) return const <Games>[];
    return matching.sublist(offset, math.min(offset + limit, matching.length));
  }

  @override
  Future<Games> getEventRailGameById(String gameId) async {
    selectedGameCalls.add(gameId);
    final future = selectedGameFuture;
    if (future != null) return await future;
    final exact = selectedGame;
    if (exact != null && exact.id == gameId) return exact;
    for (final game in <Games>[...selectedRoundPage, ...firstTourPage]) {
      if (game.id == gameId) return game;
    }
    throw StateError('Unexpected selected game id: $gameId');
  }

  @override
  Future<int> countGamesByTourId(String tourId) {
    countCalls.add(tourId);
    final error = countError;
    if (error != null) return Future<int>.error(error);
    return countFuture ?? Future<int>.value(totalCount);
  }

  @override
  Future<int> countEventRailGamesByTournamentIdentity({
    required String tourId,
    required String tourSlug,
  }) {
    tournamentIdentityCountCalls.add('$tourId|$tourSlug');
    return countGamesByTourId(tourId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected repository call: $invocation');
  }
}

class _PageCall {
  const _PageCall({
    required this.id,
    required this.limit,
    required this.offset,
  });

  final String id;
  final int limit;
  final int offset;

  @override
  bool operator ==(Object other) {
    return other is _PageCall &&
        other.id == id &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(id, limit, offset);

  @override
  String toString() => '_PageCall($id, limit: $limit, offset: $offset)';
}

class _RoundIdsPageCall {
  const _RoundIdsPageCall({
    required this.ids,
    required this.limit,
    required this.offset,
  });

  final List<String> ids;
  final int limit;
  final int offset;

  @override
  bool operator ==(Object other) {
    return other is _RoundIdsPageCall &&
        listEquals(other.ids, ids) &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(ids), limit, offset);

  @override
  String toString() =>
      '_RoundIdsPageCall($ids, limit: $limit, offset: $offset)';
}

class _SelectedOffsetCall {
  const _SelectedOffsetCall({
    required this.roundId,
    required this.selectedGameId,
    required this.selectedBoardNumber,
  });

  final String roundId;
  final String selectedGameId;
  final int? selectedBoardNumber;

  @override
  bool operator ==(Object other) {
    return other is _SelectedOffsetCall &&
        other.roundId == roundId &&
        other.selectedGameId == selectedGameId &&
        other.selectedBoardNumber == selectedBoardNumber;
  }

  @override
  int get hashCode => Object.hash(roundId, selectedGameId, selectedBoardNumber);

  @override
  String toString() {
    return '_SelectedOffsetCall($roundId, $selectedGameId, '
        'board: $selectedBoardNumber)';
  }
}

int _compareFakeEventRailRows(Games a, Games b) {
  final aBoard = a.boardNr;
  final bBoard = b.boardNr;
  if (aBoard != null && bBoard != null) {
    final boardCompare = aBoard.compareTo(bBoard);
    if (boardCompare != 0) return boardCompare;
  } else if (aBoard != null) {
    return -1;
  } else if (bBoard != null) {
    return 1;
  }
  return a.id.compareTo(b.id);
}

Games _game({
  required String id,
  required String roundId,
  required int? boardNumber,
  String? roundName,
  String? roundSlug,
  DateTime? roundStartsAt,
  String status = 'started',
  String? pgn,
  String? whiteName,
  String? blackName,
}) {
  return Games(
    id: id,
    roundId: roundId,
    roundSlug: roundSlug ?? roundId,
    tourId: 'tour-1',
    tourSlug: 'tour-1',
    name: 'Game $id',
    fen: 'fen-$id',
    players: <Player>[
      Player(
        name: whiteName ?? 'White $id',
        title: '',
        rating: 2500,
        fideId: (boardNumber ?? 0) * 2,
        fed: 'TUR',
        clock: 0,
        team: '',
      ),
      Player(
        name: blackName ?? 'Black $id',
        title: '',
        rating: 2490,
        fideId: (boardNumber ?? 0) * 2 + 1,
        fed: 'TUR',
        clock: 0,
        team: '',
      ),
    ],
    status: status,
    pgn: pgn,
    boardNr: boardNumber,
    roundName: roundName,
    roundStartsAt: roundStartsAt,
  );
}
