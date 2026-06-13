import 'package:chessever/desktop/widgets/engine_pv_arrow_palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine PV arrows get progressively quieter by rank', () {
    for (var i = 1; i < enginePvArrowRankScales.length; i++) {
      expect(
        enginePvArrowRankScales[i],
        lessThan(enginePvArrowRankScales[i - 1]),
      );
      expect(
        enginePvArrowRankAlphas[i],
        lessThan(enginePvArrowRankAlphas[i - 1]),
      );
    }
  });

  test('engine PV arrow helpers clamp negative and overflow ranks', () {
    expect(enginePvArrowScale(-1), enginePvArrowRankScales.first);
    expect(enginePvArrowScale(99), enginePvArrowRankScales.last);

    expect(
      enginePvArrowColor(-1).a,
      closeTo(enginePvArrowRankAlphas.first, 0.001),
    );
    expect(
      enginePvArrowColor(99).a,
      closeTo(enginePvArrowRankAlphas.last, 0.001),
    );
  });

  test('engine PV arrow colors preserve established palette order', () {
    for (var i = 0; i < enginePvArrowPalette.length; i++) {
      final ranked = enginePvArrowColor(i);
      final base = enginePvArrowPalette[i];

      expect(ranked.r, base.r);
      expect(ranked.g, base.g);
      expect(ranked.b, base.b);
      expect(ranked.a, closeTo(enginePvArrowRankAlphas[i], 0.001));
    }
  });
}
