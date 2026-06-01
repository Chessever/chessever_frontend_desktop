import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/pgn_multi_parser.dart' show splitPgnGames;

@immutable
class BoardEditorPgnImportEntry {
  const BoardEditorPgnImportEntry({
    required this.game,
    required this.rawPgn,
    required this.sourceLabel,
    this.sourcePath,
    this.sourceRelativePath,
  });

  final ChessGame game;
  final String rawPgn;
  final String sourceLabel;
  final String? sourcePath;
  final String? sourceRelativePath;
}

@immutable
class BoardEditorPgnImportResult {
  const BoardEditorPgnImportResult({
    required this.sourceLabel,
    required this.entries,
    this.recognizedFileCount = 0,
    this.unplayableFileCount = 0,
    this.legacyDatabaseShellCount = 0,
  });

  final String sourceLabel;
  final List<BoardEditorPgnImportEntry> entries;
  final int recognizedFileCount;
  final int unplayableFileCount;
  final int legacyDatabaseShellCount;

  bool get hasEntries => entries.isNotEmpty;
}

BoardEditorPgnImportResult parseBoardEditorPgnText(
  String text, {
  required String sourceLabel,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return BoardEditorPgnImportResult(
      sourceLabel: sourceLabel,
      entries: const <BoardEditorPgnImportEntry>[],
    );
  }

  final rawPgns = splitPgnGames(trimmed);
  final entries = <BoardEditorPgnImportEntry>[];
  for (var i = 0; i < rawPgns.length; i++) {
    final rawPgn = rawPgns[i];
    try {
      final game = ChessGame.fromPgn('editor_pgn_$i', rawPgn);
      entries.add(
        BoardEditorPgnImportEntry(
          game: game,
          rawPgn: rawPgn,
          sourceLabel: sourceLabel,
        ),
      );
    } catch (_) {
      // Skip unparseable entries so one bad PGN does not discard the batch.
    }
  }

  return BoardEditorPgnImportResult(sourceLabel: sourceLabel, entries: entries);
}

Future<BoardEditorPgnImportResult> scanBoardEditorLocalChessPaths(
  List<String> paths, {
  String? sourceLabel,
}) async {
  final source = await scanLocalChessPaths(paths, sourceLabel: sourceLabel);
  return BoardEditorPgnImportResult(
    sourceLabel: source.label,
    recognizedFileCount: source.root.fileCount,
    unplayableFileCount: source.root.unsupportedCount,
    legacyDatabaseShellCount: _countLegacyDatabaseShells(source.root),
    entries: [
      for (final game in source.games)
        BoardEditorPgnImportEntry(
          game: game.game,
          rawPgn: game.rawPgn,
          sourceLabel: source.label,
          sourcePath: game.sourcePath,
          sourceRelativePath: game.sourceRelativePath,
        ),
    ],
  );
}

int _countLegacyDatabaseShells(LocalChessNode node) {
  return switch (node) {
    LocalChessFolderNode(:final children) => children.fold<int>(
      0,
      (count, child) => count + _countLegacyDatabaseShells(child),
    ),
    LocalChessFileNode(:final status, :final extension)
        when status == LocalChessFileStatus.unsupported &&
            _legacyDatabaseShellExtensions.contains(extension.toLowerCase()) =>
      1,
    _ => 0,
  };
}

const _legacyDatabaseShellExtensions = <String>{'.cbv', '.cbf'};
