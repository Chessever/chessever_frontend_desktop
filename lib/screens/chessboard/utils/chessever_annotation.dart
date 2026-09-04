import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';

/// PGN quality-verdict NAGs ($1–$6) that answer "how good was this move".
/// A completed Game Analysis report owns that question and replaces them.
const moveVerdictNags = <int>{1, 2, 3, 4, 5, 6};

/// Marks a standard quality NAG as a later ChessEver user override.
///
/// The paired `$1`–`$6` remains portable for other PGN readers. This marker
/// preserves edit provenance so a background report cannot reclaim the move
/// after Save/Copy/Share and reopen.
const kChesseverUserQualityOverrideNag = 248;

/// ChessEver's classification NAG block: `$240`–`$247`, one code per report
/// class, written **beside** the standard quality NAG rather than instead of it.
///
/// Mirrors mobile byte-for-byte (`game_share_utils.dart`) — that identity is the
/// point. A report generated on either app travels in the PGN itself, so the
/// same saved analysis or shared PGN opens with the same badges on the other
/// one, with no `[%…]` directive and nothing for a foreign reader to trip on:
/// it sees `$3` and shows `!!`, ours also sees `$240` and shows Brilliant.
///
/// `$1`–`$6` alone cannot do this — good and best both collapse to `!`, missed
/// win and blunder both to `??`, book has no glyph at all.
const kChesseverClassificationNags = <GameMoveClassification, int>{
  GameMoveClassification.brilliant: 240,
  GameMoveClassification.goodMove: 241,
  GameMoveClassification.bestMove: 242,
  GameMoveClassification.missedWin: 243,
  GameMoveClassification.inaccuracy: 244,
  GameMoveClassification.mistake: 245,
  GameMoveClassification.blunder: 246,
  GameMoveClassification.bookMove: 247,
};

final Map<int, GameMoveClassification> _classificationByNag = {
  for (final entry in kChesseverClassificationNags.entries)
    entry.value: entry.key,
};

/// The `$240`–`$247` code carrying [classification], or null when unclassified.
int? chesseverClassificationNag(GameMoveClassification? classification) =>
    classification == null
        ? null
        : kChesseverClassificationNags[classification];

/// Inverse of [chesseverClassificationNag].
GameMoveClassification? classificationForChesseverNag(int nag) =>
    _classificationByNag[nag];

/// Whether [nag] belongs to the ChessEver classification block.
bool isChesseverClassificationNag(int nag) =>
    _classificationByNag.containsKey(nag);

/// The ChessEver classification a move's NAGs carry, if any.
///
/// Presence of a block code also means "a ChessEver report judged this move",
/// which is what lets the board show the badge instead of the imported glyph.
GameMoveClassification? classificationFromNags(Iterable<int>? nags) {
  if (nags == null) return null;
  for (final nag in nags) {
    final classification = _classificationByNag[nag];
    if (classification != null) return classification;
  }
  return null;
}

/// Report classification a move's NAGs carry, as a display annotation type.
LichessMoveAnnotationType? annotationTypeFromClassificationNags(
  Iterable<int>? nags,
) {
  final classification = classificationFromNags(nags);
  return classification == null
      ? null
      : annotationTypeForClassification(classification);
}

final _chesseverAnnotationDirective = RegExp(
  r'\[%\s*chessever_annotation\s+([^\]]+?)\s*\]',
  caseSensitive: false,
);

/// Machine tags that must never surface as free-text notation comments.
///
/// Includes clocks/evals/arrows plus ChessEver's private classification
/// directive. Tags-only comments become empty after cleaning and are omitted.
final _pgnMachineTagDirective = RegExp(
  r'\[%\s*(?:clk|eval|cal|csl|emt|tag|src|chessever_annotation)\s*[^\]]*\]',
  caseSensitive: false,
);

/// Residual bare form some parsers leave after stripping brackets/percent.
/// Matches e.g. `chessever_annotation !` / `chessever_annotation ??`.
/// Glyphs (`!`, `??`, …) are non-word chars so trailing `\b` is unreliable;
/// match the keyword + glyph/token alone.
final _bareChesseverAnnotationResidue = RegExp(
  r'\bchessever_annotation\s+(?:!!|\?\?|!\?|\?!|[!?]|[A-Za-z_]+)',
  caseSensitive: false,
);

/// Strip Lichess / ChessEver machine tags from a single PGN comment and trim.
///
/// Empty result means the comment was tags-only and must not render as prose.
/// Parse helpers such as [parseChesseverAnnotationType] still read **raw**
/// move comments — this is display-only.
String cleanPgnCommentText(String comment) {
  return comment
      .replaceAll(_pgnMachineTagDirective, '')
      .replaceAll(_bareChesseverAnnotationResidue, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Cleaned prose comments for notation display (tags-only entries dropped).
List<String> cleanPgnComments(Iterable<String>? comments) {
  if (comments == null) return const <String>[];
  final out = <String>[];
  for (final comment in comments) {
    final clean = cleanPgnCommentText(comment);
    if (clean.isNotEmpty) out.add(clean);
  }
  return out;
}

/// First non-empty cleaned prose comment, or null when none remain.
String? firstPgnComment(Iterable<String>? comments) {
  final cleaned = cleanPgnComments(comments);
  return cleaned.isEmpty ? null : cleaned.first;
}

/// Classic portable glyph for a report classification (best-effort for other apps).
///
/// ChessEver’s richer labels collapse onto the five standard quality marks
/// every PGN consumer already knows.
String? classicGlyphForClassification(GameMoveClassification? classification) =>
    switch (classification) {
      GameMoveClassification.brilliant => '!!',
      GameMoveClassification.goodMove => '!',
      GameMoveClassification.bestMove => '!',
      GameMoveClassification.missedWin => '??',
      GameMoveClassification.inaccuracy => '?!',
      GameMoveClassification.mistake => '?',
      GameMoveClassification.blunder => '??',
      GameMoveClassification.bookMove => null,
      null => null,
    };

/// Standard PGN quality NAG ($1–$6) for a classic glyph.
int? nagForClassicGlyph(String? glyph) => switch (glyph) {
  '!' => 1,
  '?' => 2,
  '!!' => 3,
  '??' => 4,
  '!?' => 5,
  '?!' => 6,
  _ => null,
};

/// Best-effort product classification from a classic portable glyph.
///
/// Classic glyphs collapse several product classes (`good`/`best` → `!`,
/// `blunder`/`missedWin` → `??`), so the reverse map cannot restore product
/// labels fully — that is intentional and matches mobile export design.
LichessMoveAnnotationType? annotationTypeFromClassicGlyph(String? glyph) {
  final trimmed = glyph?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return switch (trimmed) {
    '!!' => LichessMoveAnnotationType.brilliant,
    '!' => LichessMoveAnnotationType.goodMove,
    '??' => LichessMoveAnnotationType.blunder,
    '?' => LichessMoveAnnotationType.mistake,
    '?!' => LichessMoveAnnotationType.inaccuracy,
    // Speculative has no classification badge.
    '!?' => null,
    _ => null,
  };
}

/// Parse a `[%chessever_annotation …]` token (classic glyph or legacy product name).
LichessMoveAnnotationType? annotationTypeFromChesseverToken(String? raw) {
  if (raw == null) return null;
  final token = raw.trim();
  if (token.isEmpty) return null;

  // Classic portable glyphs first (current mobile export format).
  final fromGlyph = annotationTypeFromClassicGlyph(token);
  if (fromGlyph != null) return fromGlyph;

  // Legacy product-name directives (older desktop export / backward compat).
  final normalized = token.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  return switch (normalized) {
    'brilliant' => LichessMoveAnnotationType.brilliant,
    'good' ||
    'good_move' ||
    'great' ||
    'great_move' => LichessMoveAnnotationType.goodMove,
    'best' || 'best_move' || 'top_move' => LichessMoveAnnotationType.bestMove,
    'missed_win' ||
    'missedwin' ||
    'miss' => LichessMoveAnnotationType.missedWin,
    'inaccuracy' || 'dubious' => LichessMoveAnnotationType.inaccuracy,
    'mistake' => LichessMoveAnnotationType.mistake,
    'blunder' => LichessMoveAnnotationType.blunder,
    'book' || 'book_move' => LichessMoveAnnotationType.bookMove,
    'forced' ||
    'forced_move' ||
    'only_move' => LichessMoveAnnotationType.forced,
    _ => null,
  };
}

/// First `[%chessever_annotation …]` directive found in [comments], if any.
String? extractChesseverAnnotationToken(Iterable<String>? comments) {
  if (comments == null) return null;
  for (final comment in comments) {
    final match = _chesseverAnnotationDirective.firstMatch(comment);
    if (match == null) continue;
    final token = match.group(1)?.trim();
    if (token != null && token.isNotEmpty) return token;
  }
  return null;
}

/// Classification carried by a ChessEver annotation directive on a move.
LichessMoveAnnotationType? parseChesseverAnnotationType(
  Iterable<String>? comments,
) {
  return annotationTypeFromChesseverToken(
    extractChesseverAnnotationToken(comments),
  );
}

/// Best-effort classification from quality NAGs ($1–$6).
///
/// Prefers the primary quality NAG (lowest code among quality marks present).
LichessMoveAnnotationType? annotationTypeFromQualityNags(Iterable<int>? nags) {
  if (nags == null) return null;
  int? best;
  for (final nag in nags) {
    if (nag < 1 || nag > 6) continue;
    if (best == null || nag < best) best = nag;
  }
  if (best == null) return null;
  return switch (best) {
    1 => LichessMoveAnnotationType.goodMove,
    2 => LichessMoveAnnotationType.mistake,
    3 => LichessMoveAnnotationType.brilliant,
    4 => LichessMoveAnnotationType.blunder,
    5 => null, // speculative — no classification badge
    6 => LichessMoveAnnotationType.inaccuracy,
    _ => null,
  };
}

/// Resolve the display classification for a move.
///
/// Priority: the ChessEver NAG block ($240–$247, the current wire format) →
/// the legacy `[%chessever_annotation …]` directive (PGNs saved by older
/// builds) → best-effort from the standard quality NAGs, which is all a
/// foreign PGN can offer.
LichessMoveAnnotationType? resolveDisplayAnnotationType({
  required Iterable<String>? comments,
  required Iterable<int>? nags,
}) {
  final fromBlock = annotationTypeFromClassificationNags(nags);
  if (fromBlock != null) return fromBlock;
  final fromDirective = parseChesseverAnnotationType(comments);
  if (fromDirective != null) return fromDirective;
  return annotationTypeFromQualityNags(nags);
}

/// Annotations map keyed by zero-based mainline move index, read from the PGN
/// the game arrived in — the `$240`–`$247` block first, the legacy directive
/// second.
///
/// This is how a report crosses devices: the store is local, so a game synced
/// from mobile has no report here, but its moves still carry what our analysis
/// called them.
///
/// Each entry carries [LichessMoveAnnotation.useClassificationIcon] so board
/// and notation treat these like report badges (and suppress competing quality
/// NAG glyphs).
Map<int, LichessMoveAnnotation> chesseverAnnotationsFromMainline(
  ChessGame game,
) {
  final out = <int, LichessMoveAnnotation>{};
  for (var i = 0; i < game.mainline.length; i++) {
    final move = game.mainline[i];
    final type =
        annotationTypeFromClassificationNags(move.nags) ??
        parseChesseverAnnotationType(move.comments);
    if (type == null) continue;
    out[i] = LichessMoveAnnotation(
      type: type,
      comment: '',
      useClassificationIcon: true,
      reportOwnsMoveQuality: true,
    );
  }
  return Map<int, LichessMoveAnnotation>.unmodifiable(out);
}

/// Legacy product slug for a report classification.
///
/// Kept for reading PGNs written before the `$240`–`$247` block and for the
/// GIF renderer's own legacy path. Never emitted on export any more.
String? chesseverClassificationName(GameMoveClassification? classification) =>
    switch (classification) {
      GameMoveClassification.brilliant => 'brilliant',
      GameMoveClassification.goodMove => 'good_move',
      GameMoveClassification.bestMove => 'best_move',
      GameMoveClassification.missedWin => 'missed_win',
      GameMoveClassification.inaccuracy => 'inaccuracy',
      GameMoveClassification.mistake => 'mistake',
      GameMoveClassification.blunder => 'blunder',
      GameMoveClassification.bookMove => 'book_move',
      null => null,
    };

/// Adds completed Game Analysis scores and classifications onto a [ChessGame]
/// before export (Copy PGN, Share PGN, and GIF).
///
/// Every classified move gets two NAGs: the standard quality verdict
/// (`$1`/`$2`/`$3`/`$4`/`$6`) that any PGN reader understands, and the
/// ChessEver code (`$240`–`$247`, see [kChesseverClassificationNags]) that
/// names the exact class for our own apps and the GIF renderer. The report
/// owns the verdict, so imported `$1`–`$6` are dropped first — including on
/// moves it deliberately left unlabelled.
///
/// Identical to mobile's `mergeGameReportAnnotationsForExport`, so the same
/// game exports the same bytes on both.
///
/// Legacy `[%chessever_annotation …]` comments are stripped, never written.
ChessGame mergeGameReportAnnotationsForExport(
  ChessGame game,
  List<GameReportMove> reportMoves,
) {
  if (reportMoves.isEmpty) return game;

  final byPly = <int, GameReportMove>{
    for (final move in reportMoves) move.ply: move,
  };
  var changed = false;
  final mainline = <ChessMove>[
    for (var index = 0; index < game.mainline.length; index++)
      (() {
        final move = game.mainline[index];
        final reportMove = byPly[index + 1];
        if (reportMove == null) return move;

        final reportLine = reportMove.evaluation;
        final evaluation =
            reportLine.mate != null
                ? '#${reportLine.mate}'
                : reportLine.centipawns != null
                ? (reportLine.centipawns! / 100).toStringAsFixed(2)
                : move.eval;
        final existingComments = move.comments ?? const <String>[];
        // Drop the legacy directive: this report's verdict now travels in the
        // NAGs, and a stale comment beside it would contradict them.
        final comments = <String>[
          for (final comment in existingComments)
            if (!_chesseverAnnotationDirective.hasMatch(comment))
              comment
            else if (comment
                .replaceAll(_chesseverAnnotationDirective, '')
                .trim()
                .isNotEmpty)
              comment.replaceAll(_chesseverAnnotationDirective, '').trim(),
        ];

        final existingNags = move.nags ?? const <int>[];
        final hasUserQualityOverride =
            existingNags.contains(kChesseverUserQualityOverrideNag) &&
            existingNags.any((nag) => nag >= 1 && nag <= 7);
        final classic = classicGlyphForClassification(
          reportMove.classification,
        );
        final reportNag = nagForClassicGlyph(classic);
        final chesseverNag = chesseverClassificationNag(
          reportMove.classification,
        );
        // Strip both what the report displaces (imported $1–$6) and any earlier
        // ChessEver code, so a re-run never stacks two classifications.
        final nags = existingNags
            .where(
              (nag) =>
                  (hasUserQualityOverride || !moveVerdictNags.contains(nag)) &&
                  !isChesseverClassificationNag(nag),
            )
            .toList(growable: true);
        if (!hasUserQualityOverride &&
            reportNag != null &&
            !nags.contains(reportNag)) {
          nags.add(reportNag);
        }
        if (!hasUserQualityOverride &&
            chesseverNag != null &&
            !nags.contains(chesseverNag)) {
          nags.add(chesseverNag);
        }

        final evalChanged = evaluation != null && evaluation != move.eval;
        final commentsChanged =
            comments.length != existingComments.length ||
            !comments.every(existingComments.contains);
        final nagsChanged =
            nags.length != existingNags.length ||
            !nags.every(existingNags.contains);
        if (!evalChanged && !commentsChanged && !nagsChanged) return move;
        changed = true;
        return move.copyWith(eval: evaluation, comments: comments, nags: nags);
      })(),
  ];

  return changed ? game.copyWith(mainline: mainline) : game;
}

/// Alias — GIF was the first consumer; same product-name hydrate as export.
ChessGame mergeGameReportAnnotationsForGif(
  ChessGame game,
  List<GameReportMove> reportMoves,
) => mergeGameReportAnnotationsForExport(game, reportMoves);

/// @Deprecated Use [chesseverClassificationName].
String? gifClassificationName(GameMoveClassification? classification) =>
    chesseverClassificationName(classification);

/// Merge + [exportGameToPgn] in one step (Copy PGN / Share PGN / tests).
String exportGamePgnWithReport(
  ChessGame game,
  List<GameReportMove> reportMoves,
) {
  return exportGameToPgn(
    mergeGameReportAnnotationsForExport(game, reportMoves),
  );
}
