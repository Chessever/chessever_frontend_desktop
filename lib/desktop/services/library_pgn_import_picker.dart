import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/local_chess_library.dart';

/// Picks PGN files from the Library Import action and opens them as a local
/// desktop database.
///
/// The Library import button is the user's local-PGN database entry point: it
/// should not stage games in the temporary "Import preview" buffer. The opened
/// PGN remains registered in My Databases through [LocalChessLibraryNotifier]
/// until the user explicitly removes it.
Future<String?> pickAndOpenLibraryPgnDatabase(WidgetRef ref) async {
  _libraryPgnPickerLog('picker start');
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import PGN',
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
    allowMultiple: true,
    withData: false,
    lockParentWindow: true,
  );
  _libraryPgnPickerLog('picker returned count=${result?.files.length}');
  if (result == null || result.files.isEmpty) return null;

  final paths = result.files
      .map((file) => file.path)
      .whereType<String>()
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  _libraryPgnPickerLog('picker paths=$paths');
  if (paths.isEmpty) return null;

  _libraryPgnPickerLog('open local database dispatch');
  final opened = await ref
      .read(localChessLibraryProvider.notifier)
      .openPaths(paths, sourceLabel: _sourceLabel(paths));
  _libraryPgnPickerLog('open local database returned opened=$opened');
  if (!opened) return null;
  final selected = ref.read(localChessLibraryProvider).selectedPath;
  _libraryPgnPickerLog('selectedPath=$selected');
  return selected;
}

String _sourceLabel(List<String> paths) {
  if (paths.isEmpty) return 'PGN import';
  if (paths.length == 1) return _fileName(paths.single);
  return '${paths.length} PGN files';
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}

void _libraryPgnPickerLog(String message) {
  stdout.writeln(
    '[LOCAL_PGN_PICKER ${DateTime.now().toIso8601String()}] $message',
  );
}
