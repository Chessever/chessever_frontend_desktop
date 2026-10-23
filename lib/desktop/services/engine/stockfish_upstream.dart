// `package:stockfish` drives the in-process mobile engine through FFI, which
// the web build cannot import. The web variant keeps the same names so the
// facade compiles unchanged; it never starts an engine.
export 'package:stockfish/stockfish.dart'
    if (dart.library.js_interop) 'stockfish_upstream_web.dart';
