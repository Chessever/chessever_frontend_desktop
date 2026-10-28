import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/repository/sqlite/app_database.dart';

/// The JSON documents Play keeps on this device (profile, games, rating
/// history, achievements), addressed by a relative path such as
/// `play_profile/profile.json`.
///
/// Desktop keeps them as files under the app support directory. The browser
/// build has no filesystem, so it keeps the same text in [AppDatabase]'s
/// key/value store (IndexedDB) under the same path.
class PlayLocalStore {
  const PlayLocalStore();

  static const String _webKeyPrefix = 'play_local:';

  Future<String?> read(String relativePath) async {
    if (kIsWeb) {
      return AppDatabase.instance.getString('$_webKeyPrefix$relativePath');
    }
    final file = await _file(relativePath);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<void> write(String relativePath, String contents) async {
    if (kIsWeb) {
      await AppDatabase.instance.setString(
        '$_webKeyPrefix$relativePath',
        contents,
      );
      return;
    }
    final file = await _file(relativePath);
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

  Future<File> _file(String relativePath) async {
    final support = await getApplicationSupportDirectory();
    return File(p.joinAll([support.path, ...relativePath.split('/')]));
  }
}
