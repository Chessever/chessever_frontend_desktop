import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';

/// PGN quality-verdict NAGs ($1–$6) that answer "how good was this move".
/// A completed Game Analysis report owns that question and replaces them.
const moveVerdictNags = <int>{1, 2, 3, 4, 5, 6};

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
    'good' || 'good_move' || 'great' || 'great_move' =>
      LichessMoveAnnotationType.goodMove,
    'best' || 'best_move' || 'top_move' => LichessMoveAnnotationType.bestMove,
    'missed_win' || 'missedwin' || 'miss' => LichessMoveAnnotationType.missedWin,
    'inaccuracy' || 'dubious' => LichessMoveAnnotationType.inaccuracy,
    'mistake' => LichessMoveAnnotationType.mistake,
    'blunder' => LichessMoveAnnotationType.blunder,
    'book' || 'book_move' => LichessMoveAnnotationType.bookMove,
    'forced' || 'forced_move' || 'only_move' => LichessMoveAnnotationType.forced,
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
/// ChessEver annotation directives override quality NAGs. When the directive is
/// absent, fall back to best-effort mapping from quality NAGs.
LichessMoveAnnotationType? resolveDisplayAnnotationType({
  required Iterable<String>? comments,
  required Iterable<int>? nags,
}) {
  final fromDirective = parseChesseverAnnotationType(comments);
  if (fromDirective != null) return fromDirective;
  return annotationTypeFromQualityNags(nags);
}

/// Annotations map keyed by zero-based mainline move index from PGN comments.
///
/// Each entry carries [LichessMoveAnnotation.useClassificationIcon] so board
/// and notation treat ChessEver directives like report badges (and suppress
/// competing quality NAG glyphs).
Map<int, LichessMoveAnnotation> chesseverAnnotationsFromMainline(
  ChessGame game,
) {
  final out = <int, LichessMoveAnnotation>{};
  for (var i = 0; i < game.mainline.length; i++) {
    final type = parseChesseverAnnotationType(game.mainline[i].comments);
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

/// ChessEver product slug for a report classification (Cloudflare GIF asset key).
///
/// The cloud renderer expects `[%chessever_annotation brilliant]` /
/// `good_move` / … and maps those 1:1 onto badge PNGs. Classic glyphs (`!`,
/// `!!`) are **not** used when we own the report hydrate.
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
/// When **we** generated the report, hydrate with ChessEver product-name
/// directives Cloudflare and the apps expect:
/// `[%chessever_annotation brilliant]` / `good_move` / `best_move` / …
/// plus quality NAGs `$1`–`$6` as a portable best-effort companion.
/// Classic glyph tokens (`!!`, `?!`) are for import/best-effort only — never
/// the report-export format.
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
        final product = chesseverClassificationName(
          reportMove.classification,
        );
        final directive =
            product == null ? null : '[%chessever_annotation $product]';
        final existingComments = move.comments ?? const <String>[];
        // Replace any prior chessever directive (classic glyph or product)
        // so export always carries product names for this report.
        final withoutChessever =
            existingComments
                .where((c) => !c.contains('[%chessever_annotation '))
                .toList(growable: true);
        final comments =
            directive == null
                ? withoutChessever
                : <String>[...withoutChessever, directive];

        final classic = classicGlyphForClassification(
          reportMove.classification,
        );
        final reportNag = nagForClassicGlyph(classic);
        final existingNags = move.nags ?? const <int>[];
        final nonVerdictNags =
            existingNags
                .where((nag) => !moveVerdictNags.contains(nag))
                .toList(growable: true);
        if (reportNag != null && !nonVerdictNags.contains(reportNag)) {
          nonVerdictNags.add(reportNag);
        }
        final nags = nonVerdictNags;

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
  return exportGameToPgn(mergeGameReportAnnotationsForExport(game, reportMoves));
}
