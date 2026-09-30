import 'package:dartchess/dartchess.dart';

/// Converts a UCI principal variation to numbered SAN in a worker isolate.
/// Only strings cross the isolate boundary; board positions stay in the worker.
List<String> formatEnginePvSanLine(Map<String, String> input) {
  final fen = input['fen'] ?? '';
  final moves = (input['moves'] ?? '')
      .split(RegExp(r'\s+'))
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
  try {
    Position cursor = Chess.fromSetup(Setup.parseFen(fen));
    final parts = fen.trim().split(RegExp(r'\s+'));
    var fullMove = parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
    var whiteToMove = parts.length >= 2 ? parts[1] == 'w' : true;
    final labels = <String>[];
    for (final uci in moves) {
      final move = Move.parse(uci);
      if (move == null || !cursor.isLegal(move)) break;
      final san = cursor.makeSan(move).$2;
      labels.add(
        whiteToMove
            ? '$fullMove.$san'
            : labels.isEmpty
            ? '$fullMove…$san'
            : san,
      );
      cursor = cursor.playUnchecked(move);
      if (!whiteToMove) fullMove += 1;
      whiteToMove = !whiteToMove;
    }
    return labels;
  } catch (_) {
    return moves;
  }
}
