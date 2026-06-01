import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/library/utils/folder_pgn_exporter.dart';

/// Outcome of [exportFolderToDisk] surfaced to the calling UI so it can
/// render accurate desktop feedback (or stay silent on user cancel).
class LibraryExportResult {
  const LibraryExportResult({
    required this.cancelled,
    this.writtenFiles = const <String>[],
    this.totalGames = 0,
    this.error,
  });

  final bool cancelled;
  final List<String> writtenFiles;
  final int totalGames;
  final Object? error;

  bool get didWrite => !cancelled && error == null && writtenFiles.isNotEmpty;
}

/// Streams [folder] (and any direct children) into one or more PGN files
/// on disk. Mirrors the mobile `_handleExportPgn` flow but replaces the
/// `share_plus` share-sheet detour with a native macOS / Windows save
/// dialog (single-file export) or directory picker (tree export with
/// children).
///
/// Single-folder leaves -> one Save dialog -> one .pgn file.
/// Folder-with-children -> Directory picker -> N .pgn files (root +
/// each non-empty child) written under the chosen directory.
Future<LibraryExportResult> exportFolderToDisk({
  required LibraryRepository repo,
  required LibraryFolder folder,
  required List<LibraryFolder> childFolders,
  void Function(int processed, int total)? onProgress,
}) async {
  final hasChildren = childFolders.isNotEmpty;
  try {
    if (!hasChildren) {
      return await _exportSingle(
        repo: repo,
        folder: folder,
        onProgress: onProgress,
      );
    }
    return await _exportTree(
      repo: repo,
      folder: folder,
      childFolders: childFolders,
      onProgress: onProgress,
    );
  } catch (e) {
    return LibraryExportResult(cancelled: false, error: e);
  }
}

Future<LibraryExportResult> _exportSingle({
  required LibraryRepository repo,
  required LibraryFolder folder,
  void Function(int processed, int total)? onProgress,
}) async {
  final pgn = await exportFolderAsPgn(
    repo: repo,
    folderId: folder.id,
    folderName: folder.name,
    isSubscribed: folder.isSubscribed,
    shareToken: folder.shareToken,
    onProgress: onProgress,
  );
  if (pgn.trim().isEmpty) {
    return const LibraryExportResult(cancelled: false);
  }
  final defaultName = suggestedExportFilename(folder.name);
  final destination = await FilePicker.platform.saveFile(
    dialogTitle: 'Export "${folder.name}" as PGN',
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
  );
  if (destination == null) {
    return const LibraryExportResult(cancelled: true);
  }
  final outPath =
      destination.toLowerCase().endsWith('.pgn')
          ? destination
          : '$destination.pgn';
  await File(outPath).writeAsString(pgn, flush: true);
  return LibraryExportResult(
    cancelled: false,
    writtenFiles: [outPath],
    totalGames: _countGames(pgn),
  );
}

Future<LibraryExportResult> _exportTree({
  required LibraryRepository repo,
  required LibraryFolder folder,
  required List<LibraryFolder> childFolders,
  void Function(int processed, int total)? onProgress,
}) async {
  final files = await exportFolderTreeAsPgnFiles(
    repo: repo,
    rootFolder: folder,
    childFolders: childFolders,
    rootShareToken: folder.shareToken,
    onProgress: onProgress,
  );
  if (files.isEmpty) {
    return const LibraryExportResult(cancelled: false);
  }
  final destination = await FilePicker.platform.getDirectoryPath(
    dialogTitle: 'Choose a folder to export "${folder.name}"',
  );
  if (destination == null) {
    return const LibraryExportResult(cancelled: true);
  }

  final separator = Platform.isWindows ? '\\' : '/';
  final written = <String>[];
  var totalGames = 0;
  for (final entry in files) {
    final outPath = '$destination$separator${entry.filename}';
    await File(outPath).writeAsString(entry.pgn, flush: true);
    written.add(outPath);
    totalGames += entry.gameCount;
  }
  return LibraryExportResult(
    cancelled: false,
    writtenFiles: written,
    totalGames: totalGames,
  );
}

/// Cheap count of games in a serialized PGN blob — newline-prefixed
/// `[Event ` headers mark each game boundary. Only used for the success
/// toast copy ("Saved 24 games to …"); precision isn't critical.
int _countGames(String pgn) {
  return RegExp(r'^\[Event\s', multiLine: true).allMatches(pgn).length;
}

/// Writes a single [analysis] to disk as a one-game .pgn file via a native
/// Save dialog. Used by the games-table right-click menu so the user can
/// hand the game to another tool without entering the board view.
Future<LibraryExportResult> exportSingleAnalysisToDisk({
  required SavedAnalysis analysis,
}) async {
  try {
    final pgn = exportGameToPgn(analysis.chessGame).trim();
    if (pgn.isEmpty) {
      return const LibraryExportResult(cancelled: false);
    }
    final defaultName = suggestedExportFilename(
      analysis.title.isEmpty ? 'game' : analysis.title,
    );
    final destination = await FilePicker.platform.saveFile(
      dialogTitle: 'Export "${analysis.title}" as PGN',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: const ['pgn'],
    );
    if (destination == null) {
      return const LibraryExportResult(cancelled: true);
    }
    final outPath =
        destination.toLowerCase().endsWith('.pgn')
            ? destination
            : '$destination.pgn';
    await File(outPath).writeAsString(pgn, flush: true);
    return LibraryExportResult(
      cancelled: false,
      writtenFiles: [outPath],
      totalGames: 1,
    );
  } catch (e) {
    return LibraryExportResult(cancelled: false, error: e);
  }
}
