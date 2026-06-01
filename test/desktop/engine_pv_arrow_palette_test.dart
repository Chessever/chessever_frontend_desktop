import 'package:chessever/desktop/widgets/engine_pv_arrow_palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine PV arrow palette gives the first lines distinct colours', () {
    final colors = List.generate(5, enginePvArrowColor);

    expect(colors.toSet(), hasLength(5));
  });

  test('engine PV arrow palette cycles after the configured max lines', () {
    expect(enginePvArrowColor(5), enginePvArrowColor(0));
    expect(enginePvArrowColor(-1), enginePvArrowColor(0));
  });
}
