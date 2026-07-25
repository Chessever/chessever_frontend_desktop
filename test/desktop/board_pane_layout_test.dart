import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/player_hover_preview.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

class _CrossEventPlayerTourScreenNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      const PlayerTourStandingsSnapshot(
        tourIds: {'other-tour'},
        standings: [
          PlayerStandingModel(
            countryCode: 'ISR',
            name: 'Rozen, Eytan',
            score: 2498,
            scoreChange: 0,
            matchScore: '9 / 9',
          ),
        ],
      );
}

class _TaggedLivePlayerTourScreenNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      const PlayerTourStandingsSnapshot(
        tourIds: {'stable-tour'},
        standings: [
          PlayerStandingModel(
            countryCode: 'ISR',
            name: 'Rozen, Eytan',
            score: 2498,
            scoreChange: 0,
            matchScore: '3 / 4',
          ),
        ],
      );
}

class _BoardPointsTourRepository implements TourRepository {
  int calls = 0;

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    calls += 1;
    expect(tourId, 'stable-tour');
    return [
      TournamentPlayer(
        federation: 'ISR',
        name: 'Rozen, Eytan',
        title: 'IM',
        fideId: 2811040,
        played: 3,
        rating: 2498,
        score: 2,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RetryingBoardPointsTourRepository extends _BoardPointsTourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    calls += 1;
    expect(tourId, 'stable-tour');
    if (calls == 1) throw StateError('transient roster failure');
    return [
      TournamentPlayer(
        federation: 'ISR',
        name: 'Rozen, Eytan',
        title: 'IM',
        fideId: 2811040,
        played: 3,
        rating: 2498,
        score: 2,
      ),
    ];
  }
}

class _RefreshingBoardPointsTourRepository extends _BoardPointsTourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    calls += 1;
    expect(tourId, 'stable-tour');
    return [
      TournamentPlayer(
        federation: 'ISR',
        name: 'Rozen, Eytan',
        title: 'IM',
        fideId: 2811040,
        played: 3,
        rating: 2498,
        score: calls == 1 ? 2 : 2.5,
      ),
    ];
  }
}

class _RoundSevenBoardPointsTourRepository extends _BoardPointsTourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    calls += 1;
    expect(tourId, 'stable-tour');
    return [
      TournamentPlayer(
        federation: 'ISR',
        name: 'Rozen, Eytan',
        title: 'IM',
        played: 5,
        rating: 2498,
        score: 3,
      ),
      TournamentPlayer(
        federation: 'ARM',
        name: 'Martirosyan, Haik M.',
        title: 'GM',
        played: 7,
        rating: 2653,
        score: 6,
      ),
    ];
  }
}

class _BoardHoverGameRepository implements GameRepository {
  _BoardHoverGameRepository({this.failFirstBatch = false});

  final bool failFirstBatch;
  final List<String> requestedTourIds = <String>[];

  @override
  Future<List<Games>> getEventGamesByPlayer({
    required String tourId,
    int? fideId,
    required String playerName,
  }) async {
    requestedTourIds.add(tourId);
    if (failFirstBatch && requestedTourIds.length <= 2) {
      throw StateError('transient hover history failure');
    }
    return const <Games>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

GamesTourModel _stablePointsGame() => GamesTourModel(
  gameId: 'stable-game',
  whitePlayer: PlayerCard(
    name: 'Rozen, Eytan',
    federation: 'ISR',
    title: 'IM',
    rating: 2498,
    countryCode: 'ISR',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Martirosyan, Haik M.',
    federation: 'ARM',
    title: 'GM',
    rating: 2653,
    countryCode: 'ARM',
    team: null,
  ),
  whiteTimeDisplay: '',
  blackTimeDisplay: '',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.draw,
  roundId: 'round-3',
  tourId: 'stable-tour',
  source: GameSource.supabase,
);

Widget _pointsHeaderApp(GamesTourModel sourceGame) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 760,
      height: 48,
      child: DesktopBoardPlayerHeader(
        name: 'Rozen, Eytan',
        federation: 'ISR',
        title: 'IM',
        rating: 2498,
        fideId: null,
        result: DesktopBoardPlayerResult.draw,
        isWhite: true,
        isToMove: false,
        sourceGame: sourceGame,
      ),
    ),
  ),
);

Widget _historyHeaderApp() {
  return const MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 760,
        height: 48,
        child: DesktopBoardPlayerHeader(
          name: 'Player One',
          federation: 'USA',
          title: 'GM',
          rating: 2500,
          fideId: null,
          result: null,
          isWhite: true,
          isToMove: false,
          historyOwnerId: '',
          boardArgs: BoardTabGameArgs(
            pgn: '1. e4 e5 *',
            label: 'Sibling event',
            whiteName: 'Player One',
            blackName: 'Opponent One',
            eventGamesKey: BoardTabEventGamesKey(tourId: 'open-boards-1-66'),
            eventGames: <TournamentGameSummary>[
              TournamentGameSummary(
                id: 'board-1',
                name: 'Board 1',
                whitePlayer: 'Player One',
                blackPlayer: 'Opponent One',
                hasPgn: true,
                tourId: 'open-boards-1-66',
              ),
              TournamentGameSummary(
                id: 'board-67',
                name: 'Board 67',
                whitePlayer: 'Player One',
                blackPlayer: 'Opponent Two',
                hasPgn: true,
                tourId: 'open-boards-67-126',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

PlayerHoverPreviewIdentity _previewPlayer(
  WidgetTester tester,
  String playerName,
) => tester
    .widgetList<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
    .map((preview) => preview.player)
    .singleWhere((player) => player.name == playerName);

void main() {
  test('generated report assessment preserves incoming Lichess commentary', () {
    final merged = mergeReportMoveAnnotations(
      lichessAnnotations: const <int, LichessMoveAnnotation>{
        2: LichessMoveAnnotation(
          type: LichessMoveAnnotationType.inaccuracy,
          comment: 'Lichess: Strong knight retreat.',
        ),
      },
      reportAnnotations: const <int, LichessMoveAnnotation>{
        2: LichessMoveAnnotation(
          type: LichessMoveAnnotationType.blunder,
          comment: '',
          useClassificationIcon: true,
        ),
      },
    );

    expect(merged[2]?.type, LichessMoveAnnotationType.blunder);
    expect(merged[2]?.useClassificationIcon, isTrue);
    expect(merged[2]?.comment, 'Lichess: Strong knight retreat.');
  });

  test('generated report assessment owns the on-board move badge', () {
    final resolved = resolveBoardMoveAssessment(
      isOnMainline: true,
      userNags: const <int>[2],
      pgnNags: const <int>[6, 16],
      moveAnnotation: const LichessMoveAnnotation(
        type: LichessMoveAnnotationType.blunder,
        comment: '',
        useClassificationIcon: true,
      ),
    );

    expect(resolved.annotation?.type, LichessMoveAnnotationType.blunder);
    expect(resolved.glyph, isNull);
  });

  test(
    'neutral generated report owns quality while retaining incoming commentary',
    () {
      final merged = mergeReportMoveAnnotations(
        lichessAnnotations: const <int, LichessMoveAnnotation>{
          2: LichessMoveAnnotation(
            type: LichessMoveAnnotationType.inaccuracy,
            comment: 'Lichess: Keep this explanation.',
          ),
        },
        reportAnnotations: const <int, LichessMoveAnnotation>{},
        reportAnalyzedPlies: const <int>{2},
      );

      expect(merged[2]?.reportOwnsMoveQuality, isTrue);
      expect(merged[2]?.comment, 'Lichess: Keep this explanation.');

      final resolved = resolveBoardMoveAssessment(
        isOnMainline: true,
        userNags: const <int>[2],
        pgnNags: const <int>[6],
        moveAnnotation: merged[2],
      );
      expect(resolved.annotation, isNull);
      expect(resolved.glyph, isNull);
    },
  );

  testWidgets(
    'board player header keeps an initials avatar when no photo is available',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 760,
                height: 48,
                child: DesktopBoardPlayerHeader(
                  name: 'Ahmad, Khagan',
                  federation: 'AZE',
                  title: 'IM',
                  rating: 2480,
                  fideId: null,
                  result: DesktopBoardPlayerResult.lost,
                  isWhite: false,
                  isToMove: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final avatar = find.byKey(
        const ValueKey<String>('desktop-board-player-avatar'),
      );
      expect(avatar, findsOneWidget);
      expect(tester.getSize(avatar), const Size.square(42));
      expect(find.text('AK'), findsOneWidget);
    },
  );

  testWidgets(
    'board player header uses the current game context for an upward hover preview',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const staleSummary = TournamentGameSummary(
        id: 'game-1',
        name: 'Stale game',
        whitePlayer: 'Tiviakov, Sergei',
        blackPlayer: 'Current Opponent',
        whiteFederation: 'NED',
        blackFederation: 'GER',
        whiteTitle: 'GM',
        blackTitle: 'IM',
        whiteRating: 2530,
        blackRating: 2400,
        whiteFideId: 1001,
        blackFideId: 2001,
        hasPgn: true,
        pgn: '1. e4 e5 *',
        tourId: 'tour-1',
      );
      const localSummary = TournamentGameSummary(
        id: 'local-2',
        name: 'Local database game',
        whitePlayer: 'Tiviakov, Sergei',
        blackPlayer: 'Local Opponent',
        whiteRating: 2530,
        blackRating: 2450,
        hasPgn: true,
        pgn: '1. d4 d5 *',
        localPgnSource: TournamentGameLocalPgnSource(
          sourcePath: r'C:\Chess\database.pgn',
          sourceIndex: 7,
          sourceFileGameCount: 42,
          pgnFingerprint: 'local-fingerprint',
          title: 'Database PGN',
        ),
      );
      const headerOnlySummary = TournamentGameSummary(
        id: 'remote-empty',
        name: 'Remote header-only game',
        whitePlayer: 'Tiviakov, Sergei',
        blackPlayer: 'Remote Opponent',
        whiteRating: 2530,
        blackRating: 2500,
        hasPgn: false,
      );
      final currentGame = GamesTourModel(
        gameId: 'game-1',
        pgn: '1. e4 e5 2. Nf3 *',
        whitePlayer: PlayerCard(
          name: 'Tiviakov, Sergei',
          federation: 'NED',
          title: 'GM',
          rating: 2530,
          fideId: 1001,
          countryCode: 'NED',
          team: null,
        ),
        blackPlayer: PlayerCard(
          name: 'Current Opponent',
          federation: 'GER',
          title: 'IM',
          rating: 2600,
          fideId: 2001,
          countryCode: 'GER',
          team: null,
        ),
        whiteTimeDisplay: '',
        blackTimeDisplay: '',
        whiteClockCentiseconds: 0,
        blackClockCentiseconds: 0,
        gameStatus: GameStatus.ongoing,
        roundId: 'round-1',
        tourId: 'tour-1',
        source: GameSource.supabase,
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
                  name: 'Tiviakov, Sergei',
                  federation: 'NED',
                  title: 'GM',
                  rating: 2530,
                  fideId: null,
                  result: null,
                  isWhite: true,
                  isToMove: false,
                  openAbove: true,
                  sourceGame: currentGame,
                  boardArgs: BoardTabGameArgs(
                    gameId: 'game-1',
                    pgn: currentGame.pgn ?? '',
                    label: 'Current game',
                    whiteName: 'Tiviakov, Sergei',
                    blackName: 'Current Opponent',
                    eventBroadcastId: 'parent-event',
                    initialFen: '8/8/8/8/8/8/8/K6k w - - 0 1',
                    databaseTitle: 'Current database',
                    databaseGames: const [
                      staleSummary,
                      localSummary,
                      headerOnlySummary,
                    ],
                    gameListSelectedId: 'game-1',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final preview = tester.widget<PlayerHoverPreview>(
        find.byType(PlayerHoverPreview),
      );
      expect(preview.openAbove, isTrue);
      expect(preview.contextKey, 'game-1');
      expect(preview.player.name, 'Tiviakov, Sergei');
      expect(preview.games, hasLength(3));
      final currentPreviewGame = preview.games.singleWhere(
        (game) => game.id == 'game-1',
      );
      expect(currentPreviewGame.blackRating, 2600);

      final initialTabs = container.read(desktopTabsProvider);
      final initialBoardCount =
          initialTabs.tabs.where((tab) => tab.kind == TabKind.board).length;
      preview.onOpenOpponentInNewTab(
        const PlayerHoverPreviewIdentity(
          name: 'Current Opponent',
          federation: 'GER',
          title: 'IM',
          rating: 2600,
          fideId: 2001,
        ),
      );
      await tester.pump();
      var tabs = container.read(desktopTabsProvider);
      expect(
        tabs.tabs.where((tab) => tab.kind == TabKind.playerProfile),
        hasLength(1),
      );

      expect(preview.onOpenPlayerInNewTab, isNotNull);
      preview.onOpenPlayerInNewTab!(preview.player);
      await tester.pump();
      tabs = container.read(desktopTabsProvider);
      expect(
        tabs.tabs.where((tab) => tab.kind == TabKind.playerProfile),
        hasLength(2),
      );

      preview.onOpenGameInNewTab(currentPreviewGame);
      await tester.pump();
      tabs = container.read(desktopTabsProvider);
      expect(
        tabs.tabs.where((tab) => tab.kind == TabKind.board),
        hasLength(initialBoardCount + 1),
      );
      final firstOpenedBoardTab =
          tabs.tabs.where((tab) => tab.kind == TabKind.board).last;
      expect(
        container
            .read(boardTabGameArgsByTabIdProvider)[firstOpenedBoardTab.id]
            ?.eventBroadcastId,
        'parent-event',
      );

      preview.onOpenGameInNewTab(
        preview.games.singleWhere((game) => game.id == 'local-2'),
      );
      await tester.pump();
      tabs = container.read(desktopTabsProvider);
      final boardTabs = tabs.tabs.where((tab) => tab.kind == TabKind.board);
      expect(boardTabs, hasLength(initialBoardCount + 2));
      final openedArgs = container.read(
        boardTabGameArgsByTabIdProvider.select(
          (argsByTab) => argsByTab[boardTabs.last.id],
        ),
      );
      expect(openedArgs, isNotNull);
      expect(openedArgs!.gameId, isNull);
      expect(openedArgs.initialFen, '8/8/8/8/8/8/8/K6k w - - 0 1');
      expect(openedArgs.gameListSelectedId, 'local-2');
      expect(
        openedArgs.librarySaveOrigin?.sourcePath,
        r'C:\Chess\database.pgn',
      );
      expect(openedArgs.librarySaveOrigin?.sourceIndex, 7);
      expect(
        openedArgs.librarySaveOrigin?.sourcePgnFingerprint,
        'local-fingerprint',
      );

      preview.onOpenGameInNewTab(
        preview.games.singleWhere((game) => game.id == 'remote-empty'),
      );
      await tester.pump();
      tabs = container.read(desktopTabsProvider);
      final hydratedBoardTabs = tabs.tabs.where(
        (tab) => tab.kind == TabKind.board,
      );
      expect(hydratedBoardTabs, hasLength(initialBoardCount + 3));
      final hydratedArgs = container.read(
        boardTabGameArgsByTabIdProvider.select(
          (argsByTab) => argsByTab[hydratedBoardTabs.last.id],
        ),
      );
      expect(hydratedArgs, isNotNull);
      expect(hydratedArgs!.gameId, 'remote-empty');
      expect(hydratedArgs.pgn, isEmpty);
      expect(hydratedArgs.librarySaveOrigin, isNull);
    },
  );

  testWidgets('board player bar groups a word result with the larger clock', (
    tester,
  ) async {
    final sourceGame = GamesTourModel(
      gameId: 'game-1',
      whitePlayer: PlayerCard(
        name: 'White Player',
        federation: 'USA',
        title: 'GM',
        rating: 2500,
        countryCode: 'USA',
        team: null,
      ),
      blackPlayer: PlayerCard(
        name: 'Iniyan, Pa',
        federation: 'IND',
        title: 'GM',
        rating: 2581,
        countryCode: 'IND',
        team: null,
      ),
      whiteTimeDisplay: '25:02',
      blackTimeDisplay: '25:02',
      whiteClockCentiseconds: 150200,
      blackClockCentiseconds: 150200,
      gameStatus: GameStatus.draw,
      roundId: 'round-3',
      tourId: 'open-boards-67-126',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tournamentRosterStandingsProvider('open-boards-67-126').overrideWith(
            (ref) => Stream.value(const [
              PlayerStandingModel(
                countryCode: 'IND',
                name: 'Iniyan, Pa',
                score: 2581,
                scoreChange: 0,
                matchScore: '2 / 3',
                fideId: 25002767,
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 760,
                height: 48,
                child: DesktopBoardPlayerHeader(
                  name: 'Iniyan, Pa',
                  federation: 'IND',
                  title: 'GM',
                  rating: 2581,
                  fideId: null,
                  result: DesktopBoardPlayerResult.draw,
                  isWhite: false,
                  isToMove: false,
                  clockText: '25:02',
                  sourceGame: sourceGame,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final name = find.text('Iniyan, Pa');
    final rating = find.text('(2581)');
    final points = find.text('2/3');
    final point = find.text('½');
    final status = find.text('DRAW');
    final clock = find.text('25:02');

    expect(name, findsOneWidget);
    expect(rating, findsOneWidget);
    expect(points, findsNothing);
    expect(point, findsNothing);
    expect(status, findsOneWidget);
    expect(clock, findsOneWidget);
    expect(
      tester
          .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
          .player
          .pointsText,
      '2/3',
    );
    expect(
      tester.widget<Text>(rating).style?.color,
      kWhiteColor.withValues(alpha: 0.82),
    );

    final nameRect = tester.getRect(name);
    final ratingRect = tester.getRect(rating);
    final statusRect = tester.getRect(status);
    final clockRect = tester.getRect(clock);
    expect(ratingRect.left - nameRect.right, closeTo(8, 0.1));
    expect(ratingRect.right, lessThan(statusRect.left));
    expect(tester.widget<Text>(name).style?.fontSize, 14);
    expect(tester.widget<Text>(rating).style?.fontSize, 13);
    final flag = tester.widget<BackfilledFederationFlag>(
      find.byType(BackfilledFederationFlag),
    );
    expect(flag.width, 24);
    expect(flag.height, 17);
    expect(statusRect.right, lessThan(clockRect.left));
    expect(tester.widget<Text>(status).style?.fontSize, 12);
    expect(tester.widget<Text>(clock).style?.fontSize, 16);
    final statusSegment = find.byKey(const Key('desktop-board-result-status'));
    final clockSegment = find.byKey(const Key('desktop-board-clock-segment'));
    expect(tester.getSize(statusSegment).width, 52);
    expect(tester.getSize(statusSegment).height, 32);
    expect(tester.getSize(clockSegment).height, 32);
    expect(
      tester.getTopRight(statusSegment).dx,
      tester.getTopLeft(clockSegment).dx,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished result capsule suppresses the active clock outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 760,
              height: 48,
              child: DesktopBoardPlayerHeader(
                name: 'Player',
                federation: 'IND',
                title: 'GM',
                rating: 2581,
                fideId: null,
                result: DesktopBoardPlayerResult.lost,
                isWhite: false,
                isToMove: true,
                clockText: '02:35',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final capsule = tester.widget<Container>(
      find.byKey(const Key('desktop-board-result-clock-capsule')),
    );
    final decoration = capsule.decoration! as BoxDecoration;
    expect(decoration.border, Border.all(color: kDividerColor));
    expect(decoration.boxShadow, isNull);
  });

  testWidgets('board result capsule uses ChessEver outcome colors', (
    tester,
  ) async {
    final cases = [
      (
        result: DesktopBoardPlayerResult.won,
        label: 'WON',
        color: kPrimaryColor.withValues(alpha: 0.78),
      ),
      (
        result: DesktopBoardPlayerResult.lost,
        label: 'LOST',
        color: kRedColor.withValues(alpha: 0.82),
      ),
      (
        result: DesktopBoardPlayerResult.draw,
        label: 'DRAW',
        color: kMoveStatDrawColor,
      ),
    ];

    for (final testCase in cases) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 760,
                height: 48,
                child: DesktopBoardPlayerHeader(
                  name: 'Player',
                  federation: 'IND',
                  title: 'GM',
                  rating: 2581,
                  fideId: null,
                  result: testCase.result,
                  isWhite: false,
                  isToMove: false,
                  clockText: '25:02',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(testCase.label), findsOneWidget);
      final status = tester.widget<Container>(
        find.byKey(const Key('desktop-board-result-status')),
      );
      expect(status.color, testCase.color);
    }
  });

  test('maps finished board results from each player perspective', () {
    expect(
      boardPlayerResultForSide(GameStatus.whiteWins, isWhite: true),
      DesktopBoardPlayerResult.won,
    );
    expect(
      boardPlayerResultForSide(GameStatus.whiteWins, isWhite: false),
      DesktopBoardPlayerResult.lost,
    );
    expect(
      boardPlayerResultForSide(GameStatus.blackWins, isWhite: false),
      DesktopBoardPlayerResult.won,
    );
    expect(
      boardPlayerResultForSide(GameStatus.draw, isWhite: true),
      DesktopBoardPlayerResult.draw,
    );
    expect(boardPlayerResultForSide(GameStatus.ongoing, isWhite: true), isNull);
  });

  test('finished board results show only at the start and original ending', () {
    const endingPly = 5;

    expect(
      shouldShowFinishedBoardResult(
        const <int>[],
        gameEndingPlyIndex: endingPly,
      ),
      isTrue,
    );
    expect(
      shouldShowFinishedBoardResult(const <int>[
        2,
      ], gameEndingPlyIndex: endingPly),
      isFalse,
    );
    expect(
      shouldShowFinishedBoardResult(const <int>[
        endingPly,
      ], gameEndingPlyIndex: endingPly),
      isTrue,
    );
    expect(
      shouldShowFinishedBoardResult(const <int>[
        endingPly,
        0,
        0,
      ], gameEndingPlyIndex: endingPly),
      isFalse,
    );
    expect(
      shouldShowFinishedBoardResult(const <int>[
        endingPly + 1,
      ], gameEndingPlyIndex: endingPly),
      isFalse,
    );
    expect(
      shouldShowFinishedBoardResult(
        const <int>[],
        gameEndingPlyIndex: endingPly,
        isPreviewing: true,
      ),
      isFalse,
    );
    expect(
      shouldShowFinishedBoardResult(
        const <int>[endingPly],
        gameEndingPlyIndex: endingPly,
        isPreviewing: true,
      ),
      isFalse,
    );
  });

  test('resolves compact board points from canonical standings', () {
    const standings = [
      PlayerStandingModel(
        countryCode: 'IND',
        name: 'Iniyan, Pa',
        score: 2581,
        scoreChange: 0,
        matchScore: '2 / 3',
        fideId: 25002767,
      ),
      PlayerStandingModel(
        countryCode: 'USA',
        name: 'Name Fallback',
        score: 2400,
        scoreChange: 0,
        matchScore: '1.5 / 2',
      ),
    ];

    expect(
      boardPlayerMatchScore(
        standings: standings,
        fideId: 25002767,
        name: 'Different spelling',
      ),
      '2/3',
    );
    expect(
      boardPlayerMatchScore(
        standings: standings,
        fideId: null,
        name: 'Name-Fallback',
      ),
      '1.5/2',
    );
    expect(compactBoardMatchScore('0 / 0'), isNull);
  });

  testWidgets(
    'board passes canonical rating change and points to the hover preview',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tournamentRosterStandingsProvider('stable-tour').overrideWith(
              (ref) => Stream.value(const [
                PlayerStandingModel(
                  countryCode: 'ISR',
                  name: 'Rozen, Eytan',
                  score: 2498,
                  scoreChange: 19,
                  matchScore: '2 / 3',
                  fideId: 2811040,
                ),
              ]),
            ),
          ],
          child: _pointsHeaderApp(_stablePointsGame()),
        ),
      );
      await tester.pumpAndSettle();

      final preview = tester.widget<PlayerHoverPreview>(
        find.byType(PlayerHoverPreview),
      );
      expect(preview.player.ratingChange, 19);
      expect(preview.player.pointsText, '2/3');
    },
  );

  test('parses the Board round without reading digits from an opaque id', () {
    final game = _stablePointsGame().copyWith(
      roundId: 'opaque-2026-round-id',
      roundSlug: 'Round_7',
    );

    expect(boardGameRoundNumber(game), 7);
    expect(
      boardGameRoundNumber(
        _stablePointsGame().copyWith(roundId: 'opaque-2026-round-id'),
      ),
      isNull,
    );
    expect(
      boardGameRoundNumber(
        _stablePointsGame().copyWith(roundId: 'playground-7'),
      ),
      isNull,
    );
  });

  testWidgets(
    'board points survive global tournament context loss by using the tab tour',
    (tester) async {
      final repository = _BoardPointsTourRepository();
      final sourceGame = _stablePointsGame();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [tourRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 760,
                height: 48,
                child: DesktopBoardPlayerHeader(
                  name: 'Rozen, Eytan',
                  federation: 'ISR',
                  title: 'IM',
                  rating: 2498,
                  fideId: null,
                  result: DesktopBoardPlayerResult.draw,
                  isWhite: true,
                  isToMove: false,
                  sourceGame: sourceGame,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '2/3');
      expect(find.text('2/3'), findsNothing);
      expect(repository.calls, 1);
    },
  );

  testWidgets(
    'board hover score requires played count to match the tab game round',
    (tester) async {
      final repository = _RoundSevenBoardPointsTourRepository();
      final sourceGame = _stablePointsGame().copyWith(
        roundId: 'opaque-round-id',
        roundSlug: 'round-7',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [tourRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    width: 760,
                    height: 48,
                    child: DesktopBoardPlayerHeader(
                      name: 'Rozen, Eytan',
                      federation: 'ISR',
                      title: 'IM',
                      rating: 2498,
                      fideId: null,
                      result: DesktopBoardPlayerResult.lost,
                      isWhite: false,
                      isToMove: false,
                      sourceGame: sourceGame,
                    ),
                  ),
                  SizedBox(
                    width: 760,
                    height: 48,
                    child: DesktopBoardPlayerHeader(
                      name: 'Martirosyan, Haik M.',
                      federation: 'ARM',
                      title: 'GM',
                      rating: 2653,
                      fideId: null,
                      result: DesktopBoardPlayerResult.won,
                      isWhite: true,
                      isToMove: false,
                      sourceGame: sourceGame,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, isNull);
      expect(_previewPlayer(tester, 'Martirosyan, Haik M.').pointsText, '6/7');
      expect(find.text('3/5'), findsNothing);
      expect(find.text('6/7'), findsNothing);
    },
  );

  testWidgets('board hides points when the tab game round cannot be verified', (
    tester,
  ) async {
    final repository = _BoardPointsTourRepository();
    final sourceGame = _stablePointsGame().copyWith(roundId: 'opaque-round-id');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tourRepositoryProvider.overrideWithValue(repository)],
        child: _pointsHeaderApp(sourceGame),
      ),
    );
    await tester.pumpAndSettle();

    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, isNull);
    expect(find.text('2/3'), findsNothing);
  });

  testWidgets(
    'board points reject preserved live standings from an untagged event',
    (tester) async {
      final repository = _BoardPointsTourRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tourRepositoryProvider.overrideWithValue(repository),
            playerTourStandingsSnapshotProvider.overrideWith(
              _CrossEventPlayerTourScreenNotifier.new,
            ),
          ],
          child: _pointsHeaderApp(_stablePointsGame()),
        ),
      );
      await tester.pumpAndSettle();

      expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '2/3');
      expect(find.text('2/3'), findsNothing);
      expect(find.text('9/9'), findsNothing);
    },
  );

  testWidgets('board points retry after a transient keyed roster failure', (
    tester,
  ) async {
    final repository = _RetryingBoardPointsTourRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tourRepositoryProvider.overrideWithValue(repository)],
        child: _pointsHeaderApp(_stablePointsGame()),
      ),
    );
    await tester.pumpAndSettle();
    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, isNull);
    expect(find.text('2/3'), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '2/3');
    expect(find.text('2/3'), findsNothing);
    expect(repository.calls, 2);
  });

  testWidgets('newer tagged live points do not regress to an older roster', (
    tester,
  ) async {
    final repository = _BoardPointsTourRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          playerTourStandingsSnapshotProvider.overrideWith(
            _TaggedLivePlayerTourScreenNotifier.new,
          ),
        ],
        child: _pointsHeaderApp(
          _stablePointsGame().copyWith(roundId: 'round-4'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '3/4');
    expect(find.text('3/4'), findsNothing);
    expect(find.text('2/3'), findsNothing);
  });

  testWidgets('keyed roster points refresh after a successful snapshot', (
    tester,
  ) async {
    final repository = _RefreshingBoardPointsTourRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(seconds: 1),
          ),
        ],
        child: _pointsHeaderApp(_stablePointsGame()),
      ),
    );
    await tester.pumpAndSettle();
    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '2/3');
    expect(find.text('2/3'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(_previewPlayer(tester, 'Rozen, Eytan').pointsText, '2.5/3');
    expect(find.text('2.5/3'), findsNothing);
    expect(repository.calls, greaterThanOrEqualTo(2));
  });

  test('standing scope includes sibling board-category tour ids', () {
    final tourIds = resolveActiveStandingTourIds(
      selectedTourId: 'open-boards-1-66',
      selectedTourName: 'Open | Boards 1-66',
      tours: const [
        (id: 'open-boards-1-66', name: 'Open | Boards 1-66'),
        (id: 'open-boards-67-126', name: 'Open | Boards 67-126'),
        (id: 'women-boards-1-66', name: 'Women | Boards 1-66'),
      ],
    );

    expect(tourIds, contains('open-boards-1-66'));
    expect(tourIds, contains('open-boards-67-126'));
    expect(tourIds, isNot(contains('women-boards-1-66')));
  });

  test('board hover history key includes every tab-scoped sibling tour id', () {
    final key = boardPlayerHistoryKey(
      eventKey: const BoardTabEventGamesKey(tourId: 'open-boards-1-66'),
      eventGames: const <TournamentGameSummary>[
        TournamentGameSummary(
          id: 'board-1',
          name: 'Board 1',
          whitePlayer: 'Player One',
          blackPlayer: 'Opponent One',
          hasPgn: true,
          tourId: 'open-boards-1-66',
        ),
        TournamentGameSummary(
          id: 'board-67',
          name: 'Board 67',
          whitePlayer: 'Player One',
          blackPlayer: 'Opponent Two',
          hasPgn: true,
          tourId: 'open-boards-67-126',
        ),
      ],
      playerName: 'Player One',
      fideId: 1234,
      ownerId: 'board-tab',
    );

    expect(key?.tourIds, <String>['open-boards-1-66', 'open-boards-67-126']);
  });

  testWidgets('closed Board hover history releases its polling subscription', (
    tester,
  ) async {
    final repository = _BoardHoverGameRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
        child: _historyHeaderApp(),
      ),
    );
    await tester.pump();

    tester
        .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
        .onPreviewOpened!();
    await tester.pumpAndSettle();
    expect(repository.requestedTourIds, <String>[
      'open-boards-1-66',
      'open-boards-67-126',
    ]);

    tester
        .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
        .onPreviewClosed!();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));

    expect(repository.requestedTourIds, hasLength(2));
  });

  testWidgets('reopening Board hover retries an initial history failure', (
    tester,
  ) async {
    final repository = _BoardHoverGameRepository(failFirstBatch: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
        child: _historyHeaderApp(),
      ),
    );
    await tester.pump();

    tester
        .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
        .onPreviewOpened!();
    await tester.pumpAndSettle();
    expect(repository.requestedTourIds, hasLength(2));

    tester
        .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
        .onPreviewClosed!();
    await tester.pump();
    await tester.pump();
    tester
        .widget<PlayerHoverPreview>(find.byType(PlayerHoverPreview))
        .onPreviewOpened!();
    await tester.pumpAndSettle();

    expect(repository.requestedTourIds, hasLength(4));
  });

  test('desktop board eval bar hides when engine analysis is off', () {
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: false, showEngineGauge: true),
      ),
      isFalse,
    );
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: true, showEngineGauge: false),
      ),
      isFalse,
    );
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: true, showEngineGauge: true),
      ),
      isTrue,
    );
  });

  test('game-card eval bar follows engine gauge setting only after load', () {
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue.data(EngineSettings(showEngineGauge: true)),
      ),
      isTrue,
    );
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue.data(EngineSettings(showEngineGauge: false)),
      ),
      isFalse,
    );
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue<EngineSettings>.loading(),
      ),
      isFalse,
    );
  });

  test('board resize never enters focus mode implicitly', () {
    final scenarios = [
      (
        requestedSize: 759.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 760.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 900.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 620.0,
        grewPastResizeLimit: true,
        isAlreadyFocused: false,
      ),
      (requestedSize: 900.0, grewPastResizeLimit: true, isAlreadyFocused: true),
    ];
    for (final scenario in scenarios) {
      expect(
        shouldEnterBoardFocusAfterResize(
          requestedSize: scenario.requestedSize,
          grewPastResizeLimit: scenario.grewPastResizeLimit,
          isAlreadyFocused: scenario.isAlreadyFocused,
        ),
        isFalse,
      );
    }
  });

  test('board resize drag uses dominant signed axis without cancellation', () {
    expect(desktopBoardResizeDragDelta(const Offset(96, 24)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(96, -24)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(24, -96)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(-24, -96)), -96);
    expect(desktopBoardResizeDragDelta(const Offset(-96, 24)), -96);
    expect(desktopBoardResizeDragDelta(const Offset(-24, 96)), -96);
  });

  test('board annotation clear hit-test sweeps clicks on board squares', () {
    const contentSize = Size(1000, 800);
    const boardSize = 600.0;
    const boardWithBar = 636.0;
    const topRowHeight = 44.0;
    const bottomRowHeight = 44.0;
    const headerGap = 4.0;

    // Column is centered: left = 182, board top = 76. Board itself starts
    // after the eval bar reservation and ends at x=818.
    expect(
      shouldClearBoardAnnotationsForBoardAreaClick(
        localPosition: const Offset(500, 350),
        contentSize: contentSize,
        boardSize: boardSize,
        boardWithBar: boardWithBar,
        topRowHeight: topRowHeight,
        bottomRowHeight: bottomRowHeight,
        headerGap: headerGap,
      ),
      isTrue,
      reason: 'left-clicks on the board sweep every drawn annotation',
    );
  });

  test('board annotation clear hit-test accepts empty board margin', () {
    expect(
      shouldClearBoardAnnotationsForBoardAreaClick(
        localPosition: const Offset(80, 350),
        contentSize: const Size(1000, 800),
        boardSize: 600,
        boardWithBar: 636,
        topRowHeight: 44,
        bottomRowHeight: 44,
        headerGap: 4,
      ),
      isTrue,
      reason: 'empty side margin around the board is the clear-all gesture',
    );
  });

  test('board annotation clear hit-test ignores player/control rows', () {
    expect(
      shouldClearBoardAnnotationsForBoardAreaClick(
        localPosition: const Offset(80, 40),
        contentSize: const Size(1000, 800),
        boardSize: 600,
        boardWithBar: 636,
        topRowHeight: 44,
        bottomRowHeight: 44,
        headerGap: 4,
      ),
      isFalse,
      reason: 'clicking player headers or board controls should not clear',
    );
  });

  test(
    'dirty board close confirmation only appears for notation-changing edits',
    () {
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: false,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4',
        ),
        isFalse,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4 e5',
        ),
        isFalse,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4',
        ),
        isTrue,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4',
          lastAppliedPgn: null,
        ),
        isTrue,
      );
    },
  );

  test('empty board args do not overwrite a restored build-tree session', () {
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: false,
        hasCurrentMoves: true,
        dirtySinceLoad: true,
        loadedFrom: 'tab:Player tree',
      ),
      isTrue,
    );
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: true,
        hasCurrentMoves: true,
        dirtySinceLoad: true,
        loadedFrom: 'tab:Player tree',
      ),
      isFalse,
    );
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: true,
        hasCurrentMoves: false,
        dirtySinceLoad: false,
        loadedFrom: 'tab:Player tree',
      ),
      isFalse,
    );
  });

  test('hydrated tab PGN is persisted even for background Board tabs', () {
    const args = BoardTabGameArgs(
      gameId: 'game-1',
      pgn: '',
      label: 'Alpha vs Beta',
      whiteName: 'Alpha',
      blackName: 'Beta',
    );

    expect(
      shouldPersistHydratedBoardTabPgn(
        hydratedTabId: 'background-tab',
        currentArgs: args,
        expectedGameId: 'game-1',
      ),
      isTrue,
    );
    expect(
      shouldApplyHydratedBoardTabPgn(
        activeTabId: 'explorer-tab',
        hydratedTabId: 'background-tab',
      ),
      isFalse,
    );
  });

  test('hydrated tab PGN is ignored when the tab changed games', () {
    const args = BoardTabGameArgs(
      gameId: 'game-2',
      pgn: '',
      label: 'Gamma vs Delta',
      whiteName: 'Gamma',
      blackName: 'Delta',
    );

    expect(
      shouldPersistHydratedBoardTabPgn(
        hydratedTabId: 'board-tab',
        currentArgs: args,
        expectedGameId: 'game-1',
      ),
      isFalse,
    );
  });

  test('board focus reserves player rows and compact padding', () {
    final focused = computeBoardAreaChromeMetrics(
      focusMode: true,
      hasPlayerInfo: false,
    );

    expect(focused.hasHeaders, isTrue);
    expect(focused.topRowHeight, greaterThan(0));
    expect(focused.bottomRowHeight, greaterThan(0));
    expect(focused.headerGapTotal, greaterThan(0));
    expect(focused.outerPadding, greaterThan(0));
    expect(focused.outerPadding, lessThan(24));

    final regularWithoutPlayers = computeBoardAreaChromeMetrics(
      focusMode: false,
      hasPlayerInfo: false,
    );
    expect(regularWithoutPlayers.hasHeaders, isFalse);
    expect(regularWithoutPlayers.topRowHeight, 32);
    expect(regularWithoutPlayers.bottomRowHeight, 22);
  });
}
