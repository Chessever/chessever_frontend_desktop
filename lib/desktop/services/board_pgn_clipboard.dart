import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';

/// Builds the PGN text used by the board pane's Copy PGN action.
///
/// When the loaded game has not changed, the original PGN is preferred so
/// header ordering/formatting from the source is preserved. Once the in-memory
/// notation tree contains branches, however, the exported tree is authoritative:
/// copied PGN must include every visible variation, even if the original source
/// PGN only carried the mainline.
String boardClipboardPgn({
  required ChessGame game,
  required bool dirtySinceLoad,
  String? lastAppliedPgn,
}) {
  final pristinePgn = dirtySinceLoad ? null : lastAppliedPgn?.trim();
  if (pristinePgn != null &&
      pristinePgn.isNotEmpty &&
      !chessGameHasVariations(game)) {
    return pristinePgn;
  }
  return exportGameToPgn(game);
}

bool chessGameHasVariations(ChessGame game) =>
    _lineHasVariations(game.mainline);

bool _lineHasVariations(ChessLine line) {
  for (final move in line) {
    final variations = move.variations ?? const <ChessLine>[];
    if (variations.isNotEmpty) return true;
    for (final variation in variations) {
      if (_lineHasVariations(variation)) return true;
    }
  }
  return false;
}
