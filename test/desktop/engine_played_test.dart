import 'package:chessever/desktop/services/engine/engine_played.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('played frequency uses all recorded continuations', () {
    const played = EnginePlayed({'e2e4': 390, 'e1g1': 15, 'c2c4': 1}, 2000);
    expect(played.labelFor('e2e4'), '19.5%');
    expect(played.labelFor('e1h1', isCastling: true), '0.8%');
    expect(played.labelFor('e1h1'), '0.0%');
    expect(played.labelFor('c2c4'), '<0.1%');
    expect(played.labelFor('d2d4'), '0.0%');
    expect(const EnginePlayed({}, 0).labelFor('d2d4'), isNull);
  });
}
