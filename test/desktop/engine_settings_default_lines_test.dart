import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a fresh install shows two engine lines', () {
    const settings = EngineSettings();
    expect(settings.principalVariationIndex, 1);
    expect(settings.multiPvForStockfish(), 2);
    expect(settings.multiPvForLichess(), 2);
  });

  test('a cache without a saved line count falls back to two lines', () {
    final settings = engineSettingsFromCache(<String, dynamic>{
      'maxArrowsOnBoard': 2,
    });
    expect(settings.multiPvForStockfish(), 2);
  });

  test('a saved line count is kept', () {
    final settings = engineSettingsFromCache(<String, dynamic>{
      'principalVariationIndex': 3,
      'maxArrowsOnBoard': 2,
    });
    expect(settings.multiPvForStockfish(), 4);
  });
}
