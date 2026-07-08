import 'dart:io';

import 'package:path/path.dart' as p;

/// Deletes a local chess source path from disk.
///
/// File and `.pgn` symlink paths remove only that entity. Directory paths remove
/// PGN files under the folder and then prune any directories left empty by that
/// removal. Missing paths are treated as already deleted.
Future<bool> deleteLocalSourcePath(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return false;

  final type = await FileSystemEntity.type(trimmed, followLinks: false);
  switch (type) {
    case FileSystemEntityType.notFound:
      return false;
    case FileSystemEntityType.file:
      await File(trimmed).delete();
      return true;
    case FileSystemEntityType.directory:
      return _deletePgnFilesAndEmptyFolders(Directory(trimmed));
    case FileSystemEntityType.link:
      if (p.extension(trimmed).toLowerCase() != '.pgn') return false;
      await Link(trimmed).delete();
      return true;
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      await File(trimmed).delete();
      return true;
  }
  return false;
}

Future<bool> _deletePgnFilesAndEmptyFolders(Directory directory) async {
  if (!await directory.exists()) return false;
  var deleted = false;

  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        break;
      case FileSystemEntityType.file:
        if (p.extension(entity.path).toLowerCase() != '.pgn') break;
        await File(entity.path).delete();
        deleted = true;
        break;
      case FileSystemEntityType.directory:
        deleted =
            await _deletePgnFilesAndEmptyFolders(Directory(entity.path)) ||
            deleted;
        break;
      case FileSystemEntityType.link:
        if (p.extension(entity.path).toLowerCase() != '.pgn') break;
        await Link(entity.path).delete();
        deleted = true;
        break;
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        if (p.extension(entity.path).toLowerCase() != '.pgn') break;
        await File(entity.path).delete();
        deleted = true;
        break;
    }
  }

  if (await _directoryIsEmpty(directory)) {
    await directory.delete();
    return true;
  }
  return deleted;
}

Future<bool> _directoryIsEmpty(Directory directory) async {
  await for (final _ in directory.list(followLinks: false)) {
    return false;
  }
  return true;
}
