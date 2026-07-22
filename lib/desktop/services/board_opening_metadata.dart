import 'package:dartchess/dartchess.dart';

import 'package:chessever/desktop/services/tournament_server/eco_library.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

/// Returns the most specific built-in ECO whose move sequence is a prefix of
/// the current standard-start board line.
///
/// A null result is intentional: saving must not manufacture an ECO when the
/// current line is outside the openings ChessEver can recognize locally.
EcoOpeningSeed? recognizedEcoForBoardLine({
  required String startingFen,
  required List<String> movesUci,
}) {
  if (startingFen.trim() != Chess.initial.fen) return null;

  final line = movesUci
      .map((move) => move.trim().toLowerCase())
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
  EcoOpeningSeed? best;

  for (final opening in kBuiltInEcoLibrary) {
    final sequence = opening.moveSequence;
    if (sequence.isEmpty || sequence.length > line.length) continue;

    var matches = true;
    for (var i = 0; i < sequence.length; i++) {
      if (sequence[i].trim().toLowerCase() != line[i]) {
        matches = false;
        break;
      }
    }
    if (matches &&
        (best == null || sequence.length > best.moveSequence.length)) {
      best = opening;
    }
  }

  return best;
}

/// Adds a locally recognized ECO to a board snapshot only when its PGN does
/// not already carry a meaningful ECO value.
Map<String, dynamic> metadataWithRecognizedBoardEco({
  required Map<String, dynamic> metadata,
  required String startingFen,
  required List<String> movesUci,
}) {
  final result = Map<String, dynamic>.from(metadata);
  final existing = result['ECO']?.toString().trim() ?? '';
  if (existing.isNotEmpty && !RegExp(r'^\?+$').hasMatch(existing)) {
    return result;
  }

  final recognized = recognizedEcoForBoardLine(
    startingFen: startingFen,
    movesUci: movesUci,
  );
  if (recognized == null) {
    result.remove('ECO');
  } else {
    result['ECO'] = recognized.eco;
  }
  return result;
}
