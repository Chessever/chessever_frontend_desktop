import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/engine/legal_root_moves.dart';

void main() {
  test('root count matches Stockfish perft: initial', () {
    expect(
      legalStockfishRootMoveCount(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      ),
      20,
    );
  });
  test('root count matches Stockfish perft: two_replies', () {
    expect(legalStockfishRootMoveCount('k7/8/8/8/8/8/7r/6K1 w - - 0 1'), 2);
  });
  test('root count matches Stockfish perft: castling', () {
    expect(
      legalStockfishRootMoveCount('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1'),
      26,
    );
  });
  test('root count matches Stockfish perft: promotion', () {
    expect(legalStockfishRootMoveCount('7k/P7/8/8/8/8/8/7K w - - 0 1'), 7);
  });
  test('root count matches Stockfish perft: black_promotion', () {
    expect(legalStockfishRootMoveCount('7k/8/8/8/8/8/p7/7K b - - 0 1'), 7);
  });
  test('root count matches Stockfish perft: capture_promotion', () {
    expect(legalStockfishRootMoveCount('1r5k/P7/8/8/8/8/8/7K w - - 0 1'), 11);
  });
  test('root count matches Stockfish perft: en_passant', () {
    expect(legalStockfishRootMoveCount('7k/8/8/3pP3/8/8/8/7K w - d6 0 1'), 5);
  });
  test('root count matches Stockfish perft: checkmate', () {
    expect(legalStockfishRootMoveCount('8/8/8/8/8/2k5/1q6/K7 w - - 0 1'), 0);
  });
  test('root count matches Stockfish perft: stalemate', () {
    expect(legalStockfishRootMoveCount('8/8/8/8/8/1qk5/8/K7 w - - 0 1'), 0);
  });
}
