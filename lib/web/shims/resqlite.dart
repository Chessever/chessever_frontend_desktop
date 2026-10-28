// Native builds get the real binding; the web build gets a stand-in whose
// opens fail, since the browser cannot load the SQLite FFI library.
export 'package:resqlite/resqlite.dart'
    if (dart.library.js_interop) 'package:chessever/web/shims/resqlite_web.dart';
