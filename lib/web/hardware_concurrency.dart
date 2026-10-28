// Logical processor count reported by the browser; null in native builds,
// which read Platform.numberOfProcessors instead.
export 'package:chessever/web/hardware_concurrency_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/hardware_concurrency_web.dart';
