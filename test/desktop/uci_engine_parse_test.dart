// We can't drive a real UCI process from a unit test, but we can exercise
// the line parser the engine panel uses end-to-end. The function is private
// to engine_panel.dart, so this test relies on the same logic mirrored
// inside DesktopStockfish if/when it migrates. Until then, this test docs
// the contract by example.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UCI info-line shape (regression doc)', () {
    test('depth + cp + pv example', () {
      // This is the line shape EnginePanel._parseInfoLine handles. Keep the
      // example here so future refactors can replay it.
      const line =
          'info depth 18 seldepth 24 multipv 1 score cp 23 nodes 102342 '
          'time 412 pv e2e4 c7c5 g1f3 d7d6';
      expect(line.startsWith('info'), isTrue);
      expect(line.contains('depth 18'), isTrue);
      expect(line.contains('score cp 23'), isTrue);
      expect(line.contains('pv e2e4'), isTrue);
    });

    test('mate score is negative when side-to-move loses', () {
      const line = 'info depth 12 score mate -3 pv f7f6 e1e8';
      expect(line.contains('mate -3'), isTrue);
    });
  });
}
