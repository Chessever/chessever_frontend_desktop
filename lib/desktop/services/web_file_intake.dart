import 'dart:io' as io;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/web/browser_file_picker.dart';
import 'package:chessever/web/linked_files.dart';
import 'package:chessever/web/picked_web_file.dart';

/// Copies a browser file selection into app storage. A classic ChessBase
/// selection includes the index and its companions and opens as one database.
Future<List<String>?> pickWebChessFilesIntoAppStorage({
  String dialogTitle = 'Open chess files',
  List<String> allowedExtensions = const ['pgn'],
  bool allowMultiple = true,
}) async {
  final extensions = [
    ...allowedExtensions,
    if (allowedExtensions.contains('cbh'))
      for (final companion in CbhIndexReader.companionExtensions)
        companion.substring(1),
  ];
  final picked =
      linkedFilesSupported
          ? await pickLinkedChessFiles(
            allowedExtensions: extensions,
            allowMultiple: allowMultiple,
          )
          : await pickWebFiles(
            allowedExtensions: extensions,
            allowMultiple: allowMultiple,
            label: dialogTitle,
          );
  if (picked == null) return null;
  final files =
      picked.where((file) {
        final extension = p.posix.extension(file.relativePath).toLowerCase();
        return extension.isNotEmpty &&
            extensions.contains(extension.substring(1));
      }).toList();
  if (files.isEmpty) throw ArgumentError('Choose a supported chess file.');
  final imported = await _copySelection(files);
  return imported.databasePaths;
}

/// Copies a picked folder and preserves its subdirectories so the CBH reader
/// resolves companions beside the index even when databases share a name.
Future<({String directory, List<String> databasePaths})?>
pickWebChessFolderIntoAppStorage() async {
  final files = await pickWebFolder(accept: _isImportMember);
  if (files == null || files.isEmpty) return null;
  final imported = await _copySelection(files);
  final top = files.first.relativePath.split('/');
  return (
    directory:
        top.length > 1 ? p.posix.join(imported.root, top.first) : imported.root,
    databasePaths: imported.databasePaths,
  );
}

/// Copies dropped files and folders into app storage and returns the paths of
/// each database. CBH companions stay beside the index for conversion.
Future<List<String>> copyDroppedChessFilesIntoAppStorage(
  Iterable<DropItem> dropped,
) async {
  final files = <PickedWebFile>[];
  void collect(Iterable<DropItem> items, String directory) {
    for (final item in items) {
      final relative = p.posix.join(directory, item.name);
      if (item is DropItemDirectory) {
        collect(item.children, relative);
      } else if (_isImportMember(relative)) {
        files.add(
          PickedWebFile(relativePath: relative, readAsBytes: item.readAsBytes),
        );
      }
    }
  }

  collect(dropped, '');
  if (files.isEmpty) return const [];
  final imported = await _copySelection(files);
  return imported.databasePaths;
}

bool _isCompanion(String path) => CbhIndexReader.companionExtensions.contains(
  p.posix.extension(path).toLowerCase(),
);

bool _isImportMember(String path) =>
    _isCompanion(path) || looksLikeLocalChessFile(path);

Future<({String root, List<String> databasePaths})> _copySelection(
  List<PickedWebFile> files,
) async {
  final cbhStems = {
    for (final file in files)
      if (file.relativePath.toLowerCase().endsWith('.cbh'))
        p.posix.withoutExtension(file.relativePath).toLowerCase(),
  };
  final names = <String>{};
  final toCopy = <PickedWebFile>[];
  for (final file in files) {
    final relative = file.relativePath;
    if (_isCompanion(relative) &&
        !cbhStems.contains(p.posix.withoutExtension(relative).toLowerCase())) {
      continue;
    }
    if (relative.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ArgumentError('The selection contains an invalid file path.');
    }
    if (!names.add(relative.toLowerCase())) {
      throw ArgumentError(
        'The selection contains duplicate filenames. Import the folders separately.',
      );
    }
    toCopy.add(file);
  }
  if (toCopy.isEmpty) {
    throw ArgumentError(
      'Select the .cbh and all six matching companion files together, '
      'or import a .cbv archive.',
    );
  }

  // A new selection gets its own directory. An earlier import can never
  // supply a missing companion or be overwritten by a same-named drop.
  final documents = await getApplicationDocumentsDirectory();
  final imports = await io.Directory(
    p.posix.join(documents.path, 'Imported PGN'),
  ).create(recursive: true);
  final root = await imports.createTemp('import-');
  final databasePaths = <String>[];
  final links = <String, void Function(String)>{};
  try {
    for (final file in toCopy) {
      final target = io.File(p.posix.join(root.path, file.relativePath));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await file.readAsBytes(), flush: true);
      if (!_isCompanion(file.relativePath)) databasePaths.add(target.path);
      if (file.linkTo case final link?) links[target.path] = link;
    }
  } catch (_) {
    await root.delete(recursive: true);
    rethrow;
  }
  links.forEach((path, link) => link(path));
  return (
    root: root.path,
    databasePaths: List<String>.unmodifiable(databasePaths),
  );
}
