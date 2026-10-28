import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/event_player_board_games.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/player_hover_preview.dart';
import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

EventPlayerBoardScope scope({String player = 'Player', int fide = 101}) =>
    EventPlayerBoardScope(
      tourIds: ['event-a', 'event-a-page-2'],
      playerName: player,
      fideId: fide,
      eventTitle: 'Event A',
      eventBroadcastId: 'parent-a',
    );

TournamentGameSummary summary(
  int round, {
  String tour = 'event-a',
  int fide = 101,
}) => TournamentGameSummary(
  id: '$tour-$fide-r$round',
  name: 'Round $round',
  whitePlayer: 'Player',
  blackPlayer: 'Opponent',
  whiteFideId: fide,
  hasPgn: true,
  tourId: tour,
  roundId: 'round-$round',
  roundLabel: '$round',
  whiteCustomPoints: 0,
  blackCustomPoints: 1.5,
);

GamesTourModel model(int round) => GamesTourModel(
  gameId: 'event-a-101-r$round',
  whitePlayer: PlayerCard(
    name: 'Player',
    fideId: 101,
    federation: '',
    title: '',
    rating: 2500,
    countryCode: '',
    team: null,
    customPoints: 0,
  ),
  blackPlayer: PlayerCard(
    name: 'Opponent',
    fideId: 202,
    federation: '',
    title: '',
    rating: 2400,
    countryCode: '',
    team: null,
    customPoints: 1.5,
  ),
  whiteTimeDisplay: '',
  blackTimeDisplay: '',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.draw,
  roundId: 'round-$round',
  tourId: 'event-a',
  source: GameSource.supabase,
  pgn: '1. e4 e5 *',
);

class _Tours implements TourRepository {
  @override
  Future<List<Tour>> getTourByGroupId(String id) async => [
    for (final entry in [
      ('event-a', 'Open | Boards 1-66'),
      ('event-a-page-2', 'Open | Boards 67-126'),
      ('other-category', 'Women'),
    ])
      Tour(
        id: entry.$1,
        name: entry.$2,
        slug: entry.$1,
        info: TourInfo.fromJson({}),
        createdAt: DateTime(2026),
        url: '',
        tier: 0,
        dates: [],
        players: [],
        groupBroadcastId: 'parent-a',
      ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends EventPlayerGamesNotifier {
  @override
  Future<List<GamesTourModel>> build(EventPlayerGamesKey key) async => [
    for (var r = 1; r <= 7; r++) model(r),
  ];
}

class _Games implements GameRepository {
  @override
  Future<Games> getGameWithPGN(String gameId) async =>
      throw StateError('offline hydration');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'collapsed rail navigation retains seven-round player scope and parent event',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          gameRepositoryProvider.overrideWithValue(_Games()),
          eventPlayerGamesProvider.overrideWith(_History.new),
        ],
      );
      addTearDown(container.dispose);
      final args = buildTournamentBoardTabArgs(
        model(7),
        scope().title,
        eventGames: [model(7)],
        eventBroadcastId: 'parent-a',
        eventPlayerScope: scope(),
      );
      final tabId = openBoardGameTabFromContainer(
        container,
        args,
        reuseExisting: false,
      );
      late WidgetRef boardRef;
      late BuildContext boardContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                boardRef = ref;
                boardContext = context;
                ref.watch(
                  eventPlayerBoardGamesProvider(
                    eventPlayerBoardGamesKey(scope(), tabId),
                  ),
                );
                return const SizedBox(); // Board owner remains mounted with rail hidden.
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await navigateActiveEventGame(boardRef, context: boardContext, delta: 1);
      await tester.pumpAndSettle();
      final next = container.read(boardTabGameArgsByTabIdProvider)[tabId]!;
      expect(next.gameId, model(6).gameId);
      expect(next.eventGamesKey, isNull);
      expect(next.eventGames, hasLength(7));
      expect(next.eventBroadcastId, 'parent-a');
      expect(next.viewSource, ChessboardView.tour);
      expect(next.label, scope().title);
      expect(next.eventPlayerScope!.toJson(), args.eventPlayerScope!.toJson());
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final entrySource in [
    ChessboardView.tour,
    ChessboardView.forYou,
    ChessboardView.countryman,
  ]) {
    testWidgets(
      'real Board hover from $entrySource opens independent scoped tabs',
      (tester) async {
        final original = buildTournamentBoardTabArgs(
          model(7),
          'Event A',
          viewSource: entrySource,
          eventGames: [for (var r = 1; r <= 7; r++) model(r)],
          eventBroadcastId: 'parent-a',
        );
        final container = ProviderContainer(
          overrides: [
            tourRepositoryProvider.overrideWithValue(_Tours()),
            gameRepositoryProvider.overrideWithValue(_Games()),
          ],
        );
        addTearDown(container.dispose);
        final originalId = openBoardGameTabFromContainer(
          container,
          original,
          reuseExisting: false,
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 760,
                  height: 48,
                  child: DesktopBoardPlayerHeader(
                    name: 'Player',
                    federation: '',
                    title: '',
                    rating: 2500,
                    fideId: null,
                    result: null,
                    isWhite: true,
                    isToMove: false,
                    boardArgs: original,
                  ),
                ),
              ),
            ),
          ),
        );
        final preview = tester.widget<PlayerHoverPreview>(
          find.byType(PlayerHoverPreview),
        );
        preview.onOpenGameInNewTab(
          preview.games.singleWhere((game) => game.id == model(7).gameId),
        );
        await tester.pumpAndSettle();
        final first = container.read(desktopTabsProvider).activeId!;
        final args = container.read(boardTabGameArgsByTabIdProvider)[first]!;
        expect(first, isNot(originalId));
        expect(args.eventGamesKey, isNull);
        expect(args.eventGames, hasLength(7));
        expect(args.gameId, model(7).gameId);
        expect(args.viewSource, ChessboardView.tour);
        expect((args.eventPlayerScope!).tourIds, ['event-a', 'event-a-page-2']);
        // Activate the actual compact name from the production Board header.
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(tester.getCenter(
          find.byKey(const ValueKey('player-hover-preview-trigger')),
        )));
        await tester.pump(playerHoverIntentDelay);
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('Open event games'), findsNothing);
        await tester.tap(find.text('Games'));
        await tester.pump();
        expect(container.read(desktopTabsProvider).activeId, first);
        await tester.tap(find.byKey(const ValueKey('player-hover-header-name')));
        await tester.pumpAndSettle();
        final second = container.read(desktopTabsProvider).activeId!;
        expect(second, isNot(first));
        expect(container.read(boardTabGameArgsByTabIdProvider)[second], isNull);
        expect(container.read(playerProfileByTabIdProvider)[second], isNull);
        expect(container.read(playerScoreCardByTabIdProvider)[second]!.name, 'Player');
        final report = container.read(playerScoreCardContextByTabIdProvider)[second]!;
        expect(report.hasEventContext, isTrue);
        expect(report.gamesContext, hasLength(7));
        expect(report.gamesContext!.every((g) => g.tourId == 'event-a'), isTrue);
        expect(
          container.read(boardTabGameArgsByTabIdProvider)[originalId],
          same(original),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test(
    'exact identity and event scope retain all seven rounds, newest first',
    () {
      final rows = eventPlayerBoardGames(scope(), [
        for (var r = 1; r <= 7; r++) summary(r),
        summary(7, fide: 999), // Namesake in the same event.
        summary(8, tour: 'event-b'), // Same player in another event.
        summary(7), // Duplicate from card/current live row.
      ]);
      expect(rows.map((row) => row.roundLabel), [
        '7',
        '6',
        '5',
        '4',
        '3',
        '2',
        '1',
      ]);
      expect(rows.first.whiteCustomPoints, 0);
      expect(rows.first.blackCustomPoints, 1.5);
    },
  );

  test(
    'tab args stay ordinary event viewing and do not create a round rail',
    () {
      final args = buildTournamentBoardTabArgs(
        model(7),
        scope().title,
        eventGames: [for (var r = 7; r >= 1; r--) model(r)],
        eventBroadcastId: 'parent-a',
        eventPlayerScope: scope(),
      );
      expect(args.eventGamesKey, isNull);
      expect(args.viewSource, ChessboardView.tour);
      expect(args.routeGamesContinuation, isNull);
      expect(args.label, 'Player · Event A');
      expect(args.gameListSelectedId, 'event-a-101-r7');
      expect(args.eventGames, hasLength(7));
      expect(args.sourceGame!.whitePlayer.customPoints, 0);
    },
  );

  test('copy and detached/restored payload preserve full immutable scope', () {
    final args = buildTournamentBoardTabArgs(
      model(7),
      scope().title,
      eventPlayerScope: scope(),
      eventBroadcastId: 'parent-a',
    ).copyWith(pgn: '1. d4 d5 *');
    final restored =
        DesktopBoardWindowPayload.decode(
          DesktopBoardWindowPayload.fromArgs(args).encode(),
        ).args!;
    final restoredScope = restored.eventPlayerScope!;
    expect(restoredScope.toJson(), scope().toJson());
    expect(restored.eventGamesKey, isNull);
    expect(restored.eventBroadcastId, 'parent-a');
    expect(restored.pgn, '1. d4 d5 *');
    expect(restored.gameListSelectedId, 'event-a-101-r7');
    expect(restored.sourceGame!.blackPlayer.customPoints, 1.5);
    expect(
      eventPlayerBoardGamesKey(restoredScope, 'new-window').ownerId,
      'new-window',
    );
    expect(
      eventPlayerBoardGamesKey(restoredScope, 'new-window').tourIds,
      scope().tourIds,
    );
  });

  test('different players and ordinary event tabs do not reuse each other', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final original = buildTournamentBoardTabArgs(model(7), 'Event A');
    final eventTab = openBoardGameTabFromContainer(
      container,
      original,
      reuseExisting: false,
    );
    final playerArgs = buildTournamentBoardTabArgs(
      model(7),
      scope().title,
      eventPlayerScope: scope(),
    );
    final playerTab = openBoardGameTabFromContainer(
      container,
      playerArgs,
      reuseExisting: true,
    );
    expect(playerTab, isNot(eventTab));
    expect(
      container.read(boardTabGameArgsByTabIdProvider)[eventTab],
      same(original),
    );
    final opponentArgs = playerArgs.copyWith(
      eventPlayerScope: scope(player: 'Opponent', fide: 202),
    );
    final opponentTab = openBoardGameTabFromContainer(
      container,
      opponentArgs,
      reuseExisting: true,
    );
    expect(opponentTab, isNot(playerTab));
    expect(
      container
          .read(desktopTabsProvider)
          .tabs
          .singleWhere((tab) => tab.id == opponentTab)
          .title,
      'Opponent · Event A',
    );
    expect(openBoardGameTabFromContainer(container, original), eventTab);
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)[playerTab]!
          .eventPlayerScope!
          .playerName,
      'Player',
    );
  });
}
