import 'package:chessever/desktop/services/board_cut_previous_moves.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChessGame _game() => ChessGame.fromPgn('original', '''
[Event "Study"]
[Result "1-0"]

1. e4 e5 (1... c5 2. Nf3 \$5 {Keep this [%clk 0:04:00] [%cal Gg1f3]} (2. Nc3 Nc6) d6) 2. Nf3 Nc6 1-0
''');

void main() {
  test('mainline cut retains original black move number and game ending', () {
    final source = _game().rememberGameEndingPlyIndex(2);
    final before = exportGameToPgn(source);
    final cut = cutBoardPreviousMoves(source, const [1])!;
    final reopened = ChessGame.fromPgn('', exportGameToPgn(cut));

    expect(cut.startingFen, source.mainline.first.fen);
    expect(reopened.mainline.map((m) => m.san), ['e5', 'Nf3', 'Nc6']);
    expect(cut.gameEndingPlyIndex, 1);
    expect(cut.metadata['SetUp'], '1');
    expect(cut.metadata['Result'], '1-0');
    expect(reopened.mainline.first.num, 1);
    expect(reopened.mainline.first.turn, ChessColor.black);
    expect(reopened.mainline.first.variations!.single.first.san, 'c5');
    expect(exportGameToPgn(source), before);
  });

  test('no-op for root, first mainline move, or invalid pointers', () {
    final source = _game();
    for (final pointer in <List<int>>[
      [],
      [0],
      [4],
      [-1],
      [1, 0],
      [1, 3, 0],
      [0, 0, 3],
    ]) {
      expect(
        canCutBoardPreviousMoves(source, pointer),
        isFalse,
        reason: '$pointer',
      );
      expect(
        cutBoardPreviousMoves(source, pointer),
        isNull,
        reason: '$pointer',
      );
    }
  });

  test('cutting before the last move retains it as a one-move game', () {
    final source = _game();
    final cut = cutBoardPreviousMoves(source, const [3])!;
    final reopened = ChessGame.fromPgn('', exportGameToPgn(cut));
    expect(reopened.startingFen, source.mainline[2].fen);
    expect(reopened.mainline.single.san, 'Nc6');
    expect(reopened.mainline.single.fen, source.mainline[3].fen);
  });

  for (final mode in NotationLayoutMode.values) {
    testWidgets(
      '${mode.name} menu cuts from the clicked variation, not the selected move',
      (tester) async {
        final source = _game();
        final layout = ValueNotifier(mode);
        addTearDown(layout.dispose);
        final working = ValueNotifier<ChessGame>(source);
        addTearDown(working.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: working,
                builder:
                    (context, game, _) => NotationLadderView(
                      game: game,
                      activePointer:
                          identical(game, source) ? const [2] : const [],
                      onJump: (_) {},
                      layoutModeController: layout,
                      onCutPreviousMoves:
                          (pointer) =>
                              working.value =
                                  cutBoardPreviousMoves(game, pointer)!,
                    ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tapAt(
          tester.getCenter(find.text('c5', findRichText: true)),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete Previous Moves'));
        await tester.pumpAndSettle();

        final retained = working.value;
        final anchor = source.mainline.first.variations!.single.first;
        final reopened = ChessGame.fromPgn('', exportGameToPgn(retained));
        expect(retained.startingFen, source.mainline.first.fen);
        expect(reopened.startingFen, source.mainline.first.fen);
        expect(reopened.metadata['Result'], '*');
        expect(reopened.mainline.map((move) => move.san), ['c5', 'Nf3', 'd6']);
        expect(reopened.mainline.first.fen, anchor.fen);
        final first = reopened.mainline[1];
        expect(first.num, 2);
        expect(first.nags, contains(5));
        expect(
          first.comments!.join(),
          allOf(
            contains('Keep this'),
            contains('[%clk 0:04:00]'),
            contains('[%cal Gg1f3]'),
          ),
        );
        final alternatives = [
          for (final move in reopened.mainline) ...?move.variations,
        ];
        expect(alternatives.single.map((move) => move.san), ['Nc3', 'Nc6']);
      },
    );
  }
}
