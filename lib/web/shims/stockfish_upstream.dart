// Native builds get the real engine package; the web build gets a stand-in
// that reports an engine error, since the browser cannot load the FFI engine.
export 'package:stockfish/stockfish.dart'
    if (dart.library.js_interop) 'package:chessever/web/shims/stockfish_upstream_web.dart';
