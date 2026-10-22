import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChessGame _game(String fen, String moves) => ChessGame.fromPgn(
  'badge-anchor',
  '[SetUp "1"]\n[FEN "$fen"]\n[Result "*"]\n\n$moves *',
);

const _cases = <
  ({
    String label,
    String fen,
    String moves,
    String uci,
    Square square,
    Role role,
  })
>[
  (
    label: 'white rook e1-a1',
    fen: '1k6/8/8/8/8/8/6K1/4R3 w - - 0 1',
    moves: '1. Ra1',
    uci: 'e1a1',
    square: Square.a1,
    role: Role.rook,
  ),
  (
    label: 'white rook e1-h1',
    fen: '1k6/8/8/8/8/8/6K1/4R3 w - - 0 1',
    moves: '1. Rh1',
    uci: 'e1h1',
    square: Square.h1,
    role: Role.rook,
  ),
  (
    label: 'black rook e8-a8',
    fen: '4r3/6k1/8/8/8/8/8/1K6 b - - 0 1',
    moves: '1... Ra8',
    uci: 'e8a8',
    square: Square.a8,
    role: Role.rook,
  ),
  (
    label: 'black rook e8-h8',
    fen: '4r3/6k1/8/8/8/8/8/1K6 b - - 0 1',
    moves: '1... Rh8',
    uci: 'e8h8',
    square: Square.h8,
    role: Role.rook,
  ),
  (
    label: 'white O-O-O',
    fen: 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
    moves: '1. O-O-O',
    uci: 'e1a1',
    square: Square.c1,
    role: Role.king,
  ),
  (
    label: 'white O-O',
    fen: 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
    moves: '1. O-O',
    uci: 'e1h1',
    square: Square.g1,
    role: Role.king,
  ),
  (
    label: 'black O-O-O',
    fen: 'r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1',
    moves: '1... O-O-O',
    uci: 'e8a8',
    square: Square.c8,
    role: Role.king,
  ),
  (
    label: 'black O-O',
    fen: 'r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1',
    moves: '1... O-O',
    uci: 'e8h8',
    square: Square.g8,
    role: Role.king,
  ),
];

void main() {
  for (final c in _cases) {
    test('${c.label} uses the actual moving piece destination', () {
      final game = _game(c.fen, c.moves);
      final original = game.toJson();
      final position = Chess.fromSetup(Setup.parseFen(c.fen));
      final move = Move.parse(c.uci)! as NormalMove;
      expect(position.isLegal(move), isTrue);
      expect(position.board.pieceAt(move.from)?.role, c.role);
      expect(game.mainline.single.uci, c.uci);
      expect(boardMoveBadgeSquareForTesting(game, [0]), c.square);
      expect(game.toJson(), original);
    });
    for (final flipped in [false, true]) {
      testWidgets(
        '${c.label} renders the real badge at destination flipped=$flipped',
        (tester) async {
          final game = _game(c.fen, c.moves);
          final original = game.toJson();
          const size = 512.0;
          const cell = size / 8;
          const badgeSize = cell * 0.40;
          const contentKey = ValueKey('badge-content');
          const boardKey = ValueKey('board-area');
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  key: boardKey,
                  width: size,
                  height: size,
                  child: Stack(
                    children: [
                      boardMoveBadgeWidgetForTesting(
                        game: game,
                        pointer: [0],
                        boardSize: size,
                        flipped: flipped,
                        child: const SizedBox.expand(key: contentKey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final file = flipped ? 7 - c.square.file : c.square.file;
          final rank = flipped ? c.square.rank : 7 - c.square.rank;
          final x = (file * cell + cell - badgeSize / 2).clamp(
            0.0,
            size - badgeSize,
          );
          final y = (rank * cell - badgeSize / 2 + cell * 0.04).clamp(
            0.0,
            size - badgeSize,
          );
          final board = tester.getRect(find.byKey(boardKey));
          final badge = tester.getRect(
            find
                .ancestor(
                  of: find.byKey(contentKey),
                  matching: find.byType(Container),
                )
                .first,
          );
          expect(badge.left - board.left, closeTo(x, 0.01));
          expect(badge.top - board.top, closeTo(y, 0.01));
          expect(badge.width, closeTo(badgeSize, 0.01));
          expect(badge.height, closeTo(badgeSize, 0.01));
          expect(game.toJson(), original);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  test('initial position has no last-move badge', () {
    final game = _game(_cases.first.fen, '1. Ra1');
    expect(boardMoveBadgeSquareForTesting(game, []), isNull);
  });
  test('variation keeps its own rook landing and does not mutate the game', () {
    final game = _game(_cases.first.fen, '1. Ra1 (1. Rh1)');
    final original = game.toJson();
    expect(boardMoveBadgeSquareForTesting(game, [0]), Square.a1);
    expect(boardMoveBadgeSquareForTesting(game, [0, 0, 0]), Square.h1);
    expect(game.toJson(), original);
  });
  for (final (fen, moves, square) in <(String, String, Square)>[
    ('1k6/8/8/8/8/8/6K1/4Q3 w - - 0 1', '1. Qa1', Square.a1),
    ('4q3/6k1/8/8/8/8/8/1K6 b - - 0 1', '1... Qh8', Square.h8),
    ('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1', '1. Kf1', Square.f1),
    ('r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1', '1... Kd8', Square.d8),
  ]) {
    test('non-castling $moves keeps its real destination', () {
      expect(boardMoveBadgeSquareForTesting(_game(fen, moves), [0]), square);
    });
  }
}
