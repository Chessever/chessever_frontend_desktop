/// Restores the Game Analysis report a game's PGN already carries.
///
/// A finished report travels inside the PGN: every analysed move gets its
/// ChessEver class as a `$240`–`$247` NAG and its score as `[%eval …]`, and the
/// report writer stamps the whole with `[ChessEverReport]`. The analysis
/// service writes exactly that back onto broadcast games after its hourly
/// prewarm (`store_prewarmed_report_pgn`), and Copy/Share PGN writes it from
/// every app. A game carrying our stamped report has already been analysed, and
/// asking an engine — local or remote — to analyse it again only makes the
/// reader wait for an answer the board is already showing.
///
/// Mirrors mobile's `game_report_from_pgn.dart`: every app decides "this PGN
/// holds our report" by the same stamp and recovers the same numbers from it.
///
/// Deliberately not part of `game_analysis_report.dart`: that file is vendored
/// byte-for-byte into the analysis service, and its checksum is part of the
/// server's report-cache contract. Nothing here changes what a report says; it
/// only reads one back.
library;

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/screens/chessboard/utils/chessever_report_stamp.dart';

/// The report [game]'s PGN carries, or null when it does not carry one of ours.
///
/// Only our own analysis is restored. The PGN must carry a verified
/// [kChesseverReportStampTag] stamp (see `chessever_report_stamp.dart`): the
/// report writer adds it, and it stops verifying the moment a verdict, a score
/// or a move changes, or a user verdict is applied. Classes a user set, another
/// engine's `[%eval]`, a partly evaluated game or a PGN written before stamps
/// existed all return null, and the caller analyses instead. Badges such a PGN
/// shows in the notation are its annotations, never a report we stand behind.
///
/// What a PGN cannot carry is recomputed, never invented:
///
/// - Accuracy and estimated ratings are functions of the per-position scores
///   alone, so they are derived with the same formulas a fresh analysis uses.
///   [whiteRating] and [blackRating] anchor the estimated ratings exactly as
///   they do for a fresh analysis.
/// - The starting position's score is the one value a PGN never holds. It takes
///   the first played position's score, so the first move is charged nothing
///   for the opening edge (reading it as 0.00 would charge it the whole edge).
/// - Search lines and best alternatives are not in the PGN and stay empty.
GameAnalysisReport? gameAnalysisReportFromPgn(
  ChessGame game, {
  int? whiteRating,
  int? blackRating,
}) {
  final mainline = game.mainline;
  if (!carriesVerifiedChesseverReport(game)) return null;

  // The stamp covers each move's first ChessEver code, which is exactly what
  // [classificationFromNags] reads.
  final classifications = <int, GameMoveClassification>{};
  for (var i = 0; i < mainline.length; i++) {
    final classification = classificationFromNags(mainline[i].nags);
    if (classification != null) classifications[i] = classification;
  }

  final scores = <GameReportLine>[];
  for (final move in mainline) {
    final score = parseSavedReportEvaluation(move.eval);
    if (score == null) return null;
    scores.add(score);
  }

  final positions = <GameReportPosition>[
    GameReportPosition(fen: game.startingFen, lines: [scores.first]),
    for (var i = 0; i < mainline.length; i++)
      GameReportPosition(fen: mainline[i].fen, lines: [scores[i]]),
  ];
  final moves = <GameReportMove>[
    for (var i = 0; i < mainline.length; i++)
      GameReportMove(
        ply: i + 1,
        san: mainline[i].san,
        uci: mainline[i].uci,
        isWhite: mainline[i].turn == ChessColor.white,
        classification: classifications[i],
        evaluation: scores[i],
      ),
  ];

  final accuracy = computeGameReportAccuracy([
    for (final position in positions)
      gameReportWinPercentage(position.bestLine),
  ]);
  final ratings = computeGameReportEstimatedRatings(
    positions,
    whiteRating: whiteRating,
    blackRating: blackRating,
  );
  return GameAnalysisReport(
    fingerprint: gameReportFingerprint(game),
    positions: List.unmodifiable(positions),
    moves: List.unmodifiable(moves),
    whiteAccuracy: accuracy.white,
    blackAccuracy: accuracy.black,
    whiteEstimatedRating: ratings?.white,
    blackEstimatedRating: ratings?.black,
    // When the report was computed is not recorded in the PGN. The epoch says
    // "unknown" rather than claiming it was generated just now.
    generatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Reads a `[%eval …]` value the way a report wrote it: pawns to two decimals
/// (`0.32`, `-1.05`), or a mate distance (`#3`, `#-2`), optionally followed by a
/// search depth (`0.32,14`). Anything else is not a score.
GameReportLine? parseSavedReportEvaluation(String? raw) {
  if (raw == null) return null;
  final fields = raw.trim().split(',');
  if (fields.length > 2) return null;
  final depth = fields.length == 2 ? int.tryParse(fields[1].trim()) : 0;
  if (depth == null || depth < 0) return null;
  final score = fields.first.trim();
  if (_mateScore.hasMatch(score)) {
    final mate = int.tryParse(score.substring(1));
    if (mate == null) return null;
    return GameReportLine(moves: const [], depth: depth, mate: mate);
  }
  if (!_pawnScore.hasMatch(score)) return null;
  final pawns = double.tryParse(score);
  if (pawns == null || !pawns.isFinite) return null;
  return GameReportLine(
    moves: const [],
    depth: depth,
    centipawns: (pawns * 100).round(),
  );
}

final _mateScore = RegExp(r'^#-?\d+$');
final _pawnScore = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');
