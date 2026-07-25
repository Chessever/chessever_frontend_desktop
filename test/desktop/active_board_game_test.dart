import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/event_rail_games.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  test('scratch board keeps the local PGN identity after its first save', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(boardTabAttachedLibrarySaveOriginByTabIdProvider.notifier)
        .attachLocalPgn(
          tabId: 'scratch-board',
          sourcePath: r'C:\Games\prep.pgn',
          sourceIndex: 2,
          sourceFileGameCount: 3,
          sourcePgnFingerprint: 'fingerprint-3',
          title: 'White vs Black',
        );

    final origin =
        container.read(
          boardTabAttachedLibrarySaveOriginByTabIdProvider,
        )['scratch-board'];
    expect(origin?.kind, BoardTabLibrarySaveOriginKind.localPgnFile);
    expect(origin?.sourcePath, r'C:\Games\prep.pgn');
    expect(origin?.sourceIndex, 2);
    expect(origin?.sourceFileGameCount, 3);
    expect(origin?.sourcePgnFingerprint, 'fingerprint-3');
  });

  test('saving a copy does not replace an existing update identity', () {
    const existing = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: r'C:\Games\original.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 1,
      title: 'Original',
    );

    expect(
      shouldAttachLocalPgnIdentityAfterSave(
        sourceOrigin: null,
        attachedOrigin: null,
        hasLocalUpdateTarget: true,
      ),
      isTrue,
    );
    expect(
      shouldAttachLocalPgnIdentityAfterSave(
        sourceOrigin: existing,
        attachedOrigin: null,
        hasLocalUpdateTarget: true,
      ),
      isFalse,
    );
    expect(
      shouldAttachLocalPgnIdentityAfterSave(
        sourceOrigin: null,
        attachedOrigin: existing,
        hasLocalUpdateTarget: true,
      ),
      isFalse,
    );
  });

  testWidgets('replaceActive opens the same game in the current tab', (
    tester,
  ) async {
    late String existingId;
    late String eventId;
    late String openedId;
    late DesktopTabsState tabsState;
    late Map<String, BoardTabGameArgs> argsByTab;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () {
                  existingId = openBoardGameTab(
                    ref,
                    _args('game-1'),
                    reuseExisting: false,
                  );
                  eventId = ref
                      .read(desktopTabsProvider.notifier)
                      .open(TabKind.tournamentDetail, reuseExisting: false);
                  openedId = openBoardGameTab(
                    ref,
                    _args('game-1'),
                    replaceActive: true,
                  );
                  tabsState = ref.read(desktopTabsProvider);
                  argsByTab = ref.read(boardTabGameArgsByTabIdProvider);
                },
                child: const Text('run'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('run'));
    await tester.pump();

    expect(openedId, eventId);
    expect(tabsState.activeId, eventId);
    expect(
      tabsState.tabs.firstWhere((t) => t.id == eventId).kind,
      TabKind.board,
    );
    expect(argsByTab[existingId]?.gameId, 'game-1');
    expect(argsByTab[eventId]?.gameId, 'game-1');
  });

  testWidgets('replaceActive clears stale tab FEN when the game changes', (
    tester,
  ) async {
    late String tabId;
    late Map<String, String> fenByTab;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () {
                  tabId = openBoardGameTab(
                    ref,
                    _args('game-1'),
                    reuseExisting: false,
                  );
                  ref
                      .read(boardTabFenProvider.notifier)
                      .setFen(tabId, '8/8/8/8/8/8/8/K6k w - - 0 1');
                  openBoardGameTab(ref, _args('game-2'), replaceActive: true);
                  fenByTab = ref.read(boardTabFenProvider);
                },
                child: const Text('run'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('run'));
    await tester.pump();

    expect(fenByTab, isNot(contains(tabId)));
  });

  testWidgets(
    'replaceActive clears stale board pane session when game changes',
    (tester) async {
      late String tabId;
      late Map<String, BoardPaneSession> sessionsByTab;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                return TextButton(
                  onPressed: () {
                    tabId = openBoardGameTab(
                      ref,
                      _args('game-1'),
                      reuseExisting: false,
                    );
                    ref
                        .read(boardPaneSessionByTabIdProvider.notifier)
                        .put(
                          tabId,
                          BoardPaneSession(
                            game: ChessGame.fromPgn('', '1. e4 e5 *'),
                            pointer: const <int>[1],
                            pgnHeaders: const <String, String>{},
                            flipped: false,
                            loadedFrom: 'tab:game-1',
                            lastAppliedPgn: '1. e4 e5 *',
                            lastAppliedGameId: 'game-1',
                            lastAppliedInitialFenKey: null,
                            dirtySinceLoad: false,
                            hasUnseenMoves: false,
                            undoStack: const <BoardUndoSnapshot>[],
                          ),
                        );
                    openBoardGameTab(ref, _args('game-2'), replaceActive: true);
                    sessionsByTab = ref.read(boardPaneSessionByTabIdProvider);
                  },
                  child: const Text('run'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('run'));
      await tester.pump();

      expect(sessionsByTab, isNot(contains(tabId)));
    },
  );

  testWidgets('opening a separate game tab preserves build-tree session', (
    tester,
  ) async {
    late String treeTabId;
    late String gameTabId;
    late BoardPaneSession seededSession;
    late BoardPaneSession? restoredTreeSession;
    late Map<String, BoardTabGameArgs> argsByTab;
    late DesktopTabsState tabsState;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () {
                  final tabs = ref.read(desktopTabsProvider.notifier);
                  treeTabId = tabs.open(
                    TabKind.board,
                    title: 'Carlsen tree',
                    reuseExisting: false,
                  );
                  ref
                      .read(boardTabGameArgsByTabIdProvider.notifier)
                      .update(
                        (m) => <String, BoardTabGameArgs>{
                          ...m,
                          treeTabId: const BoardTabGameArgs(
                            pgn: '',
                            label: 'Carlsen tree',
                            whiteName: '',
                            blackName: '',
                            fenSeed:
                                'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                            initialFen:
                                'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                          ),
                        },
                      );
                  seededSession = BoardPaneSession(
                    game: ChessGame.fromPgn('', '1. e4 e5 2. Nf3 *'),
                    pointer: const <int>[2],
                    pgnHeaders: const <String, String>{},
                    flipped: false,
                    loadedFrom: 'tab:Carlsen tree',
                    lastAppliedPgn: null,
                    lastAppliedGameId: null,
                    lastAppliedInitialFenKey: null,
                    dirtySinceLoad: true,
                    hasUnseenMoves: false,
                    undoStack: const <BoardUndoSnapshot>[],
                  );
                  ref
                      .read(boardPaneSessionByTabIdProvider.notifier)
                      .put(treeTabId, seededSession);

                  gameTabId = openBoardGameTab(
                    ref,
                    _args('game-1'),
                    reuseExisting: false,
                    replaceActive: false,
                  );
                  restoredTreeSession =
                      ref.read(boardPaneSessionByTabIdProvider)[treeTabId];
                  argsByTab = ref.read(boardTabGameArgsByTabIdProvider);
                  tabsState = ref.read(desktopTabsProvider);
                },
                child: const Text('run'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('run'));
    await tester.pump();

    expect(gameTabId, isNot(treeTabId));
    expect(tabsState.activeId, gameTabId);
    expect(argsByTab[treeTabId]?.pgn, isEmpty);
    expect(argsByTab[gameTabId]?.gameId, 'game-1');
    expect(restoredTreeSession, same(seededSession));
    expect(restoredTreeSession?.game.mainline.map((move) => move.uci), [
      'e2e4',
      'e7e5',
      'g1f3',
    ]);
  });

  test('board player taps require event context for score card routing', () {
    expect(boardPlayerTapEventContextGame(null), isNull);
    expect(boardPlayerTapEventContextGame(_game(tourId: '')), isNull);

    final eventGame = _game(tourId: 'tour-1');
    expect(boardPlayerTapEventContextGame(eventGame), same(eventGame));
  });

  testWidgets(
    'score card reopen ignores stale metadata after replaceActive board navigation',
    (tester) async {
      late String scoreCardTabId;
      late String boardTabId;
      late String reopenedScoreCardTabId;
      late DesktopTabsState tabsState;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                return TextButton(
                  onPressed: () {
                    const player = PlayerStandingModel(
                      countryCode: 'AZE',
                      title: 'GM',
                      name: 'Durarbayli, Vasif',
                      score: 2590,
                      scoreChange: 0,
                      matchScore: null,
                      fideId: 13402960,
                    );
                    scoreCardTabId = openPlayerScoreCard(ref, player);
                    boardTabId = openBoardGameTab(
                      ref,
                      _args('game-from-score-card'),
                      replaceActive: true,
                    );
                    reopenedScoreCardTabId = openPlayerScoreCard(ref, player);
                    tabsState = ref.read(desktopTabsProvider);
                  },
                  child: const Text('reopen scorecard'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('reopen scorecard'));
      await tester.pump();

      expect(boardTabId, scoreCardTabId);
      expect(reopenedScoreCardTabId, isNot(scoreCardTabId));
      expect(tabsState.activeId, reopenedScoreCardTabId);
      expect(
        tabsState.tabs.firstWhere((t) => t.id == scoreCardTabId).kind,
        TabKind.board,
      );
      expect(
        tabsState.tabs.firstWhere((t) => t.id == reopenedScoreCardTabId).kind,
        TabKind.playerScoreCard,
      );
    },
  );

  testWidgets('tournament cards open without event-list hydration', (
    tester,
  ) async {
    final repository = _BlockingGameRepository();
    late DesktopTabsState tabsState;
    late Map<String, BoardTabGameArgs> argsByTab;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () async {
                  await openTournamentGameTab(
                    ref,
                    _game(tourId: 'tour-1'),
                    'Event',
                  );
                  tabsState = ref.read(desktopTabsProvider);
                  argsByTab = ref.read(boardTabGameArgsByTabIdProvider);
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final activeId = tabsState.activeId;
    expect(activeId, isNotNull);
    expect(
      tabsState.tabs.firstWhere((t) => t.id == activeId).kind,
      TabKind.board,
    );
    expect(argsByTab[activeId]?.gameId, 'game-1');
    expect(argsByTab[activeId]?.eventGames, hasLength(1));
    expect(argsByTab[activeId]?.eventGamesLoading, isFalse);
    expect(repository.gamePgnFetches, 0);
    expect(repository.eventFetches, 0);

    repository.complete();
  });

  testWidgets('tournament open flow preserves supplied route context', (
    tester,
  ) async {
    late Map<String, BoardTabGameArgs> argsByTab;
    final routeGames = [
      for (var i = 0; i < 100; i++) _game(gameId: 'game-$i', tourId: 'tour-$i'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () async {
                  await openTournamentGameTab(
                    ref,
                    routeGames[50],
                    'Event',
                    routeTitle: 'Player games',
                    routeGames: routeGames,
                  );
                  argsByTab = ref.read(boardTabGameArgsByTabIdProvider);
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final args = argsByTab.values.single;
    expect(args.routeTitle, 'Player games');
    expect(args.routeGames, hasLength(61));
    expect(args.routeGames.first.id, 'game-20');
    expect(args.routeGames.last.id, 'game-80');
    expect(args.routeGames.map((game) => game.id), contains('game-50'));
    expect(args.eventGames.map((game) => game.id), ['game-50']);
  });

  testWidgets('tournament open keeps a bounded event seed for the board rail', (
    tester,
  ) async {
    late Map<String, BoardTabGameArgs> argsByTab;
    final now = DateTime.now();
    final eventGames = [
      for (var round = 1; round <= 9; round++)
        for (var board = 1; board <= 12; board++)
          _game(
            gameId: 'round-$round-game-$board',
            tourId: 'tour-1',
            round: round,
            status: round == 9 ? GameStatus.ongoing : GameStatus.whiteWins,
            lastMoveTime:
                round == 9 ? now.subtract(const Duration(minutes: 1)) : null,
            dateStart: now.subtract(Duration(days: 9 - round)),
          ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameRepositoryProvider.overrideWithValue(_EmptyGameRepository()),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () async {
                  await openTournamentGameTab(
                    ref,
                    eventGames.last,
                    'Nine-round event',
                    eventGames: eventGames,
                  );
                  argsByTab = ref.read(boardTabGameArgsByTabIdProvider);
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final args = argsByTab.values.single;
    expect(args.eventGames, hasLength(31));
    expect(args.eventGames.map((game) => game.id), contains('round-9-game-12'));
    expect(args.eventGames.length, lessThanOrEqualTo(kEventRailGamesPageSize));
    expect(args.eventGamesKey?.tourId, 'tour-1');
    expect(args.gameListSelectedId, 'round-9-game-12');
  });
}

BoardTabGameArgs _args(String gameId) {
  return BoardTabGameArgs(
    gameId: gameId,
    pgn: '1. e4 e5 *',
    label: 'White vs Black',
    whiteName: 'White',
    blackName: 'Black',
  );
}

GamesTourModel _game({
  String gameId = 'game-1',
  required String tourId,
  int round = 1,
  GameStatus status = GameStatus.ongoing,
  DateTime? lastMoveTime,
  DateTime? dateStart,
}) {
  return GamesTourModel(
    gameId: gameId,
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    lastMove: status == GameStatus.ongoing ? 'e7e5' : null,
    pgn: status == GameStatus.ongoing ? null : '1. e4 e5 1-0',
    roundId: 'round-$round',
    roundSlug: 'round-$round',
    tourId: tourId,
    lastMoveTime: lastMoveTime,
    dateStart: dateStart,
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 0,
    countryCode: '',
    team: null,
  );
}

class _BlockingGameRepository implements GameRepository {
  final Completer<List<Games>> _eventCompleter = Completer<List<Games>>();
  var eventFetches = 0;
  var gamePgnFetches = 0;

  @override
  Future<String?> getGamePgn(String gameId) {
    gamePgnFetches += 1;
    return Completer<String?>().future;
  }

  @override
  Future<Games> getGameWithPGN(String gameId) async {
    throw StateError('No hydrated game fixture for $gameId');
  }

  @override
  Future<List<Games>> getGamesByTourId(
    String tourId, {
    int? limit,
    int offset = 0,
  }) {
    eventFetches += 1;
    return _eventCompleter.future;
  }

  void complete() {
    if (!_eventCompleter.isCompleted) {
      _eventCompleter.complete(const <Games>[]);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyGameRepository implements GameRepository {
  @override
  Future<String?> getGamePgn(String gameId) async => null;

  @override
  Future<Games> getGameWithPGN(String gameId) async {
    throw StateError('No hydrated game fixture for $gameId');
  }

  @override
  Future<List<Games>> getGamesByTourId(
    String tourId, {
    int? limit,
    int offset = 0,
  }) async {
    return const <Games>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
