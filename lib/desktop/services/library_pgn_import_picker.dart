import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/local_chess_library.dart';

/// Lets the user pick PGN files for the Library local-database import flow.
Future<List<String>?> pickLibraryPgnDatabasePaths() async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import PGN',
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
    allowMultiple: true,
    withData: false,
    lockParentWindow: true,
  );
  final paths = libraryPgnImportPathsFromResult(result);
  return paths.isEmpty ? null : paths;
}

/// Opens already-picked PGN files as a local desktop database.
///
/// The Library import button is the user's local-PGN database entry point: it
/// should not stage games in the temporary "Import preview" buffer. The opened
/// PGN remains registered in My Databases through [LocalChessLibraryNotifier]
/// until the user explicitly removes it.
Future<String?> openLibraryPgnDatabasePaths(
  WidgetRef ref,
  List<String> paths,
) async {
  if (paths.isEmpty) return null;
  final opened = await ref
      .read(localChessLibraryProvider.notifier)
      .openPaths(paths, sourceLabel: libraryPgnImportSourceLabel(paths));
  if (!opened) return null;
  return ref.read(localChessLibraryProvider).selectedPath;
}

/// Picks PGN files from the Library Import action and opens them as a local
/// desktop database.
Future<String?> pickAndOpenLibraryPgnDatabase(WidgetRef ref) async {
  final paths = await pickLibraryPgnDatabasePaths();
  if (paths == null) return null;
  return openLibraryPgnDatabasePaths(ref, paths);
}

@visibleForTesting
List<String> libraryPgnImportPathsFromResult(FilePickerResult? result) {
  if (result == null || result.files.isEmpty) return const <String>[];
  return result.files
      .map((file) => file.path)
      .whereType<String>()
      .where((path) => path.trim().isNotEmpty)
      .toList(growable: false);
}

@visibleForTesting
String libraryPgnImportSourceLabel(List<String> paths) {
  if (paths.isEmpty) return 'PGN import';
  if (paths.length == 1) {
    return _fileName(paths.single);
  }
  return '${paths.length} PGN files';
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}
