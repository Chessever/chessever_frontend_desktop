import 'package:dartchess/dartchess.dart';

/// Explicit setup data is playable without notation. Never substitute the
/// initial board for malformed or missing setup data. Dartchess accepts the
/// legacy fullmove counter 0 and canonicalizes it to 1, preserving the position.
bool localPgnHasValidSetupHeaders(Map<String, dynamic> headers) {
  final fen = headers['FEN']?.toString().trim() ?? '';
  if (fen.isEmpty) return false;
  try {
    Chess.fromSetup(Setup.parseFen(fen));
    return true;
  } on Object {
    return false;
  }
}

bool localPgnHasValidSetupPosition(String? pgn) {
  if (pgn == null || pgn.trim().isEmpty) return false;
  try {
    return localPgnHasValidSetupHeaders(PgnGame.parsePgn(pgn).headers);
  } on Object {
    return false;
  }
}
