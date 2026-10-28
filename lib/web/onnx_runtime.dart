// Loads onnxruntime-web on demand in the browser build; native builds use
// flutter_onnxruntime's bundled runtime and never call this.
export 'package:chessever/web/onnx_runtime_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/onnx_runtime_web.dart';
