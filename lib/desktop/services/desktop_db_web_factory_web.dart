import 'package:sqflite/sqflite.dart' show DatabaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// sqlite3.wasm in a shared worker, persisted to IndexedDB. The worker
/// (`sqflite_sw.js`) and `sqlite3.wasm` are placed next to index.html by
/// scripts/build_web.sh.
DatabaseFactory webDatabaseFactory() => databaseFactoryFfiWeb;
