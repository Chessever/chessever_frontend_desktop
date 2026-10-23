import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/desktop_db_web_factory.dart'
    if (dart.library.js_interop) 'package:chessever/desktop/services/desktop_db_web_factory_web.dart';
import 'package:chessever/utils/platform/io_platform.dart';

/// Initializes sqflite for desktop platforms (macOS + Windows).
///
/// The mobile `sqflite` plugin only ships native libraries for Android and iOS.
/// On desktop we point the global `databaseFactory` at the FFI-backed
/// implementation so all existing `openDatabase` / `getDatabasesPath` calls
/// continue to work unchanged. The browser build points it at sqlite3.wasm
/// instead.
///
/// Call this once during startup, before any `AppDatabase.instance.database`
/// access. It is a no-op on mobile.
void initializeDesktopDatabaseFactory() {
  if (kIsWeb) {
    databaseFactory = webDatabaseFactory();
    return;
  }
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
