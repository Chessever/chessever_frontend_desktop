import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_pointer.dart';
import 'package:dartchess/dartchess.dart' show Chess;

/// Presentation data only. Never replaces a stored clock or PGN comment.
class NotationMoveTiming {
  const NotationMoveTiming({
    this.elapsed,
    this.remaining,
    this.isRecorded = false,
  });

  final Duration? elapsed;
  final Duration? remaining;
  final bool isRecorded;

  String? get label => elapsed == null ? null : formatNotationElapsed(elapsed!);

  String get tooltip {
    if (elapsed == null) return '';
    final clock = remaining;
    return 'Time spent: ${label!}'
        '${clock == null ? '' : '\nTime remaining: ${_formatRemaining(clock)}'}';
  }
}

/// One linear tree traversal per game snapshot, shared by both notation layouts.
/// Keys are full notation pointers: sibling/nested clocks cannot leak across lines.
class NotationMoveTimingIndex {
  NotationMoveTimingIndex._(this._moves);

  final Map<String, NotationMoveTiming> _moves;

  NotationMoveTiming? at(List<int> pointer) =>
      _moves[NotationPointer.encode(pointer)];

  factory NotationMoveTimingIndex.fromGame(ChessGame game) {
    final periods = _storedTimeControl(
      game.metadata['TimeControl']?.toString(),
    );
    final moves = <String, NotationMoveTiming>{};
    final initialBase =
        game.startingFen == Chess.initial.fen && periods.isNotEmpty
            ? Duration(seconds: periods.first.seconds)
            : null;
    final seed = _ClockHistory(
      nextPly: _fenPly(game.startingFen),
      white: initialBase == null ? null : _ClockReading(0, initialBase),
      black: initialBase == null ? null : _ClockReading(0, initialBase),
    );

    void visit(ChessLine line, List<int> prefix, _ClockHistory initial) {
      var history = initial;
      for (var i = 0; i < line.length; i++) {
        final move = line[i];
        final pointer = <int>[...prefix, i];
        final ply = _movePly(move);
        // A broken sequence cannot borrow readings from an earlier position.
        final before =
            history.nextPly == ply ? history : _ClockHistory(nextPly: ply);
        final clock = _remainingClock(move);
        final remaining = clock.value;
        final recorded = _recordedElapsed(move.comments);
        Duration? elapsed;
        final nullMove = move.uci == '0000' || move.san == '--';
        if (!nullMove && ply >= 0) {
          if (recorded.seen) {
            elapsed = recorded.value;
          } else {
            final previous = before.reading(move.turn);
            final increment = _incrementAt(periods, move.num);
            if (clock.reliable &&
                remaining != null &&
                previous != null &&
                previous.moveNumber == move.num - 1 &&
                increment != null) {
              final candidate =
                  previous.clock + Duration(seconds: increment) - remaining;
              if (!candidate.isNegative) elapsed = candidate;
            }
          }
        }
        moves[NotationPointer.encode(pointer)] = NotationMoveTiming(
          elapsed: elapsed,
          remaining: remaining,
          isRecorded: !nullMove && recorded.seen && elapsed != null,
        );
        final after =
            nullMove || ply < 0
                ? _ClockHistory(nextPly: ply + 1)
                : before.after(
                  move,
                  clock.reliable ? remaining : null,
                  ply + 1,
                );
        final variations = move.variations ?? const <ChessLine>[];
        for (var v = 0; v < variations.length; v++) {
          final branch = variations[v];
          if (branch.isEmpty) continue;
          final headPly = _movePly(branch.first);
          // Imported children are alternatives to the NEXT move; root
          // alternatives and some edited trees attach to the SAME move.
          final fork =
              headPly == ply
                  ? before
                  : headPly == ply + 1
                  ? after
                  : _ClockHistory(nextPly: headPly);
          visit(branch, <int>[...pointer, v], fork);
        }
        history = after;
      }
    }

    visit(game.mainline, const [], seed);
    return NotationMoveTimingIndex._(Map.unmodifiable(moves));
  }
}

class _ClockReading {
  const _ClockReading(this.moveNumber, this.clock);
  final int moveNumber;
  final Duration clock;
}

class _ClockHistory {
  const _ClockHistory({required this.nextPly, this.white, this.black});
  final int? nextPly;
  final _ClockReading? white;
  final _ClockReading? black;

  _ClockReading? reading(ChessColor color) =>
      color == ChessColor.white ? white : black;

  _ClockHistory after(ChessMove move, Duration? clock, int nextPly) {
    // A missing clock clears this player's reading; never bridge a gap.
    final next = clock == null ? null : _ClockReading(move.num, clock);
    return _ClockHistory(
      nextPly: nextPly,
      white: move.turn == ChessColor.white ? next : white,
      black: move.turn == ChessColor.black ? next : black,
    );
  }
}

int _movePly(ChessMove move) =>
    (move.num - 1) * 2 + (move.turn == ChessColor.black ? 1 : 0);

int? _fenPly(String fen) {
  final fields = fen.trim().split(RegExp(r'\s+'));
  if (fields.length != 6 || (fields[1] != 'w' && fields[1] != 'b')) return null;
  final fullmove = int.tryParse(fields[5]);
  return fullmove == null || fullmove < 1
      ? null
      : (fullmove - 1) * 2 + (fields[1] == 'b' ? 1 : 0);
}

final _emtStart = RegExp(r'\[%emt\b', caseSensitive: false);
final _emtDirective = RegExp(r'\[%emt\b([^\]]*)\]', caseSensitive: false);
final _clkStart = RegExp(r'\[%clk\b', caseSensitive: false);
final _clkDirective = RegExp(r'\[%clk\s+([^\]]+)\]', caseSensitive: false);

({bool seen, Duration? value}) _recordedElapsed(List<String>? comments) {
  var seen = false;
  Duration? result;
  for (final comment in comments ?? const <String>[]) {
    final starts = _emtStart.allMatches(comment).length;
    if (starts == 0) continue;
    seen = true;
    final matches = _emtDirective.allMatches(comment).toList();
    if (starts != matches.length) return (seen: true, value: null);
    for (final match in matches) {
      final parsed = _parseClock(match.group(1), allowTwoParts: false);
      if (parsed == null || (result != null && result != parsed)) {
        return (seen: true, value: null);
      }
      result = parsed;
    }
  }
  return (seen: seen, value: result);
}

({Duration? value, bool reliable}) _remainingClock(ChessMove move) {
  final field = _parseClock(move.clockTime);
  if (field == null) return (value: null, reliable: false);
  // The existing model drops fractional [%clk] seconds. Recover display-only
  // precision only when the raw annotation agrees with its authoritative field.
  Duration? raw;
  for (final comment in move.comments ?? const <String>[]) {
    final matches = _clkDirective.allMatches(comment).toList();
    if (_clkStart.allMatches(comment).length != matches.length) {
      return (value: field, reliable: false);
    }
    for (final match in matches) {
      final value = _parseClock(match.group(1));
      if (value == null || (raw != null && raw != value)) {
        return (value: field, reliable: false);
      }
      raw = value;
    }
  }
  // Explicit fractional model edits win over an older raw annotation. A
  // whole-second parser field may recover precision from one consistent clock.
  final refine =
      !move.clockTime!.contains('.') && raw?.inSeconds == field.inSeconds;
  return (value: refine ? raw : field, reliable: true);
}

Duration? _parseClock(String? value, {bool allowTwoParts = true}) {
  if (value == null) return null;
  final parts = value.trim().split(':');
  if (parts.length != 3 && !(allowTwoParts && parts.length == 2)) return null;
  final secondsMatch = RegExp(
    r'^([0-5]?\d)(?:\.(\d{1,6}))?$',
  ).firstMatch(parts.last);
  if (secondsMatch == null) return null;
  final minutes = int.tryParse(parts[parts.length - 2]);
  final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
  if (minutes == null ||
      minutes < 0 ||
      (parts.length == 3 && minutes >= 60) ||
      hours == null ||
      hours < 0 ||
      hours > 999999 ||
      minutes > 59999999 ||
      !RegExp(r'^\d+$').hasMatch(parts[parts.length - 2]) ||
      !RegExp(r'^\d+$').hasMatch(parts.first)) {
    return null;
  }
  final fraction = secondsMatch.group(2) ?? '';
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: int.parse(secondsMatch.group(1)!),
    microseconds: fraction.isEmpty ? 0 : int.parse(fraction.padRight(6, '0')),
  );
}

class _TimingPeriod {
  const _TimingPeriod(this.seconds, this.moves, this.increment);
  final int seconds;
  final int? moves;
  final int increment;
}

List<_TimingPeriod> _storedTimeControl(String? value) {
  // This is the actual PGN machine header, NOT a human minutes shorthand.
  // In particular 60+2 means sixty seconds, never sixty minutes. Do not call
  // the permissive tournament-description parser here or rewrite the header.
  if (value == null || value.trim().isEmpty) return const [];
  final result = <_TimingPeriod>[];
  final fields = value.trim().split(':');
  final grammar = RegExp(r'^(\d+)(?:/(\d+))?(?:\+(\d+))?$');
  for (var i = 0; i < fields.length; i++) {
    final match = grammar.firstMatch(fields[i].trim());
    if (match == null) return const [];
    final moves = match.group(2) == null ? null : int.tryParse(match.group(1)!);
    final seconds = int.tryParse(match.group(2) ?? match.group(1)!);
    final increment = int.tryParse(match.group(3) ?? '0');
    if (seconds == null ||
        increment == null ||
        seconds > 3153600000 ||
        increment > 3153600000 ||
        (match.group(2) != null && (moves == null || moves <= 0)) ||
        (i < fields.length - 1 && moves == null)) {
      return const [];
    }
    result.add(_TimingPeriod(seconds, moves, increment));
  }
  return result;
}

int? _incrementAt(List<_TimingPeriod> periods, int moveNumber) {
  if (periods.isEmpty || moveNumber < 1) return null;
  var passed = 0;
  for (var i = 0; i < periods.length; i++) {
    final period = periods[i];
    final count = period.moves;
    if (count == null) {
      // Broadcasters may credit a new period on the boundary move or the
      // following one. Omit both rather than fabricate a huge elapsed time.
      if (passed > 0 && moveNumber == passed + 1) return null;
      return period.increment;
    }
    if (i == periods.length - 1) {
      final relative = (moveNumber - passed - 1) % count + 1;
      if (relative == count ||
          ((passed > 0 || moveNumber > count) && relative == 1)) {
        return null;
      }
      return period.increment;
    }
    final end = passed + count;
    if (moveNumber <= end) {
      if (moveNumber == end || (passed > 0 && moveNumber == passed + 1)) {
        return null;
      }
      return period.increment;
    }
    passed = end;
  }
  return null;
}

/// Explicit units distinguish elapsed time from the board's remaining clocks.
String formatNotationElapsed(Duration elapsed) {
  if (elapsed.isNegative) throw ArgumentError.value(elapsed, 'elapsed');
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes % 60;
  final micros = elapsed.inMicroseconds % Duration.microsecondsPerMinute;
  final seconds = (micros ~/ Duration.microsecondsPerSecond).toString();
  final fraction = (micros % Duration.microsecondsPerSecond)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final secondsText = fraction.isEmpty ? seconds : '$seconds.$fraction';
  return '${hours == 0 ? '' : '${hours}h'}${minutes == 0 ? '' : '${minutes}m'}'
      '${micros == 0 && (hours > 0 || minutes > 0) ? '' : '${secondsText}s'}';
}

String _formatRemaining(Duration value) {
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  final fraction = (value.inMicroseconds % Duration.microsecondsPerSecond)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final tail = fraction.isEmpty ? seconds : '$seconds.$fraction';
  return value.inHours > 0
      ? '${value.inHours}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:$tail'
      : '${value.inMinutes}:$tail';
}
