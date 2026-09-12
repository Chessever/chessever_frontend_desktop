import 'dart:async';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/repository/supabase/game_analysis_quota_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `public.claim_game_analysis_report`: one fingerprint per UTC day,
/// retries of that fingerprint are free, and there is no refund path.
class _ClaimServer {
  bool authenticated = true;
  bool premium = false;
  Object? failWith;
  String? todaysFingerprint;
  final List<String> calls = <String>[];

  Future<GameAnalysisClaimResult> claim(String fingerprint) async {
    calls.add(fingerprint);
    final failure = failWith;
    if (failure != null) throw failure;
    if (!authenticated) return _result(false, 'auth_required');
    if (fingerprint.trim().isEmpty) return _result(false, 'invalid_fingerprint');
    if (premium) return _result(true, 'premium', premium: true);
    final existing = todaysFingerprint;
    if (existing != null) {
      return existing == fingerprint
          ? _result(true, 'same_day_same_game')
          : _result(false, 'daily_limit');
    }
    todaysFingerprint = fingerprint;
    return _result(true, 'claimed');
  }
}

GameAnalysisClaimResult _result(
  bool allowed,
  String reason, {
  bool premium = false,
}) => GameAnalysisClaimResult(
  allowed: allowed,
  reason: reason,
  isPremium: premium,
);

class _Engine {
  int local = 0;
  int remote = 0;
  Completer<void>? hold;
  final List<String>? log;

  _Engine({this.log});

  GameAnalysisReportController controller({bool serverDown = true}) =>
      GameAnalysisReportController(
        evaluator: (
          fen, {
          required depth,
          required multiPv,
          required ownerId,
          onProgress,
        }) async {
          local++;
          log?.add('engine');
          final gate = hold;
          if (gate != null) await gate.future;
          return EnhancedCloudEval(
            fen: fen,
            knodes: 1,
            depth: depth,
            pvs: [Pv(moves: 'e2e4', cp: 20)],
          );
        },
        // A failing server forces the local fallback, so a local run proves
        // the fallback was reached.
        remoteRunner:
            serverDown
                ? (
                  game, {
                  whiteRating,
                  blackRating,
                  required onProgress,
                  required isCancelled,
                }) async {
                  remote++;
                  throw StateError('analysis service unreachable');
                }
                : null,
      );
}

final _gameA = ChessGame.fromPgn('a', '[Result "1-0"]\n\n1. e4 e5 1-0');
final _gameB = ChessGame.fromPgn('b', '[Result "0-1"]\n\n1. d4 d5 0-1');

GameAnalysisReport _reportFor(ChessGame game) => GameAnalysisReport(
  fingerprint: gameReportFingerprint(game),
  positions: [
    GameReportPosition(
      fen: game.startingFen,
      lines: const [GameReportLine(moves: ['e2e4'], depth: 14, centipawns: 20)],
    ),
  ],
  moves: const [],
  whiteAccuracy: 91,
  blackAccuracy: 84,
  generatedAt: DateTime.utc(2026, 9, 12),
);

GameReportRequestCoordinator _coordinator(
  GameReportClaim claim, {
  String? account,
  GameAnalysisReportStore? store,
}) => GameReportRequestCoordinator(
  claim: claim,
  accountId: () => account,
  store: store ?? GameAnalysisReportStore.memory(),
);

void main() {
  group('claim reasons', () {
    final cases = <String, (bool, GameReportRequestOutcome)>{
      'auth_required': (false, GameReportRequestOutcome.accountRequired),
      'invalid_fingerprint': (
        false,
        GameReportRequestOutcome.temporarilyUnavailable,
      ),
      'daily_limit': (false, GameReportRequestOutcome.quotaExceeded),
      'premium': (true, GameReportRequestOutcome.generated),
      'same_day_same_game': (true, GameReportRequestOutcome.generated),
      'claimed': (true, GameReportRequestOutcome.generated),
    };
    for (final entry in cases.entries) {
      test('${entry.key} -> ${entry.value.$2.name}', () async {
        final engine = _Engine();
        final controller = engine.controller();
        addTearDown(controller.dispose);
        final result = await _coordinator(
          (_) async => _result(entry.value.$1, entry.key),
        ).request(controller: controller, game: _gameA, gameFinished: true);
        expect(result.outcome, entry.value.$2);
        expect(result.claimReason, entry.key);
        if (entry.value.$1) {
          expect(engine.local, greaterThan(0));
          expect(controller.state.status, GameReportStatus.completed);
        } else {
          expect(engine.local, 0);
          expect(engine.remote, 0);
        }
      });
    }

    test('the same game is free to retry today, a new game is denied', () async {
      final server = _ClaimServer();
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      // No account: nothing is cached, so every request reaches the claim.
      final coordinator = _coordinator(server.claim);

      final first = await coordinator.request(
        controller: controller,
        game: _gameA,
        gameFinished: true,
      );
      expect(first.claimReason, 'claimed');

      controller.invalidate();
      final retry = await coordinator.request(
        controller: controller,
        game: _gameA,
        gameFinished: true,
      );
      expect(retry.outcome, GameReportRequestOutcome.generated);
      expect(retry.claimReason, 'same_day_same_game');

      controller.invalidate();
      final localRunsBefore = engine.local;
      final other = await coordinator.request(
        controller: controller,
        game: _gameB,
        gameFinished: true,
      );
      expect(other.outcome, GameReportRequestOutcome.quotaExceeded);
      expect(other.claimReason, 'daily_limit');
      expect(engine.local, localRunsBefore);
    });
  });

  group('cached reports', () {
    test('are served without calling the claim RPC, even offline', () async {
      final store = GameAnalysisReportStore.memory();
      await store.save('account-1', _reportFor(_gameA));
      store.clearHotCacheForTest(); // cold start: only durable rows remain
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      var claims = 0;

      final result = await _coordinator(
        (_) async {
          claims++;
          throw Exception('offline');
        },
        account: 'account-1',
        store: store,
      ).request(controller: controller, game: _gameA, gameFinished: true);

      expect(result.outcome, GameReportRequestOutcome.restored);
      expect(claims, 0);
      expect(engine.local + engine.remote, 0);
      expect(controller.state.status, GameReportStatus.completed);
      expect(controller.state.report?.fingerprint, gameReportFingerprint(_gameA));
    });

    test('the report on screen is restored, not re-claimed', () async {
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      expect(controller.adoptCompletedReport(_reportFor(_gameA)), isTrue);
      var claims = 0;
      final result = await _coordinator((_) async {
        claims++;
        return _result(true, 'claimed');
      }).request(controller: controller, game: _gameA, gameFinished: true);
      expect(result.outcome, GameReportRequestOutcome.restored);
      expect(claims, 0);
    });

    test('are scoped to the account that generated them', () async {
      final store = GameAnalysisReportStore.memory();
      await store.save('account-1', _reportFor(_gameA));
      final server = _ClaimServer()..todaysFingerprint = 'another game';
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);

      final result = await _coordinator(
        server.claim,
        account: 'account-2',
        store: store,
      ).request(controller: controller, game: _gameA, gameFinished: true);

      expect(server.calls, [gameReportFingerprint(_gameA)]);
      expect(result.outcome, GameReportRequestOutcome.quotaExceeded);
    });

    test('a generated report is cached for its account', () async {
      final store = GameAnalysisReportStore.memory();
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      await _coordinator(
        _ClaimServer().claim,
        account: 'account-1',
        store: store,
      ).request(controller: controller, game: _gameA, gameFinished: true);
      await store.flush();
      store.clearHotCacheForTest();
      expect(
        await store.load('account-1', gameReportFingerprint(_gameA)),
        isNotNull,
      );
      expect(
        await store.load('account-2', gameReportFingerprint(_gameA)),
        isNull,
      );
    });
  });

  test('cancelling after an affirmative claim does not refund it', () async {
    final server = _ClaimServer();
    final engine = _Engine()..hold = Completer<void>();
    final controller = engine.controller();
    addTearDown(() {
      if (!(engine.hold?.isCompleted ?? true)) engine.hold!.complete();
      controller.dispose();
    });
    final coordinator = _coordinator(server.claim);

    final running = coordinator.request(
      controller: controller,
      game: _gameA,
      gameFinished: true,
    );
    while (!controller.state.isRunning || engine.local == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.cancel();
    // Release the in-flight evaluation so the superseded run can unwind.
    engine.hold!.complete();
    engine.hold = null;
    final cancelled = await running;
    expect(cancelled.outcome, GameReportRequestOutcome.generated);
    expect(controller.state.status, GameReportStatus.cancelled);

    final localRunsBefore = engine.local;
    final newGame = await coordinator.request(
      controller: controller,
      game: _gameB,
      gameFinished: true,
    );
    expect(newGame.outcome, GameReportRequestOutcome.quotaExceeded);
    expect(engine.local, localRunsBefore);

    final sameGame = await coordinator.request(
      controller: controller,
      game: _gameA,
      gameFinished: true,
    );
    expect(sameGame.claimReason, 'same_day_same_game');
    expect(controller.state.status, GameReportStatus.completed);
  });

  group('after an upgrade', () {
    test('the entitlement is refreshed and claimed again before generating', () async {
      final log = <String>[];
      final server = _ClaimServer()..todaysFingerprint = 'another game';
      final engine = _Engine(log: log);
      final controller = engine.controller();
      addTearDown(controller.dispose);

      final result = await _coordinator((fingerprint) {
        log.add('claim');
        return server.claim(fingerprint);
      }).request(
        controller: controller,
        game: _gameA,
        gameFinished: true,
        ui: GameReportRequestUi(
          requestUpgrade: (denial) async {
            expect(denial.reason, 'daily_limit');
            log.add('upgrade');
            server.premium = true;
            return true;
          },
          refreshEntitlement: () async => log.add('refresh'),
        ),
      );

      expect(result.outcome, GameReportRequestOutcome.generated);
      expect(result.claimReason, 'premium');
      expect(log.take(5), ['claim', 'upgrade', 'refresh', 'claim', 'engine']);
    });

    test('an upgrade the server does not confirm generates nothing', () async {
      final server = _ClaimServer()..todaysFingerprint = 'another game';
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      final result = await _coordinator(server.claim).request(
        controller: controller,
        game: _gameA,
        gameFinished: true,
        ui: GameReportRequestUi(requestUpgrade: (_) async => true),
      );
      expect(server.calls, hasLength(2));
      expect(result.outcome, GameReportRequestOutcome.quotaExceeded);
      expect(engine.local + engine.remote, 0);
    });
  });

  group('the local engine fallback', () {
    test('never runs when the claim is denied', () async {
      final server = _ClaimServer()..todaysFingerprint = 'another game';
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      await _coordinator(
        server.claim,
      ).request(controller: controller, game: _gameA, gameFinished: true);
      expect(engine.local, 0);
      expect(engine.remote, 0);
    });

    test('never runs when the claim fails, and no paywall opens', () async {
      final server = _ClaimServer()..failWith = Exception('network down');
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      var paywalls = 0;
      final result = await _coordinator(server.claim).request(
        controller: controller,
        game: _gameA,
        gameFinished: true,
        ui: GameReportRequestUi(
          requestUpgrade: (_) async {
            paywalls++;
            return true;
          },
        ),
      );
      expect(result.outcome, GameReportRequestOutcome.temporarilyUnavailable);
      expect(paywalls, 0);
      expect(engine.local, 0);
      expect(engine.remote, 0);
    });

    test('runs only after an affirmative claim', () async {
      final engine = _Engine();
      final controller = engine.controller();
      addTearDown(controller.dispose);
      await _coordinator(
        _ClaimServer().claim,
      ).request(controller: controller, game: _gameA, gameFinished: true);
      expect(engine.remote, 1);
      expect(engine.local, greaterThan(0));
    });
  });

  test('invalid requests start nothing and claim nothing', () async {
    final server = _ClaimServer();
    final engine = _Engine();
    final controller = engine.controller();
    addTearDown(controller.dispose);
    final coordinator = _coordinator(server.claim);
    final unfinished = await coordinator.request(
      controller: controller,
      game: _gameA,
      gameFinished: false,
    );
    final noGame = await coordinator.request(
      controller: controller,
      game: null,
      gameFinished: true,
    );
    final lockedSource = await coordinator.request(
      controller: controller,
      game: _gameA,
      gameFinished: true,
      sourceAccessible: false,
    );
    for (final result in [unfinished, noGame, lockedSource]) {
      expect(result.outcome, GameReportRequestOutcome.unavailable);
    }
    expect(server.calls, isEmpty);
    expect(engine.local + engine.remote, 0);
  });

  test('a final result is required before a report', () {
    final open = ChessGame.fromPgn('open', '1. e4 *');
    expect(gameReportHasFinalResult(open, const {'Result': '*'}), isFalse);
    expect(gameReportHasFinalResult(open, const {}), isFalse);
    expect(gameReportHasFinalResult(open, const {'Result': '1/2-1/2'}), isTrue);
    expect(gameReportHasFinalResult(open, const {'Result': '0-1'}), isTrue);
  });
}
