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

    test('preserves Gamebase move evaluations as PGN eval comments', () {
      final pgn = buildPgnFromGamebaseData({
        'md': {'Result': '*'},
        'm': [
          {'u': 'e2e4', 'eval': '0.24'},
          {'u': 'e7e5', 'evaluation': -0.12},
          {'u': 'g1f3', 'e': '#3'},
        ],
      });

      expect(pgn, contains('e4 { [%eval 0.24] }'));
      expect(pgn, contains('e5 { [%eval -0.12] }'));
      expect(pgn, contains('Nf3 { [%eval #3] }'));

      final game = ChessGame.fromPgn('gamebase-eval-regression', pgn!);
      expect(game.mainline.map((move) => move.eval), ['0.24', '-0.12', '#3']);
    });

    test('orders PGN headers before player metadata for ChessBase paste', () {
      final pgn = buildPgnFromGamebaseData({
        'md': {
          'Black': 'Radjabov,T',
          'BlackElo': '2689',
          'BlackFideId': '13400924',
          'BlackTitle': 'GM',
          'Date': '2026.05.23',
          'ECO': 'C49',
          'Event': '75th Ann. Karpov 2026',
          'EventDate': '2026.05.21',
          'Opening': 'Four knights',
          'Result': '0-1',
          'Round': '7.3',
          'Site': 'Moscow RUS',
          'White': 'Esipenko,Andrey',
          'WhiteElo': '2684',
          'WhiteFideId': '24175439',
          'WhiteTitle': 'GM',
        },
        'm': [
          {'u': 'e2e4'},
          {'u': 'e7e5'},
        ],
      });

      expect(pgn, isNotNull);
      expect(pgn!.split('\n').take(16).toList(), [
        '[Event "75th Ann. Karpov 2026"]',
        '[Site "Moscow RUS"]',
        '[Date "2026.05.23"]',
        '[Round "7.3"]',
        '[White "Esipenko,Andrey"]',
        '[Black "Radjabov,T"]',
        '[Result "0-1"]',
        '[WhiteElo "2684"]',
        '[BlackElo "2689"]',
        '[WhiteTitle "GM"]',
        '[BlackTitle "GM"]',
        '[WhiteFideId "24175439"]',
        '[BlackFideId "13400924"]',
        '[ECO "C49"]',
        '[Opening "Four knights"]',
        '[EventDate "2026.05.21"]',
      ]);
      expect(pgn, contains('\n\n1. e4 e5 0-1'));
    });
    test('adds Seven Tag Roster defaults when Gamebase metadata is sparse', () {
      final pgn = buildPgnFromGamebaseData({
        'md': {'Result': '*'},
        'm': [
          {'u': 'e2e4'},
          {'u': 'e7e5'},
        ],
      });

      expect(pgn, isNotNull);
      expect(pgn!.split('\n').take(7).toList(), [
        '[Event "?"]',
        '[Site "?"]',
        '[Date "????.??.??"]',
        '[Round "?"]',
        '[White "?"]',
        '[Black "?"]',
        '[Result "*"]',
      ]);
    });
  });
}
