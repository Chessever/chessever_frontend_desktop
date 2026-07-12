import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StockfishSingleton cache policy', () {
    test('bypasses cached results for current-position searches', () {
      expect(
        shouldUseStockfishEvaluationCache(
          allowCache: true,
          isCurrentPosition: true,
        ),
        isFalse,
      );
    });

    test('keeps cached results available for background searches', () {
      expect(
        shouldUseStockfishEvaluationCache(
          allowCache: true,
          isCurrentPosition: false,
        ),
        isTrue,
      );
      expect(
        shouldUseStockfishEvaluationCache(
          allowCache: false,
          isCurrentPosition: false,
        ),
        isFalse,
      );
    });
  });

  test('superseded initialization releases the instance lock', () async {
    final singleton = StockfishSingleton();
    await singleton.forceRecovery();
    final releaseHeldLock = await singleton.acquireInstanceLockForTesting();
    final initialization = singleton.ensureEngineReadyForTesting();
    await pumpEventQueue();
    expect(singleton.instanceLockHeldForTesting, isTrue);

    await singleton.forceRecovery();
    await expectLater(initialization, throwsA(anything));

    expect(singleton.instanceLockHeldForTesting, isFalse);
    final releaseNextLock = await singleton
        .acquireInstanceLockForTesting()
        .timeout(const Duration(milliseconds: 250));
    releaseNextLock();
    releaseHeldLock();
  });

  test('concurrent force recovery calls share one lifecycle reset', () async {
    final singleton = StockfishSingleton();
    await singleton.forceRecovery();
    final before = singleton.engineLifecycleGenerationForTesting;

    await Future.wait(<Future<void>>[
      singleton.forceRecovery(),
      singleton.forceRecovery(),
    ]);

    expect(singleton.engineLifecycleGenerationForTesting, before + 1);
  });
}
