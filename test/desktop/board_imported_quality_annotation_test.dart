import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart'
    hide mergeGameReportAnnotationsForGif;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearing an imported quality NAG preserves prose and unrelated metadata', () {
    final move = ChessMove(
      num: 1,
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      san: 'e4',
      uci: 'e2e4',
      turn: ChessColor.white,
      nags: const <int>[2, 18, 146],
      comments: const <String>[
        'Keep this prose [%c_effect b4;square;b4;type;Mistake;persistent;true] after it.',
        '[%clk 0:01:20][%c_effect c3;square;c3;type;Inaccuracy;persistent;true][%c_effect d4;square;d4;type;Book;persistent;true]',
      ],
    );

    final cleared = clearImportedMoveQualityAnnotation(move);

    expect(cleared.nags, const <int>[18, 146]);
    expect(cleared.comments, const <String>[
      'Keep this prose after it.',
      '[%clk 0:01:20][%c_effect c3;square;c3;type;Inaccuracy;persistent;true][%c_effect d4;square;d4;type;Book;persistent;true]',
    ]);
  });

  test('GIF export merges user evaluation NAGs into the mainline', () {
    final game = ChessGame.fromPgn('gif-nags', r'1. e4 $2 e5 2. Nf3 $10 *');

    final merged = mergeUserMainlineNagsForGif(game, const {
      0: <int>[16],
      1: <int>[4, 18],
    });

    // Evaluation-only user annotation keeps the imported quality annotation.
    expect(merged.mainline[0].nags, const <int>[16, 2]);
    // User quality replaces imported quality, while both evaluations survive.
    expect(merged.mainline[1].nags, const <int>[4, 18]);
    expect(merged.mainline[2].nags, const <int>[10]);
  });

  test(
    'share/GIF PGN is hydrated from a completed report even when source PGN was bare',
    () {
      // Mirrors mobile: once Game Analysis finishes, exported PGN for share/GIF
      // always carries classic-glyph directives from the report.
      final bare = ChessGame.fromPgn('bare-share', r'1. e4 e5 2. Nf3 *');
      final reportMoves = const [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.brilliant,
          evaluation: GameReportLine(
            moves: <String>['e2e4'],
            depth: 18,
            centipawns: 35,
          ),
        ),
        GameReportMove(
          ply: 2,
          san: 'e5',
          uci: 'e7e5',
          isWhite: false,
          classification: GameMoveClassification.mistake,
          evaluation: GameReportLine(
            moves: <String>['e7e5'],
            depth: 18,
            centipawns: -80,
          ),
        ),
        GameReportMove(
          ply: 3,
          san: 'Nf3',
          uci: 'g1f3',
          isWhite: true,
          classification: GameMoveClassification.bestMove,
          evaluation: GameReportLine(
            moves: <String>['g1f3'],
            depth: 18,
            centipawns: 40,
          ),
        ),
      ];

      final pgn = exportGamePgnWithReport(bare, reportMoves);
      expect(pgn, contains('[%chessever_annotation !!]'));
      expect(pgn, contains('[%chessever_annotation ?]'));
      expect(pgn, contains('[%chessever_annotation !]'));
      expect(pgn, contains(RegExp(r'e4\s*\$3|e4!!')));
      expect(pgn, contains(RegExp(r'e5\s*\$2|e5\?')));
      // GIF path is the same merge.
      final gifGame = mergeGameReportAnnotationsForGif(bare, reportMoves);
      expect(
        gifGame.mainline[0].comments,
        contains('[%chessever_annotation !!]'),
      );
    },
  );

  test(
    'GIF/share export uses classic-glyph ChessEver annotations and quality NAGs',
    () {
      final game = ChessGame.fromPgn(
        'gif-evals',
        r'1. e4 {[%eval 0.15]} e5 2. Nf3 *',
      );
      final reportMoves = const [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.brilliant,
          evaluation: GameReportLine(
            moves: <String>['e2e4'],
            depth: 18,
            centipawns: 42,
          ),
        ),
        GameReportMove(
          ply: 2,
          san: 'e5',
          uci: 'e7e5',
          isWhite: false,
          classification: GameMoveClassification.inaccuracy,
          evaluation: GameReportLine(
            moves: <String>['e7e5'],
            depth: 18,
            centipawns: -31,
          ),
        ),
        GameReportMove(
          ply: 3,
          san: 'Nf3',
          uci: 'g1f3',
          isWhite: true,
          classification: GameMoveClassification.missedWin,
          evaluation: GameReportLine(
            moves: <String>['g1f3'],
            depth: 18,
            mate: 3,
          ),
        ),
      ];

      final evaluated = mergeGameReportAnnotationsForGif(game, reportMoves);
      final pgn = exportGamePgnWithReport(game, reportMoves);

      // Report evals replace older/default PGN values (mobile parity).
      expect(evaluated.mainline[0].eval, '0.42');
      expect(evaluated.mainline[1].eval, '-0.31');
      expect(evaluated.mainline[2].eval, '#3');

      // Classic portable glyphs — not product names.
      expect(
        evaluated.mainline[0].comments,
        contains('[%chessever_annotation !!]'),
      );
      expect(
        evaluated.mainline[1].comments,
        contains('[%chessever_annotation ?!]'),
      );
      expect(
        evaluated.mainline[2].comments,
        contains('[%chessever_annotation ??]'),
      );
      expect(evaluated.mainline[0].nags, contains(3)); // !!
      expect(evaluated.mainline[1].nags, contains(6)); // ?!
      expect(evaluated.mainline[2].nags, contains(4)); // ??

      expect(pgn, contains('[%chessever_annotation !!]'));
      expect(pgn, contains('[%chessever_annotation ?!]'));
      expect(pgn, contains('[%chessever_annotation ??]'));
      expect(pgn, isNot(contains('[%chessever_annotation brilliant]')));
      expect(pgn, isNot(contains('[%chessever_annotation good_move]')));
      expect(pgn, isNot(contains('[%chessever_annotation missed_win]')));
      expect(pgn, isNot(contains('[%chessever_annotation inaccuracy]')));
      expect(pgn, contains(RegExp(r'e4\s*\$3|e4!!')));
      expect(pgn, contains(RegExp(r'e5\s*\$6|e5\?!')));
    },
  );
}
