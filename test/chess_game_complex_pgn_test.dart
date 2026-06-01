import 'package:chessever/desktop/state/pgn_intake.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses nested PGN sublines with comments, NAGs, clocks, evals', () {
    const pgn = '''
[Event "Complex"]
[Site "Test"]
[Result "*"]

1. e4 \$1 {Main comment [%clk 0:09:59] [%eval 0.25] [%cal Ge2e4] [%csl Ye4]}
1... e5 \$2 {Reply comment}
  (1... c5 \$5 {Sicilian} 2. Nf3 2... Nc6 (2... d6 {Najdorf}))
2. Nf3 2... Nc6 (2... Nf6 {Petrov}) *
''';

    final game = ChessGame.fromPgn('complex', pgn);

    expect(game.mainline.map((m) => m.san), ['e4', 'e5', 'Nf3', 'Nc6']);

    final e4 = game.mainline.first;
    expect(e4.nags, contains(1));
    expect(e4.clockTime, '0:09:59');
    expect(e4.eval, '0.25');
    expect(e4.comments?.join(' '), contains('Main comment'));
    expect(e4.comments?.join(' '), contains('[%cal Ge2e4]'));
    expect(e4.comments?.join(' '), contains('[%csl Ye4]'));

    final sicilian = e4.variations!.single;
    expect(sicilian.map((m) => m.san), ['c5', 'Nf3', 'Nc6']);
    expect(sicilian.first.nags, contains(5));
    expect(sicilian.first.comments?.join(' '), contains('Sicilian'));
    expect(sicilian[1].variations!.single.map((m) => m.san), ['d6']);

    final e5 = game.mainline[1];
    expect(e5.nags, contains(2));
    expect(e5.comments?.join(' '), contains('Reply comment'));

    final nf3 = game.mainline[2];
    expect(nf3.variations!.single.map((m) => m.san), ['Nf6']);
    expect(
      nf3.variations!.single.first.comments?.join(' '),
      contains('Petrov'),
    );
  });

  test('PGN imports carry an optional game id for live merge scoping', () {
    const detached = PgnImport(path: 'file.pgn', pgn: '1. e4 *');
    const live = PgnImport(path: 'Round 1', pgn: '1. e4 *', gameId: 'g1');

    expect(detached.gameId, isNull);
    expect(live.gameId, 'g1');
  });
}
