import 'dart:io' as io;
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/web/folder_picker.dart';

// Browsers hand over file contents, never paths. These copy what the user
// picks or drops into the app's browser filesystem (documents/Imported PGN)
// and return the paths there, so the desktop open flows run unchanged.

Future<io.Directory> _importRoot() async {
  final documents = await getApplicationDocumentsDirectory();
  final root = io.Directory(p.join(documents.path, 'Imported PGN'));
  await root.create(recursive: true);
  return root;
}

Future<String> _write(
  io.Directory root,
  String relativePath,
  Uint8List bytes,
) async {
  final segments = p.posix.split(relativePath);
  final target = io.File(p.joinAll([root.path, ...segments]));
  await target.parent.create(recursive: true);
  await target.writeAsBytes(bytes, flush: true);
  return target.path;
}

/// Picks chess files and returns their paths in app storage, or null when
/// the user cancels or picks nothing usable.
Future<List<String>?> pickWebChessFilesIntoAppStorage({
  String dialogTitle = 'Open chess files',
  List<String> allowedExtensions = const ['pgn'],
}) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final root = await _importRoot();
  final paths = <String>[
    for (final file in result.files)
      if (file.bytes != null)
        await _write(root, p.basename(file.name), file.bytes!),
  ];
  return paths.isEmpty ? null : paths;
}

/// Picks a folder and returns its copy in app storage (chess files only), or
/// null when the user cancels or the folder holds no chess files.
Future<String?> pickWebChessFolderIntoAppStorage() async {
  final files = await pickWebFolder(accept: looksLikeLocalChessFile);
  if (files == null || files.isEmpty) return null;
  final root = await _importRoot();
  for (final file in files) {
    await _write(root, file.relativePath, file.bytes);
  }
  final top = p.posix.split(files.first.relativePath);
  return top.length > 1 ? p.join(root.path, top.first) : root.path;
}

/// Copies the chess files among [dropped] (including those inside dropped
/// folders) into app storage and returns their paths.
Future<List<String>> copyDroppedChessFilesIntoAppStorage(
  Iterable<DropItem> dropped,
) async {
  final files = <DropItem>[];
  void collect(Iterable<DropItem> items) {
    for (final item in items) {
      if (item is DropItemDirectory) {
        collect(item.children);
      } else if (looksLikeLocalChessFile(item.name)) {
        files.add(item);
      }
    }
  }

  collect(dropped);
  if (files.isEmpty) return const <String>[];
  final root = await _importRoot();
  return List<String>.unmodifiable([
    for (final file in files)
      await _write(root, p.basename(file.name), await file.readAsBytes()),
  ]);
}
