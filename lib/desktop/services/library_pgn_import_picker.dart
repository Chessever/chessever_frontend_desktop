import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/library_import_buffer.dart';
import 'package:chessever/utils/pgn_multi_parser.dart';

/// Picks PGN files from disk and stages them in the Library import preview.
///
/// This is the desktop Library intake path for local databases: users pick PGN
/// files explicitly from the Library import action instead of browsing an
/// entire local folder tree.
Future<bool> pickAndStageLibraryPgnImport(
  WidgetRef ref, {
  String? suggestedFolderId,
}) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import PGN',
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
    allowMultiple: true,
    withData: false,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return false;

  final games = <ParsedPgnEntry>[];
  final labels = <String>[];
  for (final picked in result.files) {
    final path = picked.path;
    if (path == null || path.isEmpty) continue;
    final text = await File(path).readAsString();
    final parsed = parsePgnsToChessGames(text);
    if (parsed.isEmpty) continue;
    games.addAll(parsed);
    labels.add(_fileName(path));
  }

  if (games.isEmpty) return false;

  ref
      .read(libraryImportBufferProvider.notifier)
      .accept(
        games: games.map((e) => e.chessGame).toList(),
        sourceLabel: _sourceLabel(labels),
        suggestedFolderId: suggestedFolderId,
      );
  return true;
}

String _sourceLabel(List<String> labels) {
  if (labels.isEmpty) return 'PGN import';
  if (labels.length == 1) return labels.single;
  return '${labels.length} PGN files';
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}
