import 'package:flutter/foundation.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Splits a text blob that may contain one or more PGN games into individual
/// PGN strings (trimmed, without trailing whitespace).
///
/// Uses the next PGN header after movetext as a game boundary. This preserves
/// the whole header block even when `[Event ...]` is not the first tag.
List<String> splitPgnGames(String text) {
  final normalized =
      text.contains('\r')
          ? text.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
          : text;
  final trimmed = normalized.trim();
  if (trimmed.isEmpty) return const [];

  final games = <String>[];
  final current = StringBuffer();
  var sawMovetext = false;
  var inComment = false;

  var start = 0;
  while (start <= trimmed.length) {
    final newline = trimmed.indexOf('\n', start);
    final isLastLine = newline == -1;
    final line =
        isLastLine
            ? trimmed.substring(start)
            : trimmed.substring(start, newline);
    final stripped = _stripBom(line).trimLeft();
    final isHeader =
        !inComment &&
        stripped.startsWith('[') &&
        _pgnHeaderLineRegex.hasMatch(stripped);
    if (isHeader && sawMovetext && current.isNotEmpty) {
      final game = current.toString().trim();
      if (game.isNotEmpty) games.add(game);
      current.clear();
      sawMovetext = false;
    }

    current.writeln(line);
    if (stripped.isNotEmpty && !isHeader) {
      sawMovetext = true;
    }
    inComment = _updatePgnCommentState(line, inComment);
    if (isLastLine) break;
    start = newline + 1;
  }

  final tail = current.toString().trim();
  if (tail.isNotEmpty) games.add(tail);
  return games.isEmpty ? <String>[trimmed] : games;
}

final RegExp _pgnHeaderLineRegex = RegExp(
  r'^\[\s*[A-Za-z0-9_]+\s+"(?:\\.|[^"\\])*"\s*\]$',
);

String _stripBom(String line) {
  if (line.startsWith('\uFEFF')) return line.substring(1);
  return line;
}

bool _updatePgnCommentState(String line, bool inComment) {
  if (!inComment && !line.contains('{')) return false;
  var next = inComment;
  for (final codeUnit in line.codeUnits) {
    if (codeUnit == 0x7B) {
      next = true;
    } else if (codeUnit == 0x7D) {
      next = false;
    }
  }
  return next;
}

/// Parsed PGN result, bundling the `ChessGame` alongside its raw PGN text.
class ParsedPgnEntry {
  final ChessGame chessGame;
  final String rawPgn;
  const ParsedPgnEntry({required this.chessGame, required this.rawPgn});
}

/// Parses a (possibly multi-game) PGN blob into a list of `ChessGame`s.
/// Invalid or empty entries are skipped; the result contains only games that
/// actually parsed to at least one legal move. Random text, FEN strings, or
/// PGN-like fragments with no playable moves return an empty list so callers
/// can surface a single "invalid PGN" error instead of routing to a preview
/// screen with ghost entries.
List<ParsedPgnEntry> parsePgnsToChessGames(String text) {
  final raw = splitPgnGames(text);
  final entries = <ParsedPgnEntry>[];
  for (var i = 0; i < raw.length; i++) {
    final pgn = raw[i];
    try {
      final game = ChessGame.fromPgn('imported_$i', pgn);
      if (game.mainline.isEmpty) continue;
      entries.add(ParsedPgnEntry(chessGame: game, rawPgn: pgn));
    } catch (_) {
      // Skip unparseable entries so a single bad game doesn't kill the batch.
    }
  }
  return entries;
}

/// Parses PGN text away from the UI isolate.
///
/// Large PGN databases can take long enough to parse that doing the work in
/// button/drop handlers freezes Flutter's frame loop. Keep the synchronous
/// parser for tests and tiny internal callers, but route user-facing imports
/// through this helper.
Future<List<ParsedPgnEntry>> parsePgnsToChessGamesAsync(String text) {
  return compute(parsePgnsToChessGames, text);
}
