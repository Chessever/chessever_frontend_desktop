import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart'
    hide mergeGameReportAnnotationsForGif;
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearing an imported quality NAG preserves prose and unrelated metadata', () {
    final move = ChessMove(
      num: 1,
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      san: 'e4',
      uci: 'e2e4',
      turn: ChessColor.white,
      nags: const <int>[2, 18, 146, 248],
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
    expect(merged.mainline[1].nags, const <int>[4, 18, 248]);
    expect(merged.mainline[2].nags, const <int>[10]);
  });

  test(
    'user quality override survives report PGN round-trip without stale metadata',
    () {
      final source = ChessGame.fromPgn(
        'report-override',
        r'1. e4 $2 $16 {Keep this prose.} e5 *',
      );
      final withReport = mergeGameReportAnnotationsForGif(source, const [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.inaccuracy,
          evaluation: GameReportLine(
            moves: <String>['e2e4'],
            depth: 18,
            centipawns: 35,
          ),
        ),
      ]);

      final overridden = mergeUserMainlineNagsForGif(withReport, const {
        0: <int>[4],
      });

      expect(overridden.mainline[0].nags, const <int>[4, 16, 248]);
      expect(overridden.mainline[0].eval, '0.35');
      expect(overridden.mainline[0].comments, const <String>[
        'Keep this prose.',
      ]);

      final replacedOverride = mergeUserMainlineNagsForGif(overridden, const {
        0: <int>[2],
      });
      expect(replacedOverride.mainline[0].nags, const <int>[2, 16, 248]);

      final pgn = exportGameToPgn(overridden);
      expect(pgn, isNot(contains(r'$244')));
      expect(pgn, contains(r'$248'));
      final reopened = ChessGame.fromPgn('reopened-report-override', pgn);
      expect(reopened.mainline[0].nags, const <int>[4, 16, 248]);
      expect(chesseverAnnotationsFromMainline(reopened), isEmpty);
      expect(reopened.mainline[0].eval, '0.35');
      expect(reopened.mainline[0].comments, contains('Keep this prose.'));

      final rerun = mergeGameReportAnnotationsForGif(reopened, const [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.inaccuracy,
          evaluation: GameReportLine(
            moves: <String>['e2e4'],
            depth: 20,
            centipawns: 40,
          ),
        ),
      ]);
      expect(rerun.mainline[0].nags, const <int>[4, 16, 248]);
      expect(rerun.mainline[0].eval, '0.40');
      expect(rerun.mainline[0].comments, contains('Keep this prose.'));
    },
  );

  test(
    'share/GIF PGN is hydrated with standard + ChessEver classification NAGs',
    () {
      // Cloudflare maps the classification code 1:1 onto badge PNGs.
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
      // Standard quality NAG + ChessEver classification code, no directive.
      expect(pgn, isNot(contains('chessever_annotation')));
      expect(pgn, contains(RegExp(r'e4 \$3 \$240\b')));
      expect(pgn, contains(RegExp(r'e5 \$2 \$245\b')));
      expect(pgn, contains(RegExp(r'Nf3 \$1 \$242\b')));
      // GIF path is the same merge.
      final gifGame = mergeGameReportAnnotationsForGif(bare, reportMoves);
      expect(gifGame.mainline[0].nags, [3, 240]);
      expect(gifGame.mainline[0].comments ?? const <String>[], isEmpty);
    },
  );

  test('classification NAG block matches mobile and round-trips', () {
    // The block is a cross-app wire format: these numbers must not drift from
    // mobile's `game_share_utils.dart` or a synced game opens with the wrong
    // badges.
    expect(kChesseverClassificationNags, {
      GameMoveClassification.brilliant: 240,
      GameMoveClassification.goodMove: 241,
      GameMoveClassification.bestMove: 242,
      GameMoveClassification.missedWin: 243,
      GameMoveClassification.inaccuracy: 244,
      GameMoveClassification.mistake: 245,
      GameMoveClassification.blunder: 246,
      GameMoveClassification.bookMove: 247,
    });
    for (final entry in kChesseverClassificationNags.entries) {
      expect(classificationForChesseverNag(entry.value), entry.key);
      expect(isChesseverClassificationNag(entry.value), isTrue);
      expect(classificationFromNags([16, entry.value]), entry.key);
    }
    expect(classificationFromNags(const [1, 2, 3, 4, 5, 6]), isNull);
  });

  test('a PGN from mobile reads back 1:1 on desktop', () {
    // Exactly what mobile writes for brilliant / inaccuracy / missed win /
    // book — the middle two share `??` and `!` with other classes, and book
    // has no standard glyph at all, so only the block can tell them apart.
    final synced = ChessGame.fromPgn(
      'from-mobile',
      r'1. e4 $3 $240 e5 $6 $244 2. Nf3 $4 $243 Nc6 $247 *',
    );

    final annotations = chesseverAnnotationsFromMainline(synced);
    expect(annotations[0]?.type, LichessMoveAnnotationType.brilliant);
    expect(annotations[1]?.type, LichessMoveAnnotationType.inaccuracy);
    expect(annotations[2]?.type, LichessMoveAnnotationType.missedWin);
    expect(annotations[3]?.type, LichessMoveAnnotationType.bookMove);
    for (final annotation in annotations.values) {
      expect(annotation.useClassificationIcon, isTrue);
      expect(annotation.reportOwnsMoveQuality, isTrue);
    }
    // The block outranks whatever the standard glyph alone would have said.
    expect(
      resolveDisplayAnnotationType(comments: null, nags: const [4, 243]),
      LichessMoveAnnotationType.missedWin,
    );
    expect(
      resolveDisplayAnnotationType(comments: null, nags: const [1, 242]),
      LichessMoveAnnotationType.bestMove,
    );
    // A foreign PGN with no block still gets the best-effort read.
    expect(
      resolveDisplayAnnotationType(comments: null, nags: const [4]),
      LichessMoveAnnotationType.blunder,
    );
  });

  test('legacy directive still resolves, and a re-export drops it', () {
    final legacy = ChessGame.fromPgn(
      'legacy',
      '1. e4 {[%chessever_annotation best_move]} '
          'e5 {Sharp [%chessever_annotation blunder]} *',
    );
    expect(
      chesseverAnnotationsFromMainline(legacy)[0]?.type,
      LichessMoveAnnotationType.bestMove,
    );

    final reExported = exportGamePgnWithReport(legacy, const [
      GameReportMove(
        ply: 1,
        san: 'e4',
        uci: 'e2e4',
        isWhite: true,
        classification: GameMoveClassification.bestMove,
        evaluation: GameReportLine(moves: <String>['e2e4'], depth: 18),
      ),
      GameReportMove(
        ply: 2,
        san: 'e5',
        uci: 'e7e5',
        isWhite: false,
        classification: GameMoveClassification.blunder,
        evaluation: GameReportLine(moves: <String>['e7e5'], depth: 18),
      ),
    ]);
    expect(reExported, isNot(contains('chessever_annotation')));
    expect(reExported, contains(RegExp(r'e4 \$1 \$242\b')));
    expect(reExported, contains(RegExp(r'e5 \$4 \$246\b')));
    // Prose beside the directive survives the strip.
    expect(reExported, contains('Sharp'));
  });

  test(
    'GIF/share export uses report evals plus the classification NAG pair',
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

      expect(evaluated.mainline[0].eval, '0.42');
      expect(evaluated.mainline[1].eval, '-0.31');
      expect(evaluated.mainline[2].eval, '#3');

      // Standard quality NAG first, ChessEver classification code beside it.
      expect(evaluated.mainline[0].nags, [3, 240]); // !! brilliant
      expect(evaluated.mainline[1].nags, [6, 244]); // ?! inaccuracy
      expect(evaluated.mainline[2].nags, [4, 243]); // ?? missed win
      // No classification directive is written; the PGN's eval comes from the
      // report's own value, not the stale `[%eval 0.15]` the game arrived with.
      expect(
        evaluated.mainline[0].comments ?? const <String>[],
        isNot(contains(contains('chessever_annotation'))),
      );
      expect(pgn, contains('[%eval 0.42]'));
      expect(pgn, isNot(contains('[%eval 0.15]')));

      expect(pgn, isNot(contains('chessever_annotation')));
      expect(pgn, contains(RegExp(r'e4 \$3 \$240\b')));
      expect(pgn, contains(RegExp(r'e5 \$6 \$244\b')));
      expect(pgn, contains(RegExp(r'Nf3 \$4 \$243\b')));
    },
  );
}
