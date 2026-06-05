import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/utils/pgn_multi_parser.dart';

@visibleForTesting
List<String> appendableLocalPgnParts(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const <String>[];
  return splitPgnGames(trimmed)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty && pgnHasMoves(part))
      .toList(growable: false);
}

Future<int> appendPgnTextToLocalChessFile({
  required String filePath,
  required String text,
}) async {
  final ext = p.extension(filePath).toLowerCase();
  if (ext != '.pgn') {
    throw ArgumentError('Local paste is only supported for PGN databases.');
  }

  final parts = appendableLocalPgnParts(text);
  if (parts.isEmpty) return 0;

  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('Local PGN file does not exist', filePath);
  }

  final existingLength = await file.length();
  final prefix = existingLength > 0 ? '\n\n' : '';
  await file.writeAsString(
    '$prefix${parts.join('\n\n')}\n',
    mode: FileMode.append,
    flush: true,
  );
  return parts.length;
}
