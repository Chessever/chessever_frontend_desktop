// `package:resqlite` is FFI-only, and the web build cannot import `dart:ffi`.
// Local chess databases are files on disk, so the web variant keeps the same
// names and refuses to open anything; see resqlite_web.dart.
export 'package:resqlite/resqlite.dart'
    if (dart.library.js_interop) 'resqlite_web.dart';
