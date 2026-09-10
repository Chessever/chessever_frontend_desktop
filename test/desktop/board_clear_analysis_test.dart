import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clear analysis keeps the raw mainline and removes PGN annotations', () {
    final annotated = ChessGame.fromPgn(
      'annotated',
      r'1. e4 $1 {A comment} (1. d4 d5) e5 *',
    );

    expect(gameHasClearableAnalysis(annotated), isTrue);

    final cleared = clearGameAnalysis(annotated);

    expect(cleared.mainline.map((move) => move.san), <String>['e4', 'e5']);
    expect(gameHasClearableAnalysis(cleared), isFalse);
    expect(cleared.mainline.first.comments, isEmpty);
    expect(cleared.mainline.first.nags, isEmpty);
    expect(cleared.mainline.first.variations, isNull);
  });

  test('machine annotations are removed instead of reappearing on export', () {
    final annotated = ChessGame.fromPgn(
      'machine-tags',
      '1. e4 {[%eval 0.35] [%clk 0:09:42]} e5 *',
    );

    expect(annotated.mainline.first.eval, isNotNull);
    expect(annotated.mainline.first.clockTime, isNotNull);
    expect(gameHasClearableAnalysis(annotated), isTrue);

    final cleared = clearGameAnalysis(annotated);

    expect(cleared.mainline.first.eval, isNull);
    expect(cleared.mainline.first.clockTime, isNull);
    expect(gameHasClearableAnalysis(cleared), isFalse);
  });

  test('detached root analysis is visible and cleared after a takeback', () {
    final detachedLine =
        ChessGame.fromPgn('detached-line', '1. d4 d5 *').mainline;
    final game = ChessGame.fromPgn('root', '*').copyWith(
      detachedRootAnalysis: <ChessLine>[detachedLine],
      overrideDetachedRootAnalysis: true,
    );

    expect(gameHasClearableAnalysis(game), isTrue);

    final cleared = clearGameAnalysis(game);

    expect(cleared.detachedRootAnalysis, isNull);
    expect(gameHasClearableAnalysis(cleared), isFalse);
  });

  for (final caseData in <({String name, String pgn})>[
    (name: 'comments', pgn: '1. e4 {A comment} e5 *'),
    (name: 'NAGs', pgn: r'1. e4 $1 e5 *'),
    (name: 'variations', pgn: '1. e4 (1. d4 d5) e5 *'),
  ]) {
    test('${caseData.name} make analysis clearable', () {
      final game = ChessGame.fromPgn(caseData.name, caseData.pgn);

      expect(gameHasClearableAnalysis(game), isTrue);
    });
  }

  test('report-only analysis keeps Clear analysis available', () {
    final clean = ChessGame.fromPgn('report-only', '1. e4 e5 *');

    expect(
      shouldOfferClearAnalysis(
        game: clean,
        hasShapes: false,
        hasUserNags: false,
        hasGameReport: true,
      ),
      isTrue,
    );
  });

  test('clean raw mainline does not expose clear analysis', () {
    final clean = ChessGame.fromPgn('clean', '1. e4 e5 2. Nf3 Nc6 *');

    expect(gameHasClearableAnalysis(clean), isFalse);
    expect(
      shouldOfferClearAnalysis(
        game: clean,
        hasShapes: false,
        hasUserNags: false,
        hasGameReport: false,
      ),
      isFalse,
    );
    expect(clearGameAnalysis(clean), same(clean));
  });
}
