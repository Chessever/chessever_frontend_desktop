import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';

void main() {
  test('Son NAGs have documented visible symbols and meanings', () {
    for (final code in [8, 11, 30, 142, 143, 144, 145]) {
      expect(getNagDisplay(code), isNotNull, reason: 'NAG $code');
    }
  });
  test('unknown NAG remains visible without inventing its meaning', () {
    expect(getNagDisplay(200)?.symbol, r'$200');
    expect(getNagDisplay(0), isNull);
  });
  test('ChessEver private report and override codes stay hidden', () {
    for (final code in [240, 241, 242, 243, 244, 245, 246, 247, 248]) {
      expect(getNagDisplay(code), isNull, reason: 'NAG $code');
    }
  });
}
