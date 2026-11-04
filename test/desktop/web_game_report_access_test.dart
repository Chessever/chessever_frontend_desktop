import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_allowance.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

final _game = ChessGame.fromPgn('report', '[Result "1-0"]\n\n1. e4 e5 1-0');

GameAnalysisReport _report() => GameAnalysisReport(
  fingerprint: gameReportFingerprint(_game),
  positions: [
    GameReportPosition(
      fen: _game.startingFen,
      lines: const [
        GameReportLine(moves: ['e2e4'], depth: 14, centipawns: 20),
      ],
    ),
  ],
  moves: const [],
  whiteAccuracy: 91,
  blackAccuracy: 84,
  generatedAt: DateTime.utc(2026, 11, 5),
);

class _Harness {
  _Harness() {
    controller = GameAnalysisReportController(
      remoteRunner: (
        game, {
        whiteRating,
        blackRating,
        required onProgress,
        required isCancelled,
      }) async {
        runs++;
        return _report();
      },
    );
    addTearDown(controller.dispose);
  }

  final allowance = GameReportAllowanceStore.memory();
  final store = GameAnalysisReportStore.memory();
  late final GameAnalysisReportController controller;
  String account = 'account';
  bool premium = false;
  bool known = true;
  int runs = 0;

  Future<GameReportRequestResult> request({
    GameReportRequestUi ui = const GameReportRequestUi(),
  }) => GameReportRequestCoordinator(
    accountId: () => account,
    isPremium: () => premium,
    entitlementKnown: () => known,
    premiumRequired: true,
    allowanceStore: allowance,
    store: store,
  ).request(controller: controller, game: _game, gameFinished: true, ui: ui);
}

void main() {
  test(
    'the first browser report is Premium and spends no free success',
    () async {
      final h = _Harness();
      var prompts = 0;
      final result = await h.request(
        ui: GameReportRequestUi(
          requestUpgrade: () async {
            prompts++;
            return false;
          },
        ),
      );

      expect(result.outcome, GameReportRequestOutcome.premiumRequired);
      expect(result.reason, 'premium_game_report');
      expect(result.isBlocked, isTrue);
      expect(prompts, 1);
      expect(h.runs, 0);
      expect(await h.allowance.hasLifetimeSuccess(h.account), isFalse);
    },
  );

  for (final session in [false, true]) {
    test(
      '${session ? 'session' : 'cached'} admission does not bypass browser Premium',
      () async {
        final h = _Harness();
        await h.allowance.markFreeSuccess(
          h.account,
          gameReportFingerprint(_game),
        );
        await h.store.save(h.account, _report());
        if (session) h.controller.adoptCompletedReport(_report());
        var prompts = 0;

        final result = await h.request(
          ui: GameReportRequestUi(
            requestUpgrade: () async {
              prompts++;
              return false;
            },
          ),
        );

        expect(result.outcome, GameReportRequestOutcome.premiumRequired);
        expect(prompts, 1);
        expect(h.runs, 0);
        if (!session) {
          expect(h.controller.state.status, isNot(GameReportStatus.completed));
        }
      },
    );
  }

  test('unknown browser membership asks for retry without an upsell', () async {
    final h = _Harness()..known = false;
    var prompts = 0;
    final result = await h.request(
      ui: GameReportRequestUi(
        requestUpgrade: () async {
          prompts++;
          return false;
        },
      ),
    );

    expect(result.outcome, GameReportRequestOutcome.temporarilyUnavailable);
    expect(prompts, 0);
    expect(h.runs, 0);
  });

  test('a successful paywall result alone cannot grant a report', () async {
    final h = _Harness();
    var refreshes = 0;
    final result = await h.request(
      ui: GameReportRequestUi(
        requestUpgrade: () async => true,
        refreshEntitlement: () async => refreshes++,
      ),
    );

    expect(result.outcome, GameReportRequestOutcome.premiumRequired);
    expect(refreshes, 1);
    expect(h.runs, 0);
  });

  test(
    'verified upgrade resumes once without consuming a native free report',
    () async {
      final h = _Harness();
      var refreshes = 0;
      final result = await h.request(
        ui: GameReportRequestUi(
          requestUpgrade: () async => true,
          refreshEntitlement: () async {
            refreshes++;
            h.premium = true;
          },
        ),
      );

      expect(result.outcome, GameReportRequestOutcome.generated);
      expect(result.reason, 'premium');
      expect(refreshes, 1);
      expect(h.runs, 1);
      expect(await h.allowance.hasLifetimeSuccess(h.account), isFalse);
      expect(
        await h.allowance.hasAdmittedReport(
          h.account,
          gameReportFingerprint(_game),
        ),
        isTrue,
      );
    },
  );

  test('account change during upgrade discards the original request', () async {
    final h = _Harness();
    final result = await h.request(
      ui: GameReportRequestUi(
        requestUpgrade: () async {
          h.account = 'other-account';
          h.premium = true;
          return true;
        },
      ),
    );

    expect(result.outcome, GameReportRequestOutcome.temporarilyUnavailable);
    expect(result.reason, 'stale_request');
    expect(h.runs, 0);
  });

  test('Premium restores browser cache without generating again', () async {
    final h = _Harness()..premium = true;
    await h.store.save(h.account, _report());
    await h.allowance.markReportAdmitted(
      h.account,
      gameReportFingerprint(_game),
    );

    final result = await h.request();

    expect(result.outcome, GameReportRequestOutcome.restored);
    expect(h.runs, 0);
    expect(h.controller.state.status, GameReportStatus.completed);
  });
}
