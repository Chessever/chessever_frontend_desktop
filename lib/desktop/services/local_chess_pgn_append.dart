import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/utils/pgn_multi_parser.dart';

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
  _assertLocalPgnPath(filePath, action: 'Local paste');

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

Future<int> removeLocalPgnGamesFromFile({
  required String filePath,
  required Set<int> indexesInFile,
}) async {
  _assertLocalPgnPath(filePath, action: 'Local delete');
  if (indexesInFile.isEmpty) return 0;

  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('Local PGN file does not exist', filePath);
  }

  final parts = splitPgnGames((await file.readAsString()).trim())
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return 0;

  final kept = <String>[];
  var removed = 0;
  for (var i = 0; i < parts.length; i++) {
    if (indexesInFile.contains(i)) {
      removed++;
      continue;
    }
    kept.add(parts[i]);
  }
  if (removed == 0) return 0;

  final nextText = kept.isEmpty ? '' : '${kept.join('\n\n')}\n';
  await file.writeAsString(nextText, flush: true);
  return removed;
}

void _assertLocalPgnPath(String filePath, {required String action}) {
  final ext = p.extension(filePath).toLowerCase();
  if (ext != '.pgn') {
    throw ArgumentError('$action is only supported for PGN databases.');
  }
}
