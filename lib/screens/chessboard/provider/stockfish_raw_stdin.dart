// The in-process mobile engine is written to through FFI, which the web build
// cannot import. The web variant has no in-process engine to write to.
export 'stockfish_raw_stdin_io.dart'
    if (dart.library.js_interop) 'stockfish_raw_stdin_web.dart';
