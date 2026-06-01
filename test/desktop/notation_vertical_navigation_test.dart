import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_pointer.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds notation rows in the same order as the ladder view', () {
    final game = _gameWithBlackVariation();

    final rows = notationNavigationRows(
      game,
    ).map((row) => row.entries.map((entry) => entry.pointer).toList()).toList();

    expect(rows, [
      [
        [0],
        [1],
      ],
      [
        [0, 0, 0],
      ],
      [
        [2],
        [3],
      ],
    ]);
  });

  test('moves up and down through visible line anchors', () {
    final game = _gameWithBlackVariation();

    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [0],
        direction: NotationVerticalDirection.down,
      ),
      [0, 0, 0],
    );
    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [0, 0, 0],
        direction: NotationVerticalDirection.up,
      ),
      [0],
    );
    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [0, 0, 0],
        direction: NotationVerticalDirection.down,
      ),
      isNull,
    );
  });

  test('keeps ladder mode on closest visual row columns', () {
    final game = _gameWithBlackVariation();

    expect(
      notationLadderVerticalPointer(
        game: game,
        activePointer: const [1],
        direction: NotationVerticalDirection.down,
      ),
      [0, 0, 0],
    );
    expect(
      notationLadderVerticalPointer(
        game: game,
        activePointer: const [0, 0, 0],
        direction: NotationVerticalDirection.up,
      ),
      [1],
    );
    expect(
      notationLadderVerticalPointer(
        game: game,
        activePointer: const [0, 0, 0],
        direction: NotationVerticalDirection.down,
      ),
      [3],
    );
  });

  test(
    'walks expanded inline variations depth-first by visible line anchors',
    () {
      final game = _referenceStyleGame();

      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [8], // 5.c4 at the end of the mainline row.
          direction: NotationVerticalDirection.down,
        ),
        [8, 0, 0], // 5.a3 variation head.
      );
      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [8, 0, 0],
          direction: NotationVerticalDirection.down,
        ),
        [9], // 5...Nf6 continuation after the 5.c4 variation block.
      );
      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [9],
          direction: NotationVerticalDirection.down,
        ),
        [9, 0, 0], // 7.Be3 expanded variation head.
      );
      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [9, 0, 0],
          direction: NotationVerticalDirection.down,
        ),
        [9, 0, 8, 0, 0], // 11.Rfd1 nested visible variation head.
      );
      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [9, 0, 8, 0, 0],
          direction: NotationVerticalDirection.down,
        ),
        [9, 0, 9], // 11...e5 after the nested variation block.
      );
      expect(
        notationVerticalPointer(
          game: game,
          activePointer: const [9, 0, 9],
          direction: NotationVerticalDirection.up,
        ),
        [9, 0, 8, 0, 0],
      );
    },
  );

  test('folded variations expose only their visible heads', () {
    final game = _referenceStyleGame();
    final collapsed = <String>{
      NotationPointer.encode(const [8, 0, 0]),
      NotationPointer.encode(const [9, 0, 0]),
      NotationPointer.encode(const [9, 1, 0]),
      NotationPointer.encode(const [11, 0, 0]),
    };

    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [8],
        direction: NotationVerticalDirection.down,
        collapsedIds: collapsed,
      ),
      [8, 0, 0],
    );
    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [8, 0, 0],
        direction: NotationVerticalDirection.down,
        collapsedIds: collapsed,
      ),
      [9],
    );
    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [9],
        direction: NotationVerticalDirection.down,
        collapsedIds: collapsed,
      ),
      [9, 0, 0],
    );
    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [9, 0, 0],
        direction: NotationVerticalDirection.down,
        collapsedIds: collapsed,
      ),
      [9, 1, 0],
    );
  });

  test('down from the starting position lands on the first visible move', () {
    final game = _gameWithBlackVariation();

    expect(
      notationVerticalPointer(
        game: game,
        activePointer: const [],
        direction: NotationVerticalDirection.down,
      ),
      [0],
    );
  });

  test('rendered inline order moves to nearest mainline move on adjacent rows', () {
    final order = renderedNotationVerticalMoveOrder(
      activePointer: const [3],
      positions: const [
        RenderedNotationMovePosition(pointer: [0], centerX: 10, centerY: 10),
        RenderedNotationMovePosition(pointer: [1], centerX: 60, centerY: 10),
        RenderedNotationMovePosition(pointer: [2], centerX: 12, centerY: 30),
        RenderedNotationMovePosition(pointer: [3], centerX: 62, centerY: 30),
        RenderedNotationMovePosition(pointer: [4], centerX: 14, centerY: 50),
        RenderedNotationMovePosition(pointer: [5], centerX: 58, centerY: 50),
      ],
    );

    expect(order, [
      [1],
      [3],
      [5],
    ]);
    expect(
      notationVerticalPointerInOrder(
        order: order,
        activePointer: const [3],
        direction: NotationVerticalDirection.down,
      ),
      [5],
    );
  });

  test('rendered inline order can step from mainline to variation row', () {
    final order = renderedNotationVerticalMoveOrder(
      activePointer: const [3],
      positions: const [
        RenderedNotationMovePosition(pointer: [0], centerX: 10, centerY: 10),
        RenderedNotationMovePosition(pointer: [1], centerX: 45, centerY: 10),
        RenderedNotationMovePosition(pointer: [2], centerX: 80, centerY: 10),
        RenderedNotationMovePosition(pointer: [3], centerX: 116, centerY: 10),
        RenderedNotationMovePosition(
          pointer: [3, 0, 0],
          centerX: 16,
          centerY: 32,
        ),
        RenderedNotationMovePosition(pointer: [4], centerX: 12, centerY: 52),
      ],
    );

    expect(order, [
      [3],
      [3, 0, 0],
    ]);
    expect(
      notationVerticalPointerInOrder(
        order: order,
        activePointer: const [3],
        direction: NotationVerticalDirection.down,
      ),
      [3, 0, 0],
    );
  });

}

ChessGame _gameWithBlackVariation() {
  return ChessGame(
    gameId: 'black-var',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: [
      _move(
        'e4',
        turn: ChessColor.white,
        variations: [
          [_move('c5', turn: ChessColor.black)],
        ],
      ),
      _move('e5', turn: ChessColor.black),
      _move('Nf3', turn: ChessColor.white),
      _move('Nc6', turn: ChessColor.black),
    ],
  );
}

ChessGame _referenceStyleGame() {
  return ChessGame(
    gameId: 'reference-arrow-order',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: [
      _move('e4', turn: ChessColor.white),
      _move('c5', turn: ChessColor.black),
      _move('Nf3', turn: ChessColor.white),
      _move('e6', turn: ChessColor.black),
      _move('d4', turn: ChessColor.white),
      _move('cxd4', turn: ChessColor.black),
      _move('Nxd4', turn: ChessColor.white),
      _move('a6', turn: ChessColor.black),
      _move(
        'c4',
        turn: ChessColor.white,
        variations: [
          [
            _move('a3', turn: ChessColor.white),
            _move('Qc7', turn: ChessColor.black),
            _move('Bd3', turn: ChessColor.white),
            _move('Nf6', turn: ChessColor.black),
          ],
        ],
      ),
      _move(
        'Nf6',
        turn: ChessColor.black,
        variations: [
          [
            _move('Be3', turn: ChessColor.white),
            _move('Bb4', turn: ChessColor.black),
            _move('Qb3', turn: ChessColor.white),
            _move('Bc5', turn: ChessColor.black),
            _move('Be2', turn: ChessColor.white),
            _move('d6', turn: ChessColor.black),
            _move('O-O', turn: ChessColor.white),
            _move('O-O', turn: ChessColor.black),
            _move(
              'Rad1',
              turn: ChessColor.white,
              variations: [
                [
                  _move('Rfd1', turn: ChessColor.white),
                  _move('Nc6', turn: ChessColor.black),
                ],
              ],
            ),
            _move('e5', turn: ChessColor.black),
          ],
          [
            _move('a3', turn: ChessColor.white),
            _move('b6', turn: ChessColor.black),
          ],
        ],
      ),
      _move('Nc3', turn: ChessColor.white),
      _move(
        'b6',
        turn: ChessColor.black,
        variations: [
          [_move('Nc6', turn: ChessColor.black)],
        ],
      ),
    ],
  );
}

ChessMove _move(
  String san, {
  ChessColor turn = ChessColor.white,
  List<ChessLine>? variations,
}) {
  return ChessMove(
    num: 1,
    fen: 'fen',
    san: san,
    uci: san,
    turn: turn,
    variations: variations,
  );
}
