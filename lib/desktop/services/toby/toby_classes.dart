/// The Game Report's move classes on Toby's predicted moves: each candidate
/// is judged as if it were played from the board's position, by the report's
/// own rules and constants ([classifyReportMoveEvidence],
/// [applyBookMoveOverride]), with Toby's outcomes standing in for Stockfish's
/// evaluations.
///
/// - White's win% (0..100) is `(white + draw / 2) * 100` of a [TobyWdl].
/// - "Before" is the reading's [TobyReading.positionWdl]; a candidate's
///   "after" is its own outcome.
/// - The lines the report compares a move against (its MultiPV) are every
///   move the payload sent with an outcome ([TobyReading.outcomes]), best
///   first for the side to move; the best of them is "the engine's move".
/// - Book is the report's override, fed by the opening tree's game count for
///   the move (the explorer aggregates the engine pane's "played" column
///   reads, `enginePlayedProvider`).
///
/// What Toby cannot supply, and so never fires: rules that need the previous
/// move's class (Missed Win after the opponent's blunder, Great for punishing
/// an error, the critical-punishment Brilliant) and Brilliant's two checks
/// that need engine lines (multi-ply persistence of the sacrifice, and the
/// win already established before the opponent's move). Every other
/// Brilliant gate, the sacrifice test on the real board included, applies.
///
/// The quick network stage carries no outcomes, so it has no class; Book can
/// still show.
///
/// Two copies, one rule: web `src/broadcast/lib/toby-classes.ts` (chessever
/// web frontend) and desktop `lib/desktop/services/toby/toby_classes.dart`
/// (this file). Change one, change both, each with the shared cases in its
/// tests (`test/desktop/toby_classes_test.dart` here).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/painting.dart' show Color;

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/lichess_judgment.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';

/// White's chance in [wdl] as the report's win percentage, 0..100.
double tobyWhiteWinPercent(TobyWdl wdl) => (wdl.white + wdl.draw / 2) * 100;

/// The opening tree's game count for [uci] in [counts], under either
/// spelling of a castle, or null when it has none.
int? tobyBookCount(Map<String, int>? counts, String uci) {
  if (counts == null) return null;
  final alternate = GamebaseRepository.alternateCastlingUci(uci);
  return counts[uci] ?? (alternate == null ? null : counts[alternate]);
}

/// Whether the book count applies to a position [plies] half-moves from
/// [startFen]: only from the standard start and inside the report's probe
/// window ([kBookProbeMaxPlies]), as the report looks book up.
bool tobyBookApplies({required String? startFen, required int plies}) =>
    (startFen == null || startFen == kInitialFEN) && plies < kBookProbeMaxPlies;

/// Every candidate in [reading] by UCI, with its report class, or null for
/// an ordinary move (and for every move of the network stage, unless the
/// opening tree makes it Book).
///
/// [fen] is the position read, reached by [moves] (UCI) from [startFen]
/// (null is the standard start). [bookCounts] is the opening tree's game
/// count per move in that position, or null when it is not known.
Map<String, GameMoveClassification?> tobyMoveClasses(
  TobyReading reading, {
  required String fen,
  String? startFen,
  List<String> moves = const <String>[],
  Map<String, int>? bookCounts,
}) {
  final isWhite = reading.sideToMove == Side.white;
  final sign = isWhite ? 1 : -1;
  double mover(double whiteWin) => isWhite ? whiteWin : 100 - whiteWin;

  final positionWdl = reading.positionWdl;
  final judged = reading.isFinal && positionWdl != null;
  final beforeWin =
      positionWdl == null ? 0.0 : tobyWhiteWinPercent(positionWdl);

  // The report's lines: every move with an outcome. The first with the
  // highest mover win% is the engine's move.
  final lines = <({String uci, double win})>[
    for (final outcome in reading.outcomes)
      (uci: outcome.uci, win: tobyWhiteWinPercent(outcome.wdl)),
  ];
  String? bestUci;
  var bestMover = double.negativeInfinity;
  for (final line in lines) {
    if (mover(line.win) > bestMover) {
      bestMover = mover(line.win);
      bestUci = line.uci;
    }
  }

  final start = startFen ?? kInitialFEN;
  final previousUci = moves.isEmpty ? null : moves.last;
  String? previousFen;
  var previousFenRead = false;
  String? previousPositionFen() {
    if (previousFenRead) return previousFen;
    previousFenRead = true;
    try {
      Position position = Chess.fromSetup(Setup.parseFen(start));
      for (final uci in moves.take(moves.length - 1)) {
        final move = Move.parse(uci);
        if (move == null || !position.isLegal(move)) return null;
        position = position.play(move);
      }
      previousFen = position.fen;
    } catch (_) {
      previousFen = null;
    }
    return previousFen;
  }

  GameMoveClassification? judge(TobyCandidate candidate) {
    final wdl = candidate.wdl;
    if (!judged || wdl == null) return null;
    final afterWin = tobyWhiteWinPercent(wdl);
    final playedMover = mover(afterWin);
    final playedIsBest = candidate.uci == bestUci;
    var moverChange = (afterWin - beforeWin) * sign;

    ({String uci, double win})? alternative;
    for (final line in lines) {
      if (line.uci == candidate.uci) continue;
      if (alternative == null || mover(line.win) > mover(alternative.win)) {
        alternative = line;
      }
    }
    // The report caps the change by the loss against its best line whenever
    // it has two lines to compare (`gameReportRootComparison`).
    if (alternative != null) {
      final playedLoss = playedMover - bestMover;
      if (playedLoss < moverChange) moverChange = playedLoss;
    }

    final simpleRecapture =
        lines.length > 1 &&
        previousUci != null &&
        switch (previousPositionFen()) {
          final previous? => isSimpleReportRecapture(
            previous,
            previousUci,
            candidate.uci,
          ),
          null => false,
        };

    return classifyReportMoveEvidence(
      ReportMoveEvidence(
        beforeFen: fen,
        uci: candidate.uci,
        san: candidate.san,
        isWhite: isWhite,
        beforeWin: beforeWin,
        afterWin: afterWin,
        moverChange: moverChange,
        playedIsBest: playedIsBest,
        lineCount: lines.length,
        alternativeWin: alternative?.win,
        alternativeGap:
            alternative == null ? 0.0 : playedMover - mover(alternative.win),
        previousUci: previousUci,
        simpleRecapture: simpleRecapture,
        positiveEvidenceVerified: true,
        // Lichess never judges the engine's own move; otherwise the winning
        // chances the mover handed over, on its [-1, +1] scale.
        judgement:
            playedIsBest
                ? null
                : lichessJudgementForWinningChanceLoss(
                  (beforeWin - afterWin) * sign / 50,
                ),
        likelyOpeningBook:
            () => isReportLikelyOpeningBookMove(
              ply: moves.length,
              startFen: start,
              beforeFen: () => fen,
              san: candidate.san,
              uci: candidate.uci,
            ),
      ),
    );
  }

  final bookApplies = tobyBookApplies(startFen: startFen, plies: moves.length);
  return {
    for (final candidate in reading.candidates)
      candidate.uci: applyBookMoveOverride(
        judge(candidate),
        bookApplies ? tobyBookCount(bookCounts, candidate.uci) : null,
      ),
  };
}

/// Toby's arrow on the board for a move without a class: a deep teal that
/// reads on light and dark squares alike (the board keeps its colours in
/// every theme). The same hex value on the web.
const Color kTobyArrowNeutral = Color(0xFF1E7F79);

/// A candidate's arrow hue: its class's own colour, as the report's marks
/// and the notation's SAN tint use it ([classificationColor]), or Toby's
/// teal for a move without one.
Color tobyArrowHue(GameMoveClassification? classification) =>
    classification == null
        ? kTobyArrowNeutral
        : classificationColor(classification);

/// A row's chance text for each class on the pane's dark rows: the class
/// colour mixed 40% toward white (45% for Great's deep navy), so every one
/// clears 4.5:1 on a hovered or pinned row under its own fill
/// (`test/desktop/toby_classes_test.dart` checks it).
const Map<GameMoveClassification, Color> kTobyClassRowTones = {
  GameMoveClassification.brilliant: Color(0xFF6FD2EF),
  GameMoveClassification.goodMove: Color(0xFF8896BF),
  GameMoveClassification.bestMove: Color(0xFF78BE94),
  GameMoveClassification.missedWin: Color(0xFFF18576),
  GameMoveClassification.inaccuracy: Color(0xFFDCAB86),
  GameMoveClassification.mistake: Color(0xFFDC9C78),
  GameMoveClassification.blunder: Color(0xFFFA6866),
  GameMoveClassification.bookMove: Color(0xFFD2C8AA),
};
