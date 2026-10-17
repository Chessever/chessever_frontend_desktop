import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/pgn_source_credit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/source_credit_fixture.dart';

void main() {
  test(
    'trimming an inserted variation keeps its credit at the new endpoint only',
    () {
      final game = fixture();
      final before = game.toJson();
      final nav = ChessGameNavigator(game)
        ..goToMovePointerUnchecked(const [0, 0, 1]);
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      final kept = nav.state.game.mainline.first.variations!.single;
      expect(kept.map((m) => m.san), ['c5', 'Nf3']);
      expect(kept.last.comments, contains(directive));
      expect(kept.last.comments!.join(' '), contains('Selected note'));
      expect(kept.last.comments!.join(' '), contains('[%clk 0:12:34]'));
      expect(
        kept.last.comments!.join(' '),
        isNot(contains('Deleted future prose')),
      );
      expect(nav.state.movePointer, [0, 0, 1]);
      expect(nav.state.game.metadata, game.metadata);
      expect(game.toJson(), before);
      final saved = exportGameToPgn(nav.state.game);
      expect(saved, contains(directive));
      final reopened = ChessGame.fromPgn('reopened', saved);
      expect(exportGameToPgn(reopened), contains(directive));
      nav.dispose();
    },
  );

  test(
    'a discarded nested footer is not credited to its parent continuation',
    () {
      final base = fixture(footer: '');
      final branch = List<ChessMove>.of(base.mainline.first.variations!.single);
      final child =
          ChessGame.fromPgn(
            'child',
            '[SetUp "1"]\n[FEN "${branch[1].fen}"]\n\n2... Nc6 {[%src Unrelated child]} *',
          ).mainline;
      branch[2] = branch[2].copyWith(
        variations: [child],
        overrideVariations: true,
      );
      final nav = ChessGameNavigator(withBranch(base, branch));
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(
        sourceCreditDirectives(
          nav.state.game.mainline.first.variations!.single.last.comments,
        ),
        isEmpty,
      );
      nav.dispose();
    },
  );

  test(
    'a nested trim carries only its own source while retaining sibling and parent credits',
    () {
      final base = fixture();
      final branch = List<ChessMove>.of(base.mainline.first.variations!.single);
      final child =
          ChessGame.fromPgn(
            'child',
            '[SetUp "1"]\n[FEN "${base.mainline.first.fen}"]\n\n1... e5 2. Nf3 Nc6 {[%src Nested owner]} *',
          ).mainline;
      branch[0] = branch[0].copyWith(
        variations: [child],
        overrideVariations: true,
      );
      final game = withBranch(base, branch);
      final before = game.toJson();
      final nav = ChessGameNavigator(game);
      nav.deleteContinuationAfterPointer(const [0, 0, 0, 0, 1]);
      final outer = nav.state.game.mainline.first.variations!.single;
      final nested = outer.first.variations!.single;
      expect(nested.map((m) => m.san), ['e5', 'Nf3']);
      expect(sourceCreditDirectives(nested.last.comments), [
        '[%src Nested owner]',
      ]);
      expect(outer.last.comments!.join(' '), contains(directive));
      expect(sourceCreditDirectives(outer[1].comments), isEmpty);
      expect(game.toJson(), before);
      nav.dispose();
    },
  );

  test(
    'an already credited selected endpoint does not borrow a later insertion credit',
    () {
      final base = fixture(footer: '[%src Deleted later owner]');
      final branch = List<ChessMove>.of(base.mainline.first.variations!.single);
      branch[1] = branch[1].copyWith(
        comments: [...?branch[1].comments, directive],
      );
      final nav = ChessGameNavigator(withBranch(base, branch));
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(
        sourceCreditDirectives(
          nav.state.game.mainline.first.variations!.single.last.comments,
        ),
        [directive],
      );
      nav.dispose();
    },
  );

  test('the nearest footer defines ownership, not the last later footer', () {
    final base = fixture();
    final branch = List<ChessMove>.of(base.mainline.first.variations!.single);
    final suffix =
        ChessGame.fromPgn(
          'later',
          '[SetUp "1"]\n[FEN "${branch.last.fen}"]\n\n3. d4 cxd4 {[%src Later owner]} *',
        ).mainline;
    final nav = ChessGameNavigator(withBranch(base, [...branch, ...suffix]));
    nav.deleteContinuationAfterPointer(const [0, 0, 1]);
    expect(
      sourceCreditDirectives(
        nav.state.game.mainline.first.variations!.single.last.comments,
      ),
      [directive],
    );
    nav.dispose();
  });

  test(
    'structured span proof refuses a credit for an entirely deleted later insertion',
    () {
      final nav = ChessGameNavigator(
        fixture(footer: '[%src white=Future|black=Only|plies=1]'),
      );
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(
        sourceCreditDirectives(
          nav.state.game.mainline.first.variations!.single.last.comments,
        ),
        isEmpty,
      );
      nav.dispose();
    },
  );

  test(
    'retained move annotations and child branches survive source transfer and repeated trim',
    () {
      final base = fixture();
      final branch = List<ChessMove>.of(base.mainline.first.variations!.single);
      final child =
          ChessGame.fromPgn(
            'child',
            '[SetUp "1"]\n[FEN "${branch.first.fen}"]\n\n2. Bc4 d6 {Child commentary} *',
          ).mainline;
      branch[1] = branch[1].copyWith(
        nags: [1, 247, 248],
        eval: '0.3',
        clockTime: '0:12:34',
        variations: [child],
        overrideVariations: true,
      );
      final game = withBranch(base, branch);
      final before = game.toJson();
      final nav = ChessGameNavigator(game)
        ..goToMovePointerUnchecked(const [0, 0, 1]);
      final selectedFen = nav.state.currentFen;
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      final selected = nav.state.game.mainline.first.variations!.single.last;
      expect(selected.nags, branch[1].nags);
      expect(selected.eval, branch[1].eval);
      expect(selected.clockTime, branch[1].clockTime);
      expect(
        selected.variations!.single.map((m) => m.toJson()),
        child.map((m) => m.toJson()),
      );
      expect(nav.state.currentFen, selectedFen);
      final trimmed = nav.state.game;
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(nav.state.game.toJson(), trimmed.toJson());
      expect(sourceCreditDirectives(selected.comments), [directive]);
      // Board's existing undo stores the original immutable game snapshot.
      expect(game.toJson(), before);
      final repeated = ChessGameNavigator(game);
      repeated.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(repeated.state.game.toJson(), trimmed.toJson());
      repeated.dispose();
      nav.dispose();
    },
  );

  test(
    'sibling insertion credit and original mainline remain byte-equivalent',
    () {
      final base = fixture();
      final sibling =
          fixture(
            footer: '[%src Sibling owner]',
          ).mainline.first.variations!.single;
      final game = base.copyWith(
        mainline: [
          base.mainline.first.copyWith(
            variations: [base.mainline.first.variations!.single, sibling],
            overrideVariations: true,
          ),
          ...base.mainline.skip(1),
        ],
      );
      final nav = ChessGameNavigator(game);
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      expect(
        nav.state.game.mainline.first.variations![1].map((m) => m.toJson()),
        sibling.map((m) => m.toJson()),
      );
      expect(
        nav.state.game.mainline.skip(1).map((m) => m.toJson()),
        game.mainline.skip(1).map((m) => m.toJson()),
      );
      nav.dispose();
    },
  );

  test(
    'root clearing and unproven mainline tails cannot manufacture source ownership',
    () {
      final base = fixture();
      final mainline = List<ChessMove>.of(base.mainline);
      mainline.last = mainline.last.copyWith(comments: [directive]);
      final nav = ChessGameNavigator(base.copyWith(mainline: mainline));
      nav.deleteContinuationAfterPointer(const [1]);
      expect(
        sourceCreditDirectives(nav.state.game.mainline.last.comments),
        isEmpty,
      );
      nav.deleteContinuationAfterPointer(const []);
      expect(nav.state.game.mainline, isEmpty);
      nav.dispose();
    },
  );
}

ChessGame withBranch(ChessGame base, ChessLine branch) => base.copyWith(
  mainline: [
    base.mainline.first.copyWith(
      variations: [branch],
      overrideVariations: true,
    ),
    ...base.mainline.skip(1),
  ],
);
