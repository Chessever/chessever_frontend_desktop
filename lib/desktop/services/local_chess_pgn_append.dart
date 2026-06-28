import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/utils/pgn_multi_parser.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';

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
  Set<String>? existingFingerprints,
}) async {
  final result = await _appendPgnTextToLocalChessFile(
    filePath: filePath,
    text: text,
    existingFingerprints: existingFingerprints,
  );
  return result.count;
}

Future<_AppendLocalPgnResult> _appendPgnTextToLocalChessFile({
  required String filePath,
  required String text,
  Set<String>? existingFingerprints,
}) async {
  return _appendPgnPartsToLocalChessFile(
    filePath: filePath,
    parts: appendableLocalPgnParts(text),
    existingFingerprints: existingFingerprints,
  );
}

Future<_AppendLocalPgnResult> _appendPgnPartsToLocalChessFile({
  required String filePath,
  required List<String> parts,
  Set<String>? existingFingerprints,
}) async {
  _assertLocalPgnPath(filePath, action: 'Local paste');

  if (parts.isEmpty) return const _AppendLocalPgnResult();

  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('Local PGN file does not exist', filePath);
  }

  final fingerprints = <String>{
    ...?existingFingerprints?.where((hash) => hash.trim().isNotEmpty),
  };
  if (existingFingerprints == null) {
    final existingText = (await file.readAsString()).trim();
    for (final part in splitPgnGames(existingText)) {
      final pgn = part.trim();
      if (pgn.isNotEmpty) fingerprints.add(localChessPgnFingerprint(pgn));
    }
  }

  final uniqueParts = <String>[];
  for (final part in parts) {
    if (fingerprints.add(localChessPgnFingerprint(part))) {
      uniqueParts.add(part);
    }
  }
  if (uniqueParts.isEmpty) return const _AppendLocalPgnResult();

  final existingLength = await file.length();
  final prefix = existingLength > 0 ? '\n\n' : '';
  final appended = <LocalChessAppendedPgn>[];
  var cursor = existingLength + utf8.encode(prefix).length;
  for (var i = 0; i < uniqueParts.length; i++) {
    if (i > 0) {
      cursor += 2;
    }
    final rawPgn = uniqueParts[i];
    final start = cursor;
    final end = start + utf8.encode(rawPgn).length;
    appended.add(
      LocalChessAppendedPgn(
        rawPgn: rawPgn,
        sourceByteStart: start,
        sourceByteEnd: end,
      ),
    );
    cursor = end;
  }
  await file.writeAsString(
    '$prefix${uniqueParts.join('\n\n')}\n',
    mode: FileMode.append,
    flush: true,
  );
  return _AppendLocalPgnResult(appended: appended);
}

Future<int> appendPgnTextToLocalChessDatabaseFile({
  required LocalChessDatabaseRepository repository,
  required String filePath,
  required String text,
  Set<String>? fallbackFingerprints,
}) async {
  final parts = appendableLocalPgnParts(text);
  if (parts.isEmpty) return 0;

  final candidateFingerprints = <String>{
    for (final part in parts) localChessPgnFingerprint(part),
  };
  final cachedFingerprints = await repository
      .localDatabaseMatchingPgnFingerprints(
        databasePath: filePath,
        fingerprints: candidateFingerprints,
      );
  final result = await _appendPgnPartsToLocalChessFile(
    filePath: filePath,
    parts: parts,
    existingFingerprints: cachedFingerprints ?? fallbackFingerprints,
  );
  if (result.appended.isNotEmpty && cachedFingerprints != null) {
    await repository.persistAppendedPgnGames(
      databasePath: filePath,
      appendedPgns: result.appended,
    );
  }
  return result.count;
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

Future<int> removeLocalPgnGamesFromDatabaseFile({
  required LocalChessDatabaseRepository repository,
  required String filePath,
  required Set<int> indexesInFile,
}) async {
  final removed = await repository.removeLocalPgnGames(
    databasePath: filePath,
    indexesInFile: indexesInFile,
  );
  if (removed != null) return removed;
  return removeLocalPgnGamesFromFile(
    filePath: filePath,
    indexesInFile: indexesInFile,
  );
}

void _assertLocalPgnPath(String filePath, {required String action}) {
  final ext = p.extension(filePath).toLowerCase();
  if (ext != '.pgn') {
    throw ArgumentError('$action is only supported for PGN databases.');
  }
}

class _AppendLocalPgnResult {
  const _AppendLocalPgnResult({
    this.appended = const <LocalChessAppendedPgn>[],
  });

  final List<LocalChessAppendedPgn> appended;

  int get count => appended.length;
}
