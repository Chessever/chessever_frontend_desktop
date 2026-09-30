import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:dartchess/dartchess.dart';

void main() {
  const pgn =
      '[Result "*"]\n\n{Root introduction} 1. e4 {After e4} ( {Before d4} 1. d4 {After d4} d5 ) e5 *';
  test('comments retain semantic positions through edits and session JSON', () {
    final imported = ChessGame.fromPgn('test', pgn);
    final edited = imported.copyWith(
      mainline: [
        imported.mainline.first.copyWith(comments: ['Edited after e4']),
        ...imported.mainline.skip(1),
      ],
    );
    final restored = ChessGame.fromJson(edited.toJson());
    final parsed = PgnGame.parsePgn(exportGameToPgn(restored));
    expect(parsed.comments, ['Root introduction']);
    expect(parsed.moves.children.first.data.comments, ['Edited after e4']);
    expect(parsed.moves.children[1].data.startingComments, ['Before d4']);
    expect(parsed.moves.children[1].data.comments, ['After d4']);
  });
  test('moveless guiding text survives save', () {
    final game = ChessGame.fromPgn('guide', '[Result "*"]\n\n{Guiding text} *');
    expect(
      PgnGame.parsePgn(
        exportGameToPgn(ChessGame.fromJson(game.copyWith().toJson())),
      ).comments,
      ['Guiding text'],
    );
  });
  for (final mode in NotationLayoutMode.values) {
    testWidgets('root and variation preface visible in $mode', (tester) async {
      final layout = ValueNotifier(mode);
      addTearDown(layout.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotationLadderView(
              game: ChessGame.fromPgn('test', pgn),
              activePointer: const [],
              onJump: (_) {},
              layoutModeController: layout,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Root introduction', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('Before d4', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('moveless guiding text visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotationLadderView(
            game: ChessGame.fromPgn(
              'guide',
              '[Result "*"]\n\n{Guiding text} *',
            ),
            activePointer: const [],
            onJump: (_) {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Guiding text', findRichText: true),
      findsWidgets,
    );
  });
}
