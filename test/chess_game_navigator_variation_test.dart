import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

ChessMove move(String san, {List<ChessLine>? variations}) {
  return ChessMove(
    num: 1,
    fen: 'fen',
    san: san,
    uci: san,
    turn: ChessColor.white,
    variations: variations,
  );
}

void main() {
  test('makeOrGoToMove numbers white alternatives from the next move', () {
    final game = ChessGame.fromPgn(
      'inline-numbering-white',
      '1. Nf3 Nf6 2. c4 c6 3. Nc3 d5 4. d4 g6 5. cxd5 cxd5 '
          '6. Bf4 Nc6 7. h3 Bg7 8. e3 O-O 9. Bd3 Bf5 10. O-O Bxd3 '
          '11. Qxd3 Rc8',
    );
    final navigator = ChessGameNavigator(game)
      ..goToMovePointerUnchecked(const [19]); // after 10...Bxd3

    navigator.makeOrGoToMove('d1e2'); // 11.Qe2, alternative to 11.Qxd3

    final variations = navigator.state.game.mainline[19].variations;
    expect(variations, isNotNull);
    expect(variations!.single.single.san, 'Qe2');
    expect(variations.single.single.num, 11);
    expect(variations.single.single.turn, ChessColor.white);
    expect(navigator.state.movePointer, equals(<int>[19, 0, 0]));
  });

  test('makeOrGoToMove numbers black alternatives with ellipsis context', () {
    final game = ChessGame.fromPgn(
      'inline-numbering-black',
      '1. Nf3 Nf6 2. c4 c6 3. Nc3 d5 4. d4 g6 5. cxd5 cxd5 '
          '6. Bf4 Nc6 7. h3 Bg7 8. e3 O-O 9. Bd3 Bf5 10. O-O Bxd3 '
          '11. Qxd3 Rc8',
    );
    final navigator = ChessGameNavigator(game)
      ..goToMovePointerUnchecked(const [20]); // after 11.Qxd3

    navigator.makeOrGoToMove('e7e5'); // 11...e5, alternative to 11...Rc8

    final variations = navigator.state.game.mainline[20].variations;
    expect(variations, isNotNull);
    expect(variations!.single.single.san, 'e5');
    expect(variations.single.single.num, 11);
    expect(variations.single.single.turn, ChessColor.black);
    expect(navigator.state.movePointer, equals(<int>[20, 0, 0]));
  });

  test('deleteVariationAtPointer removes variation branch', () {
    final variation = [move('Nf3')];
    final game = ChessGame(
      gameId: 'g1',
      startingFen: 'fen',
      metadata: const {},
      mainline: [
        move('e4', variations: [variation]),
      ],
    );
    final navigator = ChessGameNavigator(game);

    expect(navigator.state.game.mainline[0].variations?.length, 1);

    navigator.deleteVariationAtPointer([0, 0, 0]);

    expect(navigator.state.game.mainline[0].variations, isNull);
  });

  test('deleteContinuationAfterPointer clears all moves at root', () {
    final game = ChessGame(
      gameId: 'g1',
      startingFen: 'fen',
      metadata: const {},
      mainline: [move('e4'), move('e5')],
    );
    final navigator = ChessGameNavigator(game);

    navigator.goToTail();
    expect(navigator.state.movePointer, equals(<int>[1]));

    navigator.deleteContinuationAfterPointer(const []);

    expect(navigator.state.game.mainline, isEmpty);
    expect(navigator.state.movePointer, isEmpty);
  });

  test(
    'promoteVariationToMainline preserves other variations and mainline continuation',
    () {
      final promotedLine = [
        move(
          'c5',
          variations: [
            [move('d4')],
          ],
        ),
        move('Nc3'),
      ];
      final otherVariation = [move('d4')];

      final game = ChessGame(
        gameId: 'g1',
        startingFen: 'fen',
        metadata: const {},
        mainline: [
          move('e4', variations: [promotedLine, otherVariation]),
          move('e5'),
          move('Nf3'),
        ],
      );
      final navigator = ChessGameNavigator(game);

      navigator.promoteVariationToMainline([0, 0, 0]);

      final updated = navigator.state.game.mainline;
      expect(updated.map((m) => m.san), ['e4', 'c5', 'Nc3']);

      final e4 = updated[0];
      expect(e4.variations, isNotNull);
      // Should have 3 variations:
      // 0: old mainline [e5, Nf3]
      // 1: otherVariation [d4]
      expect(e4.variations!.length, 2);
      expect(e4.variations![0].map((m) => m.san), ['e5', 'Nf3']);
      expect(e4.variations![1].map((m) => m.san), ['d4']);

      final c5 = updated[1];
      expect(c5.variations, isNotNull);
      expect(c5.variations!.first.map((m) => m.san), ['d4']);

      expect(navigator.state.movePointer, equals(<int>[1]));
    },
  );

  test(
    'promoteVariationToMainline promotes nested variations one level and preserves siblings',
    () {
      final deepVariation = [move('d4')];
      final siblingVariation = [move('a6')];
      final firstVariation = [
        move('c5', variations: [deepVariation, siblingVariation]),
        move('Nc6'),
      ];
      final game = ChessGame(
        gameId: 'g1',
        startingFen: 'fen',
        metadata: const {},
        mainline: [
          move('e4', variations: [firstVariation]),
        ],
      );
      final navigator = ChessGameNavigator(game);

      // Promote 'd4' (variation index 0 of move 'c5' in firstVariation)
      navigator.promoteVariationToMainline([0, 0, 0, 0, 0]);

      final e4 = navigator.state.game.mainline.first;
      expect(e4.variations, isNotNull);
      final firstVar = e4.variations!.first;

      // firstVar (the promoted one) should now be e4 -> c5 -> d4
      expect(firstVar.map((m) => m.san), ['c5', 'd4']);

      final c5 = firstVar[0];
      expect(c5.variations, isNotNull);
      // c5 should have 2 variations:
      // 0: old continuation [Nc6]
      // 1: sibling variation [a6]
      expect(c5.variations!.length, 2);
      expect(c5.variations![0].map((m) => m.san), ['Nc6']);
      expect(c5.variations![1].map((m) => m.san), ['a6']);

      expect(navigator.state.movePointer, equals(<int>[0, 0, 1]));
    },
  );
}
