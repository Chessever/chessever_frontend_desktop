import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';

void main() {
  group('play session castling UCI normalization', () {
    test('rewrites white king-to-rook castling to standard UCI', () {
      final position = Chess.fromSetup(
        Setup.parseFen('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1'),
      );

      expect(debugStandardizePlayMoveUci('e1h1', position), 'e1g1');
      expect(debugStandardizePlayMoveUci('e1a1', position), 'e1c1');
    });

    test('rewrites black king-to-rook castling to standard UCI', () {
      final position = Chess.fromSetup(
        Setup.parseFen('r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1'),
      );

      expect(debugStandardizePlayMoveUci('e8h8', position), 'e8g8');
      expect(debugStandardizePlayMoveUci('e8a8', position), 'e8c8');
    });

    test('leaves non-castling moves unchanged', () {
      final position = Chess.initial;

      expect(debugStandardizePlayMoveUci('e2e4', position), 'e2e4');
      expect(debugStandardizePlayMoveUci('g1f3', position), 'g1f3');
    });

    test('queues king-to-rook castling premove as standard UCI', () {
      final notifier = _notifier(
        startingFen: 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
      );
      addTearDown(notifier.dispose);

      expect(notifier.queuePremove('e1h1'), isTrue);
      expect(notifier.state.premoves, ['e1g1']);
    });

    test('queues chained pawn premoves on the same pawn', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);

      expect(notifier.queuePremove('e2e4'), isTrue);
      expect(notifier.queuePremove('e4e5'), isTrue);
      expect(notifier.queuePremove('e5e6'), isTrue);
      expect(notifier.state.premoves, ['e2e4', 'e4e5', 'e5e6']);

      final virtual = buildVirtualPlayBoard(
        notifier.state.position.board,
        notifier.state.premoves,
      );
      expect(virtual.pieceAt(Square.e2), isNull);
      expect(virtual.pieceAt(Square.e4), isNull);
      expect(virtual.pieceAt(Square.e5), isNull);
      expect(virtual.pieceAt(Square.e6)?.role, Role.pawn);
      expect(virtual.pieceAt(Square.e6)?.color, Side.white);
    });

    test('allows premove onto own-piece square (anticipated capture)', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);

      // Queen d1 -> d2 where own pawn sits. Must be accepted.
      expect(notifier.queuePremove('d1d2'), isTrue);
      expect(notifier.state.premoves, ['d1d2']);
    });

    test('chains premoves through squares occupied by own pieces', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);

      // Bishop f1 -> e2 (own pawn there), then queen d1 -> e2 (own bishop
      // we just speculatively moved there). Both must queue.
      expect(notifier.queuePremove('f1e2'), isTrue);
      expect(notifier.queuePremove('d1e2'), isTrue);
      expect(notifier.state.premoves, ['f1e2', 'd1e2']);
    });

    test('rejects premove with identical from/to squares', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);

      expect(notifier.queuePremove('e2e2'), isFalse);
    });

    test('queues auto-queened pawn promotion premove', () {
      final notifier = _notifier(
        startingFen: '4k3/4P3/8/8/8/8/8/4K3 b - - 0 1',
      );
      addTearDown(notifier.dispose);

      expect(notifier.queuePremove('e7e8q'), isTrue);
      expect(notifier.state.premoves, ['e7e8q']);

      final virtual = buildVirtualPlayBoard(
        notifier.state.position.board,
        notifier.state.premoves,
      );
      final promoted = virtual.pieceAt(Square.e8);
      expect(promoted?.role, Role.queen);
      expect(promoted?.color, Side.white);
      expect(virtual.pieceAt(Square.e7), isNull);
    });

    test('virtual board reflects multi-piece queued premoves', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);

      expect(notifier.queuePremove('e2e4'), isTrue);
      expect(notifier.queuePremove('g1f3'), isTrue);
      expect(notifier.queuePremove('f1c4'), isTrue);

      final virtual = buildVirtualPlayBoard(
        notifier.state.position.board,
        notifier.state.premoves,
      );
      expect(virtual.pieceAt(Square.e2), isNull);
      expect(virtual.pieceAt(Square.e4)?.role, Role.pawn);
      expect(virtual.pieceAt(Square.g1), isNull);
      expect(virtual.pieceAt(Square.f3)?.role, Role.knight);
      expect(virtual.pieceAt(Square.f1), isNull);
      expect(virtual.pieceAt(Square.c4)?.role, Role.bishop);
    });

    test('keeps an uncapped multi-premove queue', () {
      final notifier = _notifier(startingFen: '7k/8/8/8/8/8/8/R3K3 w - - 0 1');
      addTearDown(notifier.dispose);
      const moves = [
        'a1a2',
        'a2a3',
        'a3a4',
        'a4a5',
        'a5a6',
        'a6a7',
        'a7a8',
        'a8b8',
        'b8c8',
        'c8d8',
      ];

      for (final move in moves) {
        expect(notifier.queuePremove(move), isTrue);
      }

      expect(notifier.state.premoves, moves);
    });

    test('builds board-pane notation from active play history', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);
      final afterE4 = notifier.state.position.play(NormalMove.fromUci('e2e4'));
      final afterE5 = afterE4.play(NormalMove.fromUci('e7e5'));
      final state = notifier.state.copyWith(
        position: afterE5,
        history: const ['e2e4', 'e7e5'],
        lastMove: NormalMove.fromUci('e7e5'),
      );

      final game = debugPlayNotationGame(state);

      expect(game.mainline.map((move) => move.san), ['e4', 'e5']);
      expect(game.mainline.map((move) => move.uci), ['e2e4', 'e7e5']);
      expect(debugPlayNotationActivePointer(game), [1]);
    });

    test('maps play review plies to notation pointers', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);
      final afterE4 = notifier.state.position.play(NormalMove.fromUci('e2e4'));
      final afterE5 = afterE4.play(NormalMove.fromUci('e7e5'));
      final state = notifier.state.copyWith(
        position: afterE5,
        history: const ['e2e4', 'e7e5'],
        lastMove: NormalMove.fromUci('e7e5'),
      );

      final game = debugPlayNotationGame(state);

      expect(debugPlayNotationPointerForPly(game, 0), isEmpty);
      expect(debugPlayNotationPointerForPly(game, 1), [0]);
      expect(debugPlayNotationPointerForPly(game, 2), [1]);
      expect(debugPlayNotationPointerForPly(game, 3), [1]);
    });

    test('replays active play history for reviewed board positions', () {
      final notifier = _notifier(startingFen: Chess.initial.fen);
      addTearDown(notifier.dispose);
      final afterE4 = notifier.state.position.play(NormalMove.fromUci('e2e4'));
      final afterE5 = afterE4.play(NormalMove.fromUci('e7e5'));
      final state = notifier.state.copyWith(
        position: afterE5,
        history: const ['e2e4', 'e7e5'],
        lastMove: NormalMove.fromUci('e7e5'),
      );

      expect(debugPlayReviewFen(state, 0), Chess.initial.fen);
      expect(debugPlayReviewFen(state, 1), afterE4.fen);
      expect(debugPlayReviewFen(state, null), afterE5.fen);
      expect(debugPlayReviewFen(state, 99), afterE5.fen);
    });

    test('prefills board-pane notation from play-from-here history', () {
      final state = debugInitialPlayState(
        _config(
          startingFen: Chess.initial.fen,
          startingMovesUci: const ['e2e4', 'e7e5'],
        ),
      );
      final afterE4 = Chess.initial.play(NormalMove.fromUci('e2e4'));
      final afterE5 = afterE4.play(NormalMove.fromUci('e7e5'));

      expect(state.position.fen, afterE5.fen);
      expect(state.history, ['e2e4', 'e7e5']);
      expect(state.lastMove?.uci, 'e7e5');

      final game = debugPlayNotationGame(state);

      expect(game.startingFen, Chess.initial.fen);
      expect(game.mainline.map((move) => move.san), ['e4', 'e5']);
      expect(game.mainline.map((move) => move.uci), ['e2e4', 'e7e5']);
      expect(debugPlayNotationActivePointer(game), [1]);
    });

    test('clearing a starting seed also clears prefilled moves', () {
      final seeded = PlayConfig.defaults.copyWith(
        startingFen: Chess.initial.fen,
        startingMovesUci: const ['e2e4'],
      );

      final cleared = seeded.copyWith(
        clearStartingFen: true,
        clearStartingMoves: true,
      );

      expect(cleared.startingFen, isNull);
      expect(cleared.startingMovesUci, isEmpty);
      expect(cleared.hasStartingPositionSeed, isFalse);
    });

    test('keeps casual game clocks stopped before the first move', () {
      final state = debugInitialPlayState(
        _config(startingFen: Chess.initial.fen),
      );

      expect(state.activeClock, isNull);
      expect(state.lastClockTick, isNull);
    });

    test('starts tournament game clocks immediately', () {
      final state = debugInitialPlayState(
        _config(startingFen: Chess.initial.fen, startClockImmediately: true),
      );

      expect(state.activeClock, Side.white);
      expect(state.lastClockTick, isNotNull);
    });

    test(
      'missing play session args create an inert fallback instead of throwing',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final state = container.read(playSessionProviderFor('missing-tab'));

        expect(state.config, PlayConfig.defaults);
        expect(state.history, isEmpty);
        expect(state.engineReady, isFalse);
      },
    );

    test('cached fallback is replaced by fresh next-game args', () {
      final container = ProviderContainer(
        overrides: [playSessionBootEngineProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      const tabId = 'play-tab';
      final provider = playSessionProviderFor(tabId);
      final firstConfig = _config(startingFen: Chess.initial.fen);
      container.read(playSessionArgsByTabIdProvider.notifier).state = {
        tabId: _args(firstConfig),
      };
      expect(container.read(provider).config, same(firstConfig));

      container.read(playSessionArgsByTabIdProvider.notifier).state = {};
      container.invalidate(provider);
      expect(container.read(provider).config, PlayConfig.defaults);

      const nextConfig = PlayConfig(
        engine: BotEngineKind.maia,
        elo: 1800,
        category: TimeControlCategory.rapid,
        baseSeconds: 600,
        incrementSeconds: 10,
        color: PlayColorChoice.black,
      );
      container.read(playSessionArgsByTabIdProvider.notifier).state = {
        tabId: _args(nextConfig),
      };

      final nextState = container.read(provider);
      expect(nextState.config, same(nextConfig));
      expect(nextState.whiteMillis, 600000);
      expect(nextState.blackMillis, 600000);
      expect(nextState.humanSide, Side.black);
    });

    test('renders castling history as SAN castling notation', () {
      final notifier = _notifier(
        startingFen: 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
      );
      addTearDown(notifier.dispose);
      final castle = NormalMove.fromUci('e1g1');
      final state = notifier.state.copyWith(
        position: notifier.state.position.play(castle),
        history: const ['e1g1'],
        lastMove: castle,
      );

      final game = debugPlayNotationGame(state);

      expect(game.mainline.single.san, 'O-O');
      expect(game.mainline.single.uci, 'e1g1');
      expect(debugPlayNotationActivePointer(game), [0]);
    });

    test('builds analysis board args at the final play position', () {
      final state = _finishedState();

      final args = debugFinishedPlayBoardArgs(
        state,
        null,
        userDisplayName: 'Tester',
      );

      expect(args.gameId, isNull);
      expect(args.initialFen, state.position.fen);
      expect(args.fenSeed, state.position.fen);
      expect(args.initialBoardFlipped, isFalse);
      expect(args.whiteName, 'Tester');
      expect(args.blackName, 'Test Bot');
      expect(args.blackRating, 1500);
      expect(args.pgn, contains('[Result "1-0"]'));
      expect(args.pgn, contains('1. e4 e5 1-0'));
    });

    test('builds black-side analysis board args without flipping to white', () {
      final state = _finishedBlackState();

      final args = debugFinishedPlayBoardArgs(
        state,
        null,
        userDisplayName: 'Tester',
      );

      expect(state.humanSide, Side.black);
      expect(args.initialBoardFlipped, isTrue);
      expect(args.whiteName, 'Test Bot');
      expect(args.blackName, 'Tester');
      expect(args.whiteRating, 1500);
      expect(args.pgn, contains('[Result "0-1"]'));
      expect(args.pgn, contains('[ChessEverHumanColor "black"]'));
    });

    test('finished play args stamp play-again metadata on the PGN', () {
      final state = _finishedState();

      final args = debugFinishedPlayBoardArgs(
        state,
        null,
        userDisplayName: 'Tester',
      );

      expect(args.pgn, contains('[ChessEverEngineKind "stockfish"]'));
      expect(args.pgn, contains('[ChessEverEngineElo "1500"]'));
      expect(args.pgn, contains('[ChessEverBaseSeconds "180"]'));
      expect(args.pgn, contains('[ChessEverIncSeconds "2"]'));
      expect(args.pgn, contains('[ChessEverCategory "blitz"]'));
      expect(args.pgn, contains('[ChessEverHumanColor "white"]'));
      expect(
        args.pgn,
        contains('[ChessEverStartingFen "${Chess.initial.fen}"]'),
      );
    });

    test('tournament play args omit play-again metadata', () {
      final state = _finishedState();
      final args = debugFinishedPlayBoardArgs(
        state,
        _args(
          state.config,
          tournamentContext: const PlayTournamentContext(
            tournamentId: 'event-1',
            tournamentTitle: 'Test Cup',
            gameId: 'game-7',
            round: 3,
          ),
        ),
        userDisplayName: 'Tester',
      );

      expect(args.pgn, isNot(contains('ChessEverEngineKind')));
      expect(args.pgn, isNot(contains('ChessEverHumanColor')));
    });

    test('finished tournament play args preserve tournament context', () {
      final state = _finishedState();
      final args = debugFinishedPlayBoardArgs(
        state,
        _args(
          state.config,
          tournamentContext: const PlayTournamentContext(
            tournamentId: 'event-1',
            tournamentTitle: 'Test Cup',
            gameId: 'game-7',
            round: 3,
          ),
        ),
        userDisplayName: 'Tester',
      );

      expect(args.tournamentTitle, 'Test Cup');
      expect(args.gameListSelectedId, 'game-7');
      expect(args.label, 'Test Cup: Tester vs Test Bot');
      expect(args.pgn, contains('[Event "Test Cup"]'));
      expect(args.pgn, contains('[Round "3"]'));
      expect(args.pgn, contains('[ChessEverTournamentGameId "game-7"]'));
    });

    test('finished play handoff converts active Play tab to Board tab', () {
      final container = ProviderContainer(
        overrides: [playSessionBootEngineProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      final tabId = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.play, reuseExisting: false);
      final state = _finishedState();
      final sessionArgs = _args(state.config);
      container.read(playSessionArgsByTabIdProvider.notifier).state = {
        tabId: sessionArgs,
      };

      debugOpenFinishedPlayGameBoard(container, state, tabId, sessionArgs);

      final tabs = container.read(desktopTabsProvider);
      final boardArgs = container.read(boardTabGameArgsByTabIdProvider)[tabId];
      expect(tabs.activeId, tabId);
      expect(tabs.active?.kind, TabKind.board);
      expect(
        container.read(playSessionArgsByTabIdProvider),
        isNot(contains(tabId)),
      );
      expect(boardArgs, isNotNull);
      expect(boardArgs!.initialFen, state.position.fen);
      expect(boardArgs.initialBoardFlipped, isFalse);
      expect(boardArgs.pgn, contains('1. e4 e5 1-0'));
    });

    test(
      'finished tournament handoff stays in Play tab and clears the session',
      () {
        final container = ProviderContainer(
          overrides: [playSessionBootEngineProvider.overrideWithValue(false)],
        );
        addTearDown(container.dispose);

        final tabId = container
            .read(desktopTabsProvider.notifier)
            .open(TabKind.play, reuseExisting: false);
        final state = _finishedState();
        final sessionArgs = _args(
          state.config,
          tournamentContext: const PlayTournamentContext(
            tournamentId: 'event-1',
            tournamentTitle: 'Test Cup',
            gameId: 'game-7',
            round: 3,
          ),
        );
        container.read(playSessionArgsByTabIdProvider.notifier).state = {
          tabId: sessionArgs,
        };

        debugFinishPlaySession(container, state, tabId);

        final tabs = container.read(desktopTabsProvider);
        final boardArgs =
            container.read(boardTabGameArgsByTabIdProvider)[tabId];
        expect(tabs.activeId, tabId);
        expect(tabs.active?.kind, TabKind.play);
        expect(boardArgs, isNull);
        expect(
          container.read(playSessionArgsByTabIdProvider),
          isNot(contains(tabId)),
        );
      },
    );

    test(
      'defers finished play handoff until notifier listeners complete',
      () async {
        final container = ProviderContainer(
          overrides: [playSessionBootEngineProvider.overrideWithValue(false)],
        );
        addTearDown(container.dispose);

        final tabId = container
            .read(desktopTabsProvider.notifier)
            .open(TabKind.play, reuseExisting: false);
        final config = PlayConfig(
          engine: BotEngineKind.stockfish,
          elo: 1500,
          category: TimeControlCategory.blitz,
          baseSeconds: 180,
          incrementSeconds: 2,
          color: PlayColorChoice.black,
          startingFen: Chess.initial.fen,
          startingMovesUci: ['f2f3', 'e7e5', 'g2g4'],
        );
        container.read(playSessionArgsByTabIdProvider.notifier).state = {
          tabId: _args(config),
        };
        final provider = playSessionProviderFor(tabId);
        final subscription = container.listen<PlaySessionState>(provider, (
          previous,
          next,
        ) {
          if (previous?.isGameOver != true && next.isGameOver) {
            debugScheduleFinishPlaySession(container, next, tabId);
          }
        });
        addTearDown(subscription.close);

        final notifier = container.read(provider.notifier);
        expect(notifier.state.position.turn, Side.black);

        expect(() => notifier.playHumanMove('d8h4'), returnsNormally);
        expect(notifier.state.isGameOver, isTrue);
        expect(container.read(desktopTabsProvider).active?.kind, TabKind.play);

        await Future<void>.delayed(Duration.zero);

        final tabs = container.read(desktopTabsProvider);
        final boardArgs =
            container.read(boardTabGameArgsByTabIdProvider)[tabId];
        expect(tabs.activeId, tabId);
        expect(tabs.active?.kind, TabKind.board);
        expect(
          container.read(playSessionArgsByTabIdProvider),
          isNot(contains(tabId)),
        );
        expect(boardArgs, isNotNull);
        expect(boardArgs!.initialBoardFlipped, isTrue);
        expect(boardArgs.pgn, contains('2. g4 Qh4#'));
      },
    );
  });
}

PlaySessionArgs _args(
  PlayConfig config, {
  PlayTournamentContext? tournamentContext,
}) {
  return PlaySessionArgs(
    config: config,
    engineBinaryPath: '/engine-unused-in-test',
    botIdentity: const BotIdentity(
      firstName: 'Next',
      lastName: 'Bot',
      countryCode: 'US',
      elo: 1800,
    ),
    tournamentContext: tournamentContext,
  );
}

PlaySessionState _finishedState() {
  final notifier = _notifier(startingFen: Chess.initial.fen);
  addTearDown(notifier.dispose);
  final e4 = NormalMove.fromUci('e2e4');
  final e5 = NormalMove.fromUci('e7e5');
  final afterE4 = notifier.state.position.play(e4);
  final afterE5 = afterE4.play(e5);
  return notifier.state.copyWith(
    position: afterE5,
    history: const ['e2e4', 'e7e5'],
    lastMove: e5,
    endReason: PlayEndReason.blackResigned,
    outcome: Outcome.whiteWins,
    clearActiveClock: true,
    clearLastTick: true,
  );
}

PlaySessionState _finishedBlackState() {
  final notifier = _notifier(
    startingFen: Chess.initial.fen,
    color: PlayColorChoice.black,
  );
  addTearDown(notifier.dispose);
  final e4 = NormalMove.fromUci('e2e4');
  final e5 = NormalMove.fromUci('e7e5');
  final afterE4 = notifier.state.position.play(e4);
  final afterE5 = afterE4.play(e5);
  return notifier.state.copyWith(
    position: afterE5,
    history: const ['e2e4', 'e7e5'],
    lastMove: e5,
    endReason: PlayEndReason.whiteResigned,
    outcome: Outcome.blackWins,
    clearActiveClock: true,
    clearLastTick: true,
  );
}

PlaySessionNotifier _notifier({
  required String startingFen,
  PlayColorChoice color = PlayColorChoice.white,
}) {
  return PlaySessionNotifier(
    config: _config(startingFen: startingFen, color: color),
    engineBinaryPath: '/no-engine-needed',
    botIdentity: const BotIdentity(
      firstName: 'Test',
      lastName: 'Bot',
      countryCode: 'US',
      elo: 1500,
    ),
    bootEngine: false,
  );
}

PlayConfig _config({
  required String startingFen,
  List<String> startingMovesUci = const <String>[],
  bool startClockImmediately = false,
  PlayColorChoice color = PlayColorChoice.white,
}) {
  return PlayConfig(
    engine: BotEngineKind.stockfish,
    elo: 1500,
    category: TimeControlCategory.blitz,
    baseSeconds: 180,
    incrementSeconds: 2,
    color: color,
    startClockImmediately: startClockImmediately,
    startingFen: startingFen,
    startingMovesUci: startingMovesUci,
  );
}
