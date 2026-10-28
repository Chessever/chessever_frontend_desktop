// Native builds get real isolates; the browser build (no isolates under
// dart2wasm) runs the same worker code in-process.
export 'dart:isolate'
    if (dart.library.js_interop) 'package:chessever/web/shims/isolate_web.dart';
