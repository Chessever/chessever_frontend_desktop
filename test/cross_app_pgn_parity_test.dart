import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Copy on mobile, paste on desktop: the two apps must render the same game the
/// same way, move for move.
///
/// [kCrossAppParityPgn] and the expectations below are duplicated verbatim in
/// `chessever-frontend/test/cross_app_pgn_parity_test.dart`. Both suites assert
/// the same fixture resolves to the same classification, clock, eval and glyph
/// on every ply, so a change to either app's reader shows up as a failing test
/// in that app rather than as a discrepancy a user has to notice.
///
/// If you change what we write, change the fixture in BOTH repos in the same
/// commit.
const kCrossAppParityPgn = '''
[Event "Senior DM50+"]
[Site "https://chessever.com/games/ghAKkSCe"]
[Date "2026.07.31"]
[Round "7.2"]
[White "Rewitz, Poul"]
[Black "Nielsen, Frode Benedikt"]
[Result "1-0"]
[TimeControl "40/5400+30:1800+30"]

1. b3 \$6 \$244 { [%eval -0.32] [%clk 1:30:53] } 1... d6 \$247 { [%eval 0.16] [%clk 1:29:21] } 2. Bb2 \$1 \$242 { [%eval 0.14] [%clk 1:31:04] } 2... c6 \$3 \$240 { [%eval 0.25] [%clk 1:29:34] } 3. f4 \$4 \$243 { [%eval -0.16] [%clk 1:28:36] } 3... Nf6 \$2 \$245 { [%eval -0.13] [%clk 1:29:10] } 4. e3 \$4 \$246 { A real comment. } { [%eval -0.25] [%clk 1:27:12] } 1-0
''';

/// Classification each ply must resolve to, on both apps.
const kCrossAppParityClassifications = <int, GameMoveClassification>{
  0: GameMoveClassification.inaccuracy,
  1: GameMoveClassification.bookMove,
  2: GameMoveClassification.bestMove,
  3: GameMoveClassification.brilliant,
  4: GameMoveClassification.missedWin,
  5: GameMoveClassification.mistake,
  6: GameMoveClassification.blunder,
};

const kCrossAppParityClocks = <String>[
  '1:30:53',
  '1:29:21',
  '1:31:04',
  '1:29:34',
  '1:28:36',
  '1:29:10',
  '1:27:12',
];

const kCrossAppParityEvals = <String>[
  '-0.32',
  '0.16',
  '0.14',
  '0.25',
  '-0.16',
  '-0.13',
  '-0.25',
];

GameMoveClassification _classificationFor(LichessMoveAnnotationType type) =>
    switch (type) {
      LichessMoveAnnotationType.brilliant => GameMoveClassification.brilliant,
      LichessMoveAnnotationType.goodMove => GameMoveClassification.goodMove,
      LichessMoveAnnotationType.bestMove => GameMoveClassification.bestMove,
      LichessMoveAnnotationType.missedWin => GameMoveClassification.missedWin,
      LichessMoveAnnotationType.inaccuracy => GameMoveClassification.inaccuracy,
      LichessMoveAnnotationType.mistake => GameMoveClassification.mistake,
      LichessMoveAnnotationType.blunder => GameMoveClassification.blunder,
      LichessMoveAnnotationType.bookMove => GameMoveClassification.bookMove,
      LichessMoveAnnotationType.forced =>
        throw StateError('forced is not a report classification'),
    };

/// Plain broadcast PGN with clocks and no annotations — the input both apps
/// hydrate when a report finishes.
const kCrossAppExportSourcePgn = '''
[Event "Senior DM50+"]
[Site "https://chessever.com/games/ghAKkSCe"]
[Date "2026.07.31"]
[Round "7.2"]
[White "Rewitz, Poul"]
[Black "Nielsen, Frode Benedikt"]
[Result "1-0"]
[TimeControl "40/5400+30:1800+30"]

1. b3 { [%clk 1:30:53] } 1... d6 { [%clk 1:29:21] } 2. Bb2 { [%clk 1:31:04] } 2... c6 { [%clk 1:29:34] } 3. f4 { [%clk 1:28:36] } 3... Nf6 { [%clk 1:29:10] } 4. e3 { [%clk 1:27:12] } 1-0
''';

/// Centipawns and classification per ply, in report order. Both apps build
/// their own report object from this and must export the same bytes.
const kCrossAppExportPlies = <(int, GameMoveClassification)>[
  (-32, GameMoveClassification.inaccuracy),
  (16, GameMoveClassification.bookMove),
  (14, GameMoveClassification.bestMove),
  (25, GameMoveClassification.brilliant),
  (-16, GameMoveClassification.missedWin),
  (-13, GameMoveClassification.mistake),
  (-25, GameMoveClassification.blunder),
];

/// The exact PGN both apps must produce from the two constants above.
///
/// Byte equality is the point: it makes desktop→mobile parity as strong as
/// mobile→desktop, because neither app can change what it writes without this
/// failing in its own suite.
const kCrossAppCanonicalExport = '''
[Event "Senior DM50+"]
[Site "https://chessever.com/games/ghAKkSCe"]
[Date "2026.07.31"]
[Round "7.2"]
[White "Rewitz, Poul"]
[Black "Nielsen, Frode Benedikt"]
[Result "1-0"]
[TimeControl "40/5400+30:1800+30"]

1. b3 \$6 \$244 { [%eval -0.32] [%clk 1:30:53] } 1... d6 \$247 { [%eval 0.16] [%clk 1:29:21] } 2. Bb2 \$1 \$242 { [%eval 0.14] [%clk 1:31:04] } 2... c6 \$3 \$240 { [%eval 0.25] [%clk 1:29:34] } 3. f4 \$4 \$243 { [%eval -0.16] [%clk 1:28:36] } 3... Nf6 \$2 \$245 { [%eval -0.13] [%clk 1:29:10] } 4. e3 \$4 \$246 { [%eval -0.25] [%clk 1:27:12] } 1-0''';

void main() {
  final game = ChessGame.fromPgn('parity', kCrossAppParityPgn);

  test('every ply resolves to the same classification badge', () {
    final annotations = chesseverAnnotationsFromMainline(game);
    expect(
      <int, GameMoveClassification>{
        for (final entry in annotations.entries)
          entry.key: _classificationFor(entry.value.type),
      },
      kCrossAppParityClassifications,
    );
    for (final annotation in annotations.values) {
      expect(annotation.useClassificationIcon, isTrue);
      expect(annotation.reportOwnsMoveQuality, isTrue);
    }
  });

  test('clocks and evals survive the shared comment format', () {
    for (var ply = 0; ply < kCrossAppParityClocks.length; ply++) {
      expect(
        game.mainline[ply].clockTime,
        kCrossAppParityClocks[ply],
        reason: 'clock on ply $ply',
      );
      expect(
        game.mainline[ply].eval,
        kCrossAppParityEvals[ply],
        reason: 'eval on ply $ply',
      );
    }
  });

  test('prose survives beside the machine tags', () {
    expect(
      cleanPgnComments(game.mainline[6].comments),
      contains('A real comment.'),
    );
  });

  test('the badge speaks for the verdict — no duplicate glyph, no raw code', () {
    // Both apps hide the standard NAG behind the classification badge and never
    // render the $240–$247 codes. If either changed, the same move would show a
    // chip on one app and a `!!` on the other.
    final annotations = chesseverAnnotationsFromMainline(game);
    for (var ply = 0; ply < kCrossAppParityClassifications.length; ply++) {
      final resolved = resolveBoardMoveAssessment(
        isOnMainline: true,
        userNags: const <int>[],
        pgnNags: game.mainline[ply].nags ?? const <int>[],
        moveAnnotation: annotations[ply],
      );
      expect(
        resolved.annotation?.useClassificationIcon,
        isTrue,
        reason: 'ply $ply must render as a badge only',
      );
      expect(resolved.glyph, isNull, reason: 'ply $ply must not draw a glyph');
    }
  });

  test('exports the same bytes the mobile app exports', () {
    final source = ChessGame.fromPgn('export-parity', kCrossAppExportSourcePgn);
    final reportMoves = <GameReportMove>[
      for (var i = 0; i < kCrossAppExportPlies.length; i++)
        GameReportMove(
          ply: i + 1,
          san: source.mainline[i].san,
          uci: source.mainline[i].uci,
          isWhite: i.isEven,
          classification: kCrossAppExportPlies[i].$2,
          evaluation: GameReportLine(
            moves: <String>[source.mainline[i].uci],
            depth: 18,
            centipawns: kCrossAppExportPlies[i].$1,
          ),
        ),
    ];

    expect(
      exportGamePgnWithReport(source, reportMoves).trim(),
      kCrossAppCanonicalExport.trim(),
    );
  });

  test('what we export is what both apps read back', () {
    // Closes the loop: the canonical bytes above re-read to the same
    // classifications the fixture asserts, so a game copied either direction
    // renders the same.
    final reopened = ChessGame.fromPgn('roundtrip', kCrossAppCanonicalExport);
    final annotations = chesseverAnnotationsFromMainline(reopened);
    expect(
      <int, GameMoveClassification>{
        for (final entry in annotations.entries)
          entry.key: _classificationFor(entry.value.type),
      },
      kCrossAppParityClassifications,
    );
    for (var ply = 0; ply < kCrossAppParityClocks.length; ply++) {
      expect(reopened.mainline[ply].clockTime, kCrossAppParityClocks[ply]);
      expect(reopened.mainline[ply].eval, kCrossAppParityEvals[ply]);
    }
  });

  // NOT asserted here: a ply where the reader has ALSO applied their own
  // quality NAG. Mobile shows the reader's mark, desktop shows the report's
  // badge — both deliberate, both covered by their own suites. That is local
  // state, not something a pasted PGN carries, so it cannot make the same
  // pasted game look different on the two apps.
}
