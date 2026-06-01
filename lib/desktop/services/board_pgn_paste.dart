import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// How an in-board PGN paste should be applied.
enum BoardPgnPasteMode {
  /// Empty/scratch board: replace the board contents with the pasted game.
  loadIntoCurrentBoard,

  /// Existing analysis/game: reuse the normal Insert game continuation path.
  insertIntoCurrentNotation,
}

BoardPgnPasteMode resolveBoardPgnPasteMode({
  required bool activeBoardHasNotation,
}) {
  return activeBoardHasNotation
      ? BoardPgnPasteMode.insertIntoCurrentNotation
      : BoardPgnPasteMode.loadIntoCurrentBoard;
}

String clipboardPgnSourceLabel(String pgn) {
  try {
    final game = ChessGame.fromPgn('clipboard-pgn', pgn);
    final metadata = game.metadata;
    final result = _normalizeResult(
      (metadata['Result']?.toString() ?? '').trim(),
    );
    final white = _compactPlayerCitation(
      metadata['White']?.toString() ?? '',
      _readInt(metadata['WhiteElo']),
    );
    final black = _compactPlayerCitation(
      metadata['Black']?.toString() ?? '',
      _readInt(metadata['BlackElo']),
    );
    final site =
        (metadata['Site']?.toString() ?? metadata['Event']?.toString() ?? '')
            .trim();
    final year = _yearFromDate(metadata['Date']?.toString() ?? '');
    final hasIdentity =
        white.isNotEmpty ||
        black.isNotEmpty ||
        (site.isNotEmpty && site != '?') ||
        year.isNotEmpty;
    if (!hasIdentity && game.mainline.isEmpty) return 'Clipboard PGN';
    final label =
        [
          if (result.isNotEmpty && (result != '*' || hasIdentity)) result,
          if (white.isNotEmpty || black.isNotEmpty) '$white-$black',
          if (site.isNotEmpty && site != '?') site,
          if (year.isNotEmpty) year,
        ].join(' ').trim();
    return label.isEmpty ? 'Clipboard PGN' : label;
  } catch (_) {
    return 'Clipboard PGN';
  }
}

String _normalizeResult(String result) {
  final normalized = result.replaceAll('½', '1/2').trim();
  return switch (normalized) {
    '1/2-1/2' => '½-½',
    '1-0' || '0-1' || '*' => normalized,
    _ => result,
  };
}

String _compactPlayerCitation(String rawName, int rating) {
  final clean = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty || RegExp(r'^\?+$').hasMatch(clean)) return '';
  final comma = clean.indexOf(',');
  final String last;
  final String given;
  if (comma >= 0) {
    last = clean.substring(0, comma).trim();
    given = clean.substring(comma + 1).trim();
  } else {
    final parts = clean.split(' ').where((p) => p.isNotEmpty).toList();
    last = parts.isEmpty ? clean : parts.last;
    given = parts.length >= 2 ? parts.first : '';
  }
  if (last.isEmpty) return '';
  final initial = given.isEmpty ? '' : ',${given.substring(0, 1)}';
  final ratingText = rating > 0 ? ' ($rating)' : '';
  return '$last$initial$ratingText';
}

String _yearFromDate(String rawDate) {
  final raw = rawDate.trim();
  if (raw.isEmpty || RegExp(r'^\?+(\.\?+)*$').hasMatch(raw)) return '';
  if (raw.length >= 4) return raw.substring(0, 4);
  return '';
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
