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
}
