import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

const kPositionGameNotationPlies = 40;

/// A row's displayed notation and hover positions, prepared before rendering.
/// Only the displayed prefix is retained; the full continuation stays with
/// the games table for keyboard navigation and autoplay.
@immutable
class PositionGameNotation {
  const PositionGameNotation._({
    required this.startingFen,
    required this.continuation,
    required this.tokens,
    required this.positions,
  });

  factory PositionGameNotation.fromLine(String fen, List<String> ucis) {
    final prefix = List<String>.unmodifiable(
      ucis.take(kPositionGameNotationPlies),
    );
    final replay = _replayLine(fen, prefix, capturePositions: true);
    return PositionGameNotation._(
      startingFen: fen,
      continuation: prefix,
      tokens: replay.tokens,
      positions: replay.positions,
    );
  }

  final String startingFen;
  final List<String> continuation;
  final List<String> tokens;

  /// Starting position followed by the position after each valid token.
  final List<String> positions;

  bool matches(String fen, List<String> ucis) {
    if (fen != startingFen ||
        continuation.length !=
            ucis.length.clamp(0, kPositionGameNotationPlies)) {
      return false;
    }
    for (var i = 0; i < continuation.length; i++) {
      if (continuation[i] != ucis[i]) return false;
    }
    return true;
  }
}

/// One worker per page, rather than replaying every newly mounted row during
/// a frame. Inputs contain only the FEN and capped UCI lines, never UI state.
Future<List<PositionGameNotation>> preparePositionGameNotations(
  String fen,
  List<List<String>> continuations,
) {
  if (continuations.isEmpty) return Future.value(const []);
  return compute(_prepareBatch, (
    fen: fen,
    continuations: [
      for (final line in continuations)
        line.take(kPositionGameNotationPlies).toList(growable: false),
    ],
  ), debugLabel: 'position-games-notation');
}

List<PositionGameNotation> _prepareBatch(
  ({String fen, List<List<String>> continuations}) request,
) => [
  for (final line in request.continuations)
    PositionGameNotation.fromLine(request.fen, line),
];

/// SAN with move numbers, including a black-to-move first ply (8…Bc5).
/// Unlike table previews, title/line callers can format an uncapped line.
List<String> positionGameSanTokens(String fen, List<String> ucis) =>
    _replayLine(fen, ucis).tokens;

({List<String> tokens, List<String> positions}) _replayLine(
  String fen,
  List<String> ucis, {
  bool capturePositions = false,
}) {
  final positions = <String>[if (capturePositions) fen];
  Position position;
  try {
    position = Chess.fromSetup(
      Setup.parseFen(fen),
      ignoreImpossibleCheck: true,
    );
  } catch (_) {
    return (tokens: const [], positions: List.unmodifiable(positions));
  }

  final tokens = <String>[];
  var fullMove = position.fullmoves;
  var whiteToMove = position.turn == Side.white;
  for (final uci in ucis) {
    final move = Move.parse(uci);
    if (move == null) break;
    late final (Position, String) made;
    try {
      made = position.makeSan(move);
    } catch (_) {
      break;
    }
    final (next, san) = made;
    tokens.add(
      whiteToMove
          ? '$fullMove.$san'
          : (tokens.isEmpty ? '$fullMove…$san' : san),
    );
    position = next;
    if (capturePositions) positions.add(next.fen);
    if (!whiteToMove) fullMove += 1;
    whiteToMove = !whiteToMove;
  }
  return (
    tokens: List<String>.unmodifiable(tokens),
    positions: List<String>.unmodifiable(positions),
  );
}
