import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _referenceSan(String fen, List<String> moves) {
  Position cursor = Chess.fromSetup(Setup.parseFen(fen));
  final parts = fen.split(' ');
  var fullMove = int.parse(parts[5]);
  var whiteToMove = parts[1] == 'w';
  final labels = <String>[];
  for (final uci in moves) {
    final move = Move.parse(uci)!;
    if (!cursor.isLegal(move)) break;
    final san = cursor.makeSan(move).$2;
    labels.add(
      whiteToMove
          ? '$fullMove.$san'
          : labels.isEmpty
          ? '$fullMove…$san'
          : san,
    );
    cursor = cursor.playUnchecked(move);
    if (!whiteToMove) fullMove += 1;
    whiteToMove = !whiteToMove;
  }
  return labels;
}

void main() {
  const blackToMove =
      'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';
  const afterBb5 =
      'r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3';

  List<String> format(String fen, List<String> moves) =>
      formatEnginePvSanLine({'fen': fen, 'moves': moves.join(' ')});

  test('a line that shares a prefix with a cached line matches a replay', () {
    final first = ['f1b5', 'a7a6', 'b5a4', 'g8f6', 'e1g1'];
    final second = ['f1b5', 'a7a6', 'b5c6', 'd7c6', 'e1g1', 'f7f6'];
    expect(format(blackToMove, first), _referenceSan(blackToMove, first));
    expect(format(blackToMove, second), _referenceSan(blackToMove, second));
    // Shorter than the cached line, then longer again.
    expect(
      format(blackToMove, second.take(2).toList()),
      _referenceSan(blackToMove, second.take(2).toList()),
    );
    expect(format(blackToMove, second), _referenceSan(blackToMove, second));
  });

  test('black to move keeps the ellipsis label on the first ply', () {
    final line = ['a7a6', 'b5a4', 'g8f6'];
    expect(format(afterBb5, line), ['3…a6', '4.Ba4', 'Nf6']);
    expect(format(afterBb5, [...line, 'e1g1']), [
      '3…a6',
      '4.Ba4',
      'Nf6',
      '5.O-O',
    ]);
  });

  test('an illegal tail stops the line at the last legal move', () {
    final line = ['f1b5', 'a7a6', 'e2e4'];
    expect(format(blackToMove, line), ['3.Bb5', 'a6']);
    expect(format(blackToMove, line), ['3.Bb5', 'a6']);
  });
}
