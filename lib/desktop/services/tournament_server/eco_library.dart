import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

/// Built-in catalog of common ECO openings the user can select to lock a
/// tournament to. Each entry is a sequence of SAN-ish UCI moves that the
/// conductor seeds before turning the engines loose; the FEN is computed
/// once at startup so picking a line is cheap.
///
/// We keep this list short and well-known so it's manageable; a future pass
/// can read a fuller ECO map from disk. The ECO labels follow Hooper &
/// Whyld's classification.
final List<EcoOpeningSeed> kBuiltInEcoLibrary = _buildLibrary();

@visibleForTesting
List<EcoOpeningSeed> buildLibraryForTesting() => _buildLibrary();

List<EcoOpeningSeed> _buildLibrary() {
  return [
    _seed('C20', 'King\'s Pawn', ['e2e4']),
    _seed('C40', 'King\'s Knight Opening', ['e2e4', 'e7e5', 'g1f3']),
    _seed('C44', 'Scotch Game', ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'd2d4']),
    _seed('C45', 'Scotch — Mieses Variation',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'd2d4', 'e5d4', 'f3d4']),
    _seed('C50', 'Italian Game',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4']),
    _seed('C53', 'Italian — Giuoco Piano',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'f8c5', 'c2c3']),
    _seed('C60', 'Ruy Lopez', ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5']),
    _seed('C65', 'Ruy Lopez — Berlin Defense',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'g8f6']),
    _seed('C84', 'Ruy Lopez — Closed',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6', 'b5a4', 'g8f6',
          'e1g1', 'f8e7']),
    _seed('B00', 'King\'s Pawn — Various', ['e2e4', 'd7d6']),
    _seed('B01', 'Scandinavian', ['e2e4', 'd7d5']),
    _seed('B10', 'Caro-Kann', ['e2e4', 'c7c6']),
    _seed('B12', 'Caro-Kann — Advance',
        ['e2e4', 'c7c6', 'd2d4', 'd7d5', 'e4e5']),
    _seed('B20', 'Sicilian', ['e2e4', 'c7c5']),
    _seed('B40', 'Sicilian — Open',
        ['e2e4', 'c7c5', 'g1f3', 'e7e6']),
    _seed('B90', 'Sicilian — Najdorf',
        ['e2e4', 'c7c5', 'g1f3', 'd7d6', 'd2d4', 'c5d4', 'f3d4', 'g8f6',
          'b1c3', 'a7a6']),
    _seed('C00', 'French Defense', ['e2e4', 'e7e6']),
    _seed('C02', 'French — Advance',
        ['e2e4', 'e7e6', 'd2d4', 'd7d5', 'e4e5']),
    _seed('A04', 'Reti', ['g1f3']),
    _seed('A07', 'King\'s Indian Attack',
        ['g1f3', 'd7d5', 'g2g3']),
    _seed('A45', 'Queen\'s Pawn', ['d2d4', 'g8f6']),
    _seed('A48', 'Torre Attack',
        ['d2d4', 'g8f6', 'g1f3', 'g7g6', 'c1g5']),
    _seed('D00', 'Queen\'s Pawn — Closed', ['d2d4', 'd7d5']),
    _seed('D02', 'Queen\'s Pawn — London',
        ['d2d4', 'd7d5', 'g1f3', 'g8f6', 'c1f4']),
    _seed('D30', 'Queen\'s Gambit Declined',
        ['d2d4', 'd7d5', 'c2c4', 'e7e6']),
    _seed('D80', 'Grünfeld',
        ['d2d4', 'g8f6', 'c2c4', 'g7g6', 'b1c3', 'd7d5']),
    _seed('E00', 'Queen\'s Pawn — Indian Game',
        ['d2d4', 'g8f6', 'c2c4']),
    _seed('E60', 'King\'s Indian Defense',
        ['d2d4', 'g8f6', 'c2c4', 'g7g6']),
    _seed('E70', 'King\'s Indian — Main Line',
        ['d2d4', 'g8f6', 'c2c4', 'g7g6', 'b1c3', 'f8g7', 'e2e4']),
  ];
}

EcoOpeningSeed _seed(String eco, String label, List<String> moves) {
  var pos = Chess.initial;
  for (final uci in moves) {
    final m = NormalMove.fromUci(uci);
    pos = pos.play(m) as Chess;
  }
  return EcoOpeningSeed(
    eco: eco,
    label: '$eco — $label',
    fen: pos.fen,
    moveSequence: moves,
  );
}
