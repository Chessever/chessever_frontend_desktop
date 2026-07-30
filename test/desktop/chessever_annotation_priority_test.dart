import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classicGlyphForClassification / nagForClassicGlyph', () {
    test('maps every report class to portable marks', () {
      expect(
        classicGlyphForClassification(GameMoveClassification.brilliant),
        '!!',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.goodMove),
        '!',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.bestMove),
        '!',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.missedWin),
        '??',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.inaccuracy),
        '?!',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.mistake),
        '?',
      );
      expect(
        classicGlyphForClassification(GameMoveClassification.blunder),
        '??',
      );
      expect(nagForClassicGlyph('!!'), 3);
      expect(nagForClassicGlyph('?!'), 6);
      expect(nagForClassicGlyph('??'), 4);
    });
  });

  group('resolveDisplayAnnotationType priority', () {
    test('chessever classic glyph overrides disagreeing quality NAG', () {
      // Mobile sample shape: $1 with [%chessever_annotation !]
      final type = resolveDisplayAnnotationType(
        comments: const ['[%clk 0:29:44]', '[%eval -0.55]', '[%chessever_annotation !]'],
        nags: const [1],
      );
      expect(type, LichessMoveAnnotationType.goodMove);

      // Override case: NAG says blunder ($4) but ChessEver says good (!).
      final overridden = resolveDisplayAnnotationType(
        comments: const ['[%chessever_annotation !]'],
        nags: const [4],
      );
      expect(
        overridden,
        LichessMoveAnnotationType.goodMove,
        reason: 'chessever directive must win over \$4 blunder NAG',
      );

      // Brilliant glyph overrides inaccuracy NAG.
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%chessever_annotation !!]'],
          nags: const [6],
        ),
        LichessMoveAnnotationType.brilliant,
      );
    });

    test('falls back to quality NAG best-effort when directive is missing', () {
      expect(
        resolveDisplayAnnotationType(comments: const [], nags: const [3]),
        LichessMoveAnnotationType.brilliant,
      );
      expect(
        resolveDisplayAnnotationType(comments: null, nags: const [6]),
        LichessMoveAnnotationType.inaccuracy,
      );
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%clk 1:00:00]', '[%eval 0.25]'],
          nags: const [2],
        ),
        LichessMoveAnnotationType.mistake,
      );
      expect(
        resolveDisplayAnnotationType(comments: const [], nags: const [16]),
        isNull,
        reason: 'evaluation NAGs are not quality classifications',
      );
    });

    test('parses legacy product-name directives for backward compatibility', () {
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%chessever_annotation brilliant]'],
          nags: const [1],
        ),
        LichessMoveAnnotationType.brilliant,
      );
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%chessever_annotation good_move]'],
          nags: const [4],
        ),
        LichessMoveAnnotationType.goodMove,
      );
      expect(
        resolveDisplayAnnotationType(
          comments: const ['[%chessever_annotation missed_win]'],
          nags: const [],
        ),
        LichessMoveAnnotationType.missedWin,
      );
    });

    test('loads Granada-style mobile share PGN annotations on mainline', () {
      const sample = r'''
[Event "Granada Chess Open 26"]
[Site "https://chessever.com/games/rWXiru7i"]
[Result "1-0"]

1. e4 { [%clk 1:19:15] } { [%eval 0.29] } 1... c5 { [%clk 1:30:53] } { [%eval 0.35] } 2. Nf3 { [%clk 1:18:05] } { [%eval 0.34] } 2... Nc6 18. Nf3 { [%clk 0:32:00] } { [%eval -0.30] } 18... Bg4 $1 { [%clk 0:29:44] } { [%eval -0.55] } { [%chessever_annotation !] } 19. Qe3 { [%clk 0:28:04] } { [%eval -0.59] } 19... Bxf3 $1 { [%clk 0:27:50] } { [%eval -0.56] } { [%chessever_annotation !] } 27... Rxb3 $6 { [%clk 0:12:40] } { [%eval 0.37] } { [%chessever_annotation ?!] } 31... Rb7 $4 { [%clk 0:04:50] } { [%eval 2.14] } { [%chessever_annotation ??] } 1-0
''';
      // Use a minimal legal game with the annotation shapes from the sample.
      final game = ChessGame.fromPgn(
        'granada-annotations',
        r'1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 $1 { [%clk 0:29:44] } { [%eval -0.55] } { [%chessever_annotation !] } 4. Ba4 Nf6 $4 { [%clk 0:04:50] } { [%eval 2.14] } { [%chessever_annotation ??] } 5. O-O Be7 $6 { [%clk 0:12:40] } { [%eval 0.37] } { [%chessever_annotation ?!] } *',
      );

      final annotations = chesseverAnnotationsFromMainline(game);
      // a6 is mainline index 5 (0-based: e4,e5,Nf3,Nc6,Bb5,a6)
      expect(game.mainline[5].san, 'a6');
      expect(annotations[5]?.type, LichessMoveAnnotationType.goodMove);
      expect(annotations[5]?.useClassificationIcon, isTrue);
      expect(annotations[5]?.reportOwnsMoveQuality, isTrue);

      // Nf6 index 7
      expect(game.mainline[7].san, 'Nf6');
      expect(annotations[7]?.type, LichessMoveAnnotationType.blunder);

      // Be7 index 9
      expect(game.mainline[9].san, 'Be7');
      expect(annotations[9]?.type, LichessMoveAnnotationType.inaccuracy);

      // Priority over NAG when resolving display type for Be7 ($6 vs ?!)
      expect(
        resolveDisplayAnnotationType(
          comments: game.mainline[9].comments,
          nags: game.mainline[9].nags,
        ),
        LichessMoveAnnotationType.inaccuracy,
      );

      // Silence unused sample const warning by referencing shape.
      expect(sample.contains('[%chessever_annotation !]'), isTrue);
    });
  });
}
