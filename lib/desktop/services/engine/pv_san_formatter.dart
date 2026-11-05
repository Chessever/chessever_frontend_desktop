import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Native formatting runs in an isolate. Browser formatting cooperatively
/// yields between small batches, since Flutter's web `compute` is synchronous
/// work on the same event loop that builds and paints the board.
Future<List<String>> formatEnginePvSanForDisplay(Map<String, String> input) =>
    kIsWeb
        ? formatEnginePvSanCooperatively(input)
        : compute(formatEnginePvSanLine, input);

/// Shares the same parser and prefix cache as the native formatter, but lets
/// pending input and frames run during a long principal variation.
Future<List<String>> formatEnginePvSanCooperatively(
  Map<String, String> input, {
  Duration workBudget = const Duration(milliseconds: 1),
}) async {
  final batches = _formatEnginePvSanSteps(input).iterator;
  var labels = const <String>[];
  final clock = Stopwatch()..start();
  while (batches.moveNext()) {
    labels = batches.current;
    if (clock.elapsed >= workBudget) {
      if (SchedulerBinding.instance.hasScheduledFrame) {
        await SchedulerBinding.instance.endOfFrame;
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      clock.reset();
    }
  }
  return labels;
}

/// Converts a UCI principal variation to numbered SAN in a worker isolate.
/// Only strings cross the isolate boundary; board positions stay in the worker.
///
/// In the browser `compute` runs on the UI thread, and the engine re-sends
/// each line a few times a second with only its tail changed. Recent lines are
/// kept with the position after every ply, so the next call replays only the
/// moves past the shared prefix. On native each `compute` gets a fresh
/// isolate, so the cache simply starts empty there.
List<String> formatEnginePvSanLine(Map<String, String> input) {
  return _formatEnginePvSanSteps(input).last;
}

Iterable<List<String>> _formatEnginePvSanSteps(
  Map<String, String> input,
) sync* {
  final fen = input['fen'] ?? '';
  final moves = (input['moves'] ?? '')
      .split(_whitespace)
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
  if (moves.isEmpty) {
    yield const <String>[];
    return;
  }
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
      // makeSan already plays the move. Reusing that position avoids a second
      // board copy and move application for every ply of every engine line.
      final (nextPosition, san) = cursor.makeSan(move);
      labels.add(
        whiteToMove
            ? '$fullMove.$san'
            : labels.isEmpty
            ? '$fullMove…$san'
            : san,
      );
      cursor = nextPosition;
      ucis.add(uci);
      positions.add(cursor);
      if (!whiteToMove) fullMove += 1;
      whiteToMove = !whiteToMove;
      yield labels;
    }

    _recentLines[key] = _FormattedPvLine(root, ucis, labels, positions);
    while (_recentLines.length > _recentLineLimit) {
      _recentLines.remove(_recentLines.keys.first);
    }
    yield List<String>.of(labels);
  } catch (_) {
    yield moves;
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
