import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:chessever/screens/chessboard/utils/pgn_source_credit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/source_credit_fixture.dart' as sample;

void main() {
  test(
    'compatible copy turns a source marker into readable PGN prose without changing native data',
    () {
      final nav = ChessGameNavigator(sample.fixture());
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      final before = nav.state.game.toJson();
      final native = exportGameToPgn(nav.state.game);
      final external = toExternalCompatiblePgn(native);
      expect(external, isNot(contains('[%src')));
      expect(external, contains(sample.credit));
      expect(external, contains('Selected note'));
      expect(external, contains('[%clk 0:12:34]'));
      final reopened = ChessGame.fromPgn('external', external);
      expect(
        reopened.mainline.map((m) => m.uci),
        nav.state.game.mainline.map((m) => m.uci),
      );
      expect(
        reopened.mainline.first.variations!.single.map((m) => m.uci),
        nav.state.game.mainline.first.variations!.single.map((m) => m.uci),
      );
      expect(
        reopened.mainline.first.variations!.single.last.comments!.join(' '),
        contains(sample.credit),
      );
      expect(nav.state.game.toJson(), before);
      expect(exportGameToPgn(nav.state.game), native);
      nav.dispose();
    },
  );

  test(
    'structured credits are decoded without leaking field names or dropping other annotations',
    () {
      const native =
          '[Event "Original"]\n[Annotator "Human"]\n[X_Keep "opaque"]\n[Result "*"]\n\n'
          '1. e4 \$1 \$247 \$248 {Before [%src white=Brkić,A|whiteTitle=GM|whiteElo=2642|black=Valderrama,Q|blackElo=2390|result=1-0|plies=3|event=Olymp 2026 Open|site=Baku|round=4|year=2026] After [%clk 0:12:34] [%eval 0.3] [%csl Ge4] [%unknown keep]} '
          'e5 (1... c5 {Nested [%src Child reference] prose} 2. Nf3) *';
      final external = toExternalCompatiblePgn(native);
      expect(external, isNot(contains('[%src')));
      expect(external, isNot(contains('white=')));
      expect(external, contains('GM Brkić,A (2642) – Valderrama,Q (2390)'));
      expect(external, contains('Olymp 2026 Open · Baku · R4 · 2026'));
      expect(external, contains('1–0 (3)'));
      for (final text in [
        'Before',
        'After',
        '[%clk 0:12:34]',
        '[%eval 0.3]',
        '[%csl Ge4]',
        '[%unknown keep]',
        '[Event "Original"]',
        '[Annotator "Human"]',
        '[X_Keep "opaque"]',
        'Nested Child reference prose',
      ]) {
        expect(external, contains(text));
      }
      final original = ChessGame.fromPgn('native', native);
      final copied = ChessGame.fromPgn('foreign', external);
      expect(
        copied.mainline.map((m) => m.uci),
        original.mainline.map((m) => m.uci),
      );
      final copiedBranch =
          copied.mainline.expand((m) => m.variations ?? <ChessLine>[]).single;
      final originalBranch =
          original.mainline.expand((m) => m.variations ?? <ChessLine>[]).single;
      expect(copiedBranch.map((m) => m.uci), originalBranch.map((m) => m.uci));
      expect(copied.mainline.first.nags, containsAll([1, 247]));
      expect(original.mainline.first.comments!.join(' '), contains('[%src'));
      expect(toExternalCompatiblePgn(external), external);
    },
  );

  test(
    'multiple legacy directives become readable credits without altering unrelated literal syntax',
    () {
      const comment =
          '{My human note [%src Legacy, Name – Opponent 2026] tail [%src Other credit] [%srcx untouched]}';
      expect(
        externalSourceCreditComment(comment),
        '{My human note Legacy, Name – Opponent 2026 tail Other credit [%srcx untouched]}',
      );
      expect(sourceCreditText('Human event a=b'), 'Human event a=b');
      expect(sourceCreditText('white=?|black=?|result=*'), isEmpty);
      expect(
        externalSourceCreditComment('{Plain human note [%eval -0.2]}'),
        '{Plain human note [%eval -0.2]}',
      );
    },
  );
}
