import 'dart:io';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

class LocalLibraryGameUpdateTarget {
  const LocalLibraryGameUpdateTarget({
    required this.sourcePath,
    required this.indexInFile,
    required this.fileGameCount,
  });

  final String sourcePath;
  final int indexInFile;
  final int fileGameCount;
}

class LocalLibraryGameUpdateOutcome {
  const LocalLibraryGameUpdateOutcome({required this.sourcePath});

  final String sourcePath;
}

Future<LocalLibraryGameUpdateOutcome> updateLocalLibraryPgnGame({
  required LocalLibraryGameUpdateTarget target,
  required ChessGame game,
}) async {
  final path = target.sourcePath.trim();
  if (!isLocalLibraryPgnUpdateSupported(path)) {
    throw UnsupportedError('Only PGN files can be updated in place.');
  }
  final nextPgn = exportGameToPgn(game).trim();
  if (nextPgn.isEmpty) {
    throw ArgumentError('Cannot update the source file with an empty PGN.');
  }

  final file = File(path);
  final text = await file.readAsString();
  final ranges = pgnGameRanges(text);
  if (target.fileGameCount > 0 && ranges.length != target.fileGameCount) {
    throw StateError(
      'The source PGN changed since this game was opened. '
      'Expected ${target.fileGameCount} games, found ${ranges.length}.',
    );
  }

  final index = target.indexInFile;
  if (index < 0 || index >= ranges.length) {
    throw RangeError.index(
      index,
      ranges,
      'indexInFile',
      'The original game was not found in the source PGN file.',
    );
  }

  final range = ranges[index];
  final before = text.substring(0, range.start).trimRight();
  final after = text.substring(range.end).trimLeft();
  final buffer = StringBuffer();
  if (before.isNotEmpty) {
    buffer.write(before);
    buffer.write('\n\n');
  }
  buffer.write(nextPgn);
  if (after.isNotEmpty) {
    buffer.write('\n\n');
    buffer.write(after);
  }
  buffer.write('\n');
  await file.writeAsString(buffer.toString(), flush: true);
  return LocalLibraryGameUpdateOutcome(sourcePath: path);
}

bool isLocalLibraryPgnUpdateSupported(String path) {
  return path.trim().toLowerCase().endsWith('.pgn');
}

List<PgnGameRange> pgnGameRanges(String text) {
  final headerMatches = RegExp(
    r'^[ \t]*\[[A-Za-z0-9_]+\s+"',
    multiLine: true,
  ).allMatches(text).toList(growable: false);
  if (headerMatches.isEmpty) {
    return const <PgnGameRange>[];
  }

  final starts = <int>[];
  for (var i = 0; i < headerMatches.length; i++) {
    final match = headerMatches[i];
    final start = match.start;
    if (starts.isEmpty) {
      starts.add(start);
      continue;
    }
    final previousHeaderEnd = _lineEnd(text, headerMatches[i - 1].end);
    final between = text.substring(previousHeaderEnd, start);
    if (between.trim().isNotEmpty) {
      starts.add(start);
    }
  }

  return [
    for (var i = 0; i < starts.length; i++)
      PgnGameRange(
        starts[i],
        i + 1 < starts.length ? starts[i + 1] : text.length,
      ),
  ];
}

int _lineEnd(String text, int offset) {
  final newline = text.indexOf('\n', offset);
  return newline == -1 ? text.length : newline + 1;
}

class PgnGameRange {
  const PgnGameRange(this.start, this.end);

  final int start;
  final int end;
}
