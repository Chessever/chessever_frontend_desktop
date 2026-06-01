import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildPgnFromGamebaseData', () {
    test('preserves Gamebase move clocks as PGN clock comments', () {
      final pgn = buildPgnFromGamebaseData({
        'md': {
          'White': 'Aravindh, Chithambaram VR.',
          'Black': 'Robson, Ray',
          'Result': '*',
        },
        'm': [
          {'u': 'e2e4', 'ct': '1:30:33'},
          {'u': 'e7e5', 'ct': '1:30:19'},
          {'u': 'g1f3', 'ct': '1:30:46'},
        ],
      });

      expect(pgn, isNotNull);
      expect(pgn, contains('1. e4 { [%clk 1:30:33] }'));
      expect(pgn, contains('e5 { [%clk 1:30:19] }'));
      expect(pgn, contains('2. Nf3 { [%clk 1:30:46] }'));

      final game = ChessGame.fromPgn('gamebase-clock-regression', pgn!);
      expect(game.mainline.map((move) => move.clockTime), [
        '1:30:33',
        '1:30:19',
        '1:30:46',
      ]);
    });
  });
}
