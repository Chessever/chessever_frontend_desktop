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
  _FakeGameStreamRepository(
    this.stream, {
    this.confirmedUpdate,
    this.fetchCurrentOverride,
  });

  final Stream<Map<String, dynamic>?> stream;
  LiveGameUpdate? confirmedUpdate;
  final Future<LiveGameUpdate?> Function(String gameId)? fetchCurrentOverride;
  int subscribeToGameUpdatesCount = 0;
  int subscribeToBatchUpdatesCount = 0;
  int subscribeToRoundUpdatesCount = 0;
  int subscribeToTourUpdatesCount = 0;
  int fetchCurrentLiveGameUpdateCount = 0;

  @override
  Future<LiveGameUpdate?> fetchCurrentLiveGameUpdate(String gameId) async {
    fetchCurrentLiveGameUpdateCount++;
    final override = fetchCurrentOverride;
    if (override != null) return override(gameId);
    return confirmedUpdate;
  }

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
    const afterNf3 =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
    const pgnAfterE4E5 = '''
[Event "Test"]

1. e4 e5 *
''';

    test(
      'canonical finished games do not consume the live row stream',
      () async {
        final repository = _FakeGameStreamRepository(
          const Stream<Map<String, dynamic>?>.empty(),
        );

        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
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
            const LiveGameWatchParams(gameId: 'game-1', streamEnabled: false),
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
      },
    );

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

    test('visible-card batches retain terminal rows for final hydration', () {
      final liveGame = _game(id: 'live-1', status: GameStatus.ongoing);
      final finishedGame = _game(id: 'finished-1', status: GameStatus.draw);
      final databaseGame = _game(
        id: 'database-1',
        status: GameStatus.draw,
        source: GameSource.gamebase,
      );

      final keys = liveBatchKeysForGames(
        games: [liveGame, finishedGame, databaseGame],
        scopePrefix: 'visible_terminal',
        includeFinishedGames: true,
      );

      expect(keys.keys, containsAll(<String>['live-1', 'finished-1']));
      expect(keys.containsKey('database-1'), isFalse);
      expect(
        liveContextBatchKeyForGame(
          game: finishedGame,
          contextGames: [liveGame, finishedGame],
          scopePrefix: 'visible_terminal',
          includeFinishedGames: true,
        ),
        isNotNull,
      );
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

    test('live merge applies every canonical status code', () {
      final base = _game(id: 'game-1', status: GameStatus.ongoing);
      final expected = <String, GameStatus>{
        'W': GameStatus.whiteWins,
        'B': GameStatus.blackWins,
        'D': GameStatus.draw,
        'live': GameStatus.ongoing,
        'ONGOING': GameStatus.ongoing,
      };

      for (final entry in expected.entries) {
        final merged = mergeLiveGameUpdateWithBase(
          baseGame: base,
          update: LiveGameUpdate(gameId: base.gameId, status: entry.key),
        );
        expect(merged.gameStatus, entry.value, reason: 'status=${entry.key}');
      }
    });

    test(
      'live merge applies valid player corrections and rejects partials',
      () {
        final base = _game(id: 'game-1', status: GameStatus.ongoing);
        final corrected = mergeLiveGameUpdateWithBase(
          baseGame: base,
          update: const LiveGameUpdate(
            gameId: 'game-1',
            players: <Object>[
              <String, Object>{
                'name': 'Corrected White',
                'title': 'IM',
                'rating': 2512,
                'fideId': 123,
                'fed': 'TUR',
                'clock': 0,
                'team': 'A',
              },
              <String, Object>{
                'name': 'Corrected Black',
                'title': 'GM',
                'rating': 2601,
                'fideId': 456,
                'fed': 'USA',
                'clock': 0,
                'team': 'B',
              },
            ],
          ),
        );

        expect(corrected.whitePlayer.name, 'Corrected White');
        expect(corrected.whitePlayer.rating, 2512);
        expect(corrected.whitePlayer.team, 'A');
        expect(corrected.blackPlayer.name, 'Corrected Black');
        expect(corrected.blackPlayer.fideId, 456);

        final partial = mergeLiveGameUpdateWithBase(
          baseGame: corrected,
          update: const LiveGameUpdate(
            gameId: 'game-1',
            players: <Object>[
              <String, Object>{'name': 'Corrected White', 'rating': 2520},
              <String, Object>{'name': 'Corrected Black'},
            ],
          ),
        );
        expect(partial.whitePlayer.rating, 2520);
        expect(partial.whitePlayer.title, 'IM');
        expect(partial.whitePlayer.federation, 'TUR');
        expect(partial.whitePlayer.fideId, 123);
        expect(partial.whitePlayer.team, 'A');
        expect(partial.blackPlayer.rating, 2601);
        expect(partial.blackPlayer.title, 'GM');
        expect(partial.blackPlayer.federation, 'USA');
        expect(partial.blackPlayer.fideId, 456);
        expect(partial.blackPlayer.team, 'B');

        final malformed = mergeLiveGameUpdateWithBase(
          baseGame: partial,
          update: const LiveGameUpdate(
            gameId: 'game-1',
            players: <Object>[
              <String, Object>{'name': ''},
            ],
          ),
        );
        expect(malformed.whitePlayer, same(partial.whitePlayer));
        expect(malformed.blackPlayer, same(partial.blackPlayer));
      },
    );

    test(
      'full canonical row preserves zeroes and clears nullable live fields',
      () {
        final base = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
          whiteClockSeconds: 170,
          blackClockSeconds: 160,
        ).copyWith(
          whitePlayer: _player(
            'White',
          ).copyWith(title: 'GM', rating: 2700, fideId: 123, team: 'Old Team'),
        );

        final merged = mergeLiveGameUpdateWithBase(
          baseGame: base,
          update: const LiveGameUpdate(
            gameId: 'game-1',
            lastClockWhite: 0,
            lastClockBlack: 0,
            status: 'live',
            players: <Object>[
              <String, Object?>{
                'name': 'White',
                'fed': '',
                'title': null,
                'rating': 0,
                'fideId': null,
                'team': null,
                'clock': null,
              },
              <String, Object?>{
                'name': 'Black',
                'fed': 'USA',
                'title': 'GM',
                'rating': 2700,
              },
            ],
            isFullRow: true,
          ),
        );

        expect(merged.pgn, isNull);
        expect(merged.fen, isNull);
        expect(merged.lastMove, isNull);
        expect(merged.lastMoveTime, isNull);
        expect(merged.whiteClockSeconds, 0);
        expect(merged.blackClockSeconds, 0);
        expect(merged.whiteClockCentiseconds, 0);
        expect(merged.blackClockCentiseconds, 0);
        expect(merged.whitePlayer.title, isEmpty);
        expect(merged.whitePlayer.rating, 0);
        expect(merged.whitePlayer.fideId, isNull);
        expect(merged.whitePlayer.team, isNull);
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

    test(
      'an out-of-order row never renders a stale intermediate frame',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final repository = _FakeGameStreamRepository(controller.stream);
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        final fresh = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
        );
        container.read(baseGameProvider('game-1').notifier).state = fresh;
        final provider = scopedLiveGameCardProvider(
          LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
        );
        final rendered = <GamesTourModel?>[];
        final subscription = container.listen<GamesTourModel?>(
          provider,
          (_, next) => rendered.add(next),
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        controller.add(<String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 *',
          'fen': afterE4,
          'last_move': 'e2e4',
          'last_move_time': '2026-05-26T12:00:00Z',
          'status': 'live',
        });
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
        }

        expect(subscription.read()?.fen, afterE4E5);
        expect(container.read(baseGameProvider('game-1'))?.fen, afterE4E5);
        expect(
          rendered.whereType<GamesTourModel>().map((game) => game.fen),
          isNot(contains(afterE4)),
        );
        expect(repository.fetchCurrentLiveGameUpdateCount, 1);
      },
    );

    test(
      'an equal initial snapshot stays on the zero-REST fast path',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final repository = _FakeGameStreamRepository(controller.stream);
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        final current = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
          whiteClockSeconds: 170,
          blackClockSeconds: 160,
        );
        container.read(baseGameProvider('game-1').notifier).state = current;
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        controller.add(<String, dynamic>{
          'pgn': pgnAfterE4E5,
          'fen': afterE4E5,
          'last_move': 'e7e5',
          'last_move_time': '2026-05-26T12:03:00Z',
          'last_clock_white': 170,
          'last_clock_black': 160,
          'status': 'live',
        });
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
        }

        expect(subscription.read(), current);
        expect(repository.fetchCurrentLiveGameUpdateCount, 0);
      },
    );

    test(
      'a rejected position applies player and status corrections only after exact confirmation',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final repository = _FakeGameStreamRepository(controller.stream);
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(baseGameProvider('game-1').notifier).state = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
        );
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final correctedRow = <String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 *',
          'fen': afterE4,
          'last_move': 'e2e4',
          'last_move_time': '2026-05-26T12:00:00Z',
          'players': <Object>[
            <String, Object>{'name': 'Corrected White', 'rating': 2750},
            <String, Object>{'name': 'Corrected Black', 'rating': 2740},
          ],
          'status': 'D',
        };
        repository.confirmedUpdate = LiveGameUpdate.fromLegacyMap(
          'game-1',
          correctedRow,
        );
        controller.add(correctedRow);
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
        }

        final rendered = subscription.read();
        expect(rendered?.fen, afterE4);
        expect(rendered?.pgn, '[Event "Test"]\n\n1. e4 *');
        expect(rendered?.lastMove, 'e2e4');
        expect(rendered?.whitePlayer.name, 'Corrected White');
        expect(rendered?.whitePlayer.rating, 2750);
        expect(rendered?.blackPlayer.name, 'Corrected Black');
        expect(rendered?.gameStatus, GameStatus.draw);
        expect(repository.fetchCurrentLiveGameUpdateCount, 1);
      },
    );

    test(
      'a server-confirmed later row applies an intentional takeback',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final repository = _FakeGameStreamRepository(controller.stream);
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(baseGameProvider('game-1').notifier).state = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
          whiteClockSeconds: 170,
          blackClockSeconds: 160,
        );
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        // Generation one establishes this channel's initial snapshot. It is
        // deliberately identical to the base row.
        controller.add(<String, dynamic>{
          'pgn': pgnAfterE4E5,
          'fen': afterE4E5,
          'last_move': 'e7e5',
          'last_move_time': '2026-05-26T12:03:00Z',
          'last_clock_white': 170,
          'last_clock_black': 160,
          'status': 'live',
        });
        await container.pump();

        // This later row is an arbiter correction on the same active channel.
        // Its shorter PGN and older last-move time are intentional, not stale.
        final takebackRow = <String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 *',
          'fen': afterE4,
          'last_move': 'e2e4',
          'last_move_time': '2026-05-26T12:00:00Z',
          'last_clock_white': 180,
          'last_clock_black': 180,
          'players': <Object>[
            <String, Object>{'name': 'Corrected White', 'rating': 2765},
            <String, Object>{'name': 'Corrected Black', 'rating': 2730},
          ],
          'status': 'D',
        };
        repository.confirmedUpdate = LiveGameUpdate.fromLegacyMap(
          'game-1',
          takebackRow,
        );
        controller.add(takebackRow);
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
        }

        final rendered = subscription.read();
        expect(rendered?.fen, afterE4);
        expect(rendered?.pgn, '[Event "Test"]\n\n1. e4 *');
        expect(rendered?.lastMove, 'e2e4');
        expect(rendered?.lastMoveTime, DateTime.utc(2026, 5, 26, 12));
        expect(rendered?.whiteClockSeconds, 180);
        expect(rendered?.blackClockSeconds, 180);
        expect(rendered?.whitePlayer.name, 'Corrected White');
        expect(rendered?.whitePlayer.rating, 2765);
        expect(rendered?.gameStatus, GameStatus.draw);
        expect(container.read(baseGameProvider('game-1'))?.fen, afterE4);
        expect(repository.fetchCurrentLiveGameUpdateCount, 1);
      },
    );

    test(
      'a first reconnect snapshot can apply a server-confirmed takeback',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final takebackRow = <String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 *',
          'fen': afterE4,
          'last_move': 'e2e4',
          'last_move_time': '2026-05-26T12:00:00Z',
          'last_clock_white': 180,
          'last_clock_black': 180,
          'status': 'live',
        };
        final repository = _FakeGameStreamRepository(
          controller.stream,
          confirmedUpdate: LiveGameUpdate.fromLegacyMap('game-1', takebackRow),
        );
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(baseGameProvider('game-1').notifier).state = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
          whiteClockSeconds: 170,
          blackClockSeconds: 160,
        );
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        controller.add(takebackRow);
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (subscription.read()?.fen == afterE4) break;
        }

        final rendered = subscription.read();
        expect(rendered?.fen, afterE4);
        expect(rendered?.pgn, '[Event "Test"]\n\n1. e4 *');
        expect(rendered?.lastMove, 'e2e4');
        expect(rendered?.whiteClockSeconds, 180);
        expect(rendered?.blackClockSeconds, 180);
        expect(repository.fetchCurrentLiveGameUpdateCount, 1);
      },
    );

    test(
      'a late regression confirmation cannot overwrite a newer row',
      () async {
        final controller = StreamController<Map<String, dynamic>?>();
        addTearDown(controller.close);
        final confirmation = Completer<LiveGameUpdate?>();
        final repository = _FakeGameStreamRepository(
          controller.stream,
          fetchCurrentOverride: (_) => confirmation.future,
        );
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(baseGameProvider('game-1').notifier).state = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: pgnAfterE4E5,
          lastMove: 'e7e5',
          lastMoveTime: DateTime.utc(2026, 5, 26, 12, 3),
        );
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        const staleTakeback = LiveGameUpdate(
          gameId: 'game-1',
          pgn: '[Event "Test"]\n\n1. e4 *',
          fen: afterE4,
          lastMove: 'e2e4',
          lastMoveTime: '2026-05-26T12:00:00Z',
          status: 'live',
        );
        controller.add(staleTakeback.toLegacyMap());
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (repository.fetchCurrentLiveGameUpdateCount == 1) break;
        }

        controller.add(<String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 e5 2. Nf3 *',
          'fen': afterNf3,
          'last_move': 'g1f3',
          'last_move_time': '2026-05-26T12:04:00Z',
          'status': 'live',
        });
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (subscription.read()?.fen == afterNf3) break;
        }
        expect(subscription.read()?.fen, afterNf3);

        confirmation.complete(staleTakeback);
        for (var attempt = 0; attempt < 10; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
        }

        expect(subscription.read()?.fen, afterNf3);
        expect(container.read(baseGameProvider('game-1'))?.fen, afterNf3);
      },
    );

    test(
      'terminal status does not detach before the final PGN row arrives',
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
        );
        final subscription = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(gameId: 'game-1', batchKey: _batchKey()),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        // Some broadcasters commit the result before their final PGN/FEN
        // update. This first terminal row must not tear down the visible
        // card's batch leaf before the next change arrives.
        controller.add(<String, dynamic>{
          'pgn': '[Event "Test"]\n\n1. e4 *',
          'fen': afterE4,
          'last_move': 'e2e4',
          'last_move_time': '2026-05-26T12:01:00Z',
          'status': 'W',
        });
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (subscription.read()?.gameStatus == GameStatus.whiteWins) break;
        }
        expect(subscription.read()?.gameStatus, GameStatus.whiteWins);

        controller.add(<String, dynamic>{
          'pgn': pgnAfterE4E5.replaceFirst('*', '1-0'),
          'fen': afterE4E5,
          'last_move': 'e7e5',
          'last_move_time': '2026-05-26T12:02:00Z',
          'status': 'W',
        });
        for (var attempt = 0; attempt < 5; attempt++) {
          await container.pump();
          await Future<void>.delayed(Duration.zero);
          if (subscription.read()?.fen == afterE4E5) break;
        }

        expect(subscription.read()?.fen, afterE4E5);
        expect(subscription.read()?.lastMove, 'e7e5');
        expect(subscription.read()?.pgn, contains('e4 e5 1-0'));
        expect(subscription.read()?.gameStatus, GameStatus.whiteWins);
      },
    );

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
    const afterE4E5 =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
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

    test('requires exact confirmation for player-only corrections', () {
      final current = at(t0);
      final corrected = current.copyWith(
        whitePlayer: current.whitePlayer.copyWith(rating: 2712),
      );

      expect(shouldReplaceBaseGame(current, corrected), isFalse);
    });

    test(
      'navigation keeps a newer streamed card over an older fetched row',
      () {
        final current = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: afterE4E5,
          pgn: '[Event "Test"]\n\n1. e4 e5 *',
          lastMove: 'e7e5',
          lastMoveTime: t1,
        );
        final fetched = _game(
          id: 'game-1',
          status: GameStatus.ongoing,
          fen: fen,
          pgn: '[Event "Test"]\n\n1. e4 *',
          lastMove: 'e2e4',
          lastMoveTime: t0,
        );

        final selected = selectFreshestNavigationGame(
          current: current,
          incoming: fetched,
        );

        expect(selected, same(current));
      },
    );

    test('navigation accepts a richer PGN at the same live position', () {
      final current = _game(
        id: 'game-1',
        status: GameStatus.ongoing,
        fen: afterE4E5,
        pgn: '1. e4 e5 *',
        lastMove: 'e7e5',
        lastMoveTime: t1,
      );
      final fetched = _game(
        id: 'game-1',
        status: GameStatus.ongoing,
        fen: afterE4E5,
        pgn: '''
[Event "Test"]
[White "White"]
[Black "Black"]

1. e4 e5 *
''',
        lastMove: 'e7e5',
        lastMoveTime: t1,
      );

      final selected = selectFreshestNavigationGame(
        current: current,
        incoming: fetched,
      );

      expect(selected, same(fetched));
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
