// The local SQLite driver: package:sqlite3 over FFI with worker isolates on
// desktop, and over WebAssembly in the browser build. Both expose the same
// Database / Transaction surface and share local_sqlite_types.dart.
export 'package:chessever/desktop/services/local_sqlite/local_sqlite_native.dart'
    if (dart.library.js_interop) 'package:chessever/web/shims/local_sqlite_web.dart';
