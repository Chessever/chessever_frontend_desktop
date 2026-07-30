import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cleanPgnCommentText / cleanPgnComments', () {
    test('strips Granada-shaped machine tags including chessever_annotation', () {
      final cleaned = cleanPgnComments(const [
        '[%clk 0:29:44]',
        '[%eval -0.55]',
        '[%chessever_annotation !]',
      ]);
      expect(cleaned, isEmpty);

      expect(
        cleanPgnCommentText('[%chessever_annotation ??]'),
        isEmpty,
      );
      expect(
        cleanPgnCommentText('[%chessever_annotation ?!]'),
        isEmpty,
      );
      expect(
        cleanPgnCommentText('[%clk 1:00:00] [%eval 0.25] [%chessever_annotation !!]'),
        isEmpty,
      );
    });

    test('keeps real prose and drops only the machine tags mixed with it', () {
      expect(
        cleanPgnCommentText(
          'Nice idea [%chessever_annotation !] [%clk 0:10:00]',
        ),
        'Nice idea',
      );
      expect(
        cleanPgnComments(const [
          'Keep this prose [%chessever_annotation ??]',
          '[%eval 1.2]',
          'Second line',
        ]),
        ['Keep this prose', 'Second line'],
      );
    });

    test('strips bare chessever_annotation residue without brackets', () {
      // Safety net if a parser/display path leaves residual text.
      expect(cleanPgnCommentText('chessever_annotation !'), isEmpty);
      expect(cleanPgnCommentText('chessever_annotation ??'), isEmpty);
      expect(
        cleanPgnCommentText('Prose chessever_annotation ?! leftover'),
        'Prose leftover',
      );
    });

    test('firstPgnComment returns null when only machine tags remain', () {
      expect(
        firstPgnComment(const [
          '[%clk 0:04:50]',
          '[%eval 2.14]',
          '[%chessever_annotation ??]',
        ]),
        isNull,
      );
      expect(
        firstPgnComment(const [
          '[%chessever_annotation !]',
          'Human note after tags',
        ]),
        'Human note after tags',
      );
    });
  });

  group('parse still reads raw comments (strip is display-only)', () {
    test('Granada-shaped comments resolve classification types', () {
      expect(
        resolveDisplayAnnotationType(
          comments: const [
            '[%clk 0:29:44]',
            '[%eval -0.55]',
            '[%chessever_annotation !]',
          ],
          nags: const [1],
        ),
        LichessMoveAnnotationType.goodMove,
      );
      expect(
        resolveDisplayAnnotationType(
          comments: const [
            '[%clk 0:12:40]',
            '[%eval 0.37]',
            '[%chessever_annotation ?!]',
          ],
          nags: const [6],
        ),
        LichessMoveAnnotationType.inaccuracy,
      );
      expect(
        resolveDisplayAnnotationType(
          comments: const [
            '[%clk 0:04:50]',
            '[%eval 2.14]',
            '[%chessever_annotation ??]',
          ],
          nags: const [4],
        ),
        LichessMoveAnnotationType.blunder,
      );
    });

    test('directive overrides disagreeing quality NAG', () {
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%chessever_annotation !]'],
          nags: const [4], // blunder NAG
        ),
        LichessMoveAnnotationType.goodMove,
      );
    });

    test('fromPgn stores raw directive; clean hides it; parse still sees it', () {
      final game = ChessGame.fromPgn(
        'granada-comment-strip',
        r'1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 $1 { [%clk 0:29:44] } { [%eval -0.55] } { [%chessever_annotation !] } 4. Ba4 Nf6 $4 { [%clk 0:04:50] } { [%eval 2.14] } { [%chessever_annotation ??] } *',
      );

      // a6
      expect(game.mainline[5].san, 'a6');
      final a6Comments = game.mainline[5].comments ?? const <String>[];
      expect(
        a6Comments.any((c) => c.contains('chessever_annotation')),
        isTrue,
        reason: 'raw comments must retain the directive for parse/badge wiring',
      );
      expect(
        cleanPgnComments(a6Comments),
        isEmpty,
        reason: 'display cleaner must drop tags-only comments',
      );
      expect(
        parseChesseverAnnotationType(a6Comments),
        LichessMoveAnnotationType.goodMove,
      );
      expect(
        chesseverAnnotationsFromMainline(game)[5]?.type,
        LichessMoveAnnotationType.goodMove,
      );

      // Nf6
      expect(game.mainline[7].san, 'Nf6');
      final nf6Comments = game.mainline[7].comments ?? const <String>[];
      expect(cleanPgnComments(nf6Comments), isEmpty);
      expect(
        parseChesseverAnnotationType(nf6Comments),
        LichessMoveAnnotationType.blunder,
      );
    });
  });
}
