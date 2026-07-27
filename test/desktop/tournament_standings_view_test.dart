import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/tournament_standings_view.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/group_event/model/about_tour_model.dart';
import 'package:chessever/screens/group_event/model/tour_detail_view_model.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show selectedPlayerProvider, scoreCardHasEventContextProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';

final _mergedGamesSourcesStateProvider =
    StateProvider<MergedTournamentGamesSourceState>(
      (ref) => throw UnimplementedError(),
    );

void main() {
  test(
    'maps round results and opponent tooltip from the player perspective',
    () {
      final standings = [
        _standing(
          name: 'Carlsen, Magnus',
          fideId: 1503014,
          rating: 2830,
          rank: 1,
        ),
        _standing(name: 'Gukesh D', fideId: 46616543, rating: 2750, rank: 12),
      ];
      final table = buildTournamentStandingsRoundTable(
        standings: standings,
        games: [
          _game(
            id: 'game-1',
            round: 'Round 1',
            white: _card('Carlsen, Magnus', 1503014, 2830),
            black: _card('Gukesh D', 46616543, 2750),
            status: GameStatus.blackWins,
          ),
        ],
      );

      expect(table.rounds, [1]);
      final carlsen = table.cellsFor(standings.first).single;
      expect(carlsen.resultText, '0');
      expect(carlsen.playedWhite, isTrue);
      expect(carlsen.opponentName, 'Gukesh D');
      expect(carlsen.tooltipMessage, '#12 Gukesh D · 2750');

      final gukesh = table.cellsFor(standings.last).single;
      expect(gukesh.resultText, '1');
      expect(gukesh.playedWhite, isFalse);
      expect(gukesh.tooltipMessage, '#1 Carlsen, Magnus · 2830');
    },
  );

  test('keeps named stages and repeated round games deterministically', () {
    final player = _standing(
      name: 'Carlsen, Magnus',
      fideId: 1503014,
      rating: 2830,
      rank: 1,
    );
    final opponent = _standing(
      name: 'Opponent',
      fideId: 46616543,
      rating: 2750,
      rank: 2,
    );
    final white = _card(player.name, player.fideId!, player.score);
    final black = _card(opponent.name, opponent.fideId!, opponent.score);
    final games = [
      _game(
        id: 'round-1-b',
        round: 'Round 1',
        white: white,
        black: black,
        status: GameStatus.draw,
      ),
      _game(
        id: 'armageddon',
        round: 'Armageddon',
        white: black,
        black: white,
        status: GameStatus.blackWins,
      ),
      _game(
        id: 'finals',
        round: 'Finals',
        white: white,
        black: black,
        status: GameStatus.whiteWins,
      ),
      _game(
        id: 'round-1-a',
        round: 'Round 1',
        white: black,
        black: white,
        status: GameStatus.whiteWins,
      ),
      _game(
        id: 'tiebreak',
        round: 'Tiebreak',
        white: white,
        black: black,
        status: GameStatus.draw,
      ),
    ];

    final table = buildTournamentStandingsRoundTable(
      standings: [player, opponent],
      games: games,
    );
    final reversed = buildTournamentStandingsRoundTable(
      standings: [player, opponent],
      games: games.reversed.toList(),
    );

    expect(table.cellsFor(player).map((cell) => cell.game.gameId), [
      'round-1-a',
      'round-1-b',
      'finals',
      'tiebreak',
      'armageddon',
    ]);
    expect(
      reversed.cellsFor(player).map((cell) => cell.game.gameId),
      table.cellsFor(player).map((cell) => cell.game.gameId),
    );
  });

  test('retains scoped games through loading and error then accepts empty', () {
    final game = _game(
      id: 'retained-game',
      round: 'Round 1',
      white: _card('Carlsen, Magnus', 1503014, 2830),
      black: _card('Opponent', 46616543, 2750),
      status: GameStatus.whiteWins,
    );
    const detail = TourDetailViewModel(
      aboutTourModel: AboutTourModel(
        id: 'event-1',
        slug: 'event-1',
        name: 'Event',
        description: '',
        imageUrl: '',
        players: [],
        timeControl: '',
        date: '',
        location: '',
        websiteUrl: '',
        standingsUrl: '',
        tourUrl: '',
      ),
      liveTourIds: [],
      tours: [],
    );
    final dataSources = (
      tourDetail: const AsyncValue.data(detail),
      gamesTour: AsyncValue.data(
        GamesScreenModel(gamesTourModels: [game], pinnedGamedIs: const []),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        _mergedGamesSourcesStateProvider.overrideWith((ref) => dataSources),
        mergedTournamentGamesSourceProvider.overrideWith(
          (ref) => ref.watch(_mergedGamesSourcesStateProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      mergedTournamentGamesProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    expect(container.read(mergedTournamentGamesProvider), [same(game)]);

    container.read(_mergedGamesSourcesStateProvider.notifier).state = (
      tourDetail: const AsyncValue<TourDetailViewModel>.loading(),
      gamesTour: dataSources.gamesTour,
    );
    expect(container.read(mergedTournamentGamesProvider), [same(game)]);

    container.read(_mergedGamesSourcesStateProvider.notifier).state = (
      tourDetail: AsyncValue<TourDetailViewModel>.error(
        StateError('refresh failed'),
        StackTrace.empty,
      ),
      gamesTour: dataSources.gamesTour,
    );
    expect(container.read(mergedTournamentGamesProvider), [same(game)]);

    container.read(_mergedGamesSourcesStateProvider.notifier).state = (
      tourDetail: const AsyncValue.data(detail),
      gamesTour: AsyncValue.data(
        GamesScreenModel(gamesTourModels: const [], pinnedGamedIs: const []),
      ),
    );
    expect(container.read(mergedTournamentGamesProvider), isEmpty);
  });

  test('scopes round games to the standings snapshot tour IDs', () {
    const snapshot = PlayerTourStandingsSnapshot(
      broadcastId: 'event-a',
      selectedTourId: 'tour-a',
      tourIds: {'tour-a'},
      standings: <PlayerStandingModel>[],
    );
    final tourA = _game(
      id: 'game-a',
      round: 'Round 1',
      tourId: 'tour-a',
      white: _card('Player A', 1, 2500),
      black: _card('Player B', 2, 2450),
      status: GameStatus.draw,
    );
    final tourB = _game(
      id: 'game-b',
      round: 'Round 1',
      tourId: 'tour-b',
      white: _card('Player A', 1, 2500),
      black: _card('Player B', 2, 2450),
      status: GameStatus.whiteWins,
    );

    expect(scopeTournamentStandingsGames(snapshot, [tourA, tourB]), [tourA]);
  });

  test('authoritative FIDE-ID conflicts never fall back to player names', () {
    final first = _standing(
      name: 'Same Player',
      fideId: 111,
      rating: 2500,
      rank: 1,
    );
    final second = _standing(
      name: 'Same Player',
      fideId: 222,
      rating: 2450,
      rank: 2,
    );
    final table = buildTournamentStandingsRoundTable(
      standings: [first, second],
      games: [
        _game(
          id: 'conflicting-game',
          round: 'Round 1',
          white: _card('Same Player', 333, 2400),
          black: _card('Opponent', 444, 2350),
          status: GameStatus.whiteWins,
        ),
      ],
    );

    expect(table.cellsFor(first), isEmpty);
    expect(table.cellsFor(second), isEmpty);
  });

  testWidgets(
    'keeps player identity compact and rating points and rounds aligned',
    (tester) async {
      final resolvedFideIds = <String?>[];
      final game = _game(
        id: 'game-layout',
        round: 'Round 1',
        white: _card('Carlsen, Magnus', 1503014, 2830),
        black: _card(
          'A Very Long Opponent Name That Must Not Move Rating',
          46616543,
          2750,
        ),
        status: GameStatus.whiteWins,
      );
      final container = ProviderContainer(
        overrides: [
          playerTourStandingsSnapshotProvider.overrideWith(
            _LayoutStandingsNotifier.new,
          ),
          mergedTournamentGamesProvider.overrideWith((ref) => [game]),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 840,
                height: 480,
                child: TournamentStandingsView(
                  tabId: 'layout-tab',
                  tournamentId: 'event-1',
                  photoResolver: (fideId) async {
                    resolvedFideIds.add(fideId);
                    return null;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('standings-round-header-1')), findsOneWidget);
      expect(
        find.byKey(const Key('standings-round-1503014-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('standings-player-avatar-1503014')),
        findsOneWidget,
      );
      expect(resolvedFideIds, contains('1503014'));
      expect(resolvedFideIds, contains('46616543'));

      final title = tester.widget<Text>(
        find.byKey(const Key('standings-title-1503014')),
      );
      expect(title.style?.color, kPrimaryColor);
      expect(title.style?.fontSize, 14);
      final points = tester.widget<Text>(
        find.byKey(const Key('standings-points-1503014')),
      );
      expect(points.data, '1');
      expect(points.style?.fontSize, 14);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('standings-rating-1503014')))
            .style
            ?.fontSize,
        13,
      );
      expect(
        tester.widget<Text>(find.text('Carlsen, Magnus')).style?.fontSize,
        14,
      );
      expect(
        tester.getSize(
          find.byKey(const Key('standings-player-avatar-1503014')),
        ),
        const Size.square(40),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('standings-round-1503014-1')))
            .width,
        46,
      );
      final roundContainers = tester.widgetList<Container>(
        find.descendant(
          of: find.byKey(const Key('standings-round-1503014-1')),
          matching: find.byType(Container),
        ),
      );
      expect(
        roundContainers.any(
          (container) =>
              container.constraints ==
              const BoxConstraints.tightFor(width: 26, height: 26),
        ),
        isTrue,
      );

      final firstRatingX =
          tester
              .getTopLeft(find.byKey(const Key('standings-rating-1503014')))
              .dx;
      final secondRatingX =
          tester
              .getTopLeft(find.byKey(const Key('standings-rating-46616543')))
              .dx;
      expect(firstRatingX, secondRatingX);

      final avatarX =
          tester
              .getTopLeft(
                find.byKey(const Key('standings-player-avatar-1503014')),
              )
              .dx;
      final flagX =
          tester.getTopLeft(find.byKey(const Key('standings-flag-1503014'))).dx;
      final titleX =
          tester
              .getTopLeft(find.byKey(const Key('standings-title-1503014')))
              .dx;
      final flagIcon = find.descendant(
        of: find.byKey(const Key('standings-flag-1503014')),
        matching: find.byType(FederationFlag),
      );
      expect(tester.getSize(flagIcon), const Size(26, 17));
      expect(titleX - tester.getTopRight(flagIcon).dx, 8);
      final nameX = tester.getTopLeft(find.text('Carlsen, Magnus')).dx;
      expect(avatarX, lessThan(flagX));
      expect(flagX, lessThan(titleX));
      expect(titleX, lessThan(nameX));
      expect(nameX, lessThan(firstRatingX));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders refreshed official roster rows from getTourPlayers', (
    tester,
  ) async {
    final repository = _ControlledOfficialRosterRepository();
    final container = ProviderContainer(
      overrides: [
        tourRepositoryProvider.overrideWithValue(repository),
        playerTourStandingsSnapshotProvider.overrideWith(
          _LayoutStandingsNotifier.new,
        ),
        mergedTournamentGamesProvider.overrideWith((ref) => const []),
        tournamentRosterRefreshIntervalProvider.overrideWithValue(
          const Duration(days: 1),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 840,
              height: 480,
              child: TournamentStandingsView(
                tabId: 'official-roster-tab',
                tournamentId: 'event-1',
                photoResolver: (_) async => null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(repository.calls, hasLength(1));
    repository.calls.single.complete([
      TournamentPlayer(
        federation: 'IND',
        name: 'Official Player',
        title: 'GM',
        fideId: 999,
        played: 2,
        rating: 2700,
        score: 1.5,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Official Player'), findsOneWidget);
    expect(find.byKey(const Key('standings-points-999')), findsOneWidget);
  });

  testWidgets('opens the exact game represented by a clicked round result', (
    tester,
  ) async {
    GamesTourModel? openedGame;
    List<GamesTourModel>? openedEventGames;
    void captureOpen(GamesTourModel game, List<GamesTourModel> eventGames) {
      openedGame = game;
      openedEventGames = eventGames;
    }

    final roundOne = _game(
      id: 'game-click-1',
      round: 'Round 1',
      white: _card('Carlsen, Magnus', 1503014, 2830),
      black: _card(
        'A Very Long Opponent Name That Must Not Move Rating',
        46616543,
        2750,
      ),
      status: GameStatus.whiteWins,
      source: GameSource.gamebase,
    );
    final roundTwo = _game(
      id: 'game-click-2',
      round: 'Round 2',
      white: _card(
        'A Very Long Opponent Name That Must Not Move Rating',
        46616543,
        2750,
      ),
      black: _card('Carlsen, Magnus', 1503014, 2830),
      status: GameStatus.draw,
      source: GameSource.gamebase,
    );
    final container = ProviderContainer(
      overrides: [
        playerTourStandingsSnapshotProvider.overrideWith(
          _LayoutStandingsNotifier.new,
        ),
        mergedTournamentGamesProvider.overrideWith(
          (ref) => [roundOne, roundTwo],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 840,
              height: 480,
              child: TournamentStandingsView(
                tabId: 'click-tab',
                tournamentId: 'event-1',
                photoResolver: (_) async => null,
                gameOpener: captureOpen,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('standings-round-1503014-2')));
    await tester.pumpAndSettle();

    expect(openedGame, same(roundTwo));
    expect(openedGame?.gameId, 'game-click-2');
    expect(openedEventGames, [same(roundOne), same(roundTwo)]);
  });

  testWidgets('newer delayed round click owns the in-place board destination', (
    tester,
  ) async {
    final repository = _ControlledGameHydrationRepository();
    final roundOne = _game(
      id: 'delayed-a',
      round: 'Round 1',
      white: _card('Carlsen, Magnus', 1503014, 2830),
      black: _card('Opponent', 46616543, 2750),
      status: GameStatus.whiteWins,
    );
    final roundTwo = _game(
      id: 'delayed-b',
      round: 'Round 2',
      white: _card('Opponent', 46616543, 2750),
      black: _card('Carlsen, Magnus', 1503014, 2830),
      status: GameStatus.draw,
    );
    final container = _roundOpenContainer(repository, [roundOne, roundTwo]);
    addTearDown(container.dispose);
    _seedStandingsTabContext(container);

    await tester.pumpWidget(
      _standingsHarness(container, tabId: 'tournaments-default'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('standings-round-1503014-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('standings-round-1503014-2')));
    await tester.pump();
    expect(repository.requests.map((request) => request.gameId), [
      'delayed-a',
      'delayed-b',
    ]);

    repository.complete('delayed-b', roundTwo);
    await tester.pumpAndSettle();
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)['tournaments-default']
          ?.gameId,
      'delayed-b',
    );

    repository.complete('delayed-a', roundOne);
    await tester.pumpAndSettle();
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)['tournaments-default']
          ?.gameId,
      'delayed-b',
    );
  });

  testWidgets('delayed round click cannot replace a changed tab context', (
    tester,
  ) async {
    final repository = _ControlledGameHydrationRepository();
    final game = _game(
      id: 'delayed-context',
      round: 'Round 1',
      white: _card('Carlsen, Magnus', 1503014, 2830),
      black: _card('Opponent', 46616543, 2750),
      status: GameStatus.whiteWins,
    );
    final container = _roundOpenContainer(repository, [game]);
    addTearDown(container.dispose);
    _seedStandingsTabContext(container);

    await tester.pumpWidget(
      _standingsHarness(container, tabId: 'tournaments-default'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('standings-round-1503014-1')));
    await tester.pump();
    expect(repository.requests, hasLength(1));

    container
        .read(desktopTabsProvider.notifier)
        .navigateActive(TabKind.library, title: 'Library');
    repository.complete('delayed-context', game);
    await tester.pumpAndSettle();

    expect(container.read(desktopTabsProvider).active?.kind, TabKind.library);
    expect(
      container.read(boardTabGameArgsByTabIdProvider),
      isNot(contains('tournaments-default')),
    );
  });

  testWidgets('shows opponent rank name and rating when hovering a round', (
    tester,
  ) async {
    final game = _game(
      id: 'game-tooltip',
      round: 'Round 1',
      white: _card('Carlsen, Magnus', 1503014, 2830),
      black: _card(
        'A Very Long Opponent Name That Must Not Move Rating',
        46616543,
        2750,
      ),
      status: GameStatus.whiteWins,
    );
    final container = ProviderContainer(
      overrides: [
        playerTourStandingsSnapshotProvider.overrideWith(
          _LayoutStandingsNotifier.new,
        ),
        mergedTournamentGamesProvider.overrideWith((ref) => [game]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 840,
              height: 480,
              child: TournamentStandingsView(
                tabId: 'tooltip-tab',
                tournamentId: 'event-1',
                photoResolver: (_) async => null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final result = find.byKey(const Key('standings-round-1503014-1'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(result));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text(
        '#2 A Very Long Opponent Name That Must Not Move Rating · 2750',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a standings player name opens a score card tab', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        playerTourStandingsSnapshotProvider.overrideWith(
          _FakeStandingsNotifier.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 480,
              child: TournamentStandingsView(
                tabId: 'test-tab',
                tournamentId: 'event-1',
                photoResolver: (_) async => null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Carlsen, Magnus'));
    await tester.pump();

    final tabs = container.read(desktopTabsProvider);
    final activeId = tabs.activeId;
    expect(tabs.active?.kind, TabKind.playerScoreCard);
    expect(container.read(selectedPlayerProvider)?.name, 'Carlsen, Magnus');
    expect(container.read(scoreCardHasEventContextProvider), isTrue);
    expect(
      container.read(playerScoreCardByTabIdProvider)[activeId]?.name,
      'Carlsen, Magnus',
    );
  });
}

ProviderContainer _roundOpenContainer(
  _ControlledGameHydrationRepository gameRepository,
  List<GamesTourModel> games,
) {
  return ProviderContainer(
    overrides: [
      gameRepositoryProvider.overrideWithValue(gameRepository),
      tourRepositoryProvider.overrideWithValue(_StaticLayoutRosterRepository()),
      playerTourStandingsSnapshotProvider.overrideWith(
        _LayoutStandingsNotifier.new,
      ),
      mergedTournamentGamesProvider.overrideWith((ref) => games),
      tournamentRosterRefreshIntervalProvider.overrideWithValue(
        const Duration(days: 1),
      ),
    ],
  );
}

void _seedStandingsTabContext(ProviderContainer container) {
  container
      .read(desktopTabsProvider.notifier)
      .navigateActive(TabKind.tournamentDetail, title: 'Event');
  container.read(tournamentByTabIdProvider.notifier).state = const {
    'tournaments-default': GroupEventCardModel(
      id: 'event-1',
      title: 'Event',
      dates: '',
      maxAvgElo: 0,
      timeUntilStart: '',
      tourEventCategory: TourEventCategory.completed,
      timeControl: 'Standard',
      endDate: null,
      startDate: null,
    ),
  };
  container
      .read(
        tournamentDetailSegmentByTabIdProvider('tournaments-default').notifier,
      )
      .state = TournamentDetailSegment.standings;
}

Widget _standingsHarness(ProviderContainer container, {required String tabId}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 840,
          height: 480,
          child: TournamentStandingsView(
            tabId: tabId,
            tournamentId: 'event-1',
            tournamentTitle: 'Event',
            photoResolver: (_) async => null,
          ),
        ),
      ),
    ),
  );
}

PlayerStandingModel _standing({
  required String name,
  required int fideId,
  required int rating,
  required int rank,
}) {
  return PlayerStandingModel(
    countryCode: 'FID',
    title: 'GM',
    name: name,
    score: rating,
    scoreChange: 0,
    matchScore: '0 / 0',
    fideId: fideId,
    overallRank: rank,
  );
}

PlayerCard _card(String name, int fideId, int rating) {
  return PlayerCard(
    name: name,
    federation: 'FID',
    title: 'GM',
    rating: rating,
    countryCode: 'FID',
    team: null,
    fideId: fideId,
  );
}

GamesTourModel _game({
  required String id,
  required String round,
  required PlayerCard white,
  required PlayerCard black,
  required GameStatus status,
  GameSource source = GameSource.supabase,
  String tourId = 'event-1',
}) {
  return GamesTourModel(
    gameId: id,
    source: source,
    whitePlayer: white,
    blackPlayer: black,
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-id-$round',
    roundSlug: round,
    tourId: tourId,
  );
}

class _FakeStandingsNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async {
    return const PlayerTourStandingsSnapshot(
      tourIds: {'event-1'},
      standings: [
        PlayerStandingModel(
          countryCode: 'NOR',
          title: 'GM',
          name: 'Carlsen, Magnus',
          score: 2830,
          scoreChange: 0,
          matchScore: '1 / 1',
          fideId: 1503014,
          overallRank: 1,
        ),
      ],
    );
  }
}

class _LayoutStandingsNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async {
    return PlayerTourStandingsSnapshot(
      tourIds: const {'event-1'},
      standings: [
        _standing(
          name: 'Carlsen, Magnus',
          fideId: 1503014,
          rating: 2830,
          rank: 1,
        ).copyWith(matchScore: '1 / 1'),
        _standing(
          name: 'A Very Long Opponent Name That Must Not Move Rating',
          fideId: 46616543,
          rating: 2750,
          rank: 2,
        ).copyWith(matchScore: '0 / 1'),
      ],
    );
  }
}

class _ControlledOfficialRosterRepository implements TourRepository {
  final calls = <Completer<List<TournamentPlayer>>>[];

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) {
    expect(tourId, 'event-1');
    final completer = Completer<List<TournamentPlayer>>();
    calls.add(completer);
    return completer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StaticLayoutRosterRepository implements TourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    expect(tourId, 'event-1');
    return [
      TournamentPlayer(
        federation: 'FID',
        name: 'Carlsen, Magnus',
        title: 'GM',
        fideId: 1503014,
        played: 2,
        rating: 2830,
        score: 1.5,
      ),
      TournamentPlayer(
        federation: 'FID',
        name: 'Opponent',
        title: 'GM',
        fideId: 46616543,
        played: 2,
        rating: 2750,
        score: 0.5,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ControlledGameHydrationRepository implements GameRepository {
  final requests = <({String gameId, Completer<Games> completer})>[];

  @override
  Future<Games> getGameWithPGN(String gameId) {
    final completer = Completer<Games>();
    requests.add((gameId: gameId, completer: completer));
    return completer.future;
  }

  void complete(String gameId, GamesTourModel game) {
    requests
        .singleWhere((request) => request.gameId == gameId)
        .completer
        .complete(_hydratedGame(game));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Games _hydratedGame(GamesTourModel game) {
  Player toPlayer(PlayerCard card) {
    return Player(
      name: card.name,
      title: card.title,
      rating: card.rating,
      fideId: card.fideId ?? 0,
      fed: card.federation,
      clock: 0,
      team: card.team ?? '',
    );
  }

  return Games(
    id: game.gameId,
    roundId: game.roundId,
    roundSlug: game.roundSlug ?? '',
    tourId: game.tourId,
    tourSlug: game.tourSlug ?? '',
    players: [toPlayer(game.whitePlayer), toPlayer(game.blackPlayer)],
    status: game.gameStatus.displayText,
    pgn: '1. e4 e5 ${game.gameStatus.displayText}',
  );
}
