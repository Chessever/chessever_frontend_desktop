import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/auth/web_pgn_access.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/web_file_intake.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/web_cbh_missing_files_dialog.dart';

/// Lets the user pick chess databases for the Library's local import flow.
Future<List<String>?> pickLibraryPgnDatabasePathsWithRecovery(
  BuildContext context, {
  @visibleForTesting Future<List<String>?> Function()? pick,
}) async {
  final pickPaths = pick ?? pickLibraryPgnDatabasePaths;
  while (context.mounted) {
    try {
      return await pickPaths();
    } on WebCbhSelectionIncomplete catch (error) {
      if (!context.mounted) return null;
      final retry = await showWebCbhMissingFilesDialog(
        context,
        error.databases,
      );
      // Do not delay the next picker call: it needs the button's activation.
      if (retry != true) return null;
    }
  }
  return null;
}

Future<List<String>?> pickLibraryPgnDatabasePaths() async {
  const title = 'Import chess files';
  final extensions = [
    ...localChessPickerExtensions,
    if (CbhConversionService.isAvailable)
      ...CbhConversionService.pickerExtensions,
  ];
  if (kIsWeb) {
    return pickWebChessFilesIntoAppStorage(
      dialogTitle: title,
      allowedExtensions: extensions,
      requireCompleteCbh: true,
    );
  }
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: extensions,
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
  final context = ref.context;
  final opened = await ref
      .read(localChessLibraryProvider.notifier)
      .openPaths(paths, sourceLabel: libraryPgnImportSourceLabel(paths));
  if (!opened || !context.mounted) return null;
  return ref.read(localChessLibraryProvider).selectedPath;
}

/// Picks chess files from the Library Import action and opens them as a local
/// desktop database.
Future<String?> pickAndOpenLibraryPgnDatabase(
  WidgetRef ref, {
  void Function(String message)? onError,
}) async {
  final context = ref.context;
  if (!await ensureWebPgnAccess(context, importing: true) || !context.mounted) {
    return null;
  }
  try {
    final paths = await pickLibraryPgnDatabasePathsWithRecovery(context);
    if (paths == null || !context.mounted) return null;
    final path = await openLibraryPgnDatabasePaths(ref, paths);
    if (path == null && context.mounted) {
      final error = ref.read(localChessLibraryProvider).error;
      if (error != null) onError?.call(error);
    }
    return path;
  } catch (error) {
    if (context.mounted) onError?.call(localChessOpenErrorMessage(error));
    return null;
  }
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
  return localChessDatabaseDisplayNameForPaths(paths);
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}
