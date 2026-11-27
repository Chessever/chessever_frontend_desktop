import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn = '''
[Event "Study"]
[Result "*"]

{Intro is not before-move text} 1. {Before White} e4 {After White}
1... {Before Black} {Second before Black} e5 \$1 {After Black}
(1... {Variation plan} c5 {After c5} 2. {Develop here} Nf3) 2.Nf3 Nc6 *
''';

void main() {
  test('Shift+A is the before-move shortcut on every platform', () {
    final chords = defaultBoardShortcuts()[BoardActionKey.commentBeforeMove]!;
    expect(chords, [
      KeyChord(keyId: LogicalKeyboardKey.keyA.keyId, shift: true),
    ]);
  });

  test(
    'native and external PGN preserve numbered before and after placement',
    () {
      void check(ChessGame game) {
        final first = game.mainline[0];
        final second = game.mainline[1];
        expect(game.rootComments, ['Intro is not before-move text']);
        expect(first.startingComments, ['Before White']);
        expect(first.comments, ['After White']);
        expect(second.startingComments, [
          'Before Black',
          'Second before Black',
        ]);
        expect(second.comments, ['After Black']);
        expect(second.nags, [1]);
        final variation = first.variations!.single;
        expect(variation.first.startingComments, ['Variation plan']);
        expect(variation.first.comments, ['After c5']);
        expect(variation.last.startingComments, ['Develop here']);
      }

      final game = ChessGame.fromPgn('', _pgn);
      check(game);
      final native = exportGameToPgn(game);
      final external = toExternalCompatiblePgn(native);
      for (final pgn in [native, external]) {
        expect(pgn, isNot(contains('CE-before:')));
        expect(
          pgn,
          isNot(matches(RegExp(r'\{ Second before Black \}\s*1\.\.\.'))),
        );
        check(ChessGame.fromPgn('', pgn));
      }
    },
  );

  for (final mode in NotationLayoutMode.values) {
    testWidgets(
      '${mode.name} shows both remark positions and targets the clicked move',
      (tester) async {
        final layout = ValueNotifier(mode);
        addTearDown(layout.dispose);
        final calls = <(List<int>, bool)>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotationLadderView(
                game: ChessGame.fromPgn('', _pgn),
                activePointer: const [0],
                onJump: (_) {},
                layoutModeController: layout,
                onEditPositionedComment:
                    (pointer, before) async => calls.add((pointer, before)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final black = find.text('e5', findRichText: true);
        final before = find.textContaining('Before Black', findRichText: true);
        final after = find.textContaining('After Black', findRichText: true);
        expect(before, findsWidgets);
        expect(after, findsOneWidget);
        if (mode == NotationLayoutMode.ladder) {
          expect(
            tester.getTopLeft(before.first).dy,
            lessThan(tester.getTopLeft(black).dy),
          );
          expect(
            tester.getTopLeft(after).dy,
            greaterThan(tester.getTopLeft(black).dy),
          );
        }
        for (final label in ['Comment before move', 'Comment after move']) {
          await tester.tapAt(
            tester.getCenter(black),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          expect(find.text('Comment before move'), findsOneWidget);
          expect(find.text('Comment after move'), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
        }
        expect(calls.map((call) => call.$1), [
          [1],
          [1],
        ]);
        expect(calls.map((call) => call.$2), [true, false]);
      },
    );
  }
}
