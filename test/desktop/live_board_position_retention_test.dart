import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
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
// What a broadcast sends when it clears a wrong-board mapping: headers, no
// moves, no SetUp tag.
const headerOnlyReset = '[Event "Round 7"]\n[Site "Board 3"]\n\n*';
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
    'an exact-confirmed empty source row clears a played board without swallowing its result',
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
        // The server confirmed the reset: it is the canonical row now.
        expect(sub.read()!.fen, startFen);
        expect(sub.read()!.pgn, '*');
        expect(sub.read()!.lastMove, isNull);
        expect(
          sub.read()!.lastMoveTime,
          moveTime.add(const Duration(seconds: 1)),
        );
        expect(container.read(baseGameProvider('a'))!.fen, startFen);
        expect(sub.read()!.whitePlayer.name, 'Corrected White a');
        expect(
          sub.read()!.gameStatus,
          status == 'W' ? GameStatus.whiteWins : GameStatus.ongoing,
        );
        // Only the retained board, then the confirmed reset. Nothing between.
        expect(frames.toSet(), {before.fen, startFen});
        expect(frames.last, startFen);
      }
      expect(repository.confirmationReads, greaterThan(0));
      sub.close();
    },
  );

  for (final serverCleared in [true, false]) {
    test(
      'a header-only reset with unchanged metadata is confirmed exactly and '
      '${serverCleared ? 'clears the board' : 'is retained while the server is still played'}',
      () async {
        final repository = BatchRepository();
        final container = ProviderContainer(
          overrides: [
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
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
                scopeId: 'header-only-reset',
                gameIds: ['a'],
              ),
            ),
          ),
          (_, next) => frames.add(next?.fen),
          fireImmediately: true,
        );
        // Same clocks, players and status as the played row: only the
        // position is cleared.
        final reset = LiveGameUpdate.fromRow({
          ...row(
            before,
            pgn: headerOnlyReset,
            fen: startFen,
            time: moveTime.add(const Duration(seconds: 1)),
          ),
          'last_move': null,
        });
        repository.confirmed['a'] =
            serverCleared ? reset : LiveGameUpdate.fromRow(row(before));
        repository.controller.add({'a': reset});
        await settle(container);

        expect(repository.confirmationReads, 1);
        final expectedFen = serverCleared ? startFen : before.fen;
        expect(sub.read()!.fen, expectedFen);
        expect(sub.read()!.pgn, serverCleared ? headerOnlyReset : before.pgn);
        expect(container.read(baseGameProvider('a'))!.fen, expectedFen);
        expect(frames.last, expectedFen);
        if (!serverCleared) expect(frames, everyElement(before.fen));
        sub.close();
      },
    );
  }

  test(
    'an unconfirmed incomplete reset keeps the clocks that belong to the retained move-time anchor',
    () {
      final before = game('a', firstPgn);
      final merged = mergeLiveGameUpdateWithBase(
        baseGame: before,
        update: LiveGameUpdate.fromRow({
          ...row(
            before,
            pgn: headerOnlyReset,
            fen: startFen,
            time: moveTime.add(const Duration(minutes: 5)),
          ),
          'last_move': null,
          'last_clock_white': 90,
          'last_clock_black': 80,
          'players': [
            {'name': before.whitePlayer.name, 'clock': 9000},
            {'name': before.blackPlayer.name, 'clock': 8000},
          ],
        }),
      );
      expect(merged.fen, before.fen);
      expect(merged.lastMoveTime, before.lastMoveTime);
      // A countdown runs from lastMoveTime. Pairing the retained anchor with
      // the reset row's clocks would tick from a stale start.
      expect(merged.whiteClockSeconds, before.whiteClockSeconds);
      expect(merged.blackClockSeconds, before.blackClockSeconds);
      expect(merged.whiteClockCentiseconds, before.whiteClockCentiseconds);
      expect(merged.blackClockCentiseconds, before.blackClockCentiseconds);
    },
  );

  testWidgets(
    'a confirmed reset stays applied when the card is reseeded from a pre-reset list row',
    (tester) async {
      final repository = BatchRepository(broadcast: true);
      final before = game('a', firstPgn);
      // Tournament list rows omit the PGN and were fetched before the reset.
      final listRow = before.copyWith(clearPgn: true);
      final batch = LiveGamesBatchKey(scopeId: 'reseed', gameIds: ['a']);
      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      container.read(baseGameProvider('a').notifier).state = before;
      // The broadcast clears the mapping without a move time, the hardest
      // case for timestamp freshness.
      final reset = LiveGameUpdate.fromRow({
        ...row(before, pgn: headerOnlyReset, fen: startFen),
        'last_move': null,
        'last_move_time': null,
      });
      repository.confirmed['a'] = reset;
      final painted = <String?>[];
      // The parent list rebuilds its cards with the same stale row whenever
      // anything else in the round changes.
      final parentRebuild = ValueNotifier<int>(0);
      addTearDown(parentRebuild.dispose);
      final baseWrites = <String?>[];
      final baseSub = container.listen(
        baseGameProvider('a'),
        (_, next) => baseWrites.add(next?.fen),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ValueListenableBuilder<int>(
              valueListenable: parentRebuild,
              builder: (context, tick, _) => Consumer(
                builder: (context, ref, _) {
                  final live = watchLiveGame(ref, listRow, batchKey: batch);
                  painted.add(live.fen);
                  return Text('$tick ${live.fen}');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.controller.hasListener, isTrue);
      repository.controller.add({'a': reset});
      for (var frame = 0; frame < 20; frame++) {
        if (frame >= 8) parentRebuild.value++;
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(container.read(baseGameProvider('a'))!.fen, startFen);
      expect(painted.last, startFen);
      final firstReset = painted.indexOf(startFen);
      expect(firstReset, isNonNegative);
      expect(
        painted.sublist(firstReset),
        everyElement(startFen),
        reason: 'The stale list row must not repaint the cleared moves.',
      );
      expect(
        baseWrites,
        [startFen],
        reason: 'The shared base must take the reset once and keep it.',
      );
      expect(
        repository.confirmationReads,
        1,
        reason: 'Reseeding must not loop exact reads against the same reset.',
      );
      expect(tester.takeException(), isNull);
      baseSub.close();
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      unawaited(repository.controller.close());
      await tester.pump();
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

  group('server-confirmed resets on the Board and REST paths', () {
    final before = game('a', firstPgn);
    final reset = LiveGameUpdate.fromRow({
      ...row(
        before,
        pgn: headerOnlyReset,
        fen: startFen,
        time: moveTime.add(const Duration(seconds: 1)),
      ),
      'last_move': null,
    });
    final resetGame = mergeLiveGameUpdateWithBase(
      baseGame: before,
      update: reset,
      serverConfirmed: true,
    );

    test('only incomplete resets of a played position are held', () {
      expect(
        liveUpdateHoldsPlayedPosition(baseGame: before, update: reset),
        isTrue,
      );
      const nextPgn = '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *';
      final next = LiveGameUpdate.fromRow({
        ...row(
          before,
          pgn: nextPgn,
          fen: resolveFinalPositionFromPgn(nextPgn)!.fen,
          lastMove: 'b5a4',
        ),
      });
      expect(
        liveUpdateHoldsPlayedPosition(baseGame: before, update: next),
        isFalse,
      );
      final explicitSetup = '[SetUp "1"]\n[FEN "$startFen"]\n\n*';
      expect(
        liveUpdateHoldsPlayedPosition(
          baseGame: before,
          update: LiveGameUpdate.fromRow({
            ...row(before, pgn: explicitSetup, fen: startFen),
            'last_move': null,
          }),
        ),
        isFalse,
      );
      expect(
        liveUpdateHoldsPlayedPosition(baseGame: resetGame, update: reset),
        isFalse,
        reason: 'An already-cleared board has nothing to hold.',
      );
      expect(resetGame.fen, startFen);
      expect(resetGame.pgn, headerOnlyReset);
      expect(resetGame.lastMove, isNull);
    });

    test(
      'the focused Board confirms a held reset instead of accepting it as a no-op',
      () {
        final held = mergeLiveGameUpdateWithBase(
          baseGame: before,
          update: reset,
        );
        expect(held, before);
        expect(
          shouldAcceptFocusedLiveCandidate(
            current: before,
            incoming: held,
            serverConfirmedRegression: false,
            heldPositionReset: true,
          ),
          isFalse,
        );
        expect(
          shouldAcceptFocusedLiveCandidate(
            current: before,
            incoming: resetGame,
            serverConfirmedRegression: true,
            heldPositionReset: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'shouldReplaceBaseGame clears a played base only for a confirmed row',
      () {
        expect(shouldReplaceBaseGame(before, resetGame), isFalse);
        expect(
          shouldReplaceBaseGame(before, resetGame, serverConfirmed: true),
          isTrue,
        );
        // Confirmation only lifts the reset hold, not ordinary freshness.
        const olderPgn = '1. e4 e5 *';
        final olderTakeback = before.copyWith(
          pgn: olderPgn,
          fen: resolveFinalPositionFromPgn(olderPgn)!.fen,
          lastMove: 'e7e5',
          lastMoveTime: moveTime.subtract(const Duration(seconds: 5)),
        );
        expect(
          shouldReplaceBaseGame(before, olderTakeback, serverConfirmed: true),
          isFalse,
        );
      },
    );

    test(
      'the opened Board REST read applies a reset only if nothing overtook it',
      () {
        expect(
          selectRefreshedLiveBase(
            baseBeforeRead: before,
            currentBase: before,
            fetched: resetGame,
          ),
          resetGame,
        );
        const newerPgn = '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *';
        final overtaken = before.copyWith(
          pgn: newerPgn,
          fen: resolveFinalPositionFromPgn(newerPgn)!.fen,
          lastMove: 'b5a4',
          lastMoveTime: moveTime.add(const Duration(seconds: 2)),
        );
        expect(
          selectRefreshedLiveBase(
            baseBeforeRead: before,
            currentBase: overtaken,
            fetched: resetGame,
          ),
          overtaken,
        );
      },
    );
  });
}
