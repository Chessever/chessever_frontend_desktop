import 'dart:async';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_allowance.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account epoch A-B-A rejects a late result without spending', () async {
    var epoch = 1;
    final started = Completer<void>();
    final pending = Completer<GameAnalysisReport>();
    final allowance = GameReportAllowanceStore.memory();
    final game = ChessGame.fromPgn('epoch', '[Result "1-0"]\n\n1. e4 e5 1-0');
    final controller = GameAnalysisReportController(remoteRunner:
      (game, {whiteRating, blackRating, required onProgress, required isCancelled}) {
        started.complete();
        return pending.future;
      });
    addTearDown(controller.dispose);
    final coordinator = GameReportRequestCoordinator(
      accountId: () => 'account-a', accountEpoch: () => epoch, isPremium: () => false,
      store: GameAnalysisReportStore.memory(), allowanceStore: allowance);
    final result = coordinator.request(controller: controller, game: game, gameFinished: true);
    await started.future;
    epoch = 3;
    pending.complete(_reportFor(game));
    expect((await result).reason, 'stale_request');
    expect(await allowance.hasLifetimeSuccess('account-a'), isFalse);
  });

  test(
    'first successful free report admits, second new report is denied',
    () async {
      final harness = _Harness();
      final first = await harness.request(harness.gameA);

      expect(first.outcome, GameReportRequestOutcome.generated);
      expect(harness.runs, 1);
      expect(await harness.allowance.hasLifetimeSuccess('account-1'), isTrue);

      final second = await harness.request(harness.gameB);

      expect(second.outcome, GameReportRequestOutcome.quotaExceeded);
      expect(second.reason, 'lifetime_free_success_used');
      expect(harness.runs, 1);
    },
  );

  test(
    'first explicit cached report delivery spends the free success',
    () async {
      final harness = _Harness();
      await harness.store.save('account-1', _reportFor(harness.gameA));

      final cached = await harness.request(harness.gameA);

      expect(cached.outcome, GameReportRequestOutcome.restored);
      expect(harness.runs, 0);
      expect(
        await harness.allowance.hasAdmittedReport(
          'account-1',
          gameReportFingerprint(harness.gameA),
        ),
        isTrue,
      );

      final second = await harness.request(harness.gameB);

      expect(second.outcome, GameReportRequestOutcome.quotaExceeded);
      expect(harness.runs, 0);
    },
  );

  test('admitted cached report reopens without charging again', () async {
    final harness = _Harness();
    final fingerprint = gameReportFingerprint(harness.gameA);
    await harness.store.save('account-1', _reportFor(harness.gameA));
    await harness.allowance.markFreeSuccess('account-1', fingerprint);

    final reopened = await harness.request(harness.gameA);

    expect(reopened.outcome, GameReportRequestOutcome.restored);
    expect(harness.runs, 0);
  });

  test('failed analysis does not consume the free success', () async {
    var fail = true;
    final harness = _Harness(
      runner: (
        game, {
        whiteRating,
        blackRating,
        required onProgress,
        required isCancelled,
      }) async {
        if (fail) throw StateError('analysis failed');
        return _reportFor(game);
      },
      evaluator: (
        fen, {
        required depth,
        required multiPv,
        required ownerId,
        onProgress,
      }) async {
        throw StateError('local fallback failed');
      },
    );

    final failed = await harness.request(harness.gameA);

    expect(failed.outcome, GameReportRequestOutcome.generated);
    expect(await harness.allowance.hasLifetimeSuccess('account-1'), isFalse);

    fail = false;
    final retried = await harness.request(harness.gameA);

    expect(retried.outcome, GameReportRequestOutcome.generated);
    expect(await harness.allowance.hasLifetimeSuccess('account-1'), isTrue);
  });

  test(
    'pending first free report serializes a concurrent second tab',
    () async {
      final firstCompleter = Completer<GameAnalysisReport>();
      var secondRuns = 0;
      final harness = _Harness(
        runner: (
          game, {
          whiteRating,
          blackRating,
          required onProgress,
          required isCancelled,
        }) {
          if (game.gameId == 'game-a') return firstCompleter.future;
          secondRuns++;
          return Future<GameAnalysisReport>.value(_reportFor(game));
        },
      );

      final firstRequest = harness.request(harness.gameA);
      await Future<void>.delayed(Duration.zero);
      final secondRequest = harness.request(harness.gameB);
      await Future<void>.delayed(Duration.zero);

      expect(secondRuns, 0);
      firstCompleter.complete(_reportFor(harness.gameA));

      expect((await firstRequest).outcome, GameReportRequestOutcome.generated);
      expect(
        (await secondRequest).outcome,
        GameReportRequestOutcome.quotaExceeded,
      );
      expect(secondRuns, 0);
    },
  );

  test(
    'lifetime free success persists across coordinator recreation',
    () async {
      final allowance = GameReportAllowanceStore.memory();
      final store = GameAnalysisReportStore.memory();
      final first = _Harness(allowance: allowance, store: store);
      await first.request(first.gameA);
      await allowance.flush();

      final afterRestart = _Harness(allowance: allowance, store: store);
      final second = await afterRestart.request(afterRestart.gameB);

      expect(second.outcome, GameReportRequestOutcome.quotaExceeded);
    },
  );

  test(
    'account switch isolates lifetime allowance and stale completion',
    () async {
      var account = 'account-a';
      final allowance = GameReportAllowanceStore.memory();
      final store = GameAnalysisReportStore.memory();
      final stale = Completer<GameAnalysisReport>();
      final harness = _Harness(
        accountId: () => account,
        allowance: allowance,
        store: store,
        runner: (
          game, {
          whiteRating,
          blackRating,
          required onProgress,
          required isCancelled,
        }) {
          return stale.future;
        },
      );

      final request = harness.request(harness.gameA);
      await Future<void>.delayed(Duration.zero);
      account = 'account-b';
      stale.complete(_reportFor(harness.gameA));

      expect(
        (await request).outcome,
        GameReportRequestOutcome.temporarilyUnavailable,
      );
      expect(await allowance.hasLifetimeSuccess('account-a'), isFalse);

      final freshB = _Harness(
        accountId: () => account,
        allowance: allowance,
        store: store,
      );
      final bResult = await freshB.request(freshB.gameB);

      expect(bResult.outcome, GameReportRequestOutcome.generated);
      expect(await allowance.hasLifetimeSuccess('account-b'), isTrue);
    },
  );
}

class _Harness {
  _Harness({
    String Function()? accountId,
    bool Function()? isPremium,
    GameAnalysisReportStore? store,
    GameReportAllowanceStore? allowance,
    GameReportRemoteRunner? runner,
    GameReportEvaluator? evaluator,
  }) : store = store ?? GameAnalysisReportStore.memory(),
       allowance = allowance ?? GameReportAllowanceStore.memory(),
       _accountId = accountId ?? (() => 'account-1'),
       _isPremium = isPremium ?? (() => false),
       _runner = runner,
       _evaluator = evaluator;

  final GameAnalysisReportStore store;
  final GameReportAllowanceStore allowance;
  final String Function() _accountId;
  final bool Function() _isPremium;
  final GameReportRemoteRunner? _runner;
  final GameReportEvaluator? _evaluator;
  int runs = 0;

  final gameA = ChessGame.fromPgn(
    'game-a',
    '[White "Ada"]\n[Black "Grace"]\n[Result "1-0"]\n\n1. e4 e5 1-0',
  );

  final gameB = ChessGame.fromPgn(
    'game-b',
    '[White "Linus"]\n[Black "Ken"]\n[Result "0-1"]\n\n1. d4 d5 0-1',
  );

  Future<GameReportRequestResult> request(ChessGame game) async {
    final controller = GameAnalysisReportController(
      remoteRunner:
          _runner ??
          (
            game, {
            whiteRating,
            blackRating,
            required onProgress,
            required isCancelled,
          }) async {
            runs++;
            return _reportFor(game);
          },
      evaluator: _evaluator,
    );
    addTearDown(controller.dispose);
    final coordinator = GameReportRequestCoordinator(
      accountId: _accountId,
      isPremium: _isPremium,
      store: store,
      allowanceStore: allowance,
    );
    return coordinator.request(
      controller: controller,
      game: game,
      gameFinished: true,
    );
  }
}

GameAnalysisReport _reportFor(ChessGame game) {
  return GameAnalysisReport(
    fingerprint: gameReportFingerprint(game),
    positions: [
      GameReportPosition(
        fen: game.startingFen,
        lines: const [GameReportLine(moves: [], depth: 14, centipawns: 0)],
      ),
    ],
    moves: const [],
    whiteAccuracy: 90,
    blackAccuracy: 88,
    generatedAt: DateTime.utc(2026),
  );
}
