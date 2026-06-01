import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exportGameToPgn preserves variation branches', () {
    final game = _sampleGame();

    final pgn = exportGameToPgn(game);

    expect(pgn, contains('( 1... c5 )'));
    expect(pgn, contains('1. e4 e5 ( 1... c5 ) 2. Nf3 Nc6'));
  });
}

ChessGame _sampleGame() {
  final e4 = Chess.initial.play(NormalMove.fromUci('e2e4'));
  final e5 = e4.play(NormalMove.fromUci('e7e5'));
  final nf3 = e5.play(NormalMove.fromUci('g1f3'));
  final nc6 = nf3.play(NormalMove.fromUci('b8c6'));
  final c5 = e4.play(NormalMove.fromUci('c7c5'));

  return ChessGame(
    gameId: 'notation-export-test',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: [
      ChessMove(
        num: 1,
        fen: e4.fen,
        san: 'e4',
        uci: 'e2e4',
        turn: ChessColor.white,
        variations: [
          [
            ChessMove(
              num: 1,
              fen: c5.fen,
              san: 'c5',
              uci: 'c7c5',
              turn: ChessColor.black,
            ),
          ],
        ],
      ),
      ChessMove(
        num: 1,
        fen: e5.fen,
        san: 'e5',
        uci: 'e7e5',
        turn: ChessColor.black,
      ),
      ChessMove(
        num: 2,
        fen: nf3.fen,
        san: 'Nf3',
        uci: 'g1f3',
        turn: ChessColor.white,
      ),
      ChessMove(
        num: 2,
        fen: nc6.fen,
        san: 'Nc6',
        uci: 'b8c6',
        turn: ChessColor.black,
      ),
    ],
  );
}
