import 'package:dartchess/dartchess.dart';

/// Converts a UCI principal variation to numbered SAN in a worker isolate.
/// Only strings cross the isolate boundary; board positions stay in the worker.
///
/// In the browser `compute` runs on the UI thread, and the engine re-sends
/// each line a few times a second with only its tail changed. Recent lines are
/// kept with the position after every ply, so the next call replays only the
/// moves past the shared prefix. On native each `compute` gets a fresh
/// isolate, so the cache simply starts empty there.
List<String> formatEnginePvSanLine(Map<String, String> input) {
  final fen = input['fen'] ?? '';
  final moves = (input['moves'] ?? '')
      .split(_whitespace)
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
  if (moves.isEmpty) return const <String>[];
  try {
    final key = '$fen\u0000${moves.first}';
    final cached = _recentLines.remove(key);
    final Position root = cached?.root ?? Chess.fromSetup(Setup.parseFen(fen));
    final parts = fen.trim().split(_whitespace);
    final rootFullMove = parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
    final rootWhiteToMove = parts.length >= 2 ? parts[1] == 'w' : true;

    var shared = 0;
    if (cached != null) {
      final limit =
          cached.ucis.length < moves.length ? cached.ucis.length : moves.length;
      while (shared < limit && cached.ucis[shared] == moves[shared]) {
        shared++;
      }
    }
    final ucis = <String>[...?cached?.ucis.take(shared)];
    final labels = <String>[...?cached?.labels.take(shared)];
    final positions = <Position>[...?cached?.positions.take(shared)];

    var cursor = shared == 0 ? root : positions[shared - 1];
    var fullMove = rootFullMove;
    var whiteToMove = rootWhiteToMove;
    for (var i = 0; i < shared; i++) {
      if (!whiteToMove) fullMove += 1;
      whiteToMove = !whiteToMove;
    }
    for (var i = shared; i < moves.length; i++) {
      final uci = moves[i];
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
      ucis.add(uci);
      positions.add(cursor);
      if (!whiteToMove) fullMove += 1;
      whiteToMove = !whiteToMove;
    }

    _recentLines[key] = _FormattedPvLine(root, ucis, labels, positions);
    while (_recentLines.length > _recentLineLimit) {
      _recentLines.remove(_recentLines.keys.first);
    }
    return List<String>.of(labels);
  } catch (_) {
    return moves;
  }
}

final _whitespace = RegExp(r'\s+');

/// A few positions' worth of MultiPV lines; insertion order is recency.
const _recentLineLimit = 24;
final _recentLines = <String, _FormattedPvLine>{};

class _FormattedPvLine {
  const _FormattedPvLine(this.root, this.ucis, this.labels, this.positions);

  final Position root;
  final List<String> ucis;
  final List<String> labels;
  final List<Position> positions;
}
