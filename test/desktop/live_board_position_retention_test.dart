import 'dart:async';

import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const firstPgn = '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *';
const secondPgn = '1. d4 d5 2. c4 e6 *';
final moveTime = DateTime.utc(2026, 10, 15, 17, 44, 50);

PlayerCard player(String name) => PlayerCard(
  name: name,
  federation: 'USA',
  title: 'GM',
  rating: 2500,
  countryCode: 'USA',
  team: null,
);
GamesTourModel game(String id, String pgn) => GamesTourModel(
  gameId: id,
  source: GameSource.supabase,
  whitePlayer: player('White $id'),
  blackPlayer: player('Black $id'),
  whiteTimeDisplay: '02:00',
  blackTimeDisplay: '02:00',
  whiteClockCentiseconds: 15000,
  blackClockCentiseconds: 16000,
  whiteClockSeconds: 150,
  blackClockSeconds: 160,
  gameStatus: GameStatus.ongoing,
  roundId: 'round-7',
  tourId: 'broadcast',
  pgn: pgn,
  fen: resolveFinalPositionFromPgn(pgn)!.fen,
  lastMove: resolveFinalPositionFromPgn(pgn)!.lastMoveUci,
  lastMoveTime: moveTime,
);
Map<String, dynamic> row(
  GamesTourModel value, {
  String? pgn,
  String? fen,
  String? lastMove,
  DateTime? time,
}) => {
  'id': value.gameId,
  'pgn': pgn ?? value.pgn,
  'fen': fen ?? value.fen,
  'last_move': lastMove ?? value.lastMove,
  'last_move_time': (time ?? value.lastMoveTime)?.toIso8601String(),
  'last_clock_white': value.whiteClockSeconds,
  'last_clock_black': value.blackClockSeconds,
  'status': 'live',
  'players': [
    {
      'name': value.whitePlayer.name,
      'rating': 2500,
      'fed': 'USA',
      'title': 'GM',
      'clock': 15000,
    },
    {
      'name': value.blackPlayer.name,
      'rating': 2500,
      'fed': 'USA',
      'title': 'GM',
      'clock': 16000,
    },
  ],
};

class BatchRepository extends GameStreamRepository {
  BatchRepository({bool broadcast = false})
    : controller =
          broadcast
              ? StreamController<Map<String, LiveGameUpdate>>.broadcast()
              : StreamController<Map<String, LiveGameUpdate>>();
  final StreamController<Map<String, LiveGameUpdate>> controller;
  final confirmed = <String, LiveGameUpdate>{};
  Future<LiveGameUpdate?>? pending;
  int confirmationReads = 0;
  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> ids,
  ) => controller.stream;
  @override
  Future<LiveGameUpdate?> fetchCurrentLiveGameUpdate(String id) async {
    confirmationReads++;
    if (pending != null) return pending!;
    return confirmed[id];
  }
}

Future<void> settle(ProviderContainer container) async {
  for (var i = 0; i < 8; i++) {
    await container.pump();
    await Future<void>.delayed(Duration.zero);
  }
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(showEvaluationBar: false);
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}

void main() {
  test(
    'placeholder board placement cannot masquerade as progress through its FEN move counter',
    () {
      final before = game('a', firstPgn);
      final misleading = before.copyWith(
        pgn: '*',
        fen: startFen.replaceAll('0 1', '0 99'),
        clearLastMove: true,
        lastMoveTime: moveTime.add(const Duration(seconds: 1)),
      );
      expect(shouldReplaceBaseGame(before, misleading), isFalse);
      expect(
        selectFreshestNavigationGame(current: before, incoming: misleading),
        same(before),
      );
    },
  );

  testWidgets(
    'real keyed grid cards never render a starting-position frame during repeated full-row resets',
    (tester) async {
      final repository = BatchRepository(broadcast: true);
      final seeds = [game('a', firstPgn), game('b', secondPgn)];
      final batch = LiveGamesBatchKey(
        scopeId: 'real-grid-reset',
        gameIds: ['a', 'b'],
      );
      final container = ProviderContainer(
        overrides: [
          gameStreamRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_BoardSettings.new),
          engineSettingsProviderNew.overrideWith(_EngineSettings.new),
          dateTimeProvider.overrideWith((ref) => Stream.value(moveTime)),
        ],
      );
      for (final seed in seeds) {
        container.read(baseGameProvider(seed.gameId).notifier).state = seed;
        repository.confirmed[seed.gameId] = LiveGameUpdate.fromRow(row(seed));
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (final seed in seeds)
                    SizedBox(
                      width: 250,
                      height: 280,
                      child: Consumer(
                        builder: (context, ref, _) {
                          final live = watchLiveGame(
                            ref,
                            seed,
                            batchKey: batch,
                          );
                          return DesktopGameCard(
                            key: ValueKey(seed.gameId),
                            data: GameCardData.fromGamesTourModel(live),
                            layout: DesktopCardLayout.grid,
                            allowStockfishFallback: false,
                            onTap: () {},
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.controller.hasListener, isTrue);
      for (var cycle = 0; cycle < 4; cycle++) {
        repository.controller.add({
          for (final seed in seeds)
            seed.gameId: LiveGameUpdate.fromRow({
              ...row(
                seed,
                pgn: '*',
                fen: startFen,
                time: moveTime.add(Duration(seconds: cycle + 1)),
              ),
              'last_move': null,
            }),
        });
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          final previews =
              tester
                  .widgetList<cg.StaticChessboard>(
                    find.byType(cg.StaticChessboard),
                  )
                  .toList();
          expect(previews, hasLength(2));
          expect(
            previews.map((board) => board.fen),
            seeds.map((seed) => seed.fen),
          );
          expect(
            tester
                .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
                .map((card) => card.data.id),
            ['a', 'b'],
          );
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      unawaited(repository.controller.close());
      await tester.pump();
    },
  );

  test(
    'an exact-confirmed empty source row cannot erase a played board or swallow its result',
    () async {
      final repository = BatchRepository();
      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(() async {
        container.dispose();
        await repository.controller.close();
      });
      final before = game('a', firstPgn);
      container.read(baseGameProvider('a').notifier).state = before;
      final frames = <String?>[];
      final sub = container.listen(
        scopedLiveGameCardProvider(
          LiveGameWatchParams(
            gameId: 'a',
            batchKey: LiveGamesBatchKey(
              scopeId: 'confirmed-reset',
              gameIds: ['a'],
            ),
          ),
        ),
        (_, value) {
          frames.add(value?.fen);
        },
        fireImmediately: true,
      );
      for (final status in ['live', 'W']) {
        final reset = LiveGameUpdate.fromRow({
          ...row(
            before,
            pgn: '*',
            fen: startFen,
            time: moveTime.add(const Duration(seconds: 1)),
          ),
          'last_move': null,
          'status': status,
          'players': [
            {'name': 'Corrected White a', 'rating': 2500},
            {'name': 'Black a', 'rating': 2500},
          ],
        });
        repository.confirmed['a'] = reset;
        repository.controller.add({'a': reset});
        await settle(container);
        expect(sub.read()!.fen, before.fen);
        expect(sub.read()!.pgn, before.pgn);
        expect(sub.read()!.lastMove, before.lastMove);
        expect(sub.read()!.lastMoveTime, before.lastMoveTime);
        expect(sub.read()!.whitePlayer.name, 'Corrected White a');
        expect(
          sub.read()!.gameStatus,
          status == 'W' ? GameStatus.whiteWins : GameStatus.ongoing,
        );
        expect(frames, everyElement(before.fen));
      }
      expect(repository.confirmationReads, greaterThan(0));
      sub.close();
    },
  );

  test(
    'missing, header-only and malformed source positions retain the complete played position tuple',
    () {
      final before = game('a', firstPgn);
      for (final pgn in <String?>[
        null,
        '',
        '*',
        '[Event "Source"]\n\n*',
        'not a chess score',
      ]) {
        final merged = mergeLiveGameUpdateWithBase(
          baseGame: before,
          update: LiveGameUpdate.fromRow({
            ...row(before),
            'pgn': pgn,
            'fen': null,
            'last_move': null,
            'last_move_time':
                moveTime.add(const Duration(seconds: 1)).toIso8601String(),
          }),
        );
        expect(merged.pgn, before.pgn, reason: 'pgn=$pgn');
        expect(merged.fen, before.fen);
        expect(merged.lastMove, before.lastMove);
        expect(merged.lastMoveTime, before.lastMoveTime);
      }
    },
  );

  test(
    'an explicit coherent setup and a new game identity can begin at the initial position',
    () async {
      final before = game('a', firstPgn);
      final explicit = '[SetUp "1"]\n[FEN "$startFen"]\n\n*';
      final merged = mergeLiveGameUpdateWithBase(
        baseGame: before,
        update: LiveGameUpdate.fromRow({
          ...row(before, pgn: explicit, fen: startFen),
          'last_move': null,
        }),
      );
      expect(merged.fen, startFen);
      expect(merged.pgn, explicit);
      final fresh = before.copyWith(
        gameId: 'new-round-game',
        pgn: '*',
        fen: startFen,
        clearLastMove: true,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(baseGameProvider(fresh.gameId).notifier).state = fresh;
      final sub = container.listen(
        scopedLiveGameCardProvider(
          LiveGameWatchParams(gameId: fresh.gameId, streamEnabled: false),
        ),
        (_, __) {},
        fireImmediately: true,
      );
      expect(sub.read()!.fen, startFen);
      sub.close();
    },
  );

  for (final newerTime in [false, true]) {
    test(
      'a genuine coherent takeback with ${newerTime ? 'newer' : 'older'} time waits for exact confirmation and remains supported',
      () async {
        final before = game('a', firstPgn);
        const takebackPgn = '1. e4 *';
        final takeback = LiveGameUpdate.fromRow({
          ...row(
            before,
            pgn: takebackPgn,
            fen: resolveFinalPositionFromPgn(takebackPgn)!.fen,
            lastMove: 'e2e4',
            time: moveTime.add(Duration(seconds: newerTime ? 1 : -1)),
          ),
        });
        final repository = BatchRepository();
        final confirmation = Completer<LiveGameUpdate?>();
        repository.pending = confirmation.future;
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await repository.controller.close();
        });
        container.read(baseGameProvider('a').notifier).state = before;
        final sub = container.listen(
          scopedLiveGameCardProvider(
            LiveGameWatchParams(
              gameId: 'a',
              batchKey: LiveGamesBatchKey(scopeId: 'takeback', gameIds: ['a']),
            ),
          ),
          (_, __) {},
          fireImmediately: true,
        );
        repository.controller.add({'a': takeback});
        await settle(container);
        expect(sub.read()!.fen, before.fen);
        expect(repository.confirmationReads, 1);
        confirmation.complete(takeback);
        await settle(container);
        expect(sub.read()!.pgn, takebackPgn);
        expect(sub.read()!.fen, takeback.fen);
        sub.close();
      },
    );
  }

  test(
    'coherent clock-only updates keep their real zero and do not move the board',
    () async {
      final before = game('a', firstPgn);
      final merged = mergeLiveGameUpdateWithBase(
        baseGame: before,
        update: LiveGameUpdate.fromRow({
          ...row(before),
          'last_clock_white': 0,
          'last_clock_black': 152,
        }),
      );
      expect(merged.whiteClockSeconds, 0);
      expect(merged.blackClockSeconds, 152);
      expect(merged.fen, before.fen);
      expect(merged.pgn, before.pgn);
      expect(shouldReplaceBaseGame(before, merged), isTrue);
    },
  );

  test(
    'two played boards retain their positions through newer timestamp-only reset snapshots and recover normally',
    () async {
      final repository = BatchRepository();
      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(() async {
        container.dispose();
        await repository.controller.close();
      });
      final games = [game('a', firstPgn), game('b', secondPgn)];
      final batch = LiveGamesBatchKey(
        scopeId: 'reset-regression',
        gameIds: ['a', 'b'],
      );
      final frames = <String, List<String?>>{
        for (final value in games) value.gameId: [],
      };
      final subscriptions = <ProviderSubscription<GamesTourModel?>>[];
      for (final value in games) {
        container.read(baseGameProvider(value.gameId).notifier).state = value;
        repository.confirmed[value.gameId] = LiveGameUpdate.fromRow(row(value));
        subscriptions.add(
          container.listen(
            scopedLiveGameCardProvider(
              LiveGameWatchParams(gameId: value.gameId, batchKey: batch),
            ),
            (_, next) {
              frames[value.gameId]!.add(
                next == null ? null : GameCardData.fromGamesTourModel(next).fen,
              );
            },
            fireImmediately: true,
          ),
        );
      }
      repository.controller.add({
        for (final value in games)
          value.gameId: LiveGameUpdate.fromRow({
            ...row(
              value,
              pgn: '*',
              fen: startFen,
              time: moveTime.add(const Duration(seconds: 1)),
            ),
            'last_move': null,
          }),
      });
      await settle(container);
      for (var i = 0; i < games.length; i++) {
        expect(subscriptions[i].read()!.fen, games[i].fen);
        expect(
          container.read(baseGameProvider(games[i].gameId))!.fen,
          games[i].fen,
        );
        expect(frames[games[i].gameId], everyElement(games[i].fen));
      }
      final next = [
        games[0].copyWith(
          pgn: '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *',
          fen:
              resolveFinalPositionFromPgn(
                '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *',
              )!.fen,
          lastMove: 'b5a4',
          lastMoveTime: moveTime.add(const Duration(seconds: 2)),
        ),
        games[1].copyWith(
          pgn: '1. d4 d5 2. c4 e6 3. Nc3 *',
          fen: resolveFinalPositionFromPgn('1. d4 d5 2. c4 e6 3. Nc3 *')!.fen,
          lastMove: 'b1c3',
          lastMoveTime: moveTime.add(const Duration(seconds: 2)),
        ),
      ];
      repository.controller.add({
        for (final value in next)
          value.gameId: LiveGameUpdate.fromRow(row(value)),
      });
      await settle(container);
      for (var i = 0; i < next.length; i++) {
        expect(subscriptions[i].read()!.fen, next[i].fen);
        expect(
          GameCardData.fromGamesTourModel(subscriptions[i].read()!).fen,
          next[i].fen,
        );
        subscriptions[i].close();
      }
    },
  );
}
