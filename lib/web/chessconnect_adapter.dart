// `window.chessconnectAdapter` (Chessconnect Adapter API v1) in the web
// build. Native builds have no page for Chessconnect to read, so the stub does
// nothing. The shared rules live in
// `lib/desktop/services/chessconnect/chessconnect_bridge.dart`.
export 'package:chessever/web/chessconnect_adapter_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/chessconnect_adapter_web.dart';
