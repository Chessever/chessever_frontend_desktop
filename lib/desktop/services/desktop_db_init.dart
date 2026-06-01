import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initializes sqflite for desktop platforms (macOS + Windows).
///
/// The mobile `sqflite` plugin only ships native libraries for Android and iOS.
/// On desktop we point the global `databaseFactory` at the FFI-backed
/// implementation so all existing `openDatabase` / `getDatabasesPath` calls
/// continue to work unchanged.
///
/// Call this once during startup, before any `AppDatabase.instance.database`
/// access. It is a no-op on mobile.
void initializeDesktopDatabaseFactory() {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
