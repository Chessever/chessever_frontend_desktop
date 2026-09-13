import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_allowance.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

final _gameA = ChessGame.fromPgn('a', '[Result "1-0"]\n\n1. e4 e5 1-0');
final _gameB = ChessGame.fromPgn('b', '[Result "0-1"]\n\n1. d4 d5 0-1');

GameAnalysisReport _reportFor(ChessGame game) => GameAnalysisReport(
  fingerprint: gameReportFingerprint(game),
  positions: [
    GameReportPosition(
      fen: game.startingFen,
      lines: const [
        GameReportLine(moves: ['e2e4'], depth: 14, centipawns: 20),
      ],
    ),
  ],
  moves: const [],
  whiteAccuracy: 91,
  blackAccuracy: 84,
  generatedAt: DateTime.utc(2026, 9, 12),
);

void main() {
  test('a free account gets one successful delivered report', () async {
    final allowance = GameReportAllowanceStore.memory();
    final store = GameAnalysisReportStore.memory();
    var runs = 0;

    Future<GameReportRequestResult> request(ChessGame game) {
      final controller = GameAnalysisReportController(
        remoteRunner: (
          game, {
          whiteRating,
          blackRating,
          required onProgress,
          required isCancelled,
        }) async {
          runs++;
          return _reportFor(game);
        },
      );
      addTearDown(controller.dispose);
      return GameReportRequestCoordinator(
        accountId: () => 'account-1',
        isPremium: () => false,
        store: store,
        allowanceStore: allowance,
      ).request(controller: controller, game: game, gameFinished: true);
    }

    final first = await request(_gameA);
    final second = await request(_gameB);

    expect(first.outcome, GameReportRequestOutcome.generated);
    expect(second.outcome, GameReportRequestOutcome.quotaExceeded);
    expect(runs, 1);
  });

  test('premium can generate after the free success is spent', () async {
    final allowance = GameReportAllowanceStore.memory();
    final store = GameAnalysisReportStore.memory();
    var premium = false;
    var runs = 0;
    await allowance.markFreeSuccess('account-1', gameReportFingerprint(_gameA));

    final controller = GameAnalysisReportController(
      remoteRunner: (
        game, {
        whiteRating,
        blackRating,
        required onProgress,
        required isCancelled,
      }) async {
        runs++;
        return _reportFor(game);
      },
    );
    addTearDown(controller.dispose);

    final result = await GameReportRequestCoordinator(
      accountId: () => 'account-1',
      isPremium: () => premium,
      store: store,
      allowanceStore: allowance,
    ).request(
      controller: controller,
      game: _gameB,
      gameFinished: true,
      ui: GameReportRequestUi(
        requestUpgrade: () async {
          premium = true;
          return true;
        },
      ),
    );

    expect(result.outcome, GameReportRequestOutcome.generated);
    expect(runs, 1);
  });

  test('invalid requests start nothing', () async {
    var runs = 0;
    final controller = GameAnalysisReportController(
      remoteRunner: (
        game, {
        whiteRating,
        blackRating,
        required onProgress,
        required isCancelled,
      }) async {
        runs++;
        return _reportFor(game);
      },
    );
    addTearDown(controller.dispose);
    final coordinator = GameReportRequestCoordinator(
      accountId: () => 'account-1',
      isPremium: () => false,
      store: GameAnalysisReportStore.memory(),
      allowanceStore: GameReportAllowanceStore.memory(),
    );

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
    expect(runs, 0);
  });

  test('a final result is required before a report', () {
    final open = ChessGame.fromPgn('open', '1. e4 *');
    expect(gameReportHasFinalResult(open, const {'Result': '*'}), isFalse);
    expect(gameReportHasFinalResult(open, const {}), isFalse);
    expect(gameReportHasFinalResult(open, const {'Result': '1/2-1/2'}), isTrue);
    expect(gameReportHasFinalResult(open, const {'Result': '0-1'}), isTrue);
  });
}
