import 'dart:async';

import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _FakeGameStreamRepository extends GameStreamRepository {
  _FakeGameStreamRepository(this.stream);

  final Stream<Map<String, dynamic>?> stream;
  int subscribeToGameUpdatesCount = 0;
  int subscribeToBatchUpdatesCount = 0;
  int subscribeToRoundUpdatesCount = 0;
  int subscribeToTourUpdatesCount = 0;

  // `subscribeToLiveGameUpdate` is the repository's stream primitive;
  // `subscribeToGameUpdates` is derived from it. Override the primitive so the
  // fake controller stream flows through both paths, mirroring production.
  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) {
    subscribeToGameUpdatesCount++;
    return stream.map(
      (row) => row == null ? null : LiveGameUpdate.fromLegacyMap(gameId, row),
    );
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    subscribeToBatchUpdatesCount++;
    return _liveGameUpdatesForIds(gameIds);
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) {
    subscribeToRoundUpdatesCount++;
    return _liveGameUpdatesForIds(const ['game-1']);
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) {
    subscribeToTourUpdatesCount++;
    return _liveGameUpdatesForIds(const ['game-1']);
  }

  Stream<Map<String, LiveGameUpdate>> _liveGameUpdatesForIds(
    List<String> gameIds,
  ) {
    return stream.map((row) {
      if (row == null) return const <String, LiveGameUpdate>{};
      return {
        for (final gameId in gameIds)
          gameId: LiveGameUpdate.fromLegacyMap(gameId, row),
      };
    });
  }
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}

GamesTourModel _game({
  required String id,
  required GameStatus status,
  GameSource source = GameSource.supabase,
  String? fen,
  String? pgn,
  String? lastMove,
  DateTime? lastMoveTime,
  int? whiteClockSeconds,
  int? blackClockSeconds,
}) {
  return GamesTourModel(
    gameId: id,
    source: source,
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
    fen: fen,
    pgn: pgn,
    lastMove: lastMove,
    lastMoveTime: lastMoveTime,
    whiteClockSeconds: whiteClockSeconds,
    blackClockSeconds: blackClockSeconds,
  );
}

class _LiveGameProbe extends ConsumerWidget {
  const _LiveGameProbe({required this.game, required this.onBuild});

  final GamesTourModel game;
  final void Function(GamesTourModel game) onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveGame = watchLiveGame(ref, game, batchKey: _batchKey());
    onBuild(liveGame);
    return const SizedBox.shrink();
  }
}

LiveGamesBatchKey _batchKey([List<String> gameIds = const ['game-1']]) {
  return LiveGamesBatchKey(
    scopeId: 'test:${gameIds.join(',')}',
    gameIds: gameIds,
  );
}

void main() {
  group('liveGameCardProvider', () {
    const afterE4 =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    const afterE4E5 =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    const pgnAfterE4E5 = '''
[Event "Test"]

1. e4 e5 *
''';

    test('finished base games do not consume the live row stream', () async {
      final repository = _FakeGameStreamRepository(
        const Stream<Map<String, dynamic>?>.empty(),
      );

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(baseGameProvider('game-1').notifier).state = _game(
        id: 'game-1',
        status: GameStatus.whiteWins,
        fen: afterE4,
        lastMove: 'e2e4',
      );

      final sub = container.listen(
        scopedLiveGameCardProvider(
          LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
        ),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(sub.read()?.fen, afterE4);
      expect(repository.subscribeToBatchUpdatesCount, 0);

      final liveGame = sub.read();
      expect(liveGame?.gameStatus, GameStatus.whiteWins);
      expect(liveGame?.lastMove, 'e2e4');
      expect(liveGame?.fen, afterE4);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(baseGameProvider('game-1'))?.fen, afterE4);
    });

    test('context batch keys include only subscribable live game ids', () {
      final liveGame = _game(id: 'game-1', status: GameStatus.ongoing);
      final finishedGame = _game(id: 'game-2', status: GameStatus.draw);
      final databaseGame = _game(
        id: 'gamebase-1',
        status: GameStatus.ongoing,
        source: GameSource.gamebase,
      );

      final key = liveContextBatchKeyForGame(
        game: liveGame,
        contextGames: [liveGame, finishedGame, databaseGame],
        scopePrefix: 'test_context',
      );

      expect(key, isNotNull);
      expect(key!.gameIds, ['game-1']);
      expect(
        liveContextBatchKeyForGame(
          game: finishedGame,
          contextGames: [liveGame, finishedGame, databaseGame],
          scopePrefix: 'test_context',
        ),
        isNull,
      );
      expect(
        liveContextBatchKeyForGame(
          game: databaseGame,
          contextGames: [liveGame, finishedGame, databaseGame],
          scopePrefix: 'test_context',
        ),
        isNull,
      );
    });

    test('live batch key map chunks only subscribable games', () {
      final liveGames = [
        for (var i = 0; i < 26; i++)
          _game(
            id: 'live-${i.toString().padLeft(2, '0')}',
            status: GameStatus.ongoing,
          ),
      ];
      final finishedGame = _game(id: 'finished-1', status: GameStatus.draw);
      final databaseGame = _game(
        id: 'database-1',
        status: GameStatus.ongoing,
        source: GameSource.gamebase,
      );

      final keys = liveBatchKeysForGames(
        games: [...liveGames, finishedGame, databaseGame],
        scopePrefix: 'test_chunk',
        batchSize: 25,
      );

      expect(keys.length, 26);
      expect(keys.containsKey(finishedGame.gameId), isFalse);
      expect(keys.containsKey(databaseGame.gameId), isFalse);
      expect(keys['live-00'], same(keys['live-24']));
      expect(keys['live-00'], isNot(same(keys['live-25'])));
      expect(keys['live-00']!.gameIds.length, 25);
      expect(keys['live-25']!.gameIds, ['live-25']);
    });

    test(
      'shared live merge helper keeps board-side state as fresh as cards',
      () {
        final base = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4,
          pgn: '[Event "Test"]\n\n1. e4 *',
          lastMove: 'e2e4',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12),
          whiteClockSeconds: 180,
          blackClockSeconds: 180,
        );

        final merged = mergeLiveGameUpdateWithBase(
          baseGame: base,
          update: const LiveGameUpdate(
            gameId: 'game-1',
            pgn: pgnAfterE4E5,
            fen: afterE4E5,
            lastMove: 'e7e5',
            lastMoveTime: '2026-05-26T12:03:00Z',
            lastClockWhite: 170,
            lastClockBlack: 160,
            status: '*',
          ),
        );

        expect(merged.fen, afterE4E5);
        expect(merged.pgn, pgnAfterE4E5);
        expect(merged.lastMove, 'e7e5');
        expect(merged.lastMoveTime, DateTime.utc(2026, 5, 26, 12, 3));
        expect(merged.whiteClockSeconds, 170);
        expect(merged.blackClockSeconds, 160);
        expect(merged.gameStatus, GameStatus.ongoing);
      },
    );

    test('disabled stream gate returns base game without subscribing', () {
      final repository = _FakeGameStreamRepository(
        const Stream<Map<String, dynamic>?>.empty(),
      );

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(baseGameProvider('game-1').notifier).state = _game(
        id: 'game-1',
        status: GameStatus.ongoing,
        fen: afterE4,
        lastMove: 'e2e4',
      );

      final sub = container.listen(
        scopedLiveGameCardProvider(
          LiveGameWatchParams(
            gameId: 'game-1',
            batchKey: _batchKey(),
            streamEnabled: false,
          ),
        ),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(sub.read()?.fen, afterE4);
      expect(repository.subscribeToGameUpdatesCount, 0);
    });

    test('paused live cards still consume realtime row updates', () async {
      final controller = StreamController<Map<String, dynamic>?>();
      addTearDown(controller.close);
      final repository = _FakeGameStreamRepository(controller.stream);

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(baseGameProvider('game-1').notifier).state = _game(
        id: 'game-1',
        status: GameStatus.ongoing,
        fen: afterE4,
        pgn: '[Event "Test"]\n\n1. e4 *',
        lastMove: 'e2e4',
        lastMoveTime: DateTime.utc(2026, 5, 26, 12),
        whiteClockSeconds: 180,
        blackClockSeconds: 180,
      );
      container.read(liveGameCardsPauseReasonsProvider.notifier).state = {
        'desktop_scroll',
      };

      final sub = container.listen(
        scopedLiveGameCardProvider(
          LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
        ),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      controller.add({
        'fen': afterE4E5,
        'pgn': pgnAfterE4E5,
        'last_move': 'e7e5',
        'last_move_time': '2026-05-26T12:03:00Z',
        'last_clock_white': 170,
        'last_clock_black': 160,
        'status': '*',
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(repository.subscribeToGameUpdatesCount, 0);
      expect(repository.subscribeToBatchUpdatesCount, 1);
      expect(sub.read()?.fen, afterE4E5);
      expect(sub.read()?.lastMove, 'e7e5');
      expect(sub.read()?.whiteClockSeconds, 170);
      expect(sub.read()?.blackClockSeconds, 160);
    });

    test('cards without a realtime context do not open per-game channels', () {
      final repository = _FakeGameStreamRepository(
        const Stream<Map<String, dynamic>?>.empty(),
      );

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(baseGameProvider('gamebase-1').notifier).state = _game(
        id: 'gamebase-1',
        source: GameSource.gamebase,
        status: GameStatus.ongoing,
        fen: afterE4,
      );

      final sub = container.listen(
        scopedLiveGameCardProvider(
          const LiveGameWatchParams(gameId: 'gamebase-1'),
        ),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(repository.subscribeToGameUpdatesCount, 0);
      expect(repository.subscribeToBatchUpdatesCount, 0);
      expect(repository.subscribeToRoundUpdatesCount, 0);
      expect(repository.subscribeToTourUpdatesCount, 0);
      expect(sub.read()?.fen, afterE4);
    });

    test('supabase cards without context do not open round-wide channels', () {
      final repository = _FakeGameStreamRepository(
        const Stream<Map<String, dynamic>?>.empty(),
      );

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(baseGameProvider('game-1').notifier).state = _game(
        id: 'game-1',
        status: GameStatus.ongoing,
        fen: afterE4,
      );

      final sub = container.listen(
        scopedLiveGameCardProvider(const LiveGameWatchParams(gameId: 'game-1')),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(repository.subscribeToGameUpdatesCount, 0);
      expect(repository.subscribeToBatchUpdatesCount, 0);
      expect(repository.subscribeToRoundUpdatesCount, 0);
      expect(repository.subscribeToTourUpdatesCount, 0);
      expect(sub.read()?.fen, afterE4);
    });

    test(
      'clock projection keeps position and move timestamp in sync',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);

        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(
              _FakeGameStreamRepository(controller.stream),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(baseGameProvider('game-1').notifier).state = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4,
          pgn: '[Event "Test"]\n\n1. e4 *',
          lastMove: 'e2e4',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12),
          whiteClockSeconds: 180,
          blackClockSeconds: 180,
        );

        final sub = container.listen(
          liveGameClockProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);

        controller.add({
          'fen': afterE4E5,
          'pgn': pgnAfterE4E5,
          'last_move': 'e7e5',
          'last_move_time': '2026-05-26T12:03:00Z',
          'last_clock_white': 170,
          'last_clock_black': 160,
          'status': '*',
        });
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final liveGame = sub.read();
        expect(liveGame?.fen, afterE4E5);
        expect(liveGame?.pgn, pgnAfterE4E5);
        expect(liveGame?.lastMove, 'e7e5');
        expect(liveGame?.lastMoveTime, DateTime.utc(2026, 5, 26, 12, 3));
        expect(liveGame?.whiteClockSeconds, 170);
        expect(liveGame?.blackClockSeconds, 160);
      },
    );

    testWidgets(
      'parent rebuilds cannot overwrite newer streamed clocks at the same ply',
      (tester) async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);

        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(
              _FakeGameStreamRepository(controller.stream),
            ),
          ],
        );
        addTearDown(container.dispose);

        final moveTime = DateTime.utc(2026, 4, 29, 12);
        final parentGame = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: moveTime,
          whiteClockSeconds: 120,
          blackClockSeconds: 130,
        );

        GamesTourModel? renderedGame;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: _LiveGameProbe(
              game: parentGame,
              onBuild: (game) => renderedGame = game,
            ),
          ),
        );
        await tester.pump();

        controller.add({
          'fen': afterE4E5,
          'pgn': pgnAfterE4E5,
          'last_move': 'e7e5',
          'last_move_time': moveTime.toIso8601String(),
          'last_clock_white': 100,
          'last_clock_black': 110,
          'status': '*',
        });
        await tester.pump();
        await tester.pump();

        expect(renderedGame?.whiteClockSeconds, 100);
        expect(renderedGame?.blackClockSeconds, 110);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: _LiveGameProbe(
              game: parentGame,
              onBuild: (game) => renderedGame = game,
            ),
          ),
        );
        await tester.pump();

        expect(renderedGame?.whiteClockSeconds, 100);
        expect(renderedGame?.blackClockSeconds, 110);
        expect(
          container.read(baseGameProvider('game-1'))?.whiteClockSeconds,
          100,
        );
      },
    );
  });

  group('shouldReplaceBaseGame', () {
    const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    final t0 = DateTime.utc(2026, 5, 26, 12);
    final t1 = DateTime.utc(2026, 5, 26, 12, 3);

    GamesTourModel at(DateTime time, {int white = 180}) => _game(
      id: 'game-1',
      status: GameStatus.ongoing,
      fen: fen,
      pgn: '[Event "Test"]\n\n1. e4 *',
      lastMove: 'e2e4',
      lastMoveTime: time,
      whiteClockSeconds: white,
      blackClockSeconds: 180,
    );

    test('seeds when nothing is stored yet', () {
      expect(shouldReplaceBaseGame(null, at(t0)), isTrue);
    });

    test('rejects an identical snapshot', () {
      final g = at(t0);
      expect(shouldReplaceBaseGame(g, g), isFalse);
    });

    test('rejects a staler REST read (older move time)', () {
      // getGameById() lagging the realtime stream must not clobber the board.
      expect(shouldReplaceBaseGame(at(t1), at(t0)), isFalse);
    });

    test('accepts a fresher snapshot (newer move time)', () {
      expect(shouldReplaceBaseGame(at(t0), at(t1)), isTrue);
    });

    test('accepts newer clocks at the same ply', () {
      expect(
        shouldReplaceBaseGame(at(t0, white: 120), at(t0, white: 100)),
        isTrue,
      );
    });
  });

  group('gameUpdatesStreamProvider', () {
    test('board and card surfaces share one realtime channel per game', () async {
      // Single-subscription stream: if the board (legacy-map) and card (typed)
      // surfaces each opened their own subscription, the second `.map().listen`
      // on this stream would throw — so this both asserts the count and would
      // fail loudly on any re-subscription.
      final controller = StreamController<Map<String, dynamic>?>();
      addTearDown(controller.close);
      final repository = _FakeGameStreamRepository(controller.stream);

      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final cardSub = container.listen(
        liveGameUpdateStreamProvider('game-1'),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(cardSub.close);
      final boardSub = container.listen(
        gameUpdatesStreamProvider('game-1'),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(boardSub.close);

      await Future<void>.delayed(Duration.zero);

      expect(repository.subscribeToGameUpdatesCount, 1);
    });
  });
}
