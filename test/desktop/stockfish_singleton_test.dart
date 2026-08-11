import 'dart:async';

import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:chessever/desktop/services/engine/stockfish_facade.dart';
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

  group('StockfishSingleton readiness timeout policy', () {
    test('allows desktop cold starts to outlive the mobile FFI ceiling', () {
      expect(
        stockfishReadyTimeout(
          requested: const Duration(seconds: 3),
          isAndroid: false,
          isDesktop: true,
        ),
        desktopStockfishColdStartTimeout,
      );
      expect(
        desktopStockfishColdStartTimeout,
        greaterThan(desktopStockfishUciHandshakeTimeout),
      );
    });

    test('does not shorten an explicitly longer desktop timeout', () {
      expect(
        stockfishReadyTimeout(
          requested: const Duration(seconds: 45),
          isAndroid: false,
          isDesktop: true,
        ),
        const Duration(seconds: 45),
      );
    });

    test('keeps existing Android and iOS timeout behavior', () {
      expect(
        stockfishReadyTimeout(
          requested: const Duration(seconds: 3),
          isAndroid: true,
          isDesktop: false,
        ),
        const Duration(seconds: 4),
      );
      expect(
        stockfishReadyTimeout(
          requested: const Duration(seconds: 3),
          isAndroid: false,
          isDesktop: false,
        ),
        const Duration(seconds: 3),
      );
    });
  });

  test(
    'initialization failure is guarded before another caller waits',
    () async {
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        final initialization = guardedStockfishInitializationCompleter();
        initialization.completeError(StateError('engine unavailable'));
        await expectLater(initialization.future, throwsA(isA<StateError>()));
        await pumpEventQueue();
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
    },
  );

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
