import 'package:chessever/desktop/utils/pgn_analysis_effect_commentary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strips Chess.com effect directives while preserving prose', () {
    expect(
      stripAnalysisEffectDirectivesFromComments(const [
        '[%c_effect e7;square;e7;type;Mistake;persistent;true]',
        '[%c_effect e4;square;e4;type;Mistake;persistent;true] I should not move the knight there.',
        'Human explanation stays.',
      ]),
      const ['I should not move the knight there.', 'Human explanation stays.'],
    );
  });
}
