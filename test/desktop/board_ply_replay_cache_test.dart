import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

// The board build replays the active line on every rebuild and reuses recent
// replays for a shared prefix of identical moves. Whatever it reuses must
// match a replay from scratch.
void main() {
  final game = ChessGame.fromPgn(
    'ply-replay-cache',
    '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *',
  );

  List<(String, List<String>)> fresh(ChessGame g, List<int> pointer) {
    clearBoardPlyReplaysForTesting();
    return boardPlyReplayForTesting(g, pointer);
  }

  setUp(clearBoardPlyReplaysForTesting);

  test('stepping forward and back matches a fresh replay', () {
    for (final pointer in [
      [5],
      [2],
      [3],
      [5],
      [0],
      [4],
    ]) {
      final cached = boardPlyReplayForTesting(game, pointer);
      expect(cached, hasLength(pointer.first + 2));
      final expected = fresh(game, pointer);
      expect(cached, expected, reason: 'pointer $pointer');
    }
  });

  test('an edited move replays again instead of reusing the old ply', () {
    expect(boardPlyReplayForTesting(game, [5]).last.$2, isEmpty);

    final mainline = [...game.mainline];
    mainline[3] = mainline[3].copyWith(comments: ['knight development']);
    final edited = game.copyWith(mainline: mainline);

    final replay = boardPlyReplayForTesting(edited, [5]);
    expect(replay[4].$2, ['knight development']);
    expect(replay, fresh(edited, [5]));
  });

  test('a different game with the same start does not reuse moves', () {
    final other = ChessGame.fromPgn(
      'ply-replay-cache-other',
      '[Result "*"]\n\n1. d4 d5 2. c4 *',
    );
    boardPlyReplayForTesting(game, [5]);
    expect(boardPlyReplayForTesting(other, [2]), fresh(other, [2]));
  });
}
